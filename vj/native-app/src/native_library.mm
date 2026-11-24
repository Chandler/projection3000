#import "native_library.hpp"
#import "native_thumbnails.hpp"
#import "native_style.hpp"
#include <atomic>
#include <set>
using J=vj::Json;
static NSString* ns(const std::string& s){return [NSString stringWithUTF8String:s.c_str()]?:@"";}
namespace {
NSString* fitted(NSString* text,CGFloat width,NSFont* font){if([text sizeWithAttributes:@{NSFontAttributeName:font}].width<=width)return text;while(text.length&&[[text stringByAppendingString:@"…"]sizeWithAttributes:@{NSFontAttributeName:font}].width>width)text=[text substringToIndex:[text rangeOfComposedCharacterSequenceAtIndex:text.length-1].location];return [text stringByAppendingString:@"…"];}
J payload(const J& item){return {{"effect",item.at("effect")},{"name",item.at("name")},{"params",item.at("params")}};}
J filesAt(const J& items,const std::string& folder){
 J rows=J::array();std::set<std::string> directories;const auto prefix=folder.empty()?"":folder+"/";
 if(!folder.empty())rows.push_back({{"kind","folder"},{"name","‹  "+(std::filesystem::path(folder).parent_path().empty()?std::string("Files"):std::filesystem::path(folder).parent_path().filename().string())},{"path",std::filesystem::path(folder).parent_path().generic_string()}});
 J files=J::array();for(const auto& item:items){if(item.value("section",std::string{})!="Files")continue;const auto path=item.value("path",std::string{});if(!path.starts_with(prefix))continue;const auto relative=path.substr(prefix.size());const auto slash=relative.find('/');if(slash!=std::string::npos)directories.insert(relative.substr(0,slash));else files.push_back(item);}
 for(const auto& dir:directories)rows.push_back({{"kind","folder"},{"name",dir},{"path",prefix+dir}});
 for(const auto& file:files)rows.push_back(file);return rows;
}
NSString* placeholder(const J& item){auto e=item.value("effect",std::string{});return e=="video"?@"▶":e=="image"?@"▧":e=="ndi"||e=="syphon"||e=="usb_webcam"?@"●":e.starts_with("trace_")?@"∿":@"◇";}
}
@interface VJLibraryCell : NSView { @public J item;NSImage* poster;BOOL open; }
@end
@implementation VJLibraryCell
- (BOOL)isFlipped{return YES;}
- (NSView*)hitTest:(NSPoint)point {(void)point;return nil;} // The table owns selection and drag tracking.
- (void)drawRect:(NSRect)dirty {
 (void)dirty;auto kind=item.value("kind",std::string("clip"));auto name=ns(item.value("name",std::string{}));auto rect=self.bounds;if(self.enclosingScrollView)rect.size.width=MIN(rect.size.width,self.enclosingScrollView.contentSize.width-8);
 auto attributes=@{NSFontAttributeName:vj::style::font(11),NSForegroundColorAttributeName:vj::style::text()};
 if(kind=="section"){
  [vj::style::border() setFill];NSRectFill(NSMakeRect(0,rect.size.height-1,rect.size.width,1));
  [(open?@"⌄":@"›") drawAtPoint:NSMakePoint(8,5) withAttributes:attributes];[fitted(name,MAX(0,rect.size.width-54),vj::style::font(11)) drawAtPoint:NSMakePoint(25,7) withAttributes:attributes];
  auto count=ns(std::to_string(item.value("count",size_t(0))));auto size=[count sizeWithAttributes:attributes];[count drawAtPoint:NSMakePoint(rect.size.width-size.width-8,7) withAttributes:@{NSFontAttributeName:vj::style::font(10),NSForegroundColorAttributeName:vj::style::secondary()}];return;
 }
 if(kind=="patchParameter"||kind=="group"||kind=="status"||kind=="folder"){
  auto paragraph=[NSMutableParagraphStyle new];paragraph.lineBreakMode=NSLineBreakByTruncatingMiddle;
  [name drawInRect:NSMakeRect(kind=="folder"?25:8,5,MAX(0,rect.size.width-33),20) withAttributes:@{NSFontAttributeName:vj::style::font(kind=="status"?10:11),NSForegroundColorAttributeName:kind=="status"?vj::style::secondary():vj::style::text(),NSParagraphStyleAttributeName:paragraph}];
  if(kind=="folder"&&!item.value("name",std::string{}).starts_with("‹"))[@"▸" drawAtPoint:NSMakePoint(8,5) withAttributes:attributes];return;
 }
 auto thumb=NSMakeRect(0,0,58,rect.size.height);[vj::style::background() setFill];NSRectFill(thumb);
 if(poster){auto source=NSMakeRect(0,0,poster.size.width,poster.size.height);double target=thumb.size.width/thumb.size.height,ratio=source.size.width/MAX(1,source.size.height);if(ratio>target){double w=source.size.height*target;source.origin.x=(source.size.width-w)/2;source.size.width=w;}else{double h=source.size.width/target;source.origin.y=(source.size.height-h)/2;source.size.height=h;}[poster drawInRect:thumb fromRect:source operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];}
 else{auto effect=item.value("effect",std::string{});BOOL live=effect=="ndi"||effect=="syphon"||effect=="usb_webcam";auto icon=effect=="usb_webcam"?@"Camera":live?@"No signal":placeholder(item);auto a=@{NSFontAttributeName:vj::style::font(live?9:16),NSForegroundColorAttributeName:vj::style::secondary()};auto size=[icon sizeWithAttributes:a];[icon drawAtPoint:NSMakePoint((58-size.width)/2,14) withAttributes:a];}
 auto p=[NSMutableParagraphStyle new];p.lineBreakMode=NSLineBreakByTruncatingTail;
 auto effect=item.value("effect",std::string{});std::string detail;auto title=item.value("name",std::string{});if(effect=="ndi"||effect=="syphon"){auto source=J::parse(item["params"].value("source",std::string{}),nullptr,false);if(source.is_object()){title=source.value("name",title);detail=source.value("app",std::string{});if(effect=="ndi"){auto begin=title.find(" (");if(begin!=std::string::npos&&title.ends_with(")")){detail=title.substr(0,begin);title=title.substr(begin+2,title.size()-begin-3);}}}}
 if(item.contains("patchID"))detail=(item.value("patchType",std::string{})=="collection"?"Collection effect":"Video")+std::string(item.value("available",false)?"":" · Offline");
 [fitted(ns(title),MAX(0,rect.size.width-70),vj::style::font(11)) drawInRect:NSMakeRect(66,detail.empty()?14:6,MAX(0,rect.size.width-70),18) withAttributes:@{NSFontAttributeName:vj::style::font(11),NSForegroundColorAttributeName:vj::style::text(),NSParagraphStyleAttributeName:p}];if(!detail.empty())[fitted(ns(detail),MAX(0,rect.size.width-70),vj::style::font(10)) drawInRect:NSMakeRect(66,25,MAX(0,rect.size.width-70),15) withAttributes:@{NSFontAttributeName:vj::style::font(10),NSForegroundColorAttributeName:vj::style::secondary(),NSParagraphStyleAttributeName:p}];
}
@end
@interface VJLibrary()<NSTableViewDataSource,NSTableViewDelegate>
@end
@implementation VJLibrary {vj::Model* _model;J _items,_rows,_sources,_sourceStatus,_patchItems;NSTableView* _table;NSTextField* _target;NSMutableSet* _collapsed;VJClipThumbnails* _thumbnails;dispatch_group_t _tasks;NSTimer* _timer;BOOL _busy,_liveBusy,_capture;std::atomic<bool> _closed;std::string _folder;NSTimeInterval _scanned;}
- (instancetype)initWithFrame:(NSRect)frame model:(vj::Model*)model {
 if((self=[super initWithFrame:frame])){_model=model;_capture=YES;_patchItems=J::array();_items=J::array();_rows=J::array();_sources=J::object();_sourceStatus=J::object();_tasks=dispatch_group_create();_collapsed=[NSMutableSet setWithArray:[NSUserDefaults.standardUserDefaults arrayForKey:@"VJLibraryCollapsedV2"]?:@[@"Cameras",@"Live",@"Files",@"Adjustment Layers",@"Surface collection effects",@"Traces",@"Vector Art",@"Raster Art"]];
 auto root=[NSStackView stackViewWithViews:@[]];root.orientation=NSUserInterfaceLayoutOrientationVertical;root.spacing=0;root.translatesAutoresizingMaskIntoConstraints=NO;[self addSubview:root];[NSLayoutConstraint activateConstraints:@[[root.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],[root.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],[root.topAnchor constraintEqualToAnchor:self.topAnchor],[root.bottomAnchor constraintEqualToAnchor:self.bottomAnchor]]];
 _target=[NSTextField labelWithString:@"Library"];_target.font=vj::style::font(10);_target.textColor=vj::style::secondary();_target.lineBreakMode=NSLineBreakByTruncatingTail;auto targetWrap=[[NSView alloc]init];[targetWrap addSubview:_target];_target.translatesAutoresizingMaskIntoConstraints=NO;[NSLayoutConstraint activateConstraints:@[[_target.leadingAnchor constraintEqualToAnchor:targetWrap.leadingAnchor constant:8],[_target.trailingAnchor constraintEqualToAnchor:targetWrap.trailingAnchor constant:-8],[_target.centerYAnchor constraintEqualToAnchor:targetWrap.centerYAnchor],[targetWrap.heightAnchor constraintEqualToConstant:vj::style::controlHeight]]];[root addArrangedSubview:targetWrap];[targetWrap.widthAnchor constraintEqualToAnchor:root.widthAnchor].active=YES;
 _table=[[NSTableView alloc]init];auto col=[[NSTableColumn alloc]initWithIdentifier:@"source"];col.minWidth=0;col.width=frame.size.width;col.resizingMask=NSTableColumnAutoresizingMask;[_table addTableColumn:col];_table.columnAutoresizingStyle=NSTableViewUniformColumnAutoresizingStyle;_table.style=NSTableViewStyleFullWidth;_table.headerView=nil;_table.rowHeight=46;_table.selectionHighlightStyle=NSTableViewSelectionHighlightStyleRegular;_table.intercellSpacing=NSMakeSize(0,1);_table.delegate=self;_table.dataSource=self;_table.target=self;_table.action=@selector(choose:);_table.backgroundColor=vj::style::panel();[_table setDraggingSourceOperationMask:NSDragOperationCopy forLocal:YES];
 auto scroll=[[NSScrollView alloc]init];scroll.documentView=_table;scroll.hasVerticalScroller=YES;[root addArrangedSubview:scroll];[scroll.widthAnchor constraintEqualToAnchor:root.widthAnchor].active=YES;[scroll.heightAnchor constraintGreaterThanOrEqualToConstant:150].active=YES;
 __weak VJLibrary* weak=self;_thumbnails=[[VJClipThumbnails alloc]initWithModel:model redraw:^{[weak redraw];}];_timer=[NSTimer timerWithTimeInterval:.4 repeats:YES block:^(NSTimer*){[weak tick];}];[[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];[self refresh];vj::style::apply(self);
 }return self;
}
- (void)layout {[super layout];auto width=_table.enclosingScrollView.contentSize.width;if(width>0){auto frame=_table.frame;frame.size.width=width;_table.frame=frame;_table.tableColumns[0].width=width;}}
- (void)setLivePreviewsEnabled:(BOOL)enabled {_capture=enabled;if(!enabled&&_sources.empty()){_sources={{"ndi",J::array()},{"syphon",J::array()},{"usb_webcam",J::array()}};[self filter];}[_thumbnails setLivePreviewsEnabled:enabled];}
- (J)filesForEffect:(const std::string&)effect {J files=J::array();for(const auto& item:_items)if(item.value("section",std::string{})=="Files"&&item["effect"]==effect)files.push_back(item);return files;}
- (J)sourcesForEffect:(const std::string&)effect {return _sources.value(effect,J::array());}
- (J)searchItems {
 J items=_items;for(const auto& item:_patchItems)if(item.contains("effect"))items.push_back(item);
 for(const auto* effect:{"usb_webcam","ndi","syphon"})for(const auto& source:_sources.value(effect,J::array())){
  items.push_back({{"section",std::string(effect)=="usb_webcam"?"Camera":std::string(effect)=="ndi"?"NDI":"Syphon"},{"effect",effect},{"name",source.value("label",source.value("name",std::string("Camera")))},{"params",{{std::string(effect)=="usb_webcam"?"device":"source",source.value("selection",source.value("device",std::string{}))}}}});
 }
 return items;
}
- (void)refreshSearchItems {[self refresh];[self discover];}
- (void)redraw {if(_closed)return;NSRange range=[_table rowsInRect:_table.visibleRect];for(NSUInteger r=range.location;r<NSMaxRange(range)&&r<_rows.size();++r){auto cell=(VJLibraryCell*)[_table viewAtColumn:0 row:r makeIfNecessary:NO];if(![cell isKindOfClass:VJLibraryCell.class]||!_rows[r].contains("effect"))continue;auto clip=_rows[r];clip["gen"]=clip["effect"];cell->poster=[_thumbnails imageForClip:clip];[cell setNeedsDisplay:YES];}}
- (void)tick {if(_closed||self.isHiddenOrHasHiddenAncestor||!self.window)return;[self refreshPatch];[self redraw];if([NSDate timeIntervalSinceReferenceDate]-_scanned>3)[self discover];}
- (void)setContext:(const J&)snapshot bus:(NSString*)bus target:(NSString*)target {[_thumbnails setContext:snapshot bus:bus];_target.stringValue=target;_target.toolTip=target;}
- (void)browse:(id)sender {(void)sender;if(self.browse)self.browse();}
- (void)reload:(id)sender {(void)sender;[self refresh];_scanned=0;[self discover];}
- (void)refresh {
 if(_closed||_busy)return;_busy=YES;
 dispatch_group_async(_tasks,dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{@autoreleasepool{
 J items=J::array();for(const auto& e:self->_model->effectCatalog()){auto name=e.at("name").get<std::string>();if(e.value("patchSource",false)||e.value("liveSource",false)||name=="image"||name=="video")continue;std::string section=e.value("adjustment",false)?"Adjustment Layers":name.starts_with("trace_")?"Traces":e.value("kind",std::string{})=="collection"?"Surface collection effects":e.value("vector",false)?"Vector Art":"Raster Art";J params=J::object();for(const auto& p:e.value("parameters",J::array()))params[p.at("name").get<std::string>()]=p.at("default");items.push_back({{"section",section},{"name",e.value("title",name)},{"effect",name},{"params",params}});}
 auto media=self->_model->request("GET","/api/v1/media/catalog");if(media.status==200)for(const auto& m:media.body.value("items",J::array())){auto kind=m.value("type",std::string{});if(kind!="image"&&kind!="video")continue;auto status=self->_model->request("POST","/api/v1/media/status",{{"file",m.at("file")},{"type",kind}});items.push_back({{"section","Files"},{"name",m.value("name",std::string{})},{"effect",kind},{"params",{{"file",m.at("file")}}},{"resolved_file",status.body.value("resolved_file",std::string{})},{"mediaStatus",status.body},{"path",m.value("path",std::string{})}});}
 dispatch_async(dispatch_get_main_queue(),^{if(self->_closed)return;self->_busy=NO;self->_items=items;[self filter];if(self.inventoryChanged)self.inventoryChanged();});
 }});
}
- (void)discover {
 if(_closed||_liveBusy||!_capture)return;_liveBusy=YES;_scanned=[NSDate timeIntervalSinceReferenceDate];
 dispatch_group_async(_tasks,dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{@autoreleasepool{
 J sources=J::object(),status=J::object();for(const auto* effect:{"usb_webcam","syphon","ndi"}){if(self->_closed)return;auto path=std::string(effect)=="usb_webcam"?"/api/cameras":"/api/v1/sources/"+std::string(effect);auto reply=self->_model->request("GET",path);sources[effect]=reply.body.value("sources",reply.body.value("cameras",J::array()));status[effect]=reply.body.value("error",std::string{});}
 dispatch_async(dispatch_get_main_queue(),^{if(self->_closed)return;self->_liveBusy=NO;BOOL changed=sources!=self->_sources||status!=self->_sourceStatus;self->_sources=sources;self->_sourceStatus=status;if(changed){[self filter];if(self.sourcesChanged)self.sourcesChanged();if(self.inventoryChanged)self.inventoryChanged();}});
 }});
}
- (void)refreshPatch {
 J items=J::array();for(const auto* type:{"video","collection","trace","palette","control"}){
  J group=J::array();for(const auto& source:_model->patchOutputs())if(source.value("listed",false)&&source.value("type",std::string{})==type){
   J item={{"name",source.value("name",std::string("Patch"))},{"patchID",source["id"]},{"patchType",type},{"available",source.value("available",false)},{"section","Patch"}};
   if(std::string(type)=="video"||std::string(type)=="collection"||std::string(type)=="trace"){item["effect"]=std::string("patch_")+type;item["params"]={{"source",source["id"]}};}else item["kind"]="patchParameter";
   group.push_back(item);
  }
  if(!group.empty()){items.push_back({{"kind","group"},{"name",std::string(type)=="video"?"Video":std::string(type)=="collection"?"Collection effects":std::string(type)=="trace"?"Trace effects":std::string(type)=="palette"?"Palettes":"Controls"}});for(const auto& item:group)items.push_back(item);}
 }
 if(items!=_patchItems){_patchItems=std::move(items);[self filter];if(self.inventoryChanged)self.inventoryChanged();if(self.sourcesChanged)self.sourcesChanged();}
}
- (void)filter {
 auto origin=_table.enclosingScrollView.contentView.bounds.origin;_rows=J::array();
 for(const auto* group:{"Patch","Cameras","Live","Files","Adjustment Layers","Surface collection effects","Traces","Vector Art","Raster Art"}){
  J children=J::array();size_t count=0;
  if(std::string(group)=="Patch"){children=_patchItems;for(const auto& item:children)if(item.contains("patchID"))++count;}
  else if(std::string(group)=="Cameras"||std::string(group)=="Live"){
   for(const auto* effect:{"usb_webcam","ndi","syphon"}){if((std::string(group)=="Cameras")!=(std::string(effect)=="usb_webcam"))continue;auto sources=_sources.value(effect,J::array());count+=sources.size();if(std::string(group)=="Live")children.push_back({{"kind","group"},{"name",std::string(effect)=="ndi"?"NDI":"Syphon"}});
    if(sources.empty())children.push_back({{"kind","status"},{"name",_sourceStatus.value(effect,std::string{}).empty()?(_sources.contains(effect)?"No sources":"Discovering…"):"Unavailable"}});
    for(const auto& source:sources)children.push_back({{"effect",effect},{"name",source.value("label",source.value("name",std::string("Camera")))},{"params",{{std::string(effect)=="usb_webcam"?"device":"source",source.value("selection",source.value("device",std::string{}))}}}});
   }
  }else if(std::string(group)=="Files"){for(const auto& item:_items)if(item["section"]==group)++count;children.push_back({{"kind","tools"}});children.push_back({{"kind","group"},{"name",_folder.empty()?"Files":_folder}});for(const auto& item:filesAt(_items,_folder))children.push_back(item);}
  else{for(const auto& item:_items)if(item["section"]==group)children.push_back(item);count=children.size();}
  _rows.push_back({{"kind","section"},{"name",group},{"count",count}});if(![_collapsed containsObject:ns(group)]){if(children.empty())children.push_back({{"kind","status"},{"name","No items"}});for(const auto& item:children)_rows.push_back(item);}
 }
 [_table reloadData];[_table.enclosingScrollView.contentView scrollToPoint:origin];
}
- (NSInteger)numberOfRowsInTableView:(NSTableView*)table {(void)table;return _rows.size();}
- (CGFloat)tableView:(NSTableView*)table heightOfRow:(NSInteger)row {(void)table;return _rows.at(row).contains("effect")?46:_rows.at(row).value("kind",std::string{})=="status"?24:30;}
- (NSView*)tableView:(NSTableView*)table viewForTableColumn:(NSTableColumn*)col row:(NSInteger)row {
 (void)table;(void)col;const auto& item=_rows.at(row);
 if(item.value("kind",std::string{})=="tools"){auto view=[NSStackView stackViewWithViews:@[[NSButton buttonWithTitle:@"Import…" target:self action:@selector(browse:)],[NSButton buttonWithTitle:@"↻" target:self action:@selector(reload:)]]];view.spacing=4;for(NSView* child in view.subviews){((NSControl*)child).font=vj::style::font(11);[child.heightAnchor constraintEqualToConstant:vj::style::controlHeight].active=YES;}return view;}
 auto cell=[[VJLibraryCell alloc]init];cell->item=item;cell->open=![_collapsed containsObject:ns(item.value("name",std::string{}))];if(item.contains("effect")){auto clip=item;clip["gen"]=clip["effect"];cell->poster=[_thumbnails imageForClip:clip];}cell.toolTip=ns(item.value("path",item.value("name",std::string{})));cell.accessibilityLabel=ns(item.value("name",std::string{}));return cell;
}
- (id<NSPasteboardWriting>)tableView:(NSTableView*)table pasteboardWriterForRow:(NSInteger)row {(void)table;if(row<0||row>=NSInteger(_rows.size())||!_rows[row].contains("effect"))return nil;auto item=[[NSPasteboardItem alloc]init];[item setString:ns(payload(_rows[row]).dump()) forType:@"com.vibe.clip"];return item;}
- (void)choose:(id)sender {(void)sender;NSInteger row=_table.clickedRow>=0?_table.clickedRow:_table.selectedRow;if(row<0||row>=NSInteger(_rows.size()))return;auto item=_rows.at(row);auto kind=item.value("kind",std::string{});if(kind=="section"){auto group=ns(item["name"]);if([_collapsed containsObject:group])[_collapsed removeObject:group];else [_collapsed addObject:group];[NSUserDefaults.standardUserDefaults setObject:_collapsed.allObjects forKey:@"VJLibraryCollapsedV2"];[self filter];[self discover];return;}if(kind=="folder"){_folder=item["path"];[self filter];return;}if(kind=="patchParameter"&&self.assignOutput)self.assignOutput(item,[_table viewAtColumn:0 row:row makeIfNecessary:YES]);if(item.contains("effect")&&self.insert)self.insert(payload(item));}
- (NSUInteger)readyLivePreviewCount {NSUInteger count=0;for(size_t i=0;i<_rows.size();++i)if(_rows[i].contains("effect")&&(_rows[i]["effect"]=="ndi"||_rows[i]["effect"]=="syphon")){auto cell=(VJLibraryCell*)[_table viewAtColumn:0 row:i makeIfNecessary:NO];if([cell isKindOfClass:VJLibraryCell.class]&&cell->poster)++count;}return count;}
- (J)checkInteractions:(const J&)sources {
 // Called only by --check-ui, with local test senders and isolated media.
 _sources=sources;_sourceStatus=J::object();_scanned=[NSDate timeIntervalSinceReferenceDate]+30;[_collapsed removeObject:@"Live"];[_collapsed removeObject:@"Files"];[self filter];
 bool drag=true;int count=0;for(size_t i=0;i<_rows.size();++i)if(_rows[i].contains("effect")&&(_rows[i]["effect"]=="ndi"||_rows[i]["effect"]=="syphon")){auto item=(NSPasteboardItem*)[self tableView:_table pasteboardWriterForRow:i];auto value=J::parse([[item stringForType:@"com.vibe.clip"] UTF8String]);drag&=value==payload(_rows[i]);++count;}
 bool folder=false;for(size_t i=0;i<_rows.size();++i)if(_rows[i].value("kind",std::string{})=="folder"){auto path=_rows[i]["path"].get<std::string>();[_table selectRowIndexes:[NSIndexSet indexSetWithIndex:i] byExtendingSelection:NO];[self choose:nil];folder=_folder==path&&!_folder.empty();for(size_t j=0;j<_rows.size();++j)if(_rows[j].value("kind",std::string{})=="folder"&&_rows[j]["path"]==""){[_table selectRowIndexes:[NSIndexSet indexSetWithIndex:j] byExtendingSelection:NO];[self choose:nil];folder=folder&&_folder.empty();break;}break;}
 [_table deselectAll:nil];[self filter];return {{"sourceDrags",drag&&count==2},{"folderNavigation",folder}};
}
- (void)stop {_closed=true;[_timer invalidate];dispatch_group_wait(_tasks,DISPATCH_TIME_FOREVER);[_thumbnails stop];}
@end
J VJCheckLibraryStructure(){J items={{{"section","Files"},{"effect","video"},{"name","Opening.mov"},{"path","Shows/Opening.mov"},{"params",{{"file","library://Shows/Opening.mov"}}}},{{"section","Files"},{"effect","image"},{"name","Title.png"},{"path","Title.png"},{"params",{{"file","library://Title.png"}}}}};auto root=filesAt(items,"");auto folder=filesAt(items,"Shows");auto live=payload({{"effect","syphon"},{"name","Fixture — Program"},{"params",{{"source",J({{"app","Fixture"},{"name","Program"},{"uuid","test"}}).dump()}}}});return {{"folders",root.size()==2&&root[0]["kind"]=="folder"&&folder.size()==2&&folder[1]["name"]=="Opening.mov"},{"dragIdentity",live["params"].contains("source")&&live["name"]=="Fixture — Program"}};}
