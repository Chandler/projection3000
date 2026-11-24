#import "native_style.hpp"
#import "native_media_browser.hpp"
#include "media_library.hpp"
#include <set>

namespace {
NSString* ns(const std::string& value){return [NSString stringWithUTF8String:value.c_str()]?:@"";}
}
@interface VJMediaBrowser : NSWindowController<NSTableViewDataSource,NSTableViewDelegate,NSSearchFieldDelegate,NSWindowDelegate> {
    vj::Model* _model;
    vj::Json _items;
    vj::Json _filtered;
    NSTableView* _table;
    NSPopUpButton* _drive;NSButton* _up;std::string _relative,_parent;std::set<std::string> _pendingSelection;BOOL _listingBusy,_multiple;
    NSSearchField* _search;
    NSTextField* _status;
    NSButton* _use;
    NSButton* _import;
    BOOL _busy,_closed,_metadataBusy;
    NSUInteger _selectionGeneration;
    NSImageView* _poster;
    NSTextField* _metadata;
    NSPopUpButton* _subtitles;
    NSButton* _optimize;
    NSButton* _cancelProcessing;
    NSTextField* _processingStatus;
    NSTimer* _processingTimer;
    dispatch_group_t _tasks;
    void (^_completion)(vj::Json);
}
- (instancetype)initWithModel:(vj::Model*)model multiple:(BOOL)multiple completion:(void(^)(vj::Json))completion;
@end
@implementation VJMediaBrowser
- (instancetype)initWithModel:(vj::Model*)model multiple:(BOOL)multiple completion:(void(^)(vj::Json))completion {
    auto window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,620,740) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    if((self=[super initWithWindow:window])){
        _tasks=dispatch_group_create();[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(waitForImport:) name:NSApplicationWillTerminateNotification object:nil];
        _model=model;_multiple=multiple;_completion=[completion copy];window.title=multiple?@"Add collection media":@"Media";window.releasedWhenClosed=NO;window.delegate=self;
        auto root=[[NSStackView alloc] initWithFrame:window.contentView.bounds];root.orientation=NSUserInterfaceLayoutOrientationVertical;root.alignment=NSLayoutAttributeLeading;root.spacing=10;root.edgeInsets=NSEdgeInsetsMake(16,16,16,16);root.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;vj::style::mount(window,root);
        _search=[[NSSearchField alloc] initWithFrame:NSZeroRect];_search.placeholderString=@"Search media";_search.delegate=self;[_search.heightAnchor constraintEqualToConstant:vj::style::controlHeight].active=YES;[root addArrangedSubview:_search];[_search.widthAnchor constraintEqualToAnchor:root.widthAnchor constant:-32].active=YES;
        auto locations=[[NSStackView alloc] initWithFrame:NSZeroRect];locations.orientation=NSUserInterfaceLayoutOrientationHorizontal;locations.spacing=8;
        _drive=[[VJPopup alloc] initWithFrame:NSZeroRect pullsDown:NO];[_drive addItemWithTitle:@"All library media"];_drive.lastItem.representedObject=@"";_drive.target=self;_drive.action=@selector(location:);[_drive.widthAnchor constraintEqualToConstant:460].active=YES;[locations addArrangedSubview:_drive];_up=[NSButton buttonWithTitle:@"Up" target:self action:@selector(up:)];_up.enabled=NO;[locations addArrangedSubview:_up];[root addArrangedSubview:locations];
        _table=[[NSTableView alloc] initWithFrame:NSZeroRect];_table.delegate=self;_table.dataSource=self;_table.target=self;_table.doubleAction=@selector(use:);_table.allowsEmptySelection=YES;_table.allowsMultipleSelection=multiple;_table.rowHeight=26;
        for(NSString* name in @[@"Name",@"Type",@"Location"]){auto column=[[NSTableColumn alloc] initWithIdentifier:name];column.title=name;column.width=[name isEqualToString:@"Name"]?280:([name isEqualToString:@"Type"]?60:180);[_table addTableColumn:column];}
        auto scroll=[[NSScrollView alloc] initWithFrame:NSZeroRect];scroll.documentView=_table;scroll.hasVerticalScroller=YES;[root addArrangedSubview:scroll];[scroll.widthAnchor constraintEqualToAnchor:_search.widthAnchor].active=YES;[scroll.heightAnchor constraintEqualToConstant:280].active=YES;
        auto details=[[NSStackView alloc] initWithFrame:NSZeroRect];details.orientation=NSUserInterfaceLayoutOrientationHorizontal;details.spacing=12;
        _poster=[[NSImageView alloc] initWithFrame:NSZeroRect];_poster.imageScaling=NSImageScaleProportionallyUpOrDown;[_poster.widthAnchor constraintEqualToConstant:220].active=YES;[_poster.heightAnchor constraintEqualToConstant:124].active=YES;[details addArrangedSubview:_poster];
        _metadata=[NSTextField labelWithString:@""];_metadata.usesSingleLineMode=NO;_metadata.cell.wraps=YES;[_metadata.widthAnchor constraintEqualToConstant:320].active=YES;[details addArrangedSubview:_metadata];[root addArrangedSubview:details];
        auto subtitlesRow=[[NSStackView alloc] initWithFrame:NSZeroRect];subtitlesRow.orientation=NSUserInterfaceLayoutOrientationHorizontal;subtitlesRow.spacing=8;[subtitlesRow addArrangedSubview:[NSTextField labelWithString:@"Subtitles"]];
        _subtitles=[[VJPopup alloc] initWithFrame:NSZeroRect pullsDown:NO];[_subtitles addItemWithTitle:@"Off"];_subtitles.lastItem.representedObject=@"";_subtitles.enabled=NO;[_subtitles.widthAnchor constraintEqualToConstant:420].active=YES;[subtitlesRow addArrangedSubview:_subtitles];[root addArrangedSubview:subtitlesRow];
        auto processingRow=[[NSStackView alloc] initWithFrame:NSZeroRect];processingRow.orientation=NSUserInterfaceLayoutOrientationHorizontal;processingRow.spacing=8;
        _optimize=[NSButton buttonWithTitle:@"Prepare proxies" target:self action:@selector(preprocess:)];[processingRow addArrangedSubview:_optimize];_cancelProcessing=[NSButton buttonWithTitle:@"Stop" target:self action:@selector(cancelProcessing:)];[processingRow addArrangedSubview:_cancelProcessing];_processingStatus=[NSTextField labelWithString:@""];[processingRow addArrangedSubview:_processingStatus];[root addArrangedSubview:processingRow];
        __weak VJMediaBrowser* weakSelf=self;_processingTimer=[NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer* timer){(void)timer;[weakSelf refreshProcessing];}];[self refreshProcessing];
        _status=[NSTextField labelWithString:@""];[root addArrangedSubview:_status];
        auto actions=[[NSStackView alloc] initWithFrame:NSZeroRect];actions.orientation=NSUserInterfaceLayoutOrientationHorizontal;actions.spacing=8;
        _import=[NSButton buttonWithTitle:@"Import…" target:self action:@selector(import:)];[actions addArrangedSubview:_import];
        [actions addArrangedSubview:[NSButton buttonWithTitle:@"Refresh" target:self action:@selector(refresh:)]];
        [actions addArrangedSubview:[NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancel:)]];
        _use=[NSButton buttonWithTitle:(_multiple?@"Add selected":@"Use media") target:self action:@selector(use:)];_use.keyEquivalent=@"\r";[actions addArrangedSubview:_use];[root addArrangedSubview:actions];
        vj::style::window(window);[self refresh:nil];
    }return self;
}
- (void)dealloc{[_processingTimer invalidate];[[NSNotificationCenter defaultCenter] removeObserver:self];}
- (void)waitForImport:(NSNotification*)notification{(void)notification;_closed=YES;[_processingTimer invalidate];dispatch_group_wait(_tasks,DISPATCH_TIME_FOREVER);}
- (void)location:(id)sender {(void)sender;_relative.clear();_search.stringValue=@"";[self refresh:nil];}
- (void)up:(id)sender {(void)sender;if(_listingBusy)return;_relative=_parent;_search.stringValue=@"";[self refresh:nil];}
- (void)refresh:(id)sender {
    (void)sender;if(_busy||_listingBusy||_closed)return;_listingBusy=YES;_table.enabled=NO;_drive.enabled=NO;_up.enabled=NO;_use.enabled=NO;_status.stringValue=@"Loading…";
    const std::string selected=[_drive.selectedItem.representedObject UTF8String]?:"",relative=_relative;
    dispatch_group_async(_tasks,dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        auto drives=self->_model->request("GET","/api/v1/media/drives");auto response=self->_model->request("GET",selected.empty()?"/api/v1/media/catalog":"/api/removable/"+selected+"/browse",{{"path",relative}});
        dispatch_async(dispatch_get_main_queue(),^{self->_listingBusy=NO;if(self->_closed)return;self->_drive.enabled=YES;self->_table.enabled=YES;
            [self->_drive removeAllItems];[self->_drive addItemWithTitle:@"All library media"];self->_drive.lastItem.representedObject=@"";bool found=selected.empty();
            if(drives.status==200)for(const auto& drive:drives.body.value("drives",vj::Json::array())){[self->_drive addItemWithTitle:ns(drive.at("name"))];self->_drive.lastItem.representedObject=ns(drive.at("id"));if(drive.at("id")==selected){[self->_drive selectItem:self->_drive.lastItem];found=true;}}
            if(!found){[self->_drive addItemWithTitle:@"Disconnected drive"];self->_drive.lastItem.representedObject=ns(selected);[self->_drive selectItem:self->_drive.lastItem];}
            self->_items=response.status==200?response.body.value(selected.empty()?"items":"entries",vj::Json::array()):vj::Json::array();self->_parent=response.body.value("parent",std::string{});self->_relative=response.body.value("path",relative);self->_up.enabled=!selected.empty()&&!self->_relative.empty();[self filter];
            if(!self->_pendingSelection.empty()){auto indexes=[NSMutableIndexSet indexSet];for(size_t i=0;i<self->_filtered.size();++i)if(self->_pendingSelection.contains(self->_filtered[i].value("file",std::string{})))[indexes addIndex:i];[self->_table selectRowIndexes:indexes byExtendingSelection:NO];if(indexes.count)[self->_table scrollRowToVisible:indexes.firstIndex];self->_pendingSelection.clear();}
            if(response.status!=200)self->_status.stringValue=ns(response.body.value("error",std::string("Media unavailable")));
        });
    });
}
- (void)resetSubtitles {[_subtitles removeAllItems];[_subtitles addItemWithTitle:@"Off"];_subtitles.lastItem.representedObject=@"";_subtitles.enabled=NO;}
- (void)refreshProcessing {
    if(_closed)return;auto response=_model->request("GET","/api/v1/media/preprocess");if(response.status!=200)return;const auto& value=response.body;auto state=value.value("state",std::string("idle"));BOOL running=state=="running";_optimize.enabled=!running;_cancelProcessing.enabled=running;
    _processingStatus.stringValue=state=="idle"?@"":ns(state+" · "+std::to_string(value.value("completed",0))+"/"+std::to_string(value.value("total",0)));auto errors=value.value("errors",vj::Json::array());_processingStatus.toolTip=errors.empty()?nil:ns(errors.back().value("error",std::string{}));
}
- (void)preprocess:(id)sender {(void)sender;auto response=_model->request("POST","/api/v1/media/preprocess");if(response.status<200||response.status>=300)_processingStatus.stringValue=ns(response.body.value("error",std::string("Preprocessing unavailable")));else [self refreshProcessing];}
- (void)cancelProcessing:(id)sender {(void)sender;_model->request("POST","/api/v1/media/preprocess/cancel");[self refreshProcessing];}
- (void)filter { [self resetSubtitles];
    ++_selectionGeneration;_poster.image=nil;_metadata.stringValue=@"";_filtered=vj::Json::array();NSString* query=_search.stringValue;
    for(const auto& item:_items){NSString* path=ns(item.value("path",std::string{}));if(query.length==0||[path rangeOfString:query options:NSCaseInsensitiveSearch|NSDiacriticInsensitiveSearch].location!=NSNotFound)_filtered.push_back(item);}
    [_table deselectAll:nil];[_table reloadData];_use.enabled=NO;_use.title=_multiple?@"Add selected":@"Use media";_status.stringValue=[NSString stringWithFormat:@"%lu items",(unsigned long)_filtered.size()];
}
- (void)controlTextDidChange:(NSNotification*)notification{(void)notification;[self filter];}
- (NSInteger)numberOfRowsInTableView:(NSTableView*)tableView{(void)tableView;return _filtered.size();}
- (NSView*)tableView:(NSTableView*)tableView viewForTableColumn:(NSTableColumn*)column row:(NSInteger)row {
    (void)tableView;const auto& item=_filtered.at(row);std::string value;
    if([column.identifier isEqualToString:@"Name"])value=item.value("name",std::string{});
    else if([column.identifier isEqualToString:@"Type"])value=item.value("type",std::string{});
    else value=item.value("origin",std::string{})+" / "+item.value("path",std::string{});
    auto label=[NSTextField labelWithString:ns(value)];label.lineBreakMode=NSLineBreakByTruncatingMiddle;return label;
}
- (void)tableViewSelectionDidChange:(NSNotification*)notification {
    (void)notification;[self resetSubtitles];++_selectionGeneration;_poster.image=nil;_metadata.stringValue=@"";
    NSUInteger files=0;auto indexes=_table.selectedRowIndexes;
    for(NSUInteger i=indexes.firstIndex;i!=NSNotFound;i=[indexes indexGreaterThanIndex:i])if(i<_filtered.size()&&_filtered[i].value("type",std::string{})!="directory")++files;
    BOOL folder=indexes.count==1&&files==0&&indexes.firstIndex<_filtered.size();
    _use.enabled=!_busy&&!_listingBusy&&(files>0||folder);
    _use.title=folder?@"Open folder":_multiple?[NSString stringWithFormat:@"Add %lu item%@",(unsigned long)files,files==1?@"":@"s"]:@"Use media";
    if(indexes.count>1)_metadata.stringValue=[NSString stringWithFormat:@"%lu media files selected",(unsigned long)files];else [self loadMetadata];
}
- (void)loadMetadata {
    if(_closed||_metadataBusy||_table.numberOfSelectedRows!=1||_table.selectedRow<0||_filtered.at(_table.selectedRow).value("type",std::string{})=="directory")return;
    const auto file=_filtered.at(_table.selectedRow).at("file");const bool video=_filtered.at(_table.selectedRow).value("type",std::string{})=="video";const auto generation=_selectionGeneration;
    _metadataBusy=YES;_metadata.stringValue=@"Loading…";
    dispatch_group_async(_tasks,dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        auto response=self->_model->request("POST","/api/v1/media/inspect",{{"file",file},{"thumbnail",true}});
        vj::Json tracks=vj::Json::array();std::string subtitleError;if(video){auto result=self->_model->request("GET","/api/videos/subtitles",{{"file",file}});if(result.status==200)tracks=result.body.value("tracks",vj::Json::array());else subtitleError=result.body.value("error",std::string("Subtitles unavailable"));}
        dispatch_async(dispatch_get_main_queue(),^{
            self->_metadataBusy=NO;if(self->_closed)return;if(generation!=self->_selectionGeneration){[self loadMetadata];return;}
            for(const auto& track:tracks){[self->_subtitles addItemWithTitle:ns(track.value("label",std::string("Subtitle")))];self->_subtitles.lastItem.representedObject=ns(track.at("id"));}self->_subtitles.enabled=video&&!tracks.empty();self->_subtitles.toolTip=subtitleError.empty()?nil:ns(subtitleError);
            if(response.status!=200||!response.body.contains("metadata")){self->_metadata.stringValue=ns(response.body.value("error",std::string("Metadata unavailable")));return;}
            const auto& details=response.body.at("metadata");const double seconds=details.value("durationSeconds",0.);
            NSMutableArray<NSString*>* lines=[NSMutableArray array];
            [lines addObject:[NSString stringWithFormat:@"%d × %d",details.value("width",0),details.value("height",0)]];
            if(seconds>0)[lines addObject:[NSString stringWithFormat:@"%d:%05.2f · %.2f fps",(int)(seconds/60),fmod(seconds,60),details.value("frameRate",0.)]];
            [lines addObject:ns(details.value("codec",std::string{}))];
            if(details.value("hasAudio",false))[lines addObject:@"Audio"];
            if(details.value("rotationDegrees",0)!=0)[lines addObject:[NSString stringWithFormat:@"Rotation %d°",details.value("rotationDegrees",0)]];
            self->_metadata.stringValue=[lines componentsJoinedByString:@"\n"];
            if(details.contains("thumbnail")){const auto& thumbnail=details["thumbnail"];auto data=[[NSData alloc] initWithBase64EncodedString:ns(thumbnail.value("data",std::string{})) options:0];self->_poster.image=[[NSImage alloc] initWithData:data];}
        });
    });
}
- (void)use:(id)sender {
    (void)sender;if(_busy||_listingBusy||_table.selectedRow<0)return;
    auto indexes=_table.selectedRowIndexes;vj::Json selected=vj::Json::array();
    if(indexes.count==1){auto item=_filtered.at(indexes.firstIndex);if(item.value("type",std::string{})=="directory"){_relative=item.at("path");_search.stringValue=@"";[self refresh:nil];return;}}
    for(NSUInteger i=indexes.firstIndex;i!=NSNotFound;i=[indexes indexGreaterThanIndex:i]){
        if(i>=_filtered.size())continue;auto item=_filtered.at(i);if(item.value("type",std::string{})=="directory")continue;
        auto response=_model->request("POST","/api/v1/media/status",{{"file",item["file"]},{"type",item["type"]}});
        if(response.status!=200||!response.body.value("available",false)){_status.stringValue=ns("Media missing: "+item.value("name",std::string{}));return;}
        if(!_multiple&&item.value("type",std::string{})=="video")item["subtitle_track"]=std::string([_subtitles.selectedItem.representedObject UTF8String]?:"");
        selected.push_back(std::move(item));
    }
    if(selected.empty())return;
    if(_completion)_completion(_multiple?selected:selected.front());[self cancel:nil];
}
- (BOOL)windowShouldClose:(NSWindow*)sender{(void)sender;[self cancel:nil];return NO;}
- (void)cancel:(id)sender{(void)sender;if(_busy)return;_closed=YES;[_processingTimer invalidate];[self.window.sheetParent endSheet:self.window];[self close];}
- (void)import:(id)sender {
    (void)sender;if(_busy)return;
    auto panel=[NSOpenPanel openPanel];panel.canChooseDirectories=NO;panel.allowsMultipleSelection=_multiple;panel.allowedFileTypes=@[@"png",@"jpg",@"jpeg",@"webp",@"mp4",@"mov",@"webm",@"avi",@"mkv",@"m4v"];
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result){
        if(result!=NSModalResponseOK)return;
        self->_busy=YES;self->_import.enabled=NO;self->_use.enabled=NO;self->_status.stringValue=@"Importing…";
        NSArray<NSURL*>* urls=[panel.URLs copy];
        dispatch_group_async(_tasks,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
            std::set<std::string> imported;std::string errors;
            for(NSURL* url in urls){auto response=self->_model->request("POST","/api/v1/media/import",{{"path",std::string(url.path.UTF8String)}});if(response.status==200||response.status==201)imported.insert(response.body.at("item").at("file").get<std::string>());else{if(!errors.empty())errors+="\n";errors+=std::string(url.lastPathComponent.UTF8String)+": "+response.body.value("error",std::string("Import failed"));}}
            dispatch_async(dispatch_get_main_queue(),^{
                if(self->_closed)return;
                self->_busy=NO;self->_import.enabled=YES;
                if(!imported.empty()){self->_pendingSelection=imported;self->_search.stringValue=@"";[self->_drive selectItemAtIndex:0];self->_relative.clear();[self refresh:nil];}
                if(!errors.empty()){auto alert=[NSAlert new];alert.messageText=@"Some files could not be imported";alert.informativeText=ns(errors);[alert beginSheetModalForWindow:self.window completionHandler:nil];}
            });
        });
    }];
}
@end
void VJChooseMedia(vj::Model* model,NSWindow* parent,void (^completion)(vj::Json item)){
    auto browser=[[VJMediaBrowser alloc] initWithModel:model multiple:NO completion:completion];
    [parent beginSheet:browser.window completionHandler:^(NSModalResponse response){(void)response;[browser close];}];
}

