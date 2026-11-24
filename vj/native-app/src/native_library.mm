#import "native_library.hpp"
#import "native_thumbnails.hpp"
#import "native_style.hpp"
#include "library_items.hpp"
#include <atomic>
#include <set>
using J=vj::Json;
static NSString* ns(const std::string& s){return [NSString stringWithUTF8String:s.c_str()]?:@"";}
namespace {
void drawLine(NSString* value,NSRect box,NSFont* font,NSColor* color,NSLineBreakMode mode=NSLineBreakByTruncatingTail){
 if(NSWidth(box)<=0||NSHeight(box)<=0)return;
 auto style=[NSMutableParagraphStyle new];style.lineBreakMode=mode;
 [value drawInRect:box withAttributes:@{NSFontAttributeName:font,NSForegroundColorAttributeName:color,NSParagraphStyleAttributeName:style}];
}
J payload(const J& item){return vj::library::placement(item);}
J filesAt(const J& items,const std::string& folder){
 J rows=J::array();std::set<std::string> directories;const auto prefix=folder.empty()?"":folder+"/";
 if(!folder.empty())rows.push_back({{"kind","folder"},{"name","‹  "+(std::filesystem::path(folder).parent_path().empty()?std::string("Files"):std::filesystem::path(folder).parent_path().filename().string())},{"path",std::filesystem::path(folder).parent_path().generic_string()}});
 J files=J::array();for(const auto& item:items){if(item.value("section",std::string{})!="Files")continue;const auto path=item.value("path",std::string{});if(!path.starts_with(prefix))continue;const auto relative=path.substr(prefix.size());const auto slash=relative.find('/');if(slash!=std::string::npos)directories.insert(relative.substr(0,slash));else files.push_back(item);}
 for(const auto& dir:directories)rows.push_back({{"kind","folder"},{"name",dir},{"path",prefix+dir}});
 for(const auto& file:files)rows.push_back(file);return rows;
}
NSString* placeholder(const J& item){auto e=item.value("effect",std::string{});return e=="video"?@"▶":e=="image"?@"▧":e=="ndi"||e=="syphon"||e=="usb_webcam"?@"●":e.starts_with("trace_")?@"∿":@"◇";}
}
@interface VJLibraryScrollView : NSScrollView
@end
@implementation VJLibraryScrollView
- (void)tile {
 [super tile];
 auto table=(NSTableView*)self.documentView;
 if(![table isKindOfClass:NSTableView.class]||!table.tableColumns.count)return;
 CGFloat width=MAX(0,NSWidth(self.contentView.bounds));
 if(table.tableColumns[0].width!=width)table.tableColumns[0].width=width;
 if(NSWidth(table.frame)!=width)[table setFrameSize:NSMakeSize(width,NSHeight(table.frame))];
}
@end
@interface VJLibraryCell : NSView { @public J item;NSImage* poster;BOOL open;NSButton* star; }
@end
@implementation VJLibraryCell
- (BOOL)isFlipped{return YES;}
- (NSView*)hitTest:(NSPoint)point {if(star&&NSPointInRect([self convertPoint:point fromView:self.superview],star.frame))return star;return nil;} // The table owns selection and drag tracking.
- (void)drawRect:(NSRect)dirty {
 (void)dirty;auto kind=item.value("kind",std::string("clip"));auto name=ns(item.value("name",std::string{}));auto rect=self.bounds;
 if(star)rect.size.width=MAX(0,NSMinX(star.frame)-3);
 auto attributes=@{NSFontAttributeName:vj::style::font(11),NSForegroundColorAttributeName:vj::style::text()};
 if(kind=="section"){
  [vj::style::border() setFill];NSRectFill(NSMakeRect(0,rect.size.height-1,rect.size.width,1));
  CGFloat left=item.value("nested",false)?16:8;
  [(open?@"⌄":@"›") drawAtPoint:NSMakePoint(left,5) withAttributes:attributes];
  auto count=ns(std::to_string(item.value("count",size_t(0))));
  auto font=vj::style::font(10);CGFloat countWidth=ceil([count sizeWithAttributes:@{NSFontAttributeName:font}].width);
  CGFloat countX=NSWidth(rect)-8-countWidth;
  drawLine(name,NSMakeRect(left+17,7,countX-left-21,18),vj::style::font(11),vj::style::text());
  drawLine(count,NSMakeRect(countX,7,countWidth,18),font,vj::style::secondary());return;
 }
 if(kind=="subpatch"){
  auto type=item.value("patchType",std::string{});
  NSString* label=item.contains("processingInput")?@"Adjustment":type=="collection"?@"Surface collection":type=="trace"?@"Trace":type=="video"?@"Video":type=="palette"?@"Palette":@"Control";
  drawLine(name,NSMakeRect(8,4,NSWidth(rect)-16,18),vj::style::font(12),vj::style::text());
  drawLine(label,NSMakeRect(8,23,NSWidth(rect)-16,18),vj::style::font(11),vj::style::secondary());
  return;
 }
 if(kind=="patchParameter"||(kind=="unavailable"&&!item.contains("effect"))||kind=="group"||kind=="status"||kind=="folder"){
  auto paragraph=[NSMutableParagraphStyle new];paragraph.lineBreakMode=NSLineBreakByTruncatingMiddle;
  if(item.contains("available"))name=[name stringByAppendingString:item.value("available",false)?@" · Online":@" · Offline"];
  [name drawInRect:NSMakeRect(kind=="folder"?25:8,5,MAX(0,rect.size.width-33),20) withAttributes:@{NSFontAttributeName:vj::style::font(kind=="status"?10:11),NSForegroundColorAttributeName:kind=="status"?vj::style::secondary():vj::style::text(),NSParagraphStyleAttributeName:paragraph}];
  if(kind=="folder"&&!item.value("name",std::string{}).starts_with("‹"))[@"▸" drawAtPoint:NSMakePoint(8,5) withAttributes:attributes];return;
 }
 auto thumb=NSMakeRect(0,0,58,rect.size.height);[vj::style::background() setFill];NSRectFill(thumb);
 if(poster){auto source=NSMakeRect(0,0,poster.size.width,poster.size.height);double target=thumb.size.width/thumb.size.height,ratio=source.size.width/MAX(1,source.size.height);if(ratio>target){double w=source.size.height*target;source.origin.x=(source.size.width-w)/2;source.size.width=w;}else{double h=source.size.width/target;source.origin.y=(source.size.height-h)/2;source.size.height=h;}[poster drawInRect:thumb fromRect:source operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];}
 else{auto effect=item.value("effect",std::string{});BOOL live=effect=="ndi"||effect=="syphon"||effect=="usb_webcam";auto icon=effect=="usb_webcam"?@"Camera":live?@"No signal":placeholder(item);auto a=@{NSFontAttributeName:vj::style::font(live?9:16),NSForegroundColorAttributeName:vj::style::secondary()};auto size=[icon sizeWithAttributes:a];[icon drawAtPoint:NSMakePoint((58-size.width)/2,14) withAttributes:a];}
 auto effect=item.value("effect",std::string{});std::string detail;auto title=item.value("name",std::string{});if((effect=="ndi"||effect=="syphon")&&item.contains("available")){auto source=J::parse(item["params"].value("source",std::string{}),nullptr,false);if(source.is_object()){title=source.value("name",title);detail=source.value("app",std::string{});if(effect=="ndi"){auto begin=title.find(" (");if(begin!=std::string::npos&&title.ends_with(")")){detail=title.substr(0,begin);title=title.substr(begin+2,title.size()-begin-3);}}}}
 if(item.contains("patchID"))detail=item.value("patchType",std::string{});
 if(item.contains("available"))detail+=(detail.empty()?"":" · ")+std::string(item.value("available",false)?"Online":"Offline");
 drawLine(ns(title),NSMakeRect(66,detail.empty()?14:6,NSWidth(rect)-70,18),vj::style::font(11),vj::style::text());
 if(!detail.empty())drawLine(ns(detail),NSMakeRect(66,25,NSWidth(rect)-70,15),vj::style::font(10),vj::style::secondary());
}
@end
@interface VJLibrary()<NSTableViewDataSource,NSTableViewDelegate>
@end
@implementation VJLibrary {vj::Model* _model;J _items,_rows,_sources,_sourceStatus,_patchItems,_favorites,_templates,_boundSources;uint64_t _boundRevision;NSString* _libraryError;BOOL _sharedBusy;NSUInteger _pinRevision;NSTimeInterval _sharedScan;NSTableView* _table;NSTextField* _target;NSMutableSet* _collapsed;VJClipThumbnails* _thumbnails;dispatch_group_t _tasks;NSTimer* _timer;BOOL _busy,_liveBusy,_capture;std::atomic<bool> _closed;std::string _folder;NSTimeInterval _scanned;}
- (instancetype)initWithFrame:(NSRect)frame model:(vj::Model*)model {
 if((self=[super initWithFrame:frame])){self.clipsToBounds=YES;_model=model;_capture=YES;_boundRevision=UINT64_MAX;_boundSources=J::object();_favorites=J::array();_templates=J::array();_patchItems=J::array();_items=J::array();_rows=J::array();_sources=J::object();_sourceStatus=J::object();_tasks=dispatch_group_create();_collapsed=[NSMutableSet setWithArray:[NSUserDefaults.standardUserDefaults arrayForKey:@"VJLibraryCollapsedV3"]?:@[@"Cameras",@"Source nodes",@"Files",@"Adjustment Layers",@"Surface collection effects",@"Traces",@"Vector Art",@"Raster Art"]];
 auto root=[NSStackView stackViewWithViews:@[]];root.orientation=NSUserInterfaceLayoutOrientationVertical;root.spacing=0;root.translatesAutoresizingMaskIntoConstraints=NO;[self addSubview:root];[NSLayoutConstraint activateConstraints:@[[root.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],[root.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],[root.topAnchor constraintEqualToAnchor:self.topAnchor],[root.bottomAnchor constraintEqualToAnchor:self.bottomAnchor]]];
 _target=[NSTextField labelWithString:@"Library"];_target.font=vj::style::font(10);_target.textColor=vj::style::secondary();_target.lineBreakMode=NSLineBreakByTruncatingTail;[_target setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];auto targetWrap=[[NSView alloc]init];[targetWrap addSubview:_target];_target.translatesAutoresizingMaskIntoConstraints=NO;[NSLayoutConstraint activateConstraints:@[[_target.leadingAnchor constraintEqualToAnchor:targetWrap.leadingAnchor constant:8],[_target.trailingAnchor constraintEqualToAnchor:targetWrap.trailingAnchor constant:-8],[_target.centerYAnchor constraintEqualToAnchor:targetWrap.centerYAnchor],[targetWrap.heightAnchor constraintEqualToConstant:vj::style::controlHeight]]];[root addArrangedSubview:targetWrap];[targetWrap.widthAnchor constraintEqualToAnchor:root.widthAnchor].active=YES;
 _table=[[NSTableView alloc]init];auto col=[[NSTableColumn alloc]initWithIdentifier:@"source"];col.minWidth=0;col.width=frame.size.width;col.resizingMask=NSTableColumnNoResizing;[_table addTableColumn:col];_table.columnAutoresizingStyle=NSTableViewNoColumnAutoresizing;_table.allowsColumnResizing=NO;_table.style=NSTableViewStyleFullWidth;_table.headerView=nil;_table.rowHeight=46;_table.selectionHighlightStyle=NSTableViewSelectionHighlightStyleRegular;_table.intercellSpacing=NSMakeSize(0,1);_table.delegate=self;_table.dataSource=self;_table.target=self;_table.action=@selector(choose:);_table.backgroundColor=vj::style::panel();[_table setDraggingSourceOperationMask:NSDragOperationCopy forLocal:YES];
 auto scroll=[[VJLibraryScrollView alloc]init];scroll.hasVerticalScroller=YES;scroll.hasHorizontalScroller=NO;scroll.horizontalScrollElasticity=NSScrollElasticityNone;scroll.contentView.clipsToBounds=YES;scroll.documentView=_table;[root addArrangedSubview:scroll];[scroll.widthAnchor constraintEqualToAnchor:root.widthAnchor].active=YES;[scroll.heightAnchor constraintGreaterThanOrEqualToConstant:150].active=YES;
 __weak VJLibrary* weak=self;_thumbnails=[[VJClipThumbnails alloc]initWithModel:model redraw:^{[weak redraw];}];_timer=[NSTimer timerWithTimeInterval:.4 repeats:YES block:^(NSTimer*){[weak tick];}];[[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];[self refresh];vj::style::apply(self);
 }return self;
}
- (void)setLivePreviewsEnabled:(BOOL)enabled {_capture=enabled;if(!enabled&&_sources.empty()){_sources={{"ndi",J::array()},{"syphon",J::array()},{"usb_webcam",J::array()}};[self filter];}[_thumbnails setLivePreviewsEnabled:enabled];}
- (J)filesForEffect:(const std::string&)effect {J files=J::array();for(const auto& item:_items)if(item.value("section",std::string{})=="Files"&&item["effect"]==effect)files.push_back(item);return files;}
- (J)sourcesForEffect:(const std::string&)effect {return _sources.value(effect,J::array());}
- (J)sourceRows:(const std::string&)effect {
 auto discovered=_sources.value(effect,J::array());J items=J::array();
 for(const auto& source:discovered)items.push_back(vj::library::sourceRow(effect,source,discovered));
 for(const auto& bound:_boundSources.value(effect,J::array())){
  auto row=vj::library::sourceRow(effect,bound,discovered);
  auto same=[&](const J& other){return other.at("params")==row.at("params")||(row.contains("favorite")&&other.contains("favorite")&&vj::library::sameFavorite(row.at("favorite"),other.at("favorite")));};
  if(std::any_of(items.begin(),items.end(),same))continue;
  row["available"]=false;if(effect=="usb_webcam")row.erase("favorite");items.push_back(std::move(row));
 }
 for(const auto& pin:_favorites){
  if(pin.value("kind",std::string{})!="source"||!pin.value("id",std::string{}).starts_with(effect+":"))continue;
  if(std::none_of(items.begin(),items.end(),[&](const J& row){return row.contains("favorite")&&vj::library::sameFavorite(row["favorite"],pin);}))items.push_back(vj::library::unavailable(pin));
 }
 return items;
}
- (J)templateRows {
 J rows=J::array();
 for(const auto& entry:_templates){
  auto id=entry.value("id",std::string{}),name=entry.value("name",id);
  for(const auto& port:entry.value("outputs",J::array())){
   auto type=port.value("composeType",std::string{});if(type.empty())continue;
   std::string title=name;if(std::count_if(entry.at("outputs").begin(),entry.at("outputs").end(),[](const J& p){return !p.value("composeType",std::string{}).empty();})>1)title+=" · "+port.value("name",std::string("Output"));
   std::string section="Subpatches";if(entry.value("bundled",false)){
    if(entry.contains("processingInput"))section="Adjustment Layers";else if(entry.value("category",std::string{})=="Vector Art")section="Vector Art";else if(type=="video")section="Raster Art";else if(type=="collection")section="Surface collection effects";else if(type=="trace")section="Traces";
   }
   rows.push_back({{"kind","subpatch"},{"name",title},{"subpatchID",id},{"outputID",port.at("id")},{"patchType",type},{"section",section},{"favorite",entry.value("favorite",vj::library::favorite("subpatch",id,name))}});
   if(entry.contains("processingInput"))rows.back()["processingInput"]=entry["processingInput"];
  }
 }
 return rows;
}
- (J)searchItems {
 J items=_items;
 for(const auto& item:_patchItems)if(item.contains("effect"))items.push_back(item);
 for(auto& row:[self templateRows])if(row["patchType"]!="palette"&&row["patchType"]!="control")items.push_back(row);
 for(const auto* effect:{"usb_webcam","ndi","syphon"})for(auto& item:[self sourceRows:effect])if(item.contains("effect")){
  item["section"]=std::string(effect)=="usb_webcam"?"Cameras":std::string(effect)=="ndi"?"NDI":"Syphon";items.push_back(item);
 }
 return items;
}
- (void)refreshShared {
 if(_closed||_sharedBusy)return;_sharedBusy=YES;_sharedScan=[NSDate timeIntervalSinceReferenceDate];
 auto revision=_pinRevision;
 dispatch_group_async(_tasks,dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{@autoreleasepool{
  auto pins=self->_model->request("GET","/api/v1/library/favorites");
  auto templates=self->_model->request("GET","/api/v1/library/subpatches");
  dispatch_async(dispatch_get_main_queue(),^{
   if(self->_closed)return;self->_sharedBusy=NO;
   auto error=pins.status!=200?pins.body.value("error",std::string("Favorites unavailable")):templates.status!=200?templates.body.value("error",std::string("Subpatch library unavailable")):std::string{};
   BOOL changed=![(self->_libraryError?:@"") isEqualToString:ns(error)];self->_libraryError=ns(error);
   if(pins.status==200&&revision==self->_pinRevision){auto rows=pins.body.value("favorites",J::array());changed|=rows!=self->_favorites;self->_favorites=std::move(rows);}
   if(templates.status==200){auto rows=templates.body.value("subpatches",J::array());changed|=rows!=self->_templates;self->_templates=std::move(rows);}
   if(changed){[self filter];if(self.inventoryChanged)self.inventoryChanged();}
  });
 }});
}
- (void)refreshSearchItems {[self refresh];[self discover];[self refreshShared];}
- (void)redraw {if(_closed)return;NSRange range=[_table rowsInRect:_table.visibleRect];for(NSUInteger r=range.location;r<NSMaxRange(range)&&r<_rows.size();++r){auto cell=(VJLibraryCell*)[_table viewAtColumn:0 row:r makeIfNecessary:NO];if(![cell isKindOfClass:VJLibraryCell.class]||!_rows[r].contains("effect"))continue;auto clip=_rows[r];clip["gen"]=clip["effect"];cell->poster=[_thumbnails imageForClip:clip];[cell setNeedsDisplay:YES];}}
- (void)tick {if(_closed||self.isHiddenOrHasHiddenAncestor||!self.window)return;[self refreshPatch];if([NSDate timeIntervalSinceReferenceDate]-_sharedScan>3)[self refreshShared];[self redraw];if([NSDate timeIntervalSinceReferenceDate]-_scanned>3)[self discover];}
- (void)setContext:(const J&)snapshot bus:(NSString*)bus target:(NSString*)target {[_thumbnails setContext:snapshot bus:bus];_target.stringValue=target;_target.toolTip=target;
 auto revision=snapshot.value("revision",uint64_t(0));if(_boundRevision==revision)return;_boundRevision=revision;
 J bindings=J::object();
 for(const auto& row:snapshot.at("state").at("grid").at("rows"))for(const auto& clip:row.at("clips")){
  auto effect=clip.value("gen",std::string{});if(!vj::library::live(effect)&&!effect.starts_with("patch_"))continue;
  auto selection=clip.value("params",J::object()).value(effect=="usb_webcam"?"device":"source",std::string{});if(selection.empty())continue;
  J bound={{"selection",selection},{"label",clip.value("name",selection)}};
  auto& list=bindings[effect];if(std::none_of(list.begin(),list.end(),[&](const J& other){return other.at("selection")==selection;}))list.push_back(std::move(bound));
 }
 if(bindings!=_boundSources){_boundSources=std::move(bindings);[self refreshPatch];[self filter];}
}
- (void)browse:(id)sender {(void)sender;if(self.browse)self.browse();}
- (void)reload:(id)sender {(void)sender;[self refresh];_scanned=0;[self discover];}
- (void)refresh {
 if(_closed||_busy)return;_busy=YES;
 dispatch_group_async(_tasks,dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{@autoreleasepool{
 J items=J::array();for(const auto& e:self->_model->effectCatalog()){auto name=e.at("name").get<std::string>();std::string section=e.value("patchSource",false)||e.value("liveSource",false)||name=="image"||name=="video"||name=="text"||name=="media_collection"?"Source nodes":e.value("adjustment",false)?"Adjustment Layers":name.starts_with("trace_")?"Traces":e.value("kind",std::string{})=="collection"?"Surface collection effects":e.value("vector",false)?"Vector Art":"Raster Art";J params=J::object();for(const auto& p:e.value("parameters",J::array()))params[p.at("name").get<std::string>()]=p.at("default");items.push_back({{"section",section},{"name",e.value("label",e.value("title",name))},{"effect",name},{"params",params},{"favorite",vj::library::favorite("composeEffect",name,e.value("label",name))}});}
 auto media=self->_model->request("GET","/api/v1/media/catalog");if(media.status==200)for(const auto& m:media.body.value("items",J::array())){auto kind=m.value("type",std::string{});if(kind!="image"&&kind!="video")continue;auto status=self->_model->request("POST","/api/v1/media/status",{{"file",m.at("file")},{"type",kind}});items.push_back({{"section","Files"},{"favorite",vj::library::favorite("media",m.at("file"),m.value("name",std::string{}))},{"name",m.value("name",std::string{})},{"effect",kind},{"params",{{"file",m.at("file")}}},{"resolved_file",status.body.value("resolved_file",std::string{})},{"mediaStatus",status.body},{"path",m.value("path",std::string{})}});}
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
 J all=_model->patchOutputs();
 for(const auto* type:{"video","collection","trace"}){
  for(const auto& bound:_boundSources.value(std::string("patch_")+type,J::array())){
   auto found=std::find_if(all.begin(),all.end(),[&](const J& source){return source.at("id")==bound.at("selection");});
   if(found!=all.end()){(*found)["listed"]=true;continue;}
   all.push_back({{"listed",true},{"type",type},{"id",bound.at("selection")},{"name",bound.at("label")},{"available",false}});
  }
 }
 J items=J::array();for(const auto* type:{"video","collection","trace","palette","control"}){
  J group=J::array();for(const auto& source:all)if(source.value("listed",false)&&source.value("type",std::string{})==type){
   J item={{"name",source.value("name",std::string("Patch"))},{"patchID",source["id"]},{"patchType",type},{"available",source.value("available",false)},{"section","Patch Outputs"},{"favorite",vj::library::favorite("patchOutput",source.at("id"),source.value("name",std::string("Patch")))}};
   if(std::string(type)=="video"||std::string(type)=="collection"||std::string(type)=="trace"){item["effect"]=std::string("patch_")+type;item["params"]={{"source",source["id"]}};}else item["kind"]="patchParameter";
   group.push_back(item);
  }
  if(!group.empty()){items.push_back({{"kind","group"},{"name",std::string(type)=="video"?"Video":std::string(type)=="collection"?"Collection effects":std::string(type)=="trace"?"Trace effects":std::string(type)=="palette"?"Palettes":"Controls"}});for(const auto& item:group)items.push_back(item);}
 }
 if(items!=_patchItems){_patchItems=std::move(items);[self filter];if(self.inventoryChanged)self.inventoryChanged();if(self.sourcesChanged)self.sourcesChanged();}
}
- (void)filter {
 auto origin=_table.enclosingScrollView.contentView.bounds.origin;_rows=J::array();
 auto section=[&](const std::string& name,size_t count,bool nested=false){
  _rows.push_back({{"kind","section"},{"name",name},{"count",count},{"nested",nested}});
  return ![_collapsed containsObject:ns(name)];
 };
 auto showRows=[&](const J& rows,const std::string& empty){
  if(rows.empty())_rows.push_back({{"kind","status"},{"name",empty}});
  else for(auto& row:rows)_rows.push_back(row);
 };
 J sources=J::object(),inventory=_items;
 for(const auto* effect:{"ndi","syphon","usb_webcam"}){
  sources[effect]=[self sourceRows:effect];for(const auto& item:sources[effect])inventory.push_back(item);
 }
 auto templates=[self templateRows];for(const auto& row:templates)inventory.push_back(row);
 size_t patches=0;for(const auto& row:_patchItems)if(row.contains("patchID")){inventory.push_back(row);++patches;}
 J favorites=J::array();
 for(const auto& pin:_favorites){
  auto kind=pin.value("kind",std::string{});bool found=false;
  for(const auto& row:inventory)if(row.contains("favorite")&&vj::library::sameFavorite(row.at("favorite"),pin)){favorites.push_back(row);found=true;}
  if(!found&&kind!="patchNode")favorites.push_back(vj::library::unavailable(pin));
 }
 if(section("Favorites",favorites.size()))showRows(favorites,"No favorites");
 if(_libraryError.length)_rows.push_back({{"kind","status"},{"name",_libraryError.UTF8String}});
 if(section("Sources",sources["ndi"].size()+sources["syphon"].size()+sources["usb_webcam"].size()+patches)){
  for(const auto* effect:{"ndi","syphon","usb_webcam"}){
   auto title=std::string(effect)=="ndi"?"NDI":std::string(effect)=="syphon"?"Syphon":"Cameras";
   if(section(title,sources[effect].size(),true))showRows(sources[effect],!_sourceStatus.value(effect,std::string{}).empty()?"Unavailable":_sources.contains(effect)?"No sources":"Discovering…");
  }
  if(section("Patch Outputs",patches,true))showRows(_patchItems,"No published outputs");
 }
 const auto& library=_items;
 if(section("Library",library.size()+templates.size())){
  for(const auto* group:{"Subpatches","Source nodes","Files","Adjustment Layers","Surface collection effects","Traces","Vector Art","Raster Art"}){
   J rows=J::array();for(const auto& item:templates)if(item["section"]==group)rows.push_back(item);
   for(const auto& item:library)if(item["section"]==group)rows.push_back(item);
   if(!section(group,rows.size(),true))continue;
   if(std::string(group)=="Files"){_rows.push_back({{"kind","tools"}});showRows(filesAt(_items,_folder),"No files");}
   else showRows(rows,"No items");
  }
 }
 [_table reloadData];[_table.enclosingScrollView.contentView scrollToPoint:NSMakePoint(0,origin.y)];
}
- (NSInteger)numberOfRowsInTableView:(NSTableView*)table {(void)table;return _rows.size();}
- (CGFloat)tableView:(NSTableView*)table heightOfRow:(NSInteger)row {(void)table;return (_rows.at(row).contains("effect")||_rows.at(row).contains("subpatchID"))?46:_rows.at(row).value("kind",std::string{})=="status"?24:30;}
- (NSView*)tableView:(NSTableView*)table viewForTableColumn:(NSTableColumn*)col row:(NSInteger)row {
 (void)table;(void)col;const auto& item=_rows.at(row);
 if(item.value("kind",std::string{})=="tools"){auto view=[NSStackView stackViewWithViews:@[[NSButton buttonWithTitle:@"Import…" target:self action:@selector(browse:)],[NSButton buttonWithTitle:@"↻" target:self action:@selector(reload:)]]];view.spacing=4;for(NSView* child in view.subviews){((NSControl*)child).font=vj::style::font(11);[child.heightAnchor constraintEqualToConstant:vj::style::controlHeight].active=YES;}return view;}
 auto cell=[[VJLibraryCell alloc]init];cell.clipsToBounds=YES;cell->item=item;cell->open=![_collapsed containsObject:ns(item.value("name",std::string{}))];if(item.contains("effect")){auto clip=item;clip["gen"]=clip["effect"];cell->poster=[_thumbnails imageForClip:clip];}if(item.contains("favorite")){
  const auto& pin=item.at("favorite");bool pinned=std::any_of(_favorites.begin(),_favorites.end(),[&](const J& current){return vj::library::sameFavorite(current,pin);});
  auto button=[NSButton buttonWithTitle:pinned?@"★":@"☆" target:self action:@selector(pin:)];button.bordered=NO;button.font=vj::style::font(15);button.identifier=ns(pin.dump());
  button.toolTip=pinned?@"Remove from Favorites":@"Add to Favorites";button.accessibilityLabel=button.toolTip;
  cell->star=button;button.translatesAutoresizingMaskIntoConstraints=NO;[cell addSubview:button];
  [NSLayoutConstraint activateConstraints:@[[button.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-3],[button.widthAnchor constraintEqualToConstant:24],[button.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor]]];
 }
 cell.toolTip=ns(item.value("path",item.value("name",std::string{})));cell.accessibilityLabel=ns(item.value("name",std::string{}));return cell;
}
- (void)pin:(NSButton*)sender {
 auto pin=J::parse(sender.identifier.UTF8String);bool exists=std::any_of(_favorites.begin(),_favorites.end(),[&](const J& current){return vj::library::sameFavorite(current,pin);});
 pin["pinned"]=!exists;auto reply=_model->request("POST","/api/v1/library/favorites",pin);
 if(reply.status!=200){_libraryError=ns(reply.body.value("error",std::string("Could not save favorite")));[self filter];return;}
 ++_pinRevision;_favorites=reply.body.value("favorites",J::array());_libraryError=nil;[self filter];if(self.inventoryChanged)self.inventoryChanged();
}
- (id<NSPasteboardWriting>)tableView:(NSTableView*)table pasteboardWriterForRow:(NSInteger)row {(void)table;if(row<0||row>=NSInteger(_rows.size()))return nil;const auto& entry=_rows[row];if(!entry.contains("effect")&&(!entry.contains("subpatchID")||entry["patchType"]=="palette"||entry["patchType"]=="control"))return nil;auto item=[[NSPasteboardItem alloc]init];[item setString:ns(payload(_rows[row]).dump()) forType:@"com.vibe.clip"];return item;}
- (void)choose:(id)sender {(void)sender;NSInteger row=_table.clickedRow>=0?_table.clickedRow:_table.selectedRow;if(row<0||row>=NSInteger(_rows.size()))return;auto item=_rows.at(row);auto kind=item.value("kind",std::string{});if(kind=="section"){auto group=ns(item["name"]);if([_collapsed containsObject:group])[_collapsed removeObject:group];else [_collapsed addObject:group];[NSUserDefaults.standardUserDefaults setObject:_collapsed.allObjects forKey:@"VJLibraryCollapsedV3"];[self filter];[self discover];return;}if(kind=="folder"){_folder=item["path"];[self filter];return;}if((kind=="patchParameter"||(kind=="subpatch"&&(item["patchType"]=="palette"||item["patchType"]=="control")))&&self.assignOutput)self.assignOutput(item,[_table viewAtColumn:0 row:row makeIfNecessary:YES]);else if((item.contains("effect")||item.contains("subpatchID"))&&self.insert)self.insert(payload(item));}
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
