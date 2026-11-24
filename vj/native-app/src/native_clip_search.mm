#import "native_clip_search.hpp"
#import "native_style.hpp"
#include <algorithm>

namespace {
using J=vj::Json;
NSString* text(const std::string& s){return [NSString stringWithUTF8String:s.c_str()]?:@"";}
NSString* folded(NSString* s){return [[s stringByFoldingWithOptions:NSCaseInsensitiveSearch|NSDiacriticInsensitiveSearch locale:[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]] lowercaseString];}
std::string identity(const J& item){
 if(item.contains("subpatchID"))return J::array({item.at("subpatchID"),item.at("outputID")}).dump();
 return item.value("effect",std::string{})+"\n"+item.value("name",std::string{})+"\n"+item.value("params",J::object()).dump();}
NSString* detail(const J& item){
 auto section=item.value("section",std::string{}),effect=item.value("effect",std::string{});
 if(section=="Files")return text((effect=="video"?"Video":"Image")+std::string(" · ")+item.value("path",item.value("params",J::object()).value("file",std::string{})));
 return text(section.empty()?effect:section);
}
}
@interface VJClipSearch()<NSTableViewDataSource,NSTableViewDelegate,NSSearchFieldDelegate,NSWindowDelegate>
@end
@interface VJClipSearchRow : NSTableRowView @end
@implementation VJClipSearchRow
- (void)drawSelectionInRect:(NSRect)dirtyRect {
    (void)dirtyRect;[vj::style::engaged() setFill];[[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,4,1) xRadius:3 yRadius:3]fill];
}
@end
@implementation VJClipSearch {
    J _items;
    std::vector<size_t> _matches;
    NSMutableArray<NSString*>* _names;
    NSMutableArray<NSString*>* _terms;
    NSSearchField* _search;
    NSTableView* _table;
    NSTextField* _status;
    id _keys;
    BOOL _closed;
    NSString* _searchTitle;
    void (^_completion)(J);
}
- (instancetype)initWithItems:(const J&)items completion:(void(^)(J))completion {
    auto panel=[[NSPanel alloc]initWithContentRect:NSMakeRect(0,0,640,440) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    if((self=[super initWithWindow:panel])){
        _searchTitle=@"Find clip";_completion=[completion copy];panel.title=@"Find clip";panel.releasedWhenClosed=NO;panel.delegate=self;
        panel.hidesOnDeactivate=YES;panel.animationBehavior=NSWindowAnimationBehaviorUtilityWindow;
        auto root=vj::style::stack(NSUserInterfaceLayoutOrientationVertical);root.spacing=8;root.edgeInsets=NSEdgeInsetsMake(12,12,12,12);root.frame=panel.contentView.bounds;root.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;vj::style::mount(panel,root);
        _search=[[NSSearchField alloc]init];_search.placeholderString=@"Search clips, effects, files and sources";_search.delegate=self;
        _search.sendsSearchStringImmediately=YES;_search.sendsWholeSearchString=NO;
        [_search setAccessibilityLabel:@"Find clip"];[root addArrangedSubview:_search];
        [_search.widthAnchor constraintEqualToAnchor:root.widthAnchor constant:-24].active=YES;
        [_search.heightAnchor constraintEqualToConstant:36].active=YES;
        _table=[[NSTableView alloc]init];_table.headerView=nil;_table.rowHeight=46;_table.intercellSpacing=NSMakeSize(0,1);_table.style=NSTableViewStyleFullWidth;
        _table.delegate=self;_table.dataSource=self;_table.target=self;_table.doubleAction=@selector(accept:);_table.allowsMultipleSelection=NO;
        auto column=[[NSTableColumn alloc]initWithIdentifier:@"result"];column.width=610;column.minWidth=0;column.resizingMask=NSTableColumnAutoresizingMask;[_table addTableColumn:column];_table.columnAutoresizingStyle=NSTableViewUniformColumnAutoresizingStyle;
        auto scroll=[[NSScrollView alloc]init];scroll.documentView=_table;scroll.hasVerticalScroller=YES;scroll.borderType=NSNoBorder;
        [root addArrangedSubview:scroll];[scroll.widthAnchor constraintEqualToAnchor:_search.widthAnchor].active=YES;[scroll.heightAnchor constraintEqualToConstant:340].active=YES;
        _status=vj::style::label(@"");_status.textColor=vj::style::secondary();[root addArrangedSubview:_status];[_status.widthAnchor constraintEqualToAnchor:_search.widthAnchor].active=YES;
        vj::style::window(panel);[self updateItems:items];
    }return self;
}
- (void)setSearchTitle:(NSString*)title placeholder:(NSString*)placeholder {
    _searchTitle=[title copy];self.window.title=title;_search.placeholderString=placeholder;[_search setAccessibilityLabel:title];
}
- (void)showForWindow:(NSWindow*)parent target:(NSString*)target {
    self.window.title=[NSString stringWithFormat:@"%@ · %@",_searchTitle,target];
    auto frame=self.window.frame;frame.origin=NSMakePoint(NSMidX(parent.frame)-frame.size.width/2,NSMaxY(parent.frame)-frame.size.height-90);
    auto screen=parent.screen.visibleFrame;frame.origin.x=std::clamp(frame.origin.x,NSMinX(screen),std::max(NSMinX(screen),NSMaxX(screen)-frame.size.width));frame.origin.y=std::clamp(frame.origin.y,NSMinY(screen),std::max(NSMinY(screen),NSMaxY(screen)-frame.size.height));[self.window setFrame:frame display:NO];
    [parent addChildWindow:self.window ordered:NSWindowAbove];[self.window makeKeyAndOrderFront:nil];[self.window makeFirstResponder:_search];[_search selectText:nil];
    __weak VJClipSearch* weak=self;
    _keys=[NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown|NSEventMaskLeftMouseDown|NSEventMaskRightMouseDown handler:^NSEvent*(NSEvent* event){
        VJClipSearch* owner=weak;if(!owner||owner->_closed)return event;
        if(event.type==NSEventTypeLeftMouseDown||event.type==NSEventTypeRightMouseDown){if(event.window!=owner.window)[owner cancel];return event;}
        if(event.window!=owner.window)return event;
        const auto flags=event.modifierFlags&(NSEventModifierFlagCommand|NSEventModifierFlagShift|NSEventModifierFlagOption|NSEventModifierFlagControl);
        if(flags==NSEventModifierFlagCommand&&[event.charactersIgnoringModifiers.lowercaseString isEqual:@"f"]){[owner->_search selectText:nil];return nil;}
        if(flags)return event;
        if(event.keyCode==53){[owner cancel];return nil;}
        if(event.keyCode==36||event.keyCode==76){if(!event.isARepeat)[owner accept:nil];return nil;}
        if(event.keyCode==125||event.keyCode==126){[owner moveSelection:event.keyCode==125?1:-1];return nil;}
        return event;
    }];
}
- (void)updateItems:(const J&)items {
    if(_closed||_items==items)return;
    std::string selected;auto row=_table.selectedRow;if(row>=0&&size_t(row)<_matches.size())selected=identity(_items[_matches[row]]);
    _items=items;_names=[NSMutableArray array];_terms=[NSMutableArray array];
    for(const auto& item:_items){auto name=folded(text(item.value("name",std::string{})));[_names addObject:name];[_terms addObject:folded([NSString stringWithFormat:@"%@ %@ %@",name,text(item.value("effect",std::string{})),detail(item)])];}
    [self filter:selected];
}
- (void)filter:(const std::string&)selected {
    auto query=[folded(_search.stringValue) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    auto tokens=[query componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    std::vector<std::pair<int,size_t>> ranked;
    for(size_t i=0;i<_items.size();++i){BOOL matches=YES;for(NSString* token in tokens)if(token.length&&[_terms[i] rangeOfString:token].location==NSNotFound){matches=NO;break;}if(!matches)continue;
        int rank=!query.length?3:[_names[i] isEqual:query]?0:[_names[i] hasPrefix:query]?1:[_names[i] containsString:query]?2:3;ranked.emplace_back(rank,i);
    }
    std::stable_sort(ranked.begin(),ranked.end(),[&](const auto& a,const auto& b){if(a.first!=b.first)return a.first<b.first;return [_names[a.second] localizedStandardCompare:_names[b.second]]==NSOrderedAscending;});
    _matches.clear();NSInteger selection=0;for(const auto& [rank,index]:ranked){(void)rank;if(!selected.empty()&&identity(_items[index])==selected)selection=_matches.size();_matches.push_back(index);}
    [_table reloadData];if(_matches.empty())[_table deselectAll:nil];else{[_table selectRowIndexes:[NSIndexSet indexSetWithIndex:selection] byExtendingSelection:NO];[_table scrollRowToVisible:selection];}
    _status.stringValue=_matches.empty()?@"No matches":[NSString stringWithFormat:@"%lu results",(unsigned long)_matches.size()];
}
- (void)controlTextDidChange:(NSNotification*)notification {(void)notification;[self filter:""];}
- (NSInteger)numberOfRowsInTableView:(NSTableView*)table {(void)table;return _matches.size();}
- (NSTableRowView*)tableView:(NSTableView*)table rowViewForRow:(NSInteger)row {
    (void)row;auto view=(VJClipSearchRow*)[table makeViewWithIdentifier:@"clip-search-row" owner:self];if(!view){view=[[VJClipSearchRow alloc]init];view.identifier=@"clip-search-row";}return view;
}
- (NSView*)tableView:(NSTableView*)table viewForTableColumn:(NSTableColumn*)column row:(NSInteger)row {
    (void)column;auto cell=(NSTableCellView*)[table makeViewWithIdentifier:@"clip-search-result" owner:self];
    if(!cell){cell=[[NSTableCellView alloc]init];cell.identifier=@"clip-search-result";cell.textField=vj::style::label(@"");cell.textField.font=vj::style::font(13);auto secondary=vj::style::label(@"");secondary.tag=2;secondary.font=vj::style::font(11);secondary.textColor=vj::style::secondary();for(NSTextField* label in @[cell.textField,secondary]){label.lineBreakMode=NSLineBreakByTruncatingMiddle;label.translatesAutoresizingMaskIntoConstraints=NO;[cell addSubview:label];[label.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:10].active=YES;[label.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-10].active=YES;}[cell.textField.topAnchor constraintEqualToAnchor:cell.topAnchor constant:5].active=YES;[secondary.topAnchor constraintEqualToAnchor:cell.textField.bottomAnchor constant:2].active=YES;}
    const auto& item=_items[_matches.at(row)];cell.textField.stringValue=text(item.value("name",std::string{}));((NSTextField*)[cell viewWithTag:2]).stringValue=detail(item);cell.toolTip=[NSString stringWithFormat:@"%@\n%@",cell.textField.stringValue,detail(item)];return cell;
}
- (void)moveSelection:(NSInteger)step {
    if(_matches.empty())return;auto row=std::clamp<NSInteger>(_table.selectedRow+step,0,_matches.size()-1);[_table selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];[_table scrollRowToVisible:row];
}
- (void)accept:(id)sender {
    (void)sender;if(_closed)return;auto row=_table.selectedRow;if(row<0||size_t(row)>=_matches.size())return;
    auto item=_items[_matches[row]];auto completion=_completion;[self cancel];if(item.contains("subpatchID")){if(completion)completion({{"subpatchID",item["subpatchID"]},{"outputID",item["outputID"]},{"name",item["name"]}});return;}if(completion)completion({{"effect",item["effect"]},{"name",item["name"]},{"params",item.value("params",J::object())}});
}
- (void)cancel {
    if(_closed)return;_closed=YES;if(_keys){[NSEvent removeMonitor:_keys];_keys=nil;}_completion=nil;[self.window.parentWindow removeChildWindow:self.window];[self.window orderOut:nil];
}
- (void)windowDidResignKey:(NSNotification*)notification {(void)notification;[self cancel];}
- (BOOL)windowShouldClose:(NSWindow*)sender {(void)sender;[self cancel];return YES;}
- (void)dealloc {if(_keys)[NSEvent removeMonitor:_keys];}
- (J)checkInteractions {
    J checks=J::object();auto saved=_items;
    if(auto directory=getenv("VJ_UI_CAPTURE_DIR")){auto view=self.window.contentView;[view layoutSubtreeIfNeeded];[view displayIfNeeded];auto bitmap=[view bitmapImageRepForCachingDisplayInRect:view.bounds];[view cacheDisplayInRect:view.bounds toBitmapImageRep:bitmap];[[NSFileManager defaultManager]createDirectoryAtPath:text(directory) withIntermediateDirectories:YES attributes:nil error:nil];[[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}]writeToFile:[text(directory)stringByAppendingPathComponent:@"clip-search.png"] atomically:YES];}
    [self updateItems:J::array({{{"name","Plasma"},{"effect","plasma"},{"section","Raster Art"}},{{"name","Ocean.mov"},{"effect","video"},{"section","Files"},{"path","Shows/Water/Ocean.mov"},{"params",{{"file","native-media://Ocean.mov"}}}},{{"name","Patch — Mesh"},{"effect","syphon"},{"section","Syphon"},{"params",{{"source","mesh-source"}}}},{{"name","Stage"},{"effect","ndi"},{"section","NDI"}},{{"name","FaceTime"},{"effect","usb_webcam"},{"section","Camera"}},{{"name","Café"},{"effect","image"},{"section","Files"}}})];
    auto query=[&](NSString* value){_search.stringValue=value;[self filter:""];};
    checks["Search focuses typing immediately"]=_search.currentEditor!=nil;
    query(@"water ocean");checks["Search includes media folder paths"]=_matches.size()==1&&_items[_matches[0]]["effect"]=="video";
    query(@"SYPHON mesh");checks["Search includes named live sources"]=_matches.size()==1&&_items[_matches[0]]["params"]["source"]=="mesh-source";
    query(@"camera");checks["Search includes cameras"]=_matches.size()==1&&_items[_matches[0]]["effect"]=="usb_webcam";
    query(@"ndi");checks["Search includes NDI"]=_matches.size()==1&&_items[_matches[0]]["effect"]=="ndi";
    query(@"cafe");checks["Search ignores case and accents"]=_matches.size()==1&&_items[_matches[0]]["name"]=="Café";
    query(@"nothing-matches-this");[self accept:nil];checks["Empty search cannot insert"]=_matches.empty()&&self.window.visible;
    query(@"");[self moveSelection:1];checks["Search arrow selection moves"]=_table.selectedRow==1;
    auto selected=identity(_items[_matches[1]]);auto expanded=_items;expanded.push_back({{"name","AAA"},{"effect","text"}});[self updateItems:expanded];checks["Inventory refresh preserves selection"]=identity(_items[_matches[_table.selectedRow]])==selected;
    [self updateItems:saved];query(@"plasma");checks["Search selects matching effect"]=_matches.size()>0&&_items[_matches[0]]["effect"]=="plasma";
    return checks;
}
@end