void VJChooseMediaItems(vj::Model* model,NSWindow* parent,void (^completion)(vj::Json items)){
    auto browser=[[VJMediaBrowser alloc] initWithModel:model multiple:YES completion:completion];
    [parent beginSheet:browser.window completionHandler:^(NSModalResponse response){(void)response;[browser close];}];
}

@interface VJSubtitleChooser : NSWindowController<NSWindowDelegate> {
    vj::Model* _model;
    std::string _file;
    NSPopUpButton* _tracks;
    NSTextField* _status;
    NSButton* _apply;
    BOOL _closed;
    dispatch_group_t _tasks;
    void (^_completion)(std::string);
}
- (instancetype)initWithModel:(vj::Model*)model file:(const std::string&)file current:(const std::string&)current completion:(void(^)(std::string))completion;
@end
@implementation VJSubtitleChooser
- (instancetype)initWithModel:(vj::Model*)model file:(const std::string&)file current:(const std::string&)current completion:(void(^)(std::string))completion {
    auto window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,460,160) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    if((self=[super initWithWindow:window])){
        _model=model;_file=file;_completion=[completion copy];_tasks=dispatch_group_create();window.title=@"Subtitles";window.delegate=self;window.releasedWhenClosed=NO;
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(terminating:) name:NSApplicationWillTerminateNotification object:nil];
        auto stack=[[NSStackView alloc] initWithFrame:window.contentView.bounds];stack.orientation=NSUserInterfaceLayoutOrientationVertical;stack.alignment=NSLayoutAttributeLeading;stack.spacing=12;stack.edgeInsets=NSEdgeInsetsMake(16,16,16,16);stack.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;vj::style::mount(window,stack);
        _tracks=[[VJPopup alloc] initWithFrame:NSZeroRect pullsDown:NO];[_tracks addItemWithTitle:@"Off"];_tracks.lastItem.representedObject=@"";[stack addArrangedSubview:_tracks];[_tracks.widthAnchor constraintEqualToConstant:420].active=YES;
        _status=[NSTextField labelWithString:@"Loading…"];_status.lineBreakMode=NSLineBreakByTruncatingTail;[stack addArrangedSubview:_status];[_status.widthAnchor constraintEqualToConstant:420].active=YES;
        auto actions=[[NSStackView alloc] initWithFrame:NSZeroRect];actions.orientation=NSUserInterfaceLayoutOrientationHorizontal;actions.spacing=8;[actions addArrangedSubview:[NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancel:)]];_apply=[NSButton buttonWithTitle:@"Apply" target:self action:@selector(apply:)];_apply.enabled=NO;_apply.keyEquivalent=@"\r";[actions addArrangedSubview:_apply];[stack addArrangedSubview:actions];
        vj::style::window(window);const std::string selectedTrack=current,reference=file;
        if(!selectedTrack.empty()){[_tracks addItemWithTitle:ns("Track "+selectedTrack)];_tracks.lastItem.representedObject=ns(selectedTrack);[_tracks selectItem:_tracks.lastItem];}
        dispatch_group_async(_tasks,dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
            auto response=self->_model->request("GET","/api/videos/subtitles",{{"file",reference}});
            dispatch_async(dispatch_get_main_queue(),^{if(self->_closed)return;self->_apply.enabled=YES;
                if(response.status!=200){self->_status.stringValue=ns(response.body.value("error",std::string("Subtitles unavailable")));self->_status.toolTip=self->_status.stringValue;return;}
                auto tracks=response.body.value("tracks",vj::Json::array());[self->_tracks removeAllItems];[self->_tracks addItemWithTitle:@"Off"];self->_tracks.lastItem.representedObject=@"";bool found=selectedTrack.empty();for(auto& track:tracks){[self->_tracks addItemWithTitle:ns(track.value("label",std::string("Subtitle")))];self->_tracks.lastItem.representedObject=ns(track.at("id"));if(track.at("id")==selectedTrack){[self->_tracks selectItem:self->_tracks.lastItem];found=true;}}
                if(!found){[self->_tracks addItemWithTitle:ns("Unavailable track "+selectedTrack)];self->_tracks.lastItem.representedObject=ns(selectedTrack);[self->_tracks selectItem:self->_tracks.lastItem];}
                self->_status.stringValue=tracks.empty()?@"No text subtitle tracks":[NSString stringWithFormat:@"%lu tracks",(unsigned long)tracks.size()];
            });
        });
    }return self;
}
- (void)dealloc{[[NSNotificationCenter defaultCenter] removeObserver:self];}
- (void)terminating:(NSNotification*)notification{(void)notification;_closed=YES;dispatch_group_wait(_tasks,DISPATCH_TIME_FOREVER);}
- (BOOL)windowShouldClose:(NSWindow*)window{(void)window;[self cancel:nil];return NO;}
- (void)cancel:(id)sender{(void)sender;_closed=YES;[self.window.sheetParent endSheet:self.window];[self close];}
- (void)apply:(id)sender{(void)sender;std::string track=[_tracks.selectedItem.representedObject UTF8String]?:"";if(!track.empty())_model->request("POST","/api/v1/media/subtitles/prepare",{{"file",_file},{"track",track},{"retry",true}});if(_completion)_completion(track);[self cancel:nil];}
@end
void VJChooseSubtitles(vj::Model* model,NSWindow* parent,const std::string& file,const std::string& current,void (^completion)(std::string track)){
    auto chooser=[[VJSubtitleChooser alloc] initWithModel:model file:file current:current completion:completion];[parent beginSheet:chooser.window completionHandler:^(NSModalResponse response){(void)response;[chooser close];}];
}
