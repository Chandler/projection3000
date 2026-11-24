#import "native_style.hpp"
#import "native_source_browser.hpp"
#include "live_sources.hpp"

namespace {NSString* ns(const std::string& value){return [NSString stringWithUTF8String:value.c_str()]?:@"";}}
@interface VJSourceBrowser : NSWindowController<NSTableViewDataSource,NSTableViewDelegate,NSWindowDelegate> {
    vj::Model* _model;
    std::string _generator,_current;
    vj::Json _items;
    NSTableView* _table;
    NSTextField* _status;
    NSTextField* _extraIPs;
    NSButton* _scan;
    NSButton* _use;
    BOOL _busy,_closed;
    dispatch_group_t _tasks;
    void (^_completion)(vj::Json);
}
- (instancetype)initWithModel:(vj::Model*)model generator:(const std::string&)generator current:(const std::string&)current completion:(void(^)(vj::Json))completion;
@end
@implementation VJSourceBrowser
- (instancetype)initWithModel:(vj::Model*)model generator:(const std::string&)generator current:(const std::string&)current completion:(void(^)(vj::Json))completion {
    auto window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,600,440) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    if((self=[super initWithWindow:window])){
        _model=model;_generator=generator;_current=vj::normalizeLiveSelection(generator,current);_completion=[completion copy];_items=vj::Json::array();_tasks=dispatch_group_create();
        window.title=generator=="ndi"?@"NDI Sources":generator=="syphon"?@"Syphon Sources":@"Cameras";window.releasedWhenClosed=NO;window.delegate=self;
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(waitForDiscovery:) name:NSApplicationWillTerminateNotification object:nil];
        auto root=[[NSStackView alloc] initWithFrame:window.contentView.bounds];root.orientation=NSUserInterfaceLayoutOrientationVertical;root.alignment=NSLayoutAttributeLeading;root.spacing=12;root.edgeInsets=NSEdgeInsetsMake(16,16,16,16);root.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;vj::style::mount(window,root);
        if(generator=="ndi"){
            auto line=[[NSStackView alloc] initWithFrame:NSZeroRect];line.orientation=NSUserInterfaceLayoutOrientationHorizontal;line.spacing=8;
            [line addArrangedSubview:[NSTextField labelWithString:@"Remote IPs"]];_extraIPs=[[NSTextField alloc] initWithFrame:NSZeroRect];[_extraIPs.heightAnchor constraintEqualToConstant:vj::style::controlHeight].active=YES;_extraIPs.placeholderString=@"192.168.1.10, 192.168.1.11";
            if(!_current.empty())_extraIPs.stringValue=ns(vj::Json::parse(_current).value("extra_ips",std::string{}));
            [line addArrangedSubview:_extraIPs];[_extraIPs.widthAnchor constraintEqualToConstant:420].active=YES;[root addArrangedSubview:line];
        }
        _table=[[NSTableView alloc] initWithFrame:NSZeroRect];_table.delegate=self;_table.dataSource=self;_table.target=self;_table.doubleAction=@selector(use:);_table.rowHeight=28;
        for(NSString* title in @[@"Source",@"Status"]){auto column=[[NSTableColumn alloc] initWithIdentifier:title];column.title=title;column.width=[title isEqualToString:@"Source"]?430:90;[_table addTableColumn:column];}
        auto scroll=[[NSScrollView alloc] initWithFrame:NSZeroRect];scroll.documentView=_table;scroll.hasVerticalScroller=YES;[root addArrangedSubview:scroll];[scroll.widthAnchor constraintEqualToAnchor:root.widthAnchor constant:-32].active=YES;[scroll.heightAnchor constraintEqualToConstant:285].active=YES;
        _status=[NSTextField labelWithString:@"Not scanned"];_status.lineBreakMode=NSLineBreakByTruncatingTail;[root addArrangedSubview:_status];[_status.widthAnchor constraintEqualToAnchor:scroll.widthAnchor].active=YES;
        auto actions=[[NSStackView alloc] initWithFrame:NSZeroRect];actions.orientation=NSUserInterfaceLayoutOrientationHorizontal;actions.spacing=8;
        _scan=[NSButton buttonWithTitle:@"Scan" target:self action:@selector(scan:)];[actions addArrangedSubview:_scan];[actions addArrangedSubview:[NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancel:)]];
        _use=[NSButton buttonWithTitle:@"Use source" target:self action:@selector(use:)];_use.keyEquivalent=@"\r";_use.enabled=NO;[actions addArrangedSubview:_use];[root addArrangedSubview:actions];
        vj::style::window(window);[self retainCurrent];[_table reloadData];if(!_items.empty())[_table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    }return self;
}
- (void)dealloc{[[NSNotificationCenter defaultCenter] removeObserver:self];}
- (void)waitForDiscovery:(NSNotification*)notification{(void)notification;_closed=YES;dispatch_group_wait(_tasks,DISPATCH_TIME_FOREVER);}
- (void)retainCurrent {
    if(_current.empty())return;
    for(const auto& source:_items)if(vj::normalizeLiveSelection(_generator,source.value("selection",std::string{}))==_current)return;
    std::string label=_current;
    if(_generator!="usb_webcam"){const auto item=vj::Json::parse(_current);label=item.value("app",std::string{});const auto name=item.value("name",std::string{});if(!label.empty()&&!name.empty())label+=" — ";label+=name;if(label.empty())label=item.value("uuid",std::string("Saved source"));}
    _items.insert(_items.begin(),{{"label",label},{"selection",_current},{"saved",true}});
}
- (void)scan:(id)sender {
    (void)sender;if(_busy||_closed)return;
    std::string extra;
    try{if(_generator=="ndi")extra=vj::normalizeNdiExtraIPs(_extraIPs.stringValue.UTF8String);}
    catch(const std::exception& error){_status.stringValue=ns(error.what());return;}
    _busy=YES;_scan.enabled=NO;_use.enabled=NO;_extraIPs.enabled=NO;_status.stringValue=@"Scanning…";
    const std::string route=_generator=="usb_webcam"?"/api/cameras":"/api/v1/sources/"+_generator;
    dispatch_group_async(_tasks,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        auto response=self->_model->request("GET",route,{{"extra_ips",extra}});
        dispatch_async(dispatch_get_main_queue(),^{
            if(self->_closed)return;
            self->_busy=NO;self->_scan.enabled=YES;self->_extraIPs.enabled=YES;
            self->_items=response.body.value("sources",vj::Json::array());
            if(!self->_items.is_array())self->_items=vj::Json::array();
            for(auto& source:self->_items){if(!source.contains("selection")&&source.contains("device"))source["selection"]=source["device"];source["saved"]=false;}
            [self retainCurrent];[self->_table reloadData];self->_use.enabled=NO;
            if(response.status!=200||!response.body.value("available",false))self->_status.stringValue=ns(response.body.value("error",std::string("Discovery unavailable")));
            else self->_status.stringValue=[NSString stringWithFormat:@"%lu sources",(unsigned long)response.body.value("sources",vj::Json::array()).size()];
            for(size_t i=0;i<self->_items.size();++i)if(vj::normalizeLiveSelection(self->_generator,self->_items[i].value("selection",std::string{}))==self->_current){[self->_table selectRowIndexes:[NSIndexSet indexSetWithIndex:i] byExtendingSelection:NO];break;}
        });
    });
}
- (NSInteger)numberOfRowsInTableView:(NSTableView*)tableView{(void)tableView;return _items.size();}
- (NSView*)tableView:(NSTableView*)tableView viewForTableColumn:(NSTableColumn*)column row:(NSInteger)row{
    (void)tableView;const auto& item=_items.at(row);auto label=[NSTextField labelWithString:[column.identifier isEqualToString:@"Source"]?ns(item.value("label",std::string{})):(item.value("saved",false)?@"Saved":@"Available")];label.lineBreakMode=NSLineBreakByTruncatingMiddle;return label;
}
- (void)tableViewSelectionDidChange:(NSNotification*)notification{(void)notification;_use.enabled=!_busy&&_table.selectedRow>=0;}
- (void)use:(id)sender{
    (void)sender;if(_busy||_closed||_table.selectedRow<0)return;auto source=_items.at(_table.selectedRow);auto selection=vj::normalizeLiveSelection(_generator,source.value("selection",std::string{}));
    if(selection.empty()){_status.stringValue=@"Invalid source";return;}source["selection"]=selection;if(_completion)_completion(source);[self cancel:nil];
}
- (BOOL)windowShouldClose:(NSWindow*)sender{(void)sender;[self cancel:nil];return NO;}
- (void)cancel:(id)sender{(void)sender;if(_closed)return;_closed=YES;[self.window.sheetParent endSheet:self.window];[self close];}
@end
void VJChooseLiveSource(vj::Model* model,NSWindow* parent,const std::string& generator,const std::string& current,void (^completion)(vj::Json source)){
    auto browser=[[VJSourceBrowser alloc] initWithModel:model generator:generator current:current completion:completion];
    [parent beginSheet:browser.window completionHandler:^(NSModalResponse response){(void)response;[browser close];}];
}
