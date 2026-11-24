#import "native_network.hpp"
#import "native_style.hpp"
namespace {NSString* networkText(const std::string& s){return [NSString stringWithUTF8String:s.c_str()]?:@"";}NSStackView* networkStack(NSUserInterfaceLayoutOrientation orientation){return vj::style::stack(orientation);}NSString* metric(const vj::Json& value,NSString* suffix){return value.is_number()?[NSString stringWithFormat:@"%.1f%@",value.get<double>(),suffix]:@"—";}}
@interface VJNetworkContent : NSView @end
@implementation VJNetworkContent
- (void)drawRect:(NSRect)dirty{[vj::style::panel()setFill];NSRectFill(dirty);}
@end
@interface VJNetworkDocument : NSStackView @end
@implementation VJNetworkDocument
- (BOOL)isFlipped{return YES;}
@end
@interface VJNetworkWindow : NSWindow @end
@implementation VJNetworkWindow
- (void)cancelOperation:(id)sender{[self performClose:sender];}
- (void)performClose:(id)sender{if([self.delegate respondsToSelector:@selector(windowShouldClose:)]){if([self.delegate windowShouldClose:self])[self close];}else [super performClose:sender];}
@end
@interface VJNetwork()<NSWindowDelegate>@end
@implementation VJNetwork {
 vj::Model* _model;NSWindow* _window;NSStackView* _clients;NSScrollView* _scroll;NSButton* _close;BOOL _liveServices;NSTextField* _status;NSTextField* _diagnostics;NSButton* _discovery;NSTimer* _timer;BOOL _busy,_commandBusy,_stopped,_discovering;dispatch_group_t _tasks;
}
- (instancetype)initWithModel:(vj::Model*)model{if((self=[super init])){_model=model;_tasks=dispatch_group_create();[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(terminating:) name:NSApplicationWillTerminateNotification object:nil];}return self;}
- (void)dealloc{[_timer invalidate];[[NSNotificationCenter defaultCenter] removeObserver:self];}
- (void)terminating:(NSNotification*)note{(void)note;[self stop];}
- (void)stop{if(_stopped)return;_stopped=YES;[_timer invalidate];_timer=nil;if(_liveServices)_model->request("POST","/api/v1/ndi/clients/discover",{{"enabled",false}});dispatch_group_wait(_tasks,DISPATCH_TIME_FOREVER);if(_window.sheetParent)[_window.sheetParent endSheet:_window];[_window orderOut:nil];}
- (void)showForWindow:(NSWindow*)parent { [self showForWindow:parent liveServices:YES]; }
- (void)showForWindow:(NSWindow*)parent liveServices:(BOOL)liveServices {
 if(_stopped)return;_liveServices=liveServices;
 if(!_window){
  _window=[[VJNetworkWindow alloc] initWithContentRect:NSMakeRect(0,0,850,610) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
  _window.contentView=[[VJNetworkContent alloc]initWithFrame:_window.contentView.bounds];_window.title=@"Network";_window.contentMinSize=NSMakeSize(720,480);_window.releasedWhenClosed=NO;_window.delegate=self;
  _window.appearance=[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];_window.backgroundColor=vj::style::panel();
  // Keep window sizing independent of the stack's changing intrinsic size.
  auto root=networkStack(NSUserInterfaceLayoutOrientationVertical);root.translatesAutoresizingMaskIntoConstraints=NO;[_window.contentView addSubview:root];
  [NSLayoutConstraint activateConstraints:@[[root.leadingAnchor constraintEqualToAnchor:_window.contentView.leadingAnchor constant:16],[root.trailingAnchor constraintEqualToAnchor:_window.contentView.trailingAnchor constant:-16],[root.topAnchor constraintEqualToAnchor:_window.contentView.topAnchor constant:16],[root.bottomAnchor constraintEqualToAnchor:_window.contentView.bottomAnchor constant:-16]]];
  auto bar=networkStack(NSUserInterfaceLayoutOrientationHorizontal);[root addArrangedSubview:bar];[bar.widthAnchor constraintEqualToAnchor:root.widthAnchor].active=YES;
  auto title=[NSTextField labelWithString:@"Network"];title.font=vj::style::headingFont();[bar addArrangedSubview:title];
  auto spacer=[[NSView alloc]init];[bar addArrangedSubview:spacer];[spacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
  _discovery=[NSButton buttonWithTitle:@"Start discovery" target:self action:@selector(discover:)];[bar addArrangedSubview:_discovery];
  auto refresh=[NSButton buttonWithTitle:@"Refresh" target:self action:@selector(refreshAction:)];[bar addArrangedSubview:refresh];
  _close=[NSButton buttonWithTitle:@"Close" target:self action:@selector(close:)];_close.keyEquivalent=@"\e";[bar addArrangedSubview:_close];
  for(NSButton* button in @[_discovery,refresh,_close]){[button.heightAnchor constraintEqualToConstant:vj::style::controlHeight].active=YES;[button.widthAnchor constraintGreaterThanOrEqualToConstant:button==_discovery?144:80].active=YES;[button setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];}
  _status=[NSTextField labelWithString:@"0 online · 0 known"];_status.lineBreakMode=NSLineBreakByTruncatingTail;[root addArrangedSubview:_status];[_status.widthAnchor constraintEqualToAnchor:root.widthAnchor].active=YES;
  _scroll=[[NSScrollView alloc]init];_scroll.hasVerticalScroller=YES;_scroll.autohidesScrollers=YES;_scroll.drawsBackground=NO;[root addArrangedSubview:_scroll];[_scroll.widthAnchor constraintEqualToAnchor:root.widthAnchor].active=YES;[_scroll.heightAnchor constraintGreaterThanOrEqualToConstant:180].active=YES;[_scroll setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationVertical];
  _clients=[[VJNetworkDocument alloc]init];_clients.orientation=NSUserInterfaceLayoutOrientationVertical;_clients.alignment=NSLayoutAttributeLeading;_clients.spacing=14;_clients.translatesAutoresizingMaskIntoConstraints=NO;_scroll.documentView=_clients;[_clients.widthAnchor constraintEqualToAnchor:_scroll.contentView.widthAnchor].active=YES;
  _diagnostics=[NSTextField wrappingLabelWithString:@""];_diagnostics.font=[NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];_diagnostics.maximumNumberOfLines=5;[root addArrangedSubview:_diagnostics];[_diagnostics.widthAnchor constraintEqualToAnchor:root.widthAnchor].active=YES;
  [self renderClients:vj::Json::array() master:""];vj::style::apply(root);
 }
 if(!_window.sheetParent)[parent beginSheet:_window completionHandler:nil];
 [_timer invalidate];_timer=nil;
 if(_liveServices){__weak VJNetwork* weakSelf=self;_timer=[NSTimer scheduledTimerWithTimeInterval:3 repeats:YES block:^(NSTimer* timer){(void)timer;[weakSelf refresh];}];[self command:"POST" path:"/api/v1/ndi/clients/discover" body:{{"enabled",true}}];}
}
- (BOOL)windowShouldClose:(NSWindow*)sender{(void)sender;[self close:nil];return NO;}
- (void)close:(id)sender{(void)sender;[_timer invalidate];_timer=nil;if(_window.sheetParent)[_window.sheetParent endSheet:_window];[_window orderOut:nil];}
- (void)refreshAction:(id)sender{(void)sender;[self refresh];}
- (void)discover:(id)sender{(void)sender;[self command:"POST" path:"/api/v1/ndi/clients/discover" body:{{"enabled",!_discovering}}];}
- (void)refresh{
 if(_stopped||_busy||_commandBusy||!_window.visible)return;_busy=YES;
 dispatch_group_async(_tasks,dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{auto clients=self->_model->request("GET","/api/v1/ndi/clients");auto network=self->_model->request("GET","/api/v1/network");auto stats=self->_model->request("GET","/api/v1/stats");dispatch_async(dispatch_get_main_queue(),^{self->_busy=NO;if(self->_stopped||self->_commandBusy)return;
  if(clients.status>=300){self->_status.stringValue=networkText(clients.body.value("error",std::string("Receiver service unavailable")));return;}
  self->_discovering=clients.body.value("discovering",false);self->_discovery.title=self->_discovering?@"Stop discovery":@"Start discovery";auto list=clients.body.value("clients",vj::Json::array());unsigned online=0;for(auto& client:list)online+=client.value("online",false);self->_status.stringValue=[NSString stringWithFormat:@"%u online · %lu known%@",online,(unsigned long)list.size(),clients.body.value("error",std::string{}).empty()?@"":[@" · " stringByAppendingString:networkText(clients.body["error"])]];
  if(![self->_window.firstResponder isKindOfClass:[NSTextView class]])[self renderClients:list master:clients.body.value("master_id",std::string{})];
  NSMutableArray<NSString*>* lines=[NSMutableArray array];if(network.status==200){auto data=network.body;[lines addObject:[NSString stringWithFormat:@"%@ · API %d",networkText(data.value("hostname",std::string{})),data.value("serverPort",0)]];for(auto& interface:data.value("interfaces",vj::Json::array()))if(interface.value("up",false)&&!interface.value("addresses",vj::Json::array()).empty()){std::string addresses;for(auto& address:interface["addresses"]){if(!addresses.empty())addresses+=", ";addresses+=address.get<std::string>();}[lines addObject:[NSString stringWithFormat:@"%@: %@",networkText(interface.value("name",std::string{})),networkText(addresses)]];}
   auto wled=data.value("wled",vj::Json::object());[lines addObject:[NSString stringWithFormat:@"WLED %@ · %@ · %@",networkText(wled.value("host",std::string{})),wled.value("online",false)?@"online":@"offline",wled.value("online",false)?metric(wled.value("latencyMs",vj::Json()),@" ms"):networkText(wled.value("error",vj::Json()).is_string()?wled["error"].get<std::string>():std::string{})]];
  }else [lines addObject:networkText(network.body.value("error",std::string("Network unavailable")))];if(stats.status==200){auto system=stats.body.value("system",vj::Json::object()),memory=system.value("memory",vj::Json::object()),disk=system.value("disk",vj::Json::object());[lines addObject:[NSString stringWithFormat:@"CPU %@ · Memory %@ · Disk %@",metric(system.value("cpuPercent",vj::Json()),@"%"),metric(memory.value("usedPercent",vj::Json()),@"%"),metric(disk.value("usedPercent",vj::Json()),@"%")]];auto renderer=stats.body.value("renderer",vj::Json::object());[lines addObject:[NSString stringWithFormat:@"Renderer %@ · Sample %@",renderer.value("stale",true)?@"stale":@"connected",metric(renderer.value("sampleAgeSeconds",vj::Json()),@" s")]];}
  self->_diagnostics.stringValue=[lines componentsJoinedByString:@"\n"];self->_diagnostics.toolTip=self->_diagnostics.stringValue;
 });});
}
- (void)renderClients:(const vj::Json&)clients master:(const std::string&)master{
 for(NSView* view in [self->_clients.arrangedSubviews copy]){[self->_clients removeArrangedSubview:view];[view removeFromSuperview];}
 for(const auto& client:clients){std::string id=client.value("id",std::string{});BOOL online=client.value("online",false);auto section=networkStack(NSUserInterfaceLayoutOrientationVertical);auto title=networkStack(NSUserInterfaceLayoutOrientationHorizontal);auto name=[NSTextField labelWithString:networkText(client.value("name",id)+(online?" · online":" · offline"))];name.font=[NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];[title addArrangedSubview:name];auto restart=[NSButton buttonWithTitle:@"Restart player" target:self action:@selector(restart:)];restart.identifier=networkText(id);restart.enabled=online;[restart.widthAnchor constraintEqualToConstant:130].active=YES;[restart.heightAnchor constraintEqualToConstant:vj::style::controlHeight].active=YES;[title addArrangedSubview:restart];[section addArrangedSubview:title];
  for(const auto& input:client.value("inputs",vj::Json::array())){auto row=networkStack(NSUserInterfaceLayoutOrientationHorizontal);auto label=[NSTextField labelWithString:networkText(input.value("name",input.value("id",std::string{})))];[label.widthAnchor constraintEqualToConstant:130].active=YES;[row addArrangedSubview:label];std::string path="/api/v1/ndi/clients/"+id+"/inputs/"+input.at("id").get<std::string>();auto source=[[VJPopup alloc] initWithFrame:NSZeroRect pullsDown:NO];[source addItemWithTitle:@"Disconnected"];source.lastItem.representedObject=@"";auto binding=input.value("managed",vj::Json());std::string assigned=binding.is_object()&&binding.value("master_id",std::string{})==master?binding.value("projector",std::string{}):"";for(int p=1;p<=4;p++){[source addItemWithTitle:[NSString stringWithFormat:@"Projector %d",p]];source.lastItem.representedObject=networkText(std::to_string(p));if(assigned==std::to_string(p))[source selectItem:source.lastItem];}if(assigned.empty()&&!input.value("source",std::string{}).empty()){[source addItemWithTitle:@"External source"];source.lastItem.representedObject=nil;[source selectItem:source.lastItem];}source.target=self;source.action=@selector(assign:);source.identifier=networkText(path);source.enabled=online;[source.widthAnchor constraintEqualToConstant:180].active=YES;[source.heightAnchor constraintEqualToConstant:vj::style::controlHeight].active=YES;[row addArrangedSubview:source];
   auto rotation=[NSButton checkboxWithTitle:@"180°" target:self action:@selector(rotate:)];rotation.state=input.value("rotate_180",false)?NSControlStateValueOn:NSControlStateValueOff;rotation.identifier=networkText(path);rotation.enabled=online;[rotation.widthAnchor constraintEqualToConstant:70].active=YES;[rotation.heightAnchor constraintEqualToConstant:vj::style::controlHeight].active=YES;[row addArrangedSubview:rotation];[row addArrangedSubview:[NSTextField labelWithString:@"Buffer ms"]];auto buffer=[[NSTextField alloc] initWithFrame:NSMakeRect(0,0,55,24)];buffer.integerValue=input.value("buffer_ms",0);buffer.identifier=networkText(path);buffer.target=self;buffer.action=@selector(buffer:);buffer.enabled=online;[buffer.widthAnchor constraintEqualToConstant:55].active=YES;[buffer.heightAnchor constraintEqualToConstant:vj::style::controlHeight].active=YES;[row addArrangedSubview:buffer];[section addArrangedSubview:row];
  }
  if(client.contains("routing_error")||client.contains("error")){auto error=[NSTextField wrappingLabelWithString:networkText(client.value("routing_error",client.value("error",std::string{})))];error.textColor=NSColor.systemOrangeColor;[section addArrangedSubview:error];}[self->_clients addArrangedSubview:section];
 }
 if(clients.empty())[self->_clients addArrangedSubview:[NSTextField labelWithString:@"No receivers"]];vj::style::apply(_clients);
}
- (void)command:(const std::string&)method path:(const std::string&)path body:(const vj::Json&)body{if(_stopped||_commandBusy)return;_commandBusy=YES;_status.stringValue=@"Connecting…";const std::string m=method,p=path;const vj::Json b=body;dispatch_group_async(_tasks,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{auto result=self->_model->request(m,p,b);dispatch_async(dispatch_get_main_queue(),^{self->_commandBusy=NO;if(self->_stopped)return;if(result.status>=300){self->_status.stringValue=networkText(result.body.value("error",std::string("Receiver unavailable")));return;}[self refresh];});});}
- (vj::Json)checkInterface {
 vj::Json result=vj::Json::object();NSWindow* parent=_window.sheetParent;
 auto settle=[&]{[_window.contentView layoutSubtreeIfNeeded];[[NSRunLoop mainRunLoop]runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.15]];[_window.contentView layoutSubtreeIfNeeded];};
 auto capture=[&](NSString* name){const char* directory=getenv("VJ_UI_CAPTURE_DIR");if(!directory)return;auto view=_window.contentView;auto bitmap=[view bitmapImageRepForCachingDisplayInRect:view.bounds];[view cacheDisplayInRect:view.bounds toBitmapImageRep:bitmap];NSString* folder=networkText(directory);[[NSFileManager defaultManager]createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];[[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}]writeToFile:[folder stringByAppendingPathComponent:[name stringByAppendingString:@".png"]] atomically:YES];};
 settle();result["Network opens at usable size"]=_window.contentView.bounds.size.width>=720&&_window.contentView.bounds.size.height>=480&&parent!=nil;
 BOOL geometry=YES;for(NSValue* size in @[[NSValue valueWithSize:NSMakeSize(720,480)],[NSValue valueWithSize:NSMakeSize(1000,700)],[NSValue valueWithSize:NSMakeSize(850,610)]]){[_window setContentSize:size.sizeValue];settle();auto rect=[_close convertRect:_close.bounds toView:_window.contentView];geometry=geometry&&NSContainsRect(_window.contentView.bounds,rect)&&rect.size.width>=80&&rect.size.height>=30&&_scroll.frame.size.width>600&&_scroll.frame.size.height>=180;}
 result["Network resize preserves Close and receivers"]=bool(geometry);capture(@"network-empty");
 vj::Json clients=vj::Json::array();for(int i=0;i<12;++i)clients.push_back({{"id",std::to_string(i)},{"name","Receiver "+std::to_string(i+1)},{"online",false},{"inputs",vj::Json::array({{{"id","1"},{"name","HDMI 1"},{"source",""},{"buffer_ms",40}}})}});
 _status.stringValue=@"0 online · 12 known";_diagnostics.stringValue=@"vj-test · API 9120\nen0: 192.0.2.10\nWLED 192.0.2.20 · offline\nCPU 0.0% · Memory 10.0% · Disk 20.0%\nRenderer connected · Sample 0.1 s";[self renderClients:clients master:"test"];settle();[_scroll.contentView scrollToPoint:NSZeroPoint];result["Network receiver list starts at top"]=_clients.isFlipped&&_clients.frame.size.height>_scroll.contentView.bounds.size.height&&_scroll.contentView.bounds.origin.y==0;capture(@"network-receivers");
 [_close performClick:nil];settle();result["Network Close dismisses modal sheet"]=_window.sheetParent==nil&&parent.attachedSheet==nil&&!_window.visible;
 [self showForWindow:parent liveServices:NO];settle();auto escape=[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:_window.windowNumber context:nil characters:@"\e" charactersIgnoringModifiers:@"\e" isARepeat:NO keyCode:53];[_window performKeyEquivalent:escape];settle();result["Network Escape dismisses modal sheet"]=_window.sheetParent==nil&&!_window.visible;
 [self showForWindow:parent liveServices:NO];settle();[_window performClose:nil];settle();result["Network window close dismisses modal sheet"]=_window.sheetParent==nil&&!_window.visible;
 [self showForWindow:parent liveServices:NO];settle();result["Network reopens after dismissal"]=_window.sheetParent==parent&&_window.visible&&_window.contentView.bounds.size.width>=720;[_close performClick:nil];settle();
 return result;
}
- (void)assign:(NSPopUpButton*)sender{NSString* value=sender.selectedItem.representedObject;if(!value)return;[self command:"PUT" path:sender.identifier.UTF8String body:{{"projector",value.length?vj::Json(value.UTF8String):vj::Json()}}];}
- (void)rotate:(NSButton*)sender{[self command:"PUT" path:sender.identifier.UTF8String body:{{"rotate_180",sender.state==NSControlStateValueOn}}];}
- (void)buffer:(NSTextField*)sender{char* end=nullptr;const char* raw=sender.stringValue.UTF8String;long n=std::strtol(raw,&end,10);if(end==raw||*end||n<0||n>500){_status.stringValue=@"Buffer must be 0–500 ms";return;}[self command:"PUT" path:sender.identifier.UTF8String body:{{"buffer_ms",n}}];}
- (void)restart:(NSButton*)sender{[self command:"POST" path:"/api/v1/ndi/clients/"+std::string(sender.identifier.UTF8String)+"/restart" body:vj::Json::object()];}
@end
namespace {NSMutableDictionary<NSValue*,VJNetwork*>* networkWindows(){static NSMutableDictionary* windows;static dispatch_once_t once;dispatch_once(&once,^{windows=[NSMutableDictionary dictionary];});return windows;}}
void VJOpenNetwork(vj::Model* model,NSWindow* parent,bool liveServices){auto key=[NSValue valueWithPointer:model];auto registry=networkWindows();auto view=registry[key];if(!view){view=[[VJNetwork alloc] initWithModel:model];registry[key]=view;}[view showForWindow:parent liveServices:liveServices];}
void VJCloseNetworks(vj::Model* model){auto key=[NSValue valueWithPointer:model];auto registry=networkWindows();[registry[key] stop];[registry removeObjectForKey:key];}

vj::Json VJCheckNetwork(vj::Model* model){return [networkWindows()[[NSValue valueWithPointer:model]] checkInterface];}
