#import "native_controls.hpp"
#include "native_async.hpp"
#import "native_midi.hpp"
#import "native_widgets.hpp"
#import "native_style.hpp"
#import "preview.hpp"
#include "control_model.hpp"
#include <map>
using vj::Json;
static NSString* text(const std::string& value){return [NSString stringWithUTF8String:value.c_str()];}
static NSStackView* stack(NSUserInterfaceLayoutOrientation orientation){return vj::style::stack(orientation);}
static NSTextField* label(NSString* value){return vj::style::label(value);}
@interface VJControlsStack : NSStackView @end
@implementation VJControlsStack
- (BOOL)isFlipped {return YES;}
@end
@interface VJControlField : NSTextField { @public Json command;std::string path,key;double scale,step; }
@end
@implementation VJControlField
- (instancetype)initWithFrame:(NSRect)frame {if((self=[super initWithFrame:frame]))scale=1;return self;}
@end
@interface VJControlSlider : NSSlider { @public Json command;std::string path,key;bool* tracking;double step; }
@end
@implementation VJControlSlider
- (void)mouseDown:(NSEvent*)event {if(tracking)*tracking=true;[super mouseDown:event];if(tracking)*tracking=false;}
@end
@interface VJControlButton : NSButton { @public Json command;std::string path,key; }
@end
@implementation VJControlButton
@end
@interface VJControlSwatch : VJControlButton
@property(nonatomic,strong) NSColor* swatchColor;
@end
@implementation VJControlSwatch
- (void)drawRect:(NSRect)dirty { [self.swatchColor setFill];NSRectFill(NSInsetRect(self.bounds,2,2));[(self.state==NSControlStateValueOn?vj::style::accent():vj::style::border()) setStroke];NSBezierPath* border=[NSBezierPath bezierPathWithRect:NSInsetRect(self.bounds,1,1)];border.lineWidth=2;[border stroke];if(self.isHighlighted){[[NSColor colorWithWhite:1 alpha:.2] setFill];NSRectFill(self.bounds);} }
@end
@interface VJControlPopup : VJPopup { @public Json command;std::string path,key;std::vector<Json> values;bool* tracking; }
@end
@implementation VJControlPopup
- (void)mouseDown:(NSEvent*)event {if(tracking)*tracking=true;[super mouseDown:event];if(tracking)*tracking=false;}
@end
@interface VJControlDial : VJRotary { @public std::string key; }
@end
@implementation VJControlDial @end
@implementation VJControls {
    vj::Model* _model;
    NSStackView* _sections;
    NSLayoutConstraint* _documentWidth;
    NSScrollView* _scroll;
    NSStackView* _content;
    NSTextField* _status;
    NSInteger _page;
    NSInteger _renderedPage;
    uint64_t _revision;
    uint64_t _runtimeRevision;
    unsigned _changing;
    bool _tracking;
    bool _apcView,_apcClaimed;
    std::string _selectedFixture;NSTextField* _motionTarget;NSColorWell* _rgb;
    dispatch_group_t _wledTasks;BOOL _wledScanning;Json _wledDiscovery;
    NSTimeInterval _apcAt;
    VJMidiControls* _midiView;VJPreview* _monitor;VJPositionPad* _xy;NSTextField* _channels;NSMutableDictionary<NSString*,VJRGBStrip*>* _strips;VJRGBStrip* _linkedStrip;NSArray<NSString*>* _linkedFixtureIds;vj::FrameTransport::Client _ledClient;std::string _runtimeShape;
}
- (instancetype)initWithFrame:(NSRect)frame model:(vj::Model*)model {
    if((self=[super initWithFrame:frame])){
        _model=model;_wledTasks=dispatch_group_create();_strips=[NSMutableDictionary dictionary];_revision=UINT64_MAX;_renderedPage=-1;_apcView=[NSUserDefaults.standardUserDefaults boolForKey:@"VJDMXAPCView"];
        _scroll=[[NSScrollView alloc]init];_scroll.hasVerticalScroller=YES;_scroll.drawsBackground=NO;_scroll.translatesAutoresizingMaskIntoConstraints=NO;
        _status=label(@"");_status.translatesAutoresizingMaskIntoConstraints=NO;_status.textColor=vj::style::secondary();
        [self addSubview:_scroll];[self addSubview:_status];
        [NSLayoutConstraint activateConstraints:@[[_scroll.topAnchor constraintEqualToAnchor:self.topAnchor],[_scroll.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],[_scroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],[_scroll.bottomAnchor constraintEqualToAnchor:_status.topAnchor constant:-4],[_status.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],[_status.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-4]]];
        [self refresh];
    }return self;
}
- (void)layout { [super layout];if(_documentWidth){CGFloat width=MIN(860,MAX(560,_scroll.contentView.bounds.size.width));if(fabs(_documentWidth.constant-width)>.5)_documentWidth.constant=width;} }
- (void)controllerLease {
    if(!_model)return;
    const bool active=_page==2&&_apcView&&![self isHiddenOrHasHiddenAncestor]&&self.window.isVisible;
    const auto now=NSDate.timeIntervalSinceReferenceDate;if(active==_apcClaimed&&(!active||now-_apcAt<1.))return;
    _apcClaimed=active;_apcAt=now;__weak VJControls* weak=self;VJSubmitUiCommand(_model,"POST","/api/v1/dmx",{{"apc_active",active}},^(const vj::Reply& reply){VJControls* owner=weak;if(owner&&reply.status>=400)owner->_apcAt=0;});
}
- (void)setHidden:(BOOL)hidden {if(hidden)[_rgb deactivate];[super setHidden:hidden];if(_model)[self controllerLease];}
- (void)viewDidMoveToWindow {[super viewDidMoveToWindow];if(_model)[self controllerLease];}
- (void)dmxViewChanged:(NSButton*)sender {_apcView=sender.tag==1;[NSUserDefaults.standardUserDefaults setBool:_apcView forKey:@"VJDMXAPCView"];_revision=UINT64_MAX;[self refresh];}
- (void)selectPage:(NSInteger)page {
    if(page==4)page=1;
    if(_page!=page)[_rgb deactivate];
    // Navigation ends editing normally, including editing in the shared top bar.
    // Otherwise AppKit can keep its field editor focused after a button click.
    [self.window makeFirstResponder:nil];
    BOOL changed=_page!=page;_page=page;
    if(changed){[_scroll.contentView scrollToPoint:NSZeroPoint];_revision=UINT64_MAX;}
    [self refresh];
}
- (NSStackView*)row:(NSString*)title {auto row=vj::style::propertyRow(title);[_content addArrangedSubview:row];[row.widthAnchor constraintEqualToAnchor:_content.widthAnchor constant:-24].active=YES;return row;}
- (void)heading:(NSString*)title {auto section=vj::style::section(title);[_sections addArrangedSubview:section];[section.widthAnchor constraintLessThanOrEqualToConstant:860].active=YES;auto width=[section.widthAnchor constraintEqualToAnchor:_sections.widthAnchor];width.priority=750;width.active=YES;_content=section;}
- (VJControlButton*)actionButton:(NSString*)title path:(std::string)path command:(Json)command {auto* b=[[VJControlButton alloc]init];b.bezelStyle=NSBezelStyleSmallSquare;b.title=title;b.target=self;b.action=@selector(pressed:);b->path=path;b->command=command;b.identifier=text(path+":"+command.dump());[b.heightAnchor constraintEqualToConstant:vj::style::controlHeight].active=YES;[b.widthAnchor constraintGreaterThanOrEqualToConstant:72].active=YES;return b;}
- (void)slider:(NSString*)title key:(std::string)key value:(double)value min:(double)minimum max:(double)maximum path:(std::string)path command:(Json)command {
    auto* row=[self row:title];auto* slider=[[VJControlSlider alloc]init];slider->key=key;slider->tracking=&_tracking;slider->path=path;slider->command=command;slider.identifier=text(path+":"+key);slider.accessibilityLabel=title;slider->step=command.contains("sync")?5:0;slider.minValue=minimum;slider.maxValue=maximum;slider.doubleValue=value;slider.continuous=YES;slider.target=self;slider.action=@selector(sliderChanged:);[slider.widthAnchor constraintGreaterThanOrEqualToConstant:180].active=YES;[slider.heightAnchor constraintEqualToConstant:vj::style::controlHeight].active=YES;[slider setContentHuggingPriority:200 forOrientation:NSLayoutConstraintOrientationHorizontal];[row addArrangedSubview:slider];
    auto* field=[[VJControlField alloc]init];field->key=key;field->path=path;field->command=command;field->scale=(_page==0&&(key=="video_master"||key=="led_master"||key=="cast_amount"))?100:1;field->step=slider->step;field.stringValue=field->scale==100?[NSString stringWithFormat:@"%.0f%%",value*100]:command.contains("sync")?[NSString stringWithFormat:value>0?@"%+.0f":@"%.0f",value]:[NSString stringWithFormat:(key=="address"||key=="port")?@"%.0f":@"%.3g",value];field.identifier=slider.identifier;field.accessibilityLabel=title;field.target=self;field.action=@selector(fieldChanged:);[field.widthAnchor constraintEqualToConstant:64].active=YES;[field.heightAnchor constraintEqualToConstant:vj::style::controlHeight].active=YES;field.alignment=NSTextAlignmentRight;[row addArrangedSubview:field];
}
- (void)toggle:(NSString*)title key:(std::string)key value:(bool)value path:(std::string)path command:(Json)command {auto* row=[self row:title];auto* b=[[VJControlButton alloc]init];b.buttonType=NSButtonTypeSwitch;b.title=@"";b.accessibilityLabel=title;b.state=value?NSControlStateValueOn:NSControlStateValueOff;b.target=self;b.action=@selector(toggleChanged:);b->key=key;b->path=path;b->command=command;[b.widthAnchor constraintEqualToConstant:30].active=YES;[b.heightAnchor constraintEqualToConstant:vj::style::controlHeight].active=YES;[row addArrangedSubview:b];}
- (void)button:(NSString*)title path:(std::string)path command:(Json)command {[_content addArrangedSubview:[self actionButton:title path:path command:command]];}
- (void)choices:(NSString*)title key:(std::string)key value:(Json)value options:(std::vector<Json>)options path:(std::string)path command:(Json)command {auto* row=[self row:title];auto* popup=[[VJControlPopup alloc]initWithFrame:NSZeroRect pullsDown:NO];popup->key=key;popup->tracking=&_tracking;popup->path=path;popup->command=command;popup->values=options;popup.identifier=text(path+":"+key);popup.accessibilityLabel=title;for(auto& option:options){NSString* title=text(option.is_string()?option.get<std::string>():option.dump());if(path=="/api/v1/dmx"&&option.is_string()&&key!="serial"){auto value=option.get<std::string>();if(key=="program")title=value=="off"?@"Manual DMX":value=="sound"?@"Sound-active program 1":[@"Auto program " stringByAppendingString:title];else if(key=="strobe"&&value=="open")title=@"Steady";else title=[[title stringByReplacingOccurrencesOfString:@"_" withString:@" "]capitalizedString];}[popup addItemWithTitle:title];if(value==option)[popup selectItemAtIndex:popup.numberOfItems-1];}popup.target=self;popup.action=@selector(choiceChanged:);[popup.widthAnchor constraintEqualToConstant:260].active=YES;[popup.heightAnchor constraintEqualToConstant:vj::style::controlHeight].active=YES;[row addArrangedSubview:popup];}
- (void)stop {dispatch_group_wait(_wledTasks,DISPATCH_TIME_FOREVER);[_monitor stop];if(_ledClient&&_model)_model->frames().unsubscribeLeds(_ledClient);_ledClient=0;if(_model&&_apcClaimed)_model->request("POST","/api/v1/dmx",{{"apc_active",false}});_apcClaimed=false;_model=nullptr;}
- (void)scanWled:(id)sender {
    (void)sender;if(!_model||_wledScanning)return;_wledScanning=YES;_revision=UINT64_MAX;[self refresh];
    // Discovery has its own bounded worker; it never queues behind or blocks live controls.
    auto model=_model;
    dispatch_group_async(_wledTasks,dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        auto reply=model->request("POST","/api/v1/fixture-output/discover",Json::object());
        dispatch_async(dispatch_get_main_queue(),^{if(!self->_model)return;self->_wledScanning=NO;self->_wledDiscovery=reply.body;self->_revision=UINT64_MAX;[self refresh];});
    });
}
- (void)refresh {
    if(!_model)return;
    [self controllerLease];
    const bool visible=![self isHiddenOrHasHiddenAncestor]&&self.window.isVisible;bool wantLeds=visible&&(_page==0||_page==3);if(wantLeds&&!_ledClient)_ledClient=_model->frames().subscribeLeds();else if(!wantLeds&&_ledClient){_model->frames().unsubscribeLeds(_ledClient);_ledClient=0;}
    if(_ledClient)if(auto packet=_model->frames().takeLeds(_ledClient)){auto value=Json::parse(*packet,nullptr,false);if(value.is_object()){for(auto it=value["frames"].begin();it!=value["frames"].end();++it){auto bytes=[[NSData alloc]initWithBase64EncodedString:text(it.value()) options:0];_strips[text(it.key())].pixels=bytes;}if(_linkedStrip){NSMutableData* pixels=[NSMutableData data];for(NSString* fid in _linkedFixtureIds){auto key=std::string(fid.UTF8String);if(value["frames"].contains(key)){NSData* bytes=[[NSData alloc]initWithBase64EncodedString:text(value["frames"][key]) options:0];if(bytes)[pixels appendData:bytes];}}_linkedStrip.pixels=pixels;}}}
    const bool switchingPage=_renderedPage!=_page;
    if(_tracking||((_changing||_rgb.isActive)&&!switchingPage))return;
    if(_page==1)[_midiView refresh];
    auto snap=_model->presentationSnapshot();auto revision=snap.value("revision",uint64_t(0)),runtimeRevision=snap.value("runtimeRevision",uint64_t(0));auto d=snap["state"]["dmx"];auto target=d.value("target",d.value("controls",Json::object()));_xy.motionTarget=NSMakePoint(target.value("pan",.5),target.value("tilt",.5));if(_motionTarget)_motionTarget.stringValue=[NSString stringWithFormat:@"Target %.0f%% / %.0f%%",target.value("pan",.5)*100,target.value("tilt",.5)*100];if(_channels){std::string channels;auto values=d.value("channels",Json::array());for(size_t i=0;i<values.size();++i)channels+=std::to_string(d.value("address",1)+i)+": "+values[i].dump()+"   ";_channels.stringValue=text(channels);}Json status={{"dmx",d.value("status",Json())},{"error",d.value("error",Json())},{"devices",d.value("devices",Json::array())},{"wled",snap["state"].value("fixtureOutput",Json::object()).value("status",Json())},{"link",snap["state"].value("link",Json::object()).value("peers",0)}};auto runtimeShape=status.dump();if(revision==_revision&&runtimeShape==_runtimeShape)return;
    // Protect in-progress edits from background rebuilds of this page only.
    // A BPM editor elsewhere in the window must never freeze the controls view.
    if(!switchingPage&&[self.window.firstResponder isKindOfClass:NSTextView.class]){
        id editorOwner=((NSTextView*)self.window.firstResponder).delegate;
        if([editorOwner isKindOfClass:NSView.class]&&[(NSView*)editorOwner isDescendantOf:self])return;
    }
    _runtimeShape=runtimeShape;_revision=revision;_runtimeRevision=runtimeRevision;auto state=snap["state"];if(!state.contains("mix")){_status.stringValue=@"Controls unavailable";return;}
    _renderedPage=_page;
    _xy=nil;_channels=nil;_motionTarget=nil;_rgb=nil;_linkedStrip=nil;_linkedFixtureIds=nil;[_strips removeAllObjects];_monitor.hidden=YES;auto scrollOrigin=_scroll.contentView.bounds.origin;auto document=[[VJControlsStack alloc]init];document.orientation=NSUserInterfaceLayoutOrientationVertical;document.alignment=NSLayoutAttributeLeading;document.spacing=0;document.translatesAutoresizingMaskIntoConstraints=NO;_sections=document;_scroll.documentView=_sections;_documentWidth=[_sections.widthAnchor constraintEqualToConstant:MIN(860,MAX(560,_scroll.contentView.bounds.size.width))];_documentWidth.active=YES;
    if(_page==0){
        auto mix=state["mix"];std::string path="/api/v1/mix";
        [self heading:@"Channels"];
        for(auto key:{"video","led"}){std::string prefix=key;[self slider:prefix=="video"?@"Video":@"LED" key:prefix+"_master" value:mix.value(prefix+"_master",1.) min:0 max:1 path:path command:Json::object()];auto row=(NSStackView*)_content.arrangedSubviews.lastObject;auto mute=[self actionButton:@"Mute" path:path command:Json::object()];mute.buttonType=NSButtonTypePushOnPushOff;mute->key=prefix+"_mute";mute.state=mix.value(prefix+"_mute",false)?NSControlStateValueOn:NSControlStateValueOff;mute.action=@selector(toggleChanged:);[row addArrangedSubview:mute];[row addArrangedSubview:[self learn:Json{{"kind","mix_master"},{"which",prefix}}]];}
        [self heading:@"Color cast"];[self swatches:NO];[self slider:@"Amount" key:"cast_amount" value:mix.value("cast_amount",1.) min:0 max:1 path:path command:Json::object()];
        auto colorRow=[self row:@"Custom"];auto color=[[VJFlatColorWell alloc]init];_rgb=color;unsigned cast=0xffffff;if(mix["cast"].is_string()){auto raw=text(mix["cast"].get<std::string>());if([raw hasPrefix:@"#"])[[NSScanner scannerWithString:[raw substringFromIndex:1]]scanHexInt:&cast];}color.color=vj::style::hex(cast);color.identifier=@"mix-color";color.accessibilityLabel=@"Custom color cast";color.target=self;color.action=@selector(mixColor:);[color.widthAnchor constraintEqualToConstant:150].active=YES;[color.heightAnchor constraintEqualToConstant:vj::style::controlHeight].active=YES;[colorRow addArrangedSubview:color];
        [self heading:@"FX"];auto effects=stack(NSUserInterfaceLayoutOrientationHorizontal);effects.spacing=10;effects.distribution=NSStackViewDistributionFillEqually;[_content addArrangedSubview:effects];[effects.widthAnchor constraintEqualToAnchor:_content.widthAnchor constant:-24].active=YES;
        for(auto key:{"pulse","strobe","invert","blackout","flash"}){auto b=[self actionButton:[text(key) uppercaseString] path:std::string(key)=="flash"?"/api/v1/flash":path command:Json::object()];if(std::string(key)!="flash"){b.buttonType=NSButtonTypePushOnPushOff;b->key=key;b.state=mix.value(key,false)?NSControlStateValueOn:NSControlStateValueOff;b.action=@selector(toggleChanged:);}auto cell=stack(NSUserInterfaceLayoutOrientationVertical);[cell addArrangedSubview:b];[cell addArrangedSubview:[self learn:Json{{"kind","mix_effect"},{"effect",key}}]];[effects addArrangedSubview:cell];[b.widthAnchor constraintEqualToAnchor:cell.widthAnchor].active=YES;}
        [self heading:@"Master monitor"];
        if(!_monitor){_monitor=[[VJPreview alloc]initWithFrame:NSMakeRect(0,0,480,220) model:_model];[_monitor setSingleMonitor:YES];[_monitor.heightAnchor constraintEqualToConstant:220].active=YES;}[_monitor removeFromSuperview];_monitor.hidden=NO;[_content addArrangedSubview:_monitor];[_monitor.widthAnchor constraintEqualToAnchor:_content.widthAnchor constant:-24].active=YES;[self strips:state];
    }else if(_page==1){
        [self heading:@"Outputs and network"];auto settings=stack(NSUserInterfaceLayoutOrientationHorizontal);for(NSString* title in @[@"Outputs…",@"Network…"]){auto b=[NSButton buttonWithTitle:title target:self action:@selector(settings:)];[b.widthAnchor constraintEqualToConstant:112].active=YES;[b.heightAnchor constraintEqualToConstant:vj::style::controlHeight].active=YES;[settings addArrangedSubview:b];}[_content addArrangedSubview:settings];[self toggle:@"HD preview" key:"hd" value:state.value("stream_hd",false) path:"/api/v1/stream" command:Json::object()];[self toggle:@"Movie mode 24p" key:"movie_mode" value:state["mix"].value("movie_mode",false) path:"/api/v1/mix" command:Json::object()];
        [self heading:@"Native state"];
        auto statePath=[NSTextField labelWithString:text((_model->stateRoot()/"native-state.json").string())];statePath.lineBreakMode=NSLineBreakByTruncatingMiddle;statePath.font=vj::style::font();statePath.textColor=vj::style::secondary();[_content addArrangedSubview:statePath];[statePath.widthAnchor constraintLessThanOrEqualToAnchor:_content.widthAnchor constant:-24].active=YES;
        [self heading:@"MIDI"];
        if(!_midiView)_midiView=[[VJMidiControls alloc]initWithFrame:NSMakeRect(0,0,720,200) model:_model];[_midiView removeFromSuperview];[_content addArrangedSubview:_midiView];[_midiView.widthAnchor constraintEqualToAnchor:_content.widthAnchor constant:-24].active=YES;[_midiView refresh];
        [self choices:@"APC lights" key:"mode" value:state["grid"].value("controller_lights",std::string("full")) options:{"full","dim","off"} path:"/api/v1/grid" command:Json{{"action","set_controller_lights"}}];
    }else if(_page==2){
        auto d=state["dmx"],controls=d["controls"];std::string path="/api/v1/dmx";
        [self heading:@"DMX"];auto toolbar=stack(NSUserInterfaceLayoutOrientationHorizontal);[_content addArrangedSubview:toolbar];
        const bool connected=d.value("connected",false),busy=connected||d.value("status",std::string{})=="connecting"||d.value("status",std::string{})=="disconnecting";
        for(auto action:{"identify","flash"}){auto b=[self actionButton:std::string(action)=="identify"?@"Identify · 3s":@"Flash · 250ms" path:path command:Json{{"action",action}}];b.enabled=connected;[toolbar addArrangedSubview:b];}
        auto blackout=[self actionButton:@"Blackout" path:path command:Json{{"controls",Json::object()}}];blackout->key="blackout";blackout.buttonType=NSButtonTypePushOnPushOff;blackout.state=controls.value("blackout",false)?NSControlStateValueOn:NSControlStateValueOff;blackout.action=@selector(toggleChanged:);[toolbar addArrangedSubview:blackout];
        [_content addArrangedSubview:label(text(d.value("status",std::string("disconnected"))))];
        if(!d.value("error",std::string{}).empty())[_content addArrangedSubview:label(text(d["error"]))];
        auto tabs=stack(NSUserInterfaceLayoutOrientationHorizontal);[_content addArrangedSubview:tabs];for(NSInteger i=0;i<2;++i){auto b=[NSButton buttonWithTitle:i?@"APC40":@"Controls" target:self action:@selector(dmxViewChanged:)];b.tag=i;b.identifier=i?@"tab-dmx-apc":@"tab-dmx-full";b.state=(_apcView==(i==1))?NSControlStateValueOn:NSControlStateValueOff;[b.widthAnchor constraintEqualToConstant:100].active=YES;[b.heightAnchor constraintEqualToConstant:vj::style::controlHeight].active=YES;[tabs addArrangedSubview:b];}
        [self heading:@"Motion"];[self choices:@"Pattern" key:"motion" value:controls["motion"] options:{"off","circle","pan","tilt","figure_eight"} path:path command:Json{{"controls",Json::object()}}];
        [self slider:@"Size" key:"motion_size" value:controls.value("motion_size",.2) min:0 max:1 path:path command:Json{{"controls",Json::object()}}];[self slider:@"Cycle speed" key:"motion_speed" value:controls.value("motion_speed",.15) min:0 max:1 path:path command:Json{{"controls",Json::object()}}];
        auto motion=stack(NSUserInterfaceLayoutOrientationHorizontal);[motion addArrangedSubview:[self actionButton:@"Stop motion" path:path command:Json{{"controls",{{"motion","off"}}}}]];_motionTarget=label(@"");[motion addArrangedSubview:_motionTarget];[_content addArrangedSubview:motion];
        if(_apcView){
            const auto values=d["apc"];__weak VJControls* weak=self;
            auto makeDial=[&](const std::string& key,NSString* title,NSString* caption){auto box=stack(NSUserInterfaceLayoutOrientationVertical);[box addArrangedSubview:label(caption)];[box addArrangedSubview:label(title)];auto dial=[[VJControlDial alloc]initWithFrame:NSMakeRect(0,0,72,86)];dial->key=key;dial.maxValue=key=="color"?7:1;dial.valueStep=key=="color"?1:.001;dial.doubleValue=values.value(key,0.);dial.target=self;dial.action=@selector(dial:);dial.accessibilityLabel=title;dial.tracking=^(BOOL active){VJControls* owner=weak;if(owner)owner->_tracking=active;};[dial.widthAnchor constraintEqualToConstant:72].active=YES;[dial.heightAnchor constraintEqualToConstant:86].active=YES;[box addArrangedSubview:dial];return box;};
            [_content addArrangedSubview:makeDial("brightness",@"Brightness",@"TEMPO")];std::array<std::string,6> keys={"pan","tilt","speed","beam","strobe","color"};NSArray* titles=@[@"Pan",@"Tilt",@"Speed",@"Beam width",@"Strobe speed",@"Color"];
            for(int r=0;r<2;++r){auto row=stack(NSUserInterfaceLayoutOrientationHorizontal);row.distribution=NSStackViewDistributionFillEqually;[row.widthAnchor constraintEqualToConstant:480].active=YES;[_content addArrangedSubview:row];for(int c=0;c<4;++c){int i=r*4+c;if(i<6)[row addArrangedSubview:makeDial(keys[i],titles[i],text(std::to_string(i+1)))];else{auto empty=stack(NSUserInterfaceLayoutOrientationVertical);[empty addArrangedSubview:label(text(std::to_string(i+1)))];[empty addArrangedSubview:label(@"Unassigned")];[row addArrangedSubview:empty];}}}
            [self swatches:YES];
            [self toggle:@"Blackout" key:"blackout" value:controls.value("blackout",false) path:path command:Json{{"controls",Json::object()}}];
        }else{
        [self heading:@"Connection"];std::vector<Json> serials={""};for(const auto& device:d.value("devices",Json::array()))serials.push_back(device.value("serial",std::string{}));
        if(std::find(serials.begin(),serials.end(),d.value("serial",std::string{}))==serials.end())serials.push_back(d.value("serial",std::string{}));
        [self choices:@"USB adapter" key:"serial" value:d.value("serial",std::string{}) options:serials path:path command:Json::object()];auto adapter=(VJControlPopup*)((NSStackView*)_content.arrangedSubviews.lastObject).arrangedSubviews.lastObject;adapter.enabled=!busy;
        [adapter.itemArray[0] setTitle:@"First available"];for(NSUInteger i=1;i<adapter.itemArray.count;++i){auto serial=serials[i].get<std::string>();NSString* title=text(serial+" · Unavailable");BOOL available=NO;for(const auto& device:d.value("devices",Json::array()))if(device.value("serial",std::string{})==serial){title=text(device.value("name",std::string("Adapter"))+" · "+serial);available=device.value("available",false);break;}adapter.itemArray[i].title=title;adapter.itemArray[i].enabled=available;}adapter.autoenablesItems=NO;
        auto connection=stack(NSUserInterfaceLayoutOrientationHorizontal);[_content addArrangedSubview:connection];for(auto action:{"scan","connect","disconnect"}){auto b=[self actionButton:[text(action) capitalizedString] path:path command:Json{{"action",action}}];b.enabled=std::string(action)=="scan"||((std::string(action)=="connect")?!busy:busy);[connection addArrangedSubview:b];}
        auto device=d.value("device",Json());[_content addArrangedSubview:label(device.is_object()?text(device.value("name",std::string("Adapter"))+" · "+device.value("serial",std::string{})):@"No active adapter")];
        [self slider:@"Address" key:"address" value:d.value("address",1) min:1 max:513-d.value("mode",15) path:path command:Json::object()];for(NSView* v in ((NSStackView*)_content.arrangedSubviews.lastObject).arrangedSubviews)if([v isKindOfClass:NSControl.class]&&![(NSControl*)v isKindOfClass:NSTextField.class])((NSControl*)v).enabled=!busy;else if([v isKindOfClass:VJControlField.class])((NSControl*)v).enabled=!busy;
        [self choices:@"Channel mode" key:"mode" value:d["mode"] options:{15,13} path:path command:Json::object()];auto mode=(VJControlPopup*)((NSStackView*)_content.arrangedSubviews.lastObject).arrangedSubviews.lastObject;mode.enabled=!busy;mode.itemArray[0].title=@"15 CH";mode.itemArray[1].title=@"13 CH";
        [self heading:@"Movement"];_xy=[[VJPositionPad alloc]initWithFrame:NSMakeRect(0,0,320,180)];_xy.position=NSMakePoint(controls.value("pan",.5),controls.value("tilt",.5));auto target=d.value("target",controls);_xy.motionTarget=NSMakePoint(target.value("pan",.5),target.value("tilt",.5));_xy.target=self;_xy.action=@selector(position:);_xy.accessibilityLabel=@"Pan and tilt";__weak VJControls* weak=self;_xy.tracking=^(BOOL active){VJControls* owner=weak;if(owner)owner->_tracking=active;};[_xy.widthAnchor constraintEqualToConstant:320].active=YES;[_xy.heightAnchor constraintEqualToConstant:180].active=YES;[_content addArrangedSubview:_xy];
        for(auto key:{"pan","tilt","movement_speed"})[self slider:std::string(key)=="movement_speed"?@"Move speed":[text(key) capitalizedString] key:key value:controls.value(key,0.) min:0 max:1 path:path command:Json{{"controls",Json::object()}}];[self button:@"Center" path:path command:Json{{"controls",{{"pan",.5},{"tilt",.5}}}}];
        [self heading:@"Beam"];[self slider:@"Brightness" key:"dimmer" value:controls.value("dimmer",0.) min:0 max:1 path:path command:Json{{"controls",Json::object()}}];[self slider:@"Beam width" key:"zoom" value:controls.value("zoom",.5) min:0 max:1 path:path command:Json{{"controls",Json::object()}}];
        auto beam=stack(NSUserInterfaceLayoutOrientationHorizontal);for(int i=0;i<2;++i)[beam addArrangedSubview:[self actionButton:i?@"Wide":@"Narrow" path:path command:Json{{"controls",{{"zoom",i}}}}]];[_content addArrangedSubview:beam];
        [self choices:@"Shutter" key:"strobe" value:controls["strobe"] options:{"open","strobe","pulse","random"} path:path command:Json{{"controls",Json::object()}}];[self slider:@"Flash speed" key:"strobe_speed" value:controls.value("strobe_speed",.2) min:0 max:1 path:path command:Json{{"controls",Json::object()}}];
        [self heading:@"Color"];[self swatches:YES];auto rgbRow=[self row:@"RGB color"];auto rgb=[[VJFlatColorWell alloc]init];_rgb=rgb;rgb.identifier=@"dmx-rgb";rgb.accessibilityLabel=@"RGB color";rgb.color=[NSColor colorWithRed:controls.value("red",0.) green:controls.value("green",0.) blue:controls.value("blue",0.) alpha:1];rgb.target=self;rgb.action=@selector(dmxColor:);[rgb.widthAnchor constraintEqualToConstant:150].active=YES;[rgb.heightAnchor constraintEqualToConstant:vj::style::controlHeight].active=YES;[rgbRow addArrangedSubview:rgb];for(auto key:{"red","green","blue","white"})[self slider:[text(key) capitalizedString] key:key value:controls.value(key,0.) min:0 max:1 path:path command:Json{{"controls",Json::object()}}];
        [self heading:@"Effects"];[self choices:@"Color macro" key:"macro" value:controls["macro"] options:{"off","red","green","blue","white","yellow","magenta","red_white","cyan","green_white","blue_white","rgb","rgbw","jump","fade","mixed"} path:path command:Json{{"controls",Json::object()}}];[self slider:@"Macro speed" key:"macro_speed" value:controls.value("macro_speed",.3) min:0 max:1 path:path command:Json{{"controls",Json::object()}}];[self choices:@"Program" key:"program" value:controls["program"] options:{"off","1","2","3","4","5","6","7","sound"} path:path command:Json{{"controls",Json::object()}}];[self button:@"Manual" path:path command:Json{{"controls",{{"program","off"},{"macro","off"},{"strobe","open"},{"motion","off"}}}}];
        [self heading:@"Channels / motors"];std::string channels;for(size_t i=0;i<d["channels"].size();++i)channels+=std::to_string(d.value("address",1)+i)+": "+d["channels"][i].dump()+"   ";_channels=label(text(channels));_channels.maximumNumberOfLines=0;_channels.preferredMaxLayoutWidth=760;[_content addArrangedSubview:_channels];
        auto motors=stack(NSUserInterfaceLayoutOrientationHorizontal);for(auto motor:{"all","pan_tilt","zoom"}){auto b=[self actionButton:std::string(motor)=="all"?@"Reset all motors":std::string(motor)=="pan_tilt"?@"Reset pan / tilt":@"Reset zoom" path:path command:Json{{"action","reset"},{"motor",motor}}];b.enabled=connected&&controls.value("blackout",false);[motors addArrangedSubview:b];}[_content addArrangedSubview:motors];
        }
    }else if(_page==3){
        [self heading:@"LED destinations"];auto output=state.value("fixtureOutput",Json::object());[_content addArrangedSubview:label(text("WLED UDP · "+output.value("status",std::string("off"))))];
        auto scanRow=[self row:@"Discovery"];auto scan=[NSButton buttonWithTitle:_wledScanning?@"Scanning…":@"Scan for WLED" target:self action:@selector(scanWled:)];scan.identifier=@"wled-scan";scan.enabled=!_wledScanning;[scan.widthAnchor constraintEqualToConstant:150].active=YES;[scan.heightAnchor constraintEqualToConstant:vj::style::controlHeight].active=YES;[scanRow addArrangedSubview:scan];
        if(_wledDiscovery.is_object()){
            auto devices=_wledDiscovery.value("devices",Json::array());
            if(_wledDiscovery.contains("error"))[_content addArrangedSubview:label(text(_wledDiscovery.value("error",std::string{})))];
            else [_content addArrangedSubview:label(text(std::to_string(devices.size())+" found · "+(_wledScanning?"rescanning":"last scan")))];
            for(const auto& device:devices){
                auto row=[self row:text(device.value("name",device.at("host")).get<std::string>())];
                auto description=label(text(device.at("host").get<std::string>()+":"+std::to_string(device.at("port").get<int>())+" · "+std::to_string(device.at("ledCount").get<int>())+" LEDs"));[row addArrangedSubview:description];
                bool selected=output.value("host",std::string{})==device.at("host").get<std::string>()&&output.value("port",21324)==device.at("port");
                auto use=[self actionButton:selected?@"Selected":@"Use" path:"/api/v1/fixture-output" command:Json{{"action","set"},{"host",device.at("host")},{"port",device.at("port")}}];use.enabled=!selected&&!_wledScanning&&!output.value("active",false)&&!output.value("requested",false);use.toolTip=@"Stop WLED before changing the destination.";[row addArrangedSubview:use];
            }
            for(const auto& warning:_wledDiscovery.value("warnings",Json::array())){auto message=[NSTextField wrappingLabelWithString:text(warning.get<std::string>())];message.textColor=vj::style::secondary();[_content addArrangedSubview:message];[message.widthAnchor constraintEqualToAnchor:_content.widthAnchor constant:-24].active=YES;}
            if(!_wledDiscovery.value("complete",true))[_content addArrangedSubview:label(@"Scan time limit reached; scan again to retry.")];
        }
        auto destination=[self row:@"WLED host"];auto host=[[VJControlField alloc]init];host->key="host";host->path="/api/v1/fixture-output";host->command=Json::object();host.stringValue=text(output.value("host",std::string("")));host.target=self;host.action=@selector(fieldChanged:);[host.widthAnchor constraintEqualToConstant:260].active=YES;[host.heightAnchor constraintEqualToConstant:vj::style::controlHeight].active=YES;[destination addArrangedSubview:host];
        auto portRow=[self row:@"UDP port"];auto port=[[VJControlField alloc]init];port->key="port";port->path="/api/v1/fixture-output";port->command=Json::object();port.stringValue=text(std::to_string(output.value("port",21324)));port.target=self;port.action=@selector(fieldChanged:);[port.widthAnchor constraintEqualToConstant:90].active=YES;[port.heightAnchor constraintEqualToConstant:vj::style::controlHeight].active=YES;[portRow addArrangedSubview:port];
        [self button:output.value("active",false)?@"Stop WLED":@"Start WLED" path:"/api/v1/fixture-output" command:Json{{"action",output.value("active",false)?"stop":"start"}}];
        if(!output.value("error",std::string{}).empty())[_content addArrangedSubview:label(text(output["error"]))];[self toggle:@"Link strips" key:"linked" value:state.value("linked",true) path:"/api/v1/leds" command:_selectedFixture.empty()?Json::object():Json{{"source",_selectedFixture}}];auto fixtures=state.value("fixtures",Json::array());const bool linked=state.value("linked",true);Json displayed=Json::array();NSMutableArray* linkedIds=[NSMutableArray array];int linkedCount=0;Json primary;
        for(const auto& f:fixtures)if(f.value("kind",std::string{})!="virtual"){if(primary.is_null()||(f.value("enabled",false)&&!primary.value("enabled",false)))primary=f;if(f.value("enabled",false)){[linkedIds addObject:text(f["id"])];linkedCount+=f.value("count",0);}}else displayed.push_back(f);
        if(linked&&!primary.is_null()){auto representative=primary;representative["label"]="Linked strips";representative["count"]=linkedCount;representative["enabled"]=!linkedIds.count?false:true;displayed.insert(displayed.begin(),representative);}else displayed=fixtures;
        if(displayed.empty())[_content addArrangedSubview:label(@"No fixtures")];for(auto& f:displayed){std::string fid=f.value("id",std::string{}),path="/api/v1/leds/"+fid;[self heading:text(f.value("label",fid)+" · "+std::to_string(f.value("count",0)))];[self toggle:@"Enabled" key:"enabled" value:f.value("enabled",false) path:path command:Json::object()];std::vector<Json> outs={"none"};int count=state["grid"]["running"].size();for(int i=1;i<=count;i++)outs.push_back("out"+std::to_string(i));auto route=f["route"];if(std::find(outs.begin(),outs.end(),route["out"])==outs.end())outs.push_back(route["out"]);[self choices:@"Out" key:"out" value:route["out"] options:outs path:path command:Json{{"route",Json::object()}}];auto popup=(VJControlPopup*)((NSStackView*)_content.arrangedSubviews.lastObject).arrangedSubviews.lastObject;for(NSUInteger i=0;i<popup.itemArray.count;++i)popup.itemArray[i].title=i==0?@"None":i<=NSUInteger(count)?[NSString stringWithFormat:@"Out %lu",(unsigned long)i]:[text(route["out"]) stringByAppendingString:@" · Inactive"];for(auto key:{"start","end","offset"})[self slider:[text(key) capitalizedString] key:key value:route.value(key,0.) min:0 max:1 path:path command:Json{{"route",Json::object()}}];[self toggle:@"Reverse" key:"reverse" value:route.value("reverse",false) path:path command:Json{{"route",Json::object()}}];for(auto key:{"brightness","power_limit"}){if(std::string(key)=="power_limit"&&f.value("kind",std::string{})=="virtual")continue;[self slider:std::string(key)=="brightness"?@"Brightness":@"Power limit" key:key value:f.value(key,1.) min:0 max:1 path:path command:Json::object()];}[self strips:Json{{"fixtures",Json::array({f})}}];if(linked&&f.value("kind",std::string{})!="virtual"){_linkedStrip=_strips[text(fid)];_linkedFixtureIds=linkedIds;}}
    }
    vj::style::apply(_sections);[_sections layoutSubtreeIfNeeded];[self layoutSubtreeIfNeeded];[_scroll.contentView scrollToPoint:scrollOrigin];[_scroll reflectScrolledClipView:_scroll.contentView];
}
- (Json)checkParity {
    Json results=Json::object();BOOL savedView=_apcView;
    auto drain=[&]{auto until=[NSDate dateWithTimeIntervalSinceNow:5];while(!VJUiCommandsIdle(_model)&&until.timeIntervalSinceNow>0)[[NSRunLoop mainRunLoop]runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.002]];_model->snapshot();[self refresh];[self.window.contentView layoutSubtreeIfNeeded];};
    std::function<NSView*(NSView*,NSString*,Class)> find=[&](NSView* root,NSString* identifier,Class cls)->NSView*{if([root isKindOfClass:cls]&&[root.identifier isEqual:identifier])return root;for(NSView* child in root.subviews)if(auto found=find(child,identifier,cls))return found;return nil;};
    std::function<NSButton*(NSView*,NSString*)> named=[&](NSView* root,NSString* title)->NSButton*{if([root isKindOfClass:NSButton.class]&&[((NSButton*)root).title isEqual:title])return (NSButton*)root;for(NSView* child in root.subviews)if(auto found=named(child,title))return found;return nil;};
    auto click=[&](NSString* title){auto b=named(_sections,title);BOOL found=b&&b.enabled;[b performClick:nil];drain();return bool(found);};
    auto dmx=[&]{return _model->snapshot()["state"]["dmx"]["controls"];};
    auto field=[&](NSString* id){return (VJControlField*)find(_sections,id,VJControlField.class);};
    auto slider=[&](NSString* id){return (VJControlSlider*)find(_sections,id,VJControlSlider.class);};
    auto popup=[&](NSString* id){return (VJControlPopup*)find(_sections,id,VJControlPopup.class);};
    [self selectPage:0];drain();auto mixColor=(VJFlatColorWell*)find(_sections,@"mix-color",VJFlatColorWell.class);mixColor.color=vj::style::hex(0x8040c0);[mixColor sendAction:mixColor.action to:mixColor.target];drain();results["Mix custom color uses shared picker"]=mixColor&&_model->snapshot()["state"]["mix"]["cast"]=="#8040c0";
    _apcView=NO;[self selectPage:2];drain();
    _model->request("POST","/api/v1/dmx",{{"controls",{{"blackout",false}}}});_model->snapshot();[self refresh];bool blackout=click(@"Blackout")&&dmx()["blackout"]==true;blackout=click(@"Blackout")&&dmx()["blackout"]==false&&blackout;results["DMX Blackout toggles both ways"]=blackout;
    auto white=(VJControlButton*)find(_sections,@"swatch:#ffffff",VJControlButton.class);[white performClick:nil];drain();auto color=dmx();results["DMX White uses dedicated white channel"]=white&&color["white"]==1&&color["red"]==0&&color["green"]==0&&color["blue"]==0;
    auto rgb=(NSColorWell*)find(_sections,@"dmx-rgb",NSColorWell.class);rgb.color=[NSColor colorWithRed:.25 green:.5 blue:.75 alpha:1];[rgb sendAction:rgb.action to:rgb.target];drain();color=dmx();results["DMX RGB picker applies channels and clears presets"]=rgb&&std::abs(color["red"].get<double>()-.25)<.001&&std::abs(color["green"].get<double>()-.5)<.001&&std::abs(color["blue"].get<double>()-.75)<.001&&color["white"]==0&&color["macro"]=="off"&&color["program"]=="off";
    results["DMX connection actions reflect disconnection"]=!named(_sections,@"Identify · 3s").enabled&&!named(_sections,@"Flash · 250ms").enabled&&named(_sections,@"Connect").enabled&&!named(_sections,@"Disconnect").enabled;
    _model->setControlRuntime("dmx",{{"status","connected"},{"connected",true},{"devices",Json::array({{{"name","SoundSwitch"},{"serial","TEST-123"},{"available",true}},{{"name","Busy adapter"},{"serial","TEST-456"},{"available",false}}})}});_model->snapshot();_model->snapshot();[self refresh];
    auto adapter=popup(@"/api/v1/dmx:serial");results["DMX adapter names and availability"]=adapter&&adapter.numberOfItems==3&&[adapter.itemArray[0].title isEqual:@"First available"]&&[adapter.itemArray[1].title containsString:@"SoundSwitch"]&&!adapter.itemArray[2].enabled;
    results["DMX connected routing fields are locked"]=!adapter.enabled&&!field(@"/api/v1/dmx:address").enabled&&!popup(@"/api/v1/dmx:mode").enabled&&!named(_sections,@"Connect").enabled&&named(_sections,@"Disconnect").enabled;
    bool motorOff=!named(_sections,@"Reset all motors").enabled;click(@"Blackout");results["DMX motor reset controls remain visible and gated"]=motorOff&&named(_sections,@"Reset all motors").enabled&&named(_sections,@"Reset pan / tilt").enabled&&named(_sections,@"Reset zoom").enabled;
    _model->setControlRuntime("dmx",Json::object());_model->snapshot();_model->snapshot();[self refresh];click(@"Blackout");
    results["DMX beam presets send zero and full width"]=click(@"Narrow")&&dmx()["zoom"]==0&&click(@"Wide")&&dmx()["zoom"]==1;
    _model->request("POST","/api/v1/dmx",{{"controls",{{"program","2"},{"macro","red"},{"strobe","strobe"}}}});_model->snapshot();[self refresh];results["DMX Manual restores direct control"]=click(@"Manual")&&dmx()["program"]=="off"&&dmx()["macro"]=="off"&&dmx()["strobe"]=="open"&&dmx()["motion"]=="off";
    NSArray* sections=@[@"DMX",@"Motion",@"Connection",@"Movement",@"Beam",@"Color",@"Effects",@"Channels / motors"];BOOL headings=_sections.arrangedSubviews.count==sections.count;for(NSUInteger i=0;headings&&i<sections.count;++i)headings=[((NSTextField*)((NSStackView*)_sections.arrangedSubviews[i]).arrangedSubviews[0]).stringValue isEqual:sections[i]];results["DMX reference sections and flat tabs"]=headings&&find(_sections,@"tab-dmx-full",NSButton.class)&&find(_sections,@"tab-dmx-apc",NSButton.class);
    results["DMX readable shutter and program choices"]=[popup(@"/api/v1/dmx:strobe").itemArray[0].title isEqual:@"Steady"]&&[popup(@"/api/v1/dmx:program").itemArray[0].title isEqual:@"Manual DMX"];
    auto apc=(NSButton*)find(_sections,@"tab-dmx-apc",NSButton.class);[apc performClick:nil];drain();
    auto magenta=(NSButton*)find(_sections,@"swatch:#ff00ff",NSButton.class);[magenta performClick:nil];drain();color=dmx();results["APC palette ends in Magenta"]=magenta&&color["red"]==1&&color["blue"]==1&&color["green"]==0&&color["white"]==0;
    _model->request("POST","/api/v1/dmx",{{"controls",{{"motion","circle"}}}});_model->snapshot();[self refresh];results["APC exposes motion controls and Stop motion"]=popup(@"/api/v1/dmx:motion")&&slider(@"/api/v1/dmx:motion_size")&&click(@"Stop motion")&&dmx()["motion"]=="off";
    [self selectPage:0];drain();auto volume=field(@"/api/v1/mix:video_master");BOOL percentage=volume&&[volume.stringValue hasSuffix:@"%"];volume.stringValue=@"37%";[volume sendAction:volume.action to:volume.target];drain();results["Mix percent input preserves normalized API"]=percentage&&std::abs(_model->snapshot()["state"]["mix"]["video_master"].get<double>()-.37)<.0001;_model->request("POST","/api/v1/mix",{{"video_master",1.}});_model->snapshot();[self refresh];
    std::vector<Json> targets={{{"kind","mix_master"},{"which","video"}},{{"kind","mix_effect"},{"effect","flash"}},{{"kind","cast"},{"cast","#ff0000"}}};bool learning=true;
    for(const auto& target:targets){Json command={{"action","midi_learn"},{"target",target}};auto button=(NSButton*)find(_sections,text("/api/v1/midi:"+command.dump()),NSButton.class);[button performClick:nil];drain();learning=learning&&button&&_model->snapshot()["state"]["midi"]["learning"]==target;command["target"]=nullptr;button=(NSButton*)find(_sections,text("/api/v1/midi:"+command.dump()),NSButton.class);[button performClick:nil];drain();learning=learning&&button&&_model->snapshot()["state"]["midi"]["learning"].is_null();}results["Mix inline MIDI learns and cancels masters FX and casts"]=learning;
    [self selectPage:1];drain();bool excluded=true;std::function<void(NSView*)> inspectExcluded=[&](NSView* view){NSString* value=[view isKindOfClass:NSButton.class]?((NSButton*)view).title:[view isKindOfClass:NSTextField.class]?((NSTextField*)view).stringValue:@"";for(NSString* title in @[@"Room",@"BPM",@"Ableton Link",@"Sync calibration",@"API",@"Optimize new videos"])if([value isEqual:title])excluded=false;for(NSView* child in view.subviews)inspectExcluded(child);};inspectExcluded(_sections);results["Settings respects intentional parity exclusions"]=excluded;
    _model->request("PUT","/api/v1/outputs",{{"count",2}});[self selectPage:3];drain();auto state=_model->snapshot()["state"];auto fixtures=state["fixtures"];BOOL routes=fixtures.size()>=3,previews=routes,virtualPower=NO;std::vector<std::string> physical;
    for(const auto& f:fixtures){auto id=f["id"].get<std::string>();auto p=popup(text("/api/v1/leds/"+id+":out"));bool inactive=f["route"]["out"]!="none"&&f["route"]["out"]!="out1"&&f["route"]["out"]!="out2";routes=routes&&p&&p.numberOfItems==(inactive?4:3)&&(!inactive||[p.itemArray[3].title hasSuffix:@"Inactive"]);auto strip=_strips[text(id)];previews=previews&&strip&&strip.superview.superview==p.superview.superview;if(f.value("kind",std::string{})=="virtual")virtualPower=!slider(text("/api/v1/leds/"+id+":power_limit"))&&slider(text("/api/v1/leds/"+id+":brightness"));else physical.push_back(id);}
    results["LED routes offer active outputs and retain inactive assignments"]=bool(routes);results["LED previews belong to their fixture sections"]=bool(previews);results["Projected LED paths omit physical power limit"]=bool(virtualPower);
    bool linked=false;if(physical.size()>=2){_model->request("PUT","/api/v1/leds",{{"linked",false}});_model->snapshot();[self refresh];auto second=popup(text("/api/v1/leds/"+physical[1]+":out"));[second selectItemAtIndex:2];[second sendAction:second.action to:second.target];drain();std::function<VJControlButton*(NSView*)> linkButton=[&](NSView* v)->VJControlButton*{if([v isKindOfClass:VJControlButton.class]&&((VJControlButton*)v)->key=="linked")return (VJControlButton*)v;for(NSView* child in v.subviews)if(auto b=linkButton(child))return b;return nil;};auto link=linkButton(_sections);[link performClick:nil];drain();linked=link&&_model->snapshot()["state"]["linked"]==true;auto fresh=_model->snapshot()["state"]["fixtures"];for(const auto& f:fresh)if(f.value("kind",std::string{})!="virtual")linked=linked&&f["route"]["out"]=="out2";}
    results["Link strips uses the most recently edited physical route"]=linked;
    _apcView=savedView;[NSUserDefaults.standardUserDefaults setBool:savedView forKey:@"VJDMXAPCView"];_revision=UINT64_MAX;_model->snapshot();[self refresh];return results;
}

