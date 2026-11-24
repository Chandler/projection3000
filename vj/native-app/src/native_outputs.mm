#import "native_outputs.hpp"
#import "preview.hpp"
#import "native_style.hpp"
#include "native_async.hpp"
#import <CoreGraphics/CoreGraphics.h>
#include "movie_policy.hpp"
#include <chrono>
#include <map>
using vj::Json;
namespace {
NSString* str(const std::string& value){return [NSString stringWithUTF8String:value.c_str()]?:@"";}
std::string displayKey(NSScreen* screen){
    auto display=static_cast<CGDirectDisplayID>([screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue]);
    CFUUIDRef uuid=CGDisplayCreateUUIDFromDisplayID(display);if(!uuid)return std::to_string(display);
    CFStringRef value=CFUUIDCreateString(nullptr,uuid);NSString* text=CFBridgingRelease(value);CFRelease(uuid);return text.UTF8String;
}
struct MovieDisplay {
 CGDirectDisplayID display=0;CGDisplayModeRef original=nullptr;
 bool active=false,attempted=false;double fps=0;std::string error;
 std::chrono::steady_clock::time_point candidate;
 ~MovieDisplay(){if(original)CGDisplayModeRelease(original);}
};
CGDisplayModeRef movieDisplayMode(CGDirectDisplayID display,CGDisplayModeRef current){
 auto modes=CGDisplayCopyAllDisplayModes(display,nullptr);if(!modes||!current){if(modes)CFRelease(modes);return nullptr;}CGDisplayModeRef selected=nullptr;double distance=INFINITY;
 for(CFIndex i=0;i<CFArrayGetCount(modes);i++){auto mode=(CGDisplayModeRef)CFArrayGetValueAtIndex(modes,i);double rate=CGDisplayModeGetRefreshRate(mode);
  if(vj::movieDisplayModeMatches(CGDisplayModeGetWidth(mode),CGDisplayModeGetHeight(mode),CGDisplayModeGetPixelWidth(mode),CGDisplayModeGetPixelHeight(mode),rate,CGDisplayModeGetWidth(current),CGDisplayModeGetHeight(current),CGDisplayModeGetPixelWidth(current),CGDisplayModeGetPixelHeight(current))&&std::abs(rate-24.)<distance){selected=mode;distance=std::abs(rate-24.);}}
 if(selected)CGDisplayModeRetain(selected);CFRelease(modes);return selected;
}
NSStackView* stack(NSUserInterfaceLayoutOrientation orientation){return vj::style::stack(orientation);}
}
@interface VJOutputContent : NSView @end
@implementation VJOutputContent
- (void)drawRect:(NSRect)rect {(void)rect;[vj::style::panel()setFill];NSRectFill(self.bounds);}
@end
@interface VJOutputSheet : NSWindow
@property(copy) void (^dismiss)(void);
@end
@implementation VJOutputSheet
- (void)cancelOperation:(id)sender {(void)sender;if(self.dismiss)self.dismiss();}
- (void)performClose:(id)sender {(void)sender;if(self.dismiss)self.dismiss();}
@end
@interface VJOutputRow : NSStackView {
@public
    NSPopUpButton* display;
    NSButton* enabled;
    NSTextField* status;
    NSButton* ndiEnabled;
    NSTextField* ndiName;
    NSTextField* ndiWidth;
    NSTextField* ndiHeight;
    NSTextField* ndiFps;
    NSTextField* ndiStatus;
    NSButton* assign;
}
@end
@implementation VJOutputRow
@end
@implementation VJOutputs {
    vj::Model* _model;
    BOOL _allow,_stopped,_refreshing;
    std::map<std::string,std::shared_ptr<MovieDisplay>> _movies;
    std::chrono::steady_clock::time_point _started;
    NSMutableDictionary<NSString*,NSWindow*>* _windows;
    NSMutableDictionary<NSString*,NSString*>* _targets;
    NSWindow* _sheet;
    VJOutputSheet* _previewWindow;
    NSMutableDictionary<NSString*,VJPreview*>* _localPreviews;
    NSStackView* _previewColumns;
    NSMutableArray<VJOutputRow*>* _rows;
    NSTextField* _error;
    NSMutableArray<NSStackView*>* _panels;NSStackView* _projectorTabs;NSInteger _selectedProjector;
}
- (instancetype)initWithModel:(vj::Model*)model allowOutputs:(BOOL)allow {
    if((self=[super init])){_model=model;_allow=allow;_started=std::chrono::steady_clock::now();_windows=[NSMutableDictionary dictionary];_targets=[NSMutableDictionary dictionary];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(screenChanged:) name:NSApplicationDidChangeScreenParametersNotification object:nil];[self refresh];}
    return self;
}
- (void)screenChanged:(NSNotification*)notification {(void)notification;[self refresh];if(_sheet)[self updateSheet];}
- (void)closeProjector:(NSString*)mid {
    [self restoreMovie:mid];NSWindow* window=_windows[mid];if(!window)return;
    [(VJPreview*)window.contentView stop];[window orderOut:nil];[window close];[_windows removeObjectForKey:mid];[_targets removeObjectForKey:mid];
}
- (void)restoreMovie:(NSString*)mid {
 auto key=std::string(mid.UTF8String);auto found=_movies.find(key);if(found==_movies.end())return;auto mode=found->second;auto view=(VJPreview*)_windows[mid].contentView;
 if(mode->active&&mode->original){[view setMediaClockSuspended:YES];auto result=CGDisplaySetDisplayMode(mode->display,mode->original,nullptr);[view setMediaClockSuspended:NO];if(result!=kCGErrorSuccess){mode->error="Display mode restore failed ("+std::to_string(result)+")";[view setPresentationFPS:0];return;}}
 [view setPresentationFPS:0];_movies.erase(found);
}
- (Json)movieStatus:(NSString*)mid screen:(NSScreen*)screen snapshot:(const Json&)snapshot {
 auto key=std::string(mid.UTF8String);auto view=(VJPreview*)_windows[mid].contentView;const bool requested=snapshot["state"].value("mix",Json::object()).value("movie_mode",false);
 bool eligible=_allow&&requested&&view&&snapshot["mappings"].contains(key)&&vj::movieMappingEligible(snapshot["mappings"][key]["project"])&&snapshot.value("calibration",Json::object()).value("outputs",Json::object()).empty();
 double fps=eligible?[view movieFrameRate]:0;Json status={{"requested",requested},{"active",false},{"sourceFps",fps},{"error",""}};
 if(fps<=0){[self restoreMovie:mid];auto failed=_movies.find(key);if(failed!=_movies.end()){status["active"]=failed->second->active;status["error"]=failed->second->error;}return status;}
 auto& mode=_movies[key];auto now=std::chrono::steady_clock::now();if(!mode){mode=std::make_shared<MovieDisplay>();mode->candidate=now;mode->fps=fps;mode->display=[screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];}
 if(std::abs(mode->fps-fps)>.001){mode->candidate=now;mode->fps=fps;mode->attempted=false;}
 if(!mode->active&&!mode->attempted&&vj::movieModeStable(std::chrono::duration<double>(now-_started).count(),std::chrono::duration<double>(now-mode->candidate).count())){
  mode->attempted=true;if(mode->original)CGDisplayModeRelease(mode->original);mode->original=CGDisplayCopyDisplayMode(mode->display);auto selected=movieDisplayMode(mode->display,mode->original);
  if(!selected)mode->error="No matching 24 Hz display mode";
  else{[view setMediaClockSuspended:YES];auto result=CGDisplaySetDisplayMode(mode->display,selected,nullptr);[view setMediaClockSuspended:NO];if(result==kCGErrorSuccess){mode->active=true;mode->error.clear();}else mode->error="Display mode change failed ("+std::to_string(result)+")";CGDisplayModeRelease(selected);}
 }
 if(mode->active)[view setPresentationFPS:fps];status["active"]=mode->active;status["refreshRate"]=mode->active?24:0;status["error"]=mode->error;return status;
}
- (void)showPreviewForWindow:(NSWindow*)parent {
    if(_stopped)return;
    if(_previewWindow){[_previewWindow makeKeyAndOrderFront:nil];return;}
    auto screen=parent.screen?:NSScreen.mainScreen;auto available=screen.visibleFrame;
    auto window=[[VJOutputSheet alloc]initWithContentRect:NSMakeRect(0,0,std::min(1440.,available.size.width-60),420) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    _previewWindow=window;window.releasedWhenClosed=NO;window.title=@"Projector preview";window.minSize=NSMakeSize(680,220);window.backgroundColor=NSColor.blackColor;window.appearance=[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    window.collectionBehavior=NSWindowCollectionBehaviorFullScreenPrimary;
    __weak VJOutputs* weak=self;window.dismiss=^{[weak closePreview];};
    _localPreviews=[NSMutableDictionary dictionary];
    _previewColumns=stack(NSUserInterfaceLayoutOrientationHorizontal);_previewColumns.spacing=8;_previewColumns.distribution=NSStackViewDistributionFillEqually;_previewColumns.alignment=NSLayoutAttributeTop;_previewColumns.edgeInsets=NSEdgeInsetsMake(8,8,8,8);_previewColumns.translatesAutoresizingMaskIntoConstraints=NO;
    [window.contentView addSubview:_previewColumns];
    [NSLayoutConstraint activateConstraints:@[[_previewColumns.leadingAnchor constraintEqualToAnchor:window.contentView.leadingAnchor],[_previewColumns.trailingAnchor constraintEqualToAnchor:window.contentView.trailingAnchor],[_previewColumns.topAnchor constraintEqualToAnchor:window.contentView.topAnchor],[_previewColumns.bottomAnchor constraintEqualToAnchor:window.contentView.bottomAnchor]]];
    [self refreshPreview:_model->presentationSnapshot()];
    [window center];[window setFrameAutosaveName:@"VJProjectorPreview"];[window makeKeyAndOrderFront:nil];
}
- (void)closePreview {
    for(VJPreview* view in _localPreviews.allValues)[view stop];
    _localPreviews=nil;_previewColumns=nil;auto window=_previewWindow;_previewWindow=nil;window.dismiss=nil;[window close];
}
- (void)refreshPreview:(const Json&)snapshot {
    if(!_previewWindow)return;
    NSMutableSet<NSString*>* alive=[NSMutableSet set];
    for(auto it=snapshot["mappings"].begin();it!=snapshot["mappings"].end();++it){
        NSString* mid=str(it.key());[alive addObject:mid];auto view=_localPreviews[mid];
        if(!view){
            auto column=stack(NSUserInterfaceLayoutOrientationVertical);column.identifier=mid;column.spacing=6;
            auto title=vj::style::label([@"Projector " stringByAppendingString:mid],NO);title.alignment=NSTextAlignmentCenter;[column addArrangedSubview:title];
            view=[[VJPreview alloc]initWithFrame:NSMakeRect(0,0,320,180) model:_model];[view setMapping:mid];[view setSingleMonitor:YES];[view setIgnoreOutputRotation:YES];[column addArrangedSubview:view];
            [_previewColumns addArrangedSubview:column];
            [NSLayoutConstraint activateConstraints:@[[column.heightAnchor constraintEqualToAnchor:_previewColumns.heightAnchor constant:-16],[title.widthAnchor constraintEqualToAnchor:column.widthAnchor],[title.heightAnchor constraintEqualToConstant:24],[view.widthAnchor constraintEqualToAnchor:column.widthAnchor],[view.heightAnchor constraintGreaterThanOrEqualToConstant:80]]];
            [view setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationVertical];_localPreviews[mid]=view;
        }
        // Show the logical canvas upright, with the physical output's rotation
        // removed from both the image and its aspect. Display routing is unchanged.
        auto config=snapshot["state"].value("ndi_projectors",Json::object()).value(it.key(),Json::object());
        double aspect=double(config.value("width",1280))/std::max(1,config.value("height",720));
        auto display=snapshot["state"].value("output_status",Json::object()).value("projectors",Json::object()).value(it.key(),Json::object()).value("display",Json::object());
        if(display.value("active",false))for(const auto& screen:snapshot["state"]["output_status"].value("displays",Json::array()))if(screen.value("displayId",std::string{})==display.value("displayId",std::string{}))aspect=double(screen.value("width",1280))/std::max(1,screen.value("height",720));
        const int rotation=it.value()["project"].value("output",Json::object()).value("rotation",0);
        if(rotation==90||rotation==270)aspect=1/aspect;
        double width=std::clamp([view convertRectToBacking:view.bounds].size.width,640.,1920.);
        [view setOutputSize:NSMakeSize(width,std::clamp(width/aspect,32.,2160.))];
    }
    for(NSString* mid in [_localPreviews.allKeys copy])if(![alive containsObject:mid]){auto view=_localPreviews[mid];[view stop];auto column=view.superview;[_previewColumns removeArrangedSubview:column];[column removeFromSuperview];[_localPreviews removeObjectForKey:mid];}
}
- (void)refresh {
    if(_stopped||_refreshing)return;_refreshing=YES;struct Reset{BOOL& value;~Reset(){value=NO;}} reset{_refreshing};
    auto sharedSnapshot=_model->presentationSnapshotShared();const auto& snapshot=*sharedSnapshot;
    [self refreshPreview:snapshot];
    const auto assignments=snapshot["state"].value("display_assignments",Json::object());
    Json runtime={{"physicalAvailable",true},{"rendererConnected",true},{"displays",Json::array()},{"projectors",Json::object()}};
    NSMutableDictionary<NSString*,NSScreen*>* screens=[NSMutableDictionary dictionary];
    int index=0;for(NSScreen* screen in NSScreen.screens){
        const auto key=displayKey(screen);screens[str(key)]=screen;
        auto size=[screen convertRectToBacking:NSMakeRect(0,0,screen.frame.size.width,screen.frame.size.height)].size;
        runtime["displays"].push_back({{"displayId",key},{"physical",index++},{"name",screen.localizedName.UTF8String?:"Display"},{"width",int(size.width)},{"height",int(size.height)}});
    }
    for(int i=1;i<=4;++i){
        const auto mid=std::to_string(i);NSString* key=str(mid);
        auto config=assignments.value(mid,Json::object());const auto target=config.value("displayId",std::string{});
        const bool requested=config.value("enabled",false);NSScreen* screen=screens[str(target)];
        Json status={{"active",false},{"displayId",target},{"error",""}};
        if(!requested||!_allow||!screen){[self closeProjector:key];if(requested)status["error"]=_allow?"Display disconnected":"Outputs suppressed during interface check";}
        else try{
            if(_windows[key]&&![_targets[key] isEqualToString:str(target)])[self closeProjector:key];
            if(!_windows[key]){
                auto window=[[NSWindow alloc] initWithContentRect:screen.frame styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO screen:screen];
                window.releasedWhenClosed=NO;window.title=[@"VJ Projector " stringByAppendingString:key];window.backgroundColor=NSColor.blackColor;
                window.level=[screen.deviceDescription[@"NSScreenNumber"]unsignedIntValue]==CGMainDisplayID()?NSNormalWindowLevel:NSMainMenuWindowLevel+1;window.ignoresMouseEvents=YES;window.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorStationary|NSWindowCollectionBehaviorIgnoresCycle|NSWindowCollectionBehaviorFullScreenAuxiliary;
                auto view=[[VJPreview alloc] initWithFrame:NSMakeRect(0,0,screen.frame.size.width,screen.frame.size.height) model:_model];
                [view setMapping:key];[view setPhysicalOutput:YES];window.contentView=view;_windows[key]=window;_targets[key]=str(target);
            }
            auto window=_windows[key];window.level=[screen.deviceDescription[@"NSScreenNumber"]unsignedIntValue]==CGMainDisplayID()?NSNormalWindowLevel:NSMainMenuWindowLevel+1;[window setFrame:screen.frame display:NO];
            auto size=[screen convertRectToBacking:NSMakeRect(0,0,screen.frame.size.width,screen.frame.size.height)].size;
            [(VJPreview*)window.contentView setOutputSize:size];if(!window.isVisible)[window orderFront:nil];status["active"]=true;
        }catch(const std::exception& error){[self closeProjector:key];status["error"]=error.what();}
        if(status.value("active",false))status["movieMode"]=[self movieStatus:key screen:screen snapshot:snapshot];
        else if(auto failed=_movies.find(mid);failed!=_movies.end())status["movieMode"]={{"active",failed->second->active},{"error",failed->second->error}};
        if(_sheet&&i<=int(_rows.count)){auto row=_rows[i-1];auto movie=status.value("movieMode",Json::object());row->status.stringValue=movie.value("active",false)?@"Movie 24 Hz":status.value("active",false)?@"Active":requested?@"Unavailable":@"Off";row->status.toolTip=str(movie.value("error",status.value("error",std::string{})));}
        runtime["projectors"][mid]={{"display",status}};
    }
    VJPublishUiOutputRuntime(_model,runtime);
    if(_sheet)for(int i=1;i<=4;++i){auto status=snapshot["state"]["output_status"]["projectors"].value(std::to_string(i),Json::object()).value("ndi",Json::object());_rows[i-1]->ndiStatus.stringValue=str(status.value("status",std::string("disabled")));_rows[i-1]->ndiStatus.toolTip=str(status.value("error",std::string{}));}
}
- (void)showForWindow:(NSWindow*)parent {[self showForWindow:parent projector:@"1"];}
- (void)showForWindow:(NSWindow*)parent projector:(NSString*)mid {
    _selectedProjector=std::clamp(mid.integerValue,NSInteger(1),NSInteger(4));if(_sheet){[self selectProjector:nil];[_sheet orderFront:nil];return;}
    auto sheet=[[VJOutputSheet alloc]initWithContentRect:NSMakeRect(0,0,620,510) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];_sheet=sheet;sheet.contentView=[[VJOutputContent alloc]initWithFrame:NSMakeRect(0,0,620,510)];sheet.releasedWhenClosed=NO;sheet.title=@"Assign projector";sheet.backgroundColor=vj::style::panel();__weak VJOutputs* weak=self;sheet.dismiss=^{[weak done:nil];};
    auto root=stack(NSUserInterfaceLayoutOrientationVertical);root.edgeInsets=NSEdgeInsetsMake(16,16,16,16);root.translatesAutoresizingMaskIntoConstraints=NO;[_sheet.contentView addSubview:root];[NSLayoutConstraint activateConstraints:@[[root.leadingAnchor constraintEqualToAnchor:_sheet.contentView.leadingAnchor],[root.trailingAnchor constraintEqualToAnchor:_sheet.contentView.trailingAnchor],[root.topAnchor constraintEqualToAnchor:_sheet.contentView.topAnchor],[root.bottomAnchor constraintEqualToAnchor:_sheet.contentView.bottomAnchor]]];
    auto wide=[&](NSView* view,NSStackView* parent){[parent addArrangedSubview:view];[view.widthAnchor constraintEqualToAnchor:parent.widthAnchor constant:(parent==root?-36:0)].active=YES;};
    auto heading=[&](NSString* name,NSStackView* parent){auto title=[NSTextField labelWithString:name];title.font=vj::style::headingFont();[parent addArrangedSubview:title];[title.heightAnchor constraintEqualToConstant:24].active=YES;};
    _projectorTabs=stack(NSUserInterfaceLayoutOrientationHorizontal);_projectorTabs.spacing=1;wide(_projectorTabs,root);for(int i=1;i<=4;++i){auto tab=[NSButton buttonWithTitle:[NSString stringWithFormat:@"Projector %d",i] target:self action:@selector(selectProjector:)];tab.tag=i;tab.identifier=[NSString stringWithFormat:@"tab-output-%d",i];tab.buttonType=NSButtonTypePushOnPushOff;[_projectorTabs addArrangedSubview:tab];[tab.widthAnchor constraintEqualToConstant:141].active=YES;[tab.heightAnchor constraintEqualToConstant:34].active=YES;}
    _rows=[NSMutableArray array];_panels=[NSMutableArray array];
    for(int i=1;i<=4;++i){auto panel=stack(NSUserInterfaceLayoutOrientationVertical);panel.spacing=10;wide(panel,root);[_panels addObject:panel];auto row=[[VJOutputRow alloc]init];row.orientation=NSUserInterfaceLayoutOrientationHorizontal;row.alignment=NSLayoutAttributeCenterY;row.spacing=10;[_rows addObject:row];
        heading(@"Connected display",panel);row->display=[[VJPopup alloc]initWithFrame:NSZeroRect pullsDown:NO];[row addArrangedSubview:row->display];[row->display.widthAnchor constraintEqualToConstant:414].active=YES;[row->display.heightAnchor constraintEqualToConstant:vj::style::controlHeight].active=YES;
        row->enabled=[NSButton checkboxWithTitle:@"Enabled" target:nil action:nil];row->assign=[NSButton buttonWithTitle:@"Assign display" target:self action:@selector(apply:)];row->assign.tag=i;[row addArrangedSubview:row->assign];[row->assign.widthAnchor constraintEqualToConstant:154].active=YES;[row->assign.heightAnchor constraintEqualToConstant:vj::style::controlHeight].active=YES;wide(row,panel);
        row->status=[NSTextField labelWithString:@"Off"];wide(row->status,panel);[row->status.heightAnchor constraintEqualToConstant:22].active=YES;
        auto divider=[[NSBox alloc]init];divider.boxType=NSBoxSeparator;wide(divider,panel);heading(@"NDI output",panel);
        row->ndiEnabled=[NSButton checkboxWithTitle:@"Publish NDI" target:nil action:nil];[row->ndiEnabled.widthAnchor constraintEqualToConstant:160].active=YES;[row->ndiEnabled.heightAnchor constraintEqualToConstant:vj::style::controlHeight].active=YES;[panel addArrangedSubview:row->ndiEnabled];
        auto fieldRow=[&](NSString* name,CGFloat width){auto line=vj::style::propertyRow(name,vj::style::inspectorLabel);auto field=[[NSTextField alloc]init];[field.widthAnchor constraintEqualToConstant:width].active=YES;[field.heightAnchor constraintEqualToConstant:vj::style::controlHeight].active=YES;[line addArrangedSubview:field];wide(line,panel);return std::make_pair(line,field);};
        row->ndiName=fieldRow(@"Stream name",480).second;auto resolution=fieldRow(@"Resolution",96);row->ndiWidth=resolution.second;[resolution.first addArrangedSubview:[NSTextField labelWithString:@"×"]];row->ndiHeight=[[NSTextField alloc]init];[row->ndiHeight.widthAnchor constraintEqualToConstant:96].active=YES;[row->ndiHeight.heightAnchor constraintEqualToConstant:vj::style::controlHeight].active=YES;[resolution.first addArrangedSubview:row->ndiHeight];[resolution.first addArrangedSubview:[NSTextField labelWithString:@"FPS"]];row->ndiFps=[[NSTextField alloc]init];[row->ndiFps.widthAnchor constraintEqualToConstant:70].active=YES;[row->ndiFps.heightAnchor constraintEqualToConstant:vj::style::controlHeight].active=YES;[resolution.first addArrangedSubview:row->ndiFps];
        auto ndiActions=stack(NSUserInterfaceLayoutOrientationHorizontal);auto apply=[NSButton buttonWithTitle:@"Apply NDI" target:self action:@selector(applyNdi:)];apply.tag=i;[apply.widthAnchor constraintEqualToConstant:120].active=YES;[apply.heightAnchor constraintEqualToConstant:vj::style::controlHeight].active=YES;[ndiActions addArrangedSubview:apply];row->ndiStatus=[NSTextField labelWithString:@"Off"];[ndiActions addArrangedSubview:row->ndiStatus];wide(ndiActions,panel);
    }
    _error=[NSTextField labelWithString:@""];wide(_error,root);[_error.heightAnchor constraintEqualToConstant:22].active=YES;auto spacer=[[NSView alloc]init];[root addArrangedSubview:spacer];[spacer.heightAnchor constraintGreaterThanOrEqualToConstant:0].active=YES;[spacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationVertical];auto close=[NSButton buttonWithTitle:@"Done" target:self action:@selector(done:)];close.keyEquivalent=@"\e";[close.widthAnchor constraintEqualToConstant:100].active=YES;[close.heightAnchor constraintEqualToConstant:vj::style::controlHeight].active=YES;[root addArrangedSubview:close];
    [self selectProjector:nil];[self updateSheet];vj::style::apply(root);_error.textColor=NSColor.systemRedColor;[parent beginSheet:_sheet completionHandler:nil];
}
- (void)selectProjector:(NSButton*)sender {if(sender)_selectedProjector=sender.tag;for(NSInteger i=0;i<NSInteger(_panels.count);i++)_panels[i].hidden=i+1!=_selectedProjector;for(NSButton* tab in _projectorTabs.arrangedSubviews)tab.state=tab.tag==_selectedProjector?NSControlStateValueOn:NSControlStateValueOff;_sheet.title=[NSString stringWithFormat:@"Assign Projector %ld",(long)_selectedProjector];}
- (void)updateSheet {
    if(!_sheet)return;auto state=_model->presentationSnapshot()["state"];
    const auto assignments=state.value("display_assignments",Json::object());
    const auto network=state.value("ndi_projectors",Json::object());
    for(int i=1;i<=4;++i){auto row=_rows[i-1];auto config=assignments.value(std::to_string(i),Json::object());auto selected=config.value("displayId",std::string{});
        [row->display removeAllItems];[row->display addItemWithTitle:@"No display"];row->display.lastItem.representedObject=@"";
        for(NSScreen* screen in NSScreen.screens){auto size=[screen convertRectToBacking:NSMakeRect(0,0,screen.frame.size.width,screen.frame.size.height)].size;[row->display addItemWithTitle:[NSString stringWithFormat:@"%@ · %.0f × %.0f%@",screen.localizedName,size.width,size.height,screen==NSScreen.mainScreen?@" · Main":@""]];row->display.lastItem.representedObject=str(displayKey(screen));}
        NSInteger chosen=0;for(NSMenuItem* item in row->display.itemArray)if([item.representedObject isEqual:str(selected)])chosen=[row->display indexOfItem:item];
        if(!selected.empty()&&chosen==0){[row->display addItemWithTitle:@"Disconnected display"];row->display.lastItem.representedObject=str(selected);chosen=row->display.numberOfItems-1;}
        [row->display selectItemAtIndex:chosen];row->enabled.state=config.value("enabled",false)?NSControlStateValueOn:NSControlStateValueOff;
        row->status.stringValue=_windows[str(std::to_string(i))]?@"Active":config.value("enabled",false)?@"Unavailable":@"Off";
        const auto ndi=network.value(std::to_string(i),Json::object());row->ndiEnabled.state=ndi.value("enabled",false)?NSControlStateValueOn:NSControlStateValueOff;row->ndiName.stringValue=str(ndi.value("name",std::string("Vibe Projector ")+std::to_string(i)));row->ndiWidth.integerValue=ndi.value("width",1280);row->ndiHeight.integerValue=ndi.value("height",720);row->ndiFps.integerValue=ndi.value("fps",30);
    }
}
- (void)applyNdi:(NSButton*)sender {
    auto projectors=_model->presentationSnapshot()["state"].value("ndi_projectors",Json::object());auto row=_rows[sender.tag-1];
    projectors[std::to_string(sender.tag)]={{"enabled",row->ndiEnabled.state==NSControlStateValueOn},{"name",row->ndiName.stringValue.UTF8String},{"width",row->ndiWidth.integerValue},{"height",row->ndiHeight.integerValue},{"fps",row->ndiFps.integerValue}};
    __weak VJOutputs* weak=self;VJSubmitUiCommand(_model,"PUT","/api/v1/ndi/projectors",projectors,^(const vj::Reply& result){VJOutputs* owner=weak;if(!owner||owner->_stopped)return;owner->_error.stringValue=result.status==200?@"":str(result.body.value("error",std::string("NDI update failed")));if(result.status==200)[owner updateSheet];});
}
- (void)apply:(NSButton*)sender {
    auto assignments=_model->presentationSnapshot()["state"].value("display_assignments",Json::object());auto row=_rows[sender.tag-1];NSString* selected=row->display.selectedItem.representedObject;
    assignments[std::to_string(sender.tag)]={{"displayId",selected.UTF8String?:""},{"enabled",selected.length>0}};
    Json command={{"assignments",assignments}};if(selected.length)command["activate"]=std::to_string(sender.tag);
    __weak VJOutputs* weak=self;VJSubmitUiCommand(_model,"PUT","/api/v1/display-assignments",command,^(const vj::Reply& result){VJOutputs* owner=weak;if(!owner||owner->_stopped)return;owner->_error.stringValue=result.status==200?@"":str(result.body.value("error",std::string("Output update failed")));[owner refresh];[owner updateSheet];});
}
- (void)done:(id)sender {(void)sender;[_sheet.sheetParent endSheet:_sheet];[_sheet orderOut:nil];_sheet=nil;_rows=nil;_panels=nil;_projectorTabs=nil;}
- (Json)checkAssignment:(NSWindow*)parent {
    Json checks=Json::object();[self showForWindow:parent projector:@"2"];[_sheet.contentView layoutSubtreeIfNeeded];checks["Projector assignment opens selected mapping"]=_selectedProjector==2&&!_panels[1].hidden&&_panels[0].hidden;
    checks["Assignment fixture disables mapping"]=_model->request("PATCH","/api/v1/mappings/2/output",{{"enabled",false},{"revision",_model->snapshot()["mappings"]["2"]["revision"]}}).status==200;auto row=_rows[1];checks["Projector assignment lists connected displays"]=row->display.numberOfItems>1;[row->display selectItemAtIndex:1];NSString* selected=row->display.selectedItem.representedObject;[row->assign performClick:nil];auto until=[NSDate dateWithTimeIntervalSinceNow:3];while(until.timeIntervalSinceNow>0){[[NSRunLoop mainRunLoop]runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]];auto state=_model->snapshot()["state"].value("display_assignments",Json::object()).value("2",Json::object());if(state.value("displayId",std::string{})==std::string(selected.UTF8String)&&state.value("enabled",false))break;}
    auto assigned=_model->snapshot()["state"]["display_assignments"].value("2",Json::object());checks["Assign display enables selected projector route"]=assigned.value("enabled",false)&&assigned.value("displayId",std::string{})==std::string(selected.UTF8String);checks["Assign display enables a previously disabled mapping"]=_model->snapshot()["mappings"]["2"]["project"]["output"]["enabled"]==true;checks["Assignment check keeps physical windows closed"]=_windows.count==0;
    if(auto directory=getenv("VJ_UI_CAPTURE_DIR")){[_sheet.contentView layoutSubtreeIfNeeded];auto view=_sheet.contentView;auto bitmap=[view bitmapImageRepForCachingDisplayInRect:view.bounds];[view cacheDisplayInRect:view.bounds toBitmapImageRep:bitmap];[[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}]writeToFile:[str(directory)stringByAppendingPathComponent:@"projector-assignment.png"] atomically:YES];}
    [row->display selectItemAtIndex:0];[row->assign performClick:nil];until=[NSDate dateWithTimeIntervalSinceNow:3];while(until.timeIntervalSinceNow>0){[[NSRunLoop mainRunLoop]runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]];if(!_model->snapshot()["state"]["display_assignments"]["2"].value("enabled",true))break;}checks["No display removes physical assignment"] = !_model->snapshot()["state"]["display_assignments"]["2"].value("enabled",true);
    [_sheet cancelOperation:nil];checks["Projector assignment Escape closes sheet"]=_sheet==nil;[self showForWindow:parent projector:@"1"];[_sheet performClose:nil];checks["Projector assignment window close works"]=_sheet==nil;return checks;
}
- (void)stop {if(_stopped)return;_stopped=YES;[self closePreview];[[NSNotificationCenter defaultCenter] removeObserver:self];for(NSString* mid in [_windows.allKeys copy])[self closeProjector:mid];if(_sheet)[self done:nil];}
- (void)dealloc {[[NSNotificationCenter defaultCenter] removeObserver:self];}
@end