- (BOOL)checkPage:(NSInteger)page {
    if(page==4)page=1;NSArray* headings=@[@"Channels",@"Outputs and network",@"DMX",@"LED destinations"];
    auto section=(NSStackView*)_sections.arrangedSubviews.firstObject;auto heading=(NSTextField*)section.arrangedSubviews.firstObject;
    return page>=0&&page<4&&[heading isKindOfClass:NSTextField.class]&&[heading.stringValue isEqual:headings[page]];
}
- (BOOL)checkLayout {
    [self layoutSubtreeIfNeeded];BOOL valid=_scroll.frame.size.height>100&&_sections.frame.size.width<=861;
    if(_page==0){BOOL rendered=[_monitor checkRendering];NSLog(@"Controls monitor hidden %d ancestor %d frame %@ visible %@ image %d",_monitor.hidden,_monitor.isHiddenOrHasHiddenAncestor,NSStringFromRect(_monitor.frame),NSStringFromRect(_monitor.visibleRect),[_monitor capturePresentation]!=nil);valid=valid&&rendered&&!_monitor.isHiddenOrHasHiddenAncestor&&_monitor.frame.size.height>=200;}
    return valid;
}
- (BOOL)checkScrollToEnd {
    [self layoutSubtreeIfNeeded];[_sections layoutSubtreeIfNeeded];
    CGFloat end=MAX(0,_sections.bounds.size.height-_scroll.contentView.bounds.size.height);
    [_scroll.contentView scrollToPoint:NSMakePoint(0,end)];[_scroll reflectScrolledClipView:_scroll.contentView];
    BOOL atEnd=fabs(_scroll.contentView.bounds.origin.y-end)<1;
    NSInteger page=_page;[self selectPage:page==0?1:0];[self selectPage:page];[self layoutSubtreeIfNeeded];
    BOOL atTop=fabs(_scroll.contentView.bounds.origin.y)<1;
    end=MAX(0,_sections.bounds.size.height-_scroll.contentView.bounds.size.height);
    [_scroll.contentView scrollToPoint:NSMakePoint(0,end)];[_scroll reflectScrolledClipView:_scroll.contentView];
    return atEnd&&atTop&&_scroll.contentView.bounds.origin.y>=0;
}
- (void)settings:(NSButton*)sender {if(self.settingsAction)self.settingsAction(sender.title);}
- (void)strips:(const Json&)state {for(const auto& f:state.value("fixtures",Json::array())){auto fid=f.value("id",std::string{});auto row=[self row:text(f.value("label",fid))];auto strip=[[VJRGBStrip alloc]initWithFrame:NSMakeRect(0,0,320,20)];[strip.widthAnchor constraintGreaterThanOrEqualToConstant:220].active=YES;[strip setContentHuggingPriority:200 forOrientation:NSLayoutConstraintOrientationHorizontal];[strip.heightAnchor constraintEqualToConstant:20].active=YES;strip.accessibilityLabel=text(f.value("label",fid));[row addArrangedSubview:strip];_strips[text(fid)]=strip;}}
- (void)position:(VJPositionPad*)sender {[self send:{{"controls",{{"pan",sender.position.x},{"tilt",sender.position.y}}}} path:"/api/v1/dmx" continuous:YES];}
- (void)dial:(VJControlDial*)sender {Json value=sender->key=="color"?Json(int(std::round(sender.doubleValue))):Json(sender.doubleValue);[self send:{{"apc",{{sender->key,value}}}} path:"/api/v1/dmx" continuous:YES];}
- (VJControlButton*)learn:(Json)target {
    auto midi=_model->presentationSnapshot()["state"].value("midi",Json::object());BOOL learning=midi.value("learning",Json())==target;
    auto b=[self actionButton:learning?@"Learning…":@"MIDI" path:"/api/v1/midi" command:Json{{"action","midi_learn"},{"target",learning?Json():target}}];
    b.accessibilityLabel=text("MIDI "+target.dump());b.state=learning?NSControlStateValueOn:NSControlStateValueOff;
    for(const auto& m:midi.value("mappings",Json::array())){bool match=target["kind"]=="mix_master"?m.value("mix",Json())==target["which"]:target["kind"]=="mix_effect"?m.value("mix_effect",Json())==target["effect"]:m.value("cast",Json())==target["cast"];if(match){b.state=NSControlStateValueOn;b.toolTip=text((m.value("type",std::string{})=="cc"?"CC "+std::to_string(m.value("cc",0)):"Note "+std::to_string(m.value("note",0)))+" · Ch "+std::to_string(m.value("channel",0)+1));break;}}
    return b;
}
- (void)swatches:(BOOL)dmx {
    auto row=stack(NSUserInterfaceLayoutOrientationHorizontal);row.spacing=8;
    std::vector<unsigned> colors=dmx?(_apcView?std::vector<unsigned>{0xff0000,0xff8800,0xffff00,0x00ff00,0x00ffff,0x0000ff,0x8800ff,0xff00ff}:std::vector<unsigned>{0xff0000,0x00ff00,0x0000ff,0xffffff,0xffff00,0x00ffff,0xff00ff}):std::vector<unsigned>{0xff0000,0xff8800,0xffff00,0x00ff00,0x00ffff,0x0000ff,0x8800ff,0xff00ff,0xffffff};
    auto mix=_model->presentationSnapshot()["state"]["mix"];int index=0;
    for(auto rgb:colors){auto b=[[VJControlSwatch alloc]init];b.swatchColor=vj::style::hex(rgb);b.title=@"";b.bezelStyle=NSBezelStyleSmallSquare;b.target=self;b.action=@selector(pressed:);b->path=dmx?"/api/v1/dmx":"/api/v1/mix";char hex[8];snprintf(hex,sizeof(hex),"#%06x",rgb);b.toolTip=text(hex);b.accessibilityLabel=text(hex);b.identifier=text(std::string("swatch:")+hex);BOOL active=!dmx&&mix.value("cast",Json())==hex;b.state=active?NSControlStateValueOn:NSControlStateValueOff;
        bool white=dmx&&rgb==0xffffff;
        b->command=dmx?Json{{"controls",{{"red",white?0:((rgb>>16)&255)/255.},{"green",white?0:((rgb>>8)&255)/255.},{"blue",white?0:(rgb&255)/255.},{"white",white?1:0},{"macro","off"},{"program","off"}}}}:Json{{"cast",active?Json():Json(hex)}};
        if(dmx&&_apcView)b->command={{"apc",{{"color",index}}}};
        [b.widthAnchor constraintEqualToConstant:44].active=YES;[b.heightAnchor constraintEqualToConstant:34].active=YES;
        if(dmx)[row addArrangedSubview:b];else {auto cell=stack(NSUserInterfaceLayoutOrientationVertical);cell.alignment=NSLayoutAttributeCenterX;cell.spacing=3;[cell addArrangedSubview:b];auto learn=[self learn:Json{{"kind","cast"},{"cast",hex}}];for(NSLayoutConstraint* c in learn.constraints)if(c.firstAttribute==NSLayoutAttributeWidth)c.constant=44;[cell addArrangedSubview:learn];[row addArrangedSubview:cell];}++index;
    }
    if(!dmx){auto none=[self actionButton:@"No cast" path:"/api/v1/mix" command:Json{{"cast",nullptr}}];none.state=mix.value("cast",Json()).is_null()?NSControlStateValueOn:NSControlStateValueOff;[row addArrangedSubview:none];}[_content addArrangedSubview:row];
}
- (void)mixColor:(NSColorWell*)sender {auto color=[sender.color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];if(color){auto hex=[NSString stringWithFormat:@"#%02x%02x%02x",int(lround(color.redComponent*255)),int(lround(color.greenComponent*255)),int(lround(color.blueComponent*255))];[self send:Json{{"cast",hex.UTF8String}} path:"/api/v1/mix" continuous:YES];}}
- (void)dmxColor:(NSColorWell*)sender {auto color=[sender.color colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];if(color)[self send:Json{{"controls",{{"red",color.redComponent},{"green",color.greenComponent},{"blue",color.blueComponent},{"white",0},{"macro","off"},{"program","off"}}}} path:"/api/v1/dmx" continuous:YES];}
- (Json)withValue:(Json)value key:(const std::string&)key command:(Json)command {
    for(auto nesting:{"sync","controls","route","apc"})if(command.contains(nesting)){command[nesting][key]=value;return command;}command[key]=value;return command;
}
- (void)send:(Json)command path:(const std::string&)path {[self send:command path:path continuous:NO];}
- (void)send:(Json)command path:(const std::string&)path continuous:(BOOL)continuous {
    if(path.starts_with("/api/v1/leds/")&&command.contains("route")){auto id=path.substr(13);auto fixtures=_model->presentationSnapshot()["state"]["fixtures"];for(const auto& f:fixtures)if(f.value("id",std::string{})==id&&f.value("kind",std::string{})!="virtual")_selectedFixture=id;}
    std::string key;if(continuous){auto shape=command;auto eraseValues=[&](auto&& self,Json& node)->void{if(node.is_object())for(auto& value:node)self(self,value);else node=nullptr;};eraseValues(eraseValues,shape);key=path+shape.dump();}
    command["revision"]=_model->presentationSnapshot()["revision"];std::string method=path=="/api/v1/leds"?"PUT":path.starts_with("/api/v1/leds/")?"PATCH":"POST";__weak VJControls* weak=self;++_changing;VJSubmitUiCommand(_model,method,path,command,^(const vj::Reply& reply){VJControls* owner=weak;if(!owner||!owner->_model)return;owner->_status.stringValue=reply.status>=400?text(reply.body.value("error",std::string("Command failed"))):@"";--owner->_changing;owner->_revision=UINT64_MAX;[owner refresh];},key);

}
- (void)sliderChanged:(VJControlSlider*)sender {double value=sender.doubleValue;if(sender->step>0){value=std::round(value/sender->step)*sender->step;sender.doubleValue=value;}Json n=(sender->key=="address"||sender->key=="port")?Json(int(std::round(value))):Json(value);[self send:[self withValue:n key:sender->key command:sender->command] path:sender->path continuous:YES];for(NSView* sibling in sender.superview.subviews)if([sibling isKindOfClass:VJControlField.class]){auto field=(VJControlField*)sibling;field.stringValue=field->scale==100?[NSString stringWithFormat:@"%.0f%%",value*100]:field->step==5?[NSString stringWithFormat:value>0?@"%+.0f":@"%.0f",value]:[NSString stringWithFormat:@"%.3g",value];}}
- (void)fieldChanged:(VJControlField*)sender {Json value;if(sender->key=="host")value=sender.stringValue.UTF8String;else if(sender->key=="cast")value=sender.stringValue.length?Json(sender.stringValue.UTF8String):Json();else {double number;NSString* raw=sender->scale==100?[sender.stringValue stringByReplacingOccurrencesOfString:@"%" withString:@""]:sender.stringValue;NSScanner* scan=[NSScanner scannerWithString:raw];if(![scan scanDouble:&number]||!scan.isAtEnd||!std::isfinite(number)){_status.stringValue=@"Invalid number";return;}number/=sender->scale;if(sender->step>0)number=std::clamp(std::round(number/sender->step)*sender->step,-500.,500.);value=(sender->key=="address"||sender->key=="port")?Json(int(std::round(number))):Json(number);}[self send:[self withValue:value key:sender->key command:sender->command] path:sender->path];}
- (void)toggleChanged:(VJControlButton*)sender {[self send:[self withValue:sender.state==NSControlStateValueOn key:sender->key command:sender->command] path:sender->path];}
- (void)choiceChanged:(VJControlPopup*)sender {if(sender.indexOfSelectedItem>=0)[self send:[self withValue:sender->values.at(sender.indexOfSelectedItem) key:sender->key command:sender->command] path:sender->path];}
- (void)pressed:(VJControlButton*)sender {[self send:sender->command path:sender->path];}
@end
