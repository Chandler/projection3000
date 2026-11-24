#include "syphon_input.hpp"
#import <PatchKit.h>
#import "app.hpp"
#include "library_placement.hpp"
#import "show_library.hpp"
#include "native_async.hpp"
#import "native_style.hpp"
#import "native_performance.hpp"
#import "native_widgets.hpp"
#import "native_library.hpp"
#import "native_clip_search.hpp"
#import "preview.hpp"
#import "native_media_browser.hpp"
#import "mapper.hpp"
#import "native_meta_mapping.hpp"
#import "native_controls.hpp"
#import "native_source_browser.hpp"
#import "native_outputs.hpp"
#import "native_calibration.hpp"
#import "native_network.hpp"
#import "native_thumbnails.hpp"
#include <cmath>
#import <objc/runtime.h>
#import <CoreText/CoreText.h>
#import <CoreImage/CoreImage.h>
#include "text_source.hpp"
#include <map>
#include <chrono>
using vj::Json;
static NSString* text(const std::string& s){return [NSString stringWithUTF8String:s.c_str()]?:@"";}
static NSColor* rgb(double r,double g,double b){return [NSColor colorWithSRGBRed:r green:g blue:b alpha:1];}
static NSColor* color(const Json& clip){try{auto value=clip.at("params").value("color",std::string("#63867f"));unsigned n=std::stoul(value.substr(1),nullptr,16);return rgb(((n>>16)&255)/255.,((n>>8)&255)/255.,(n&255)/255.);}catch(...){return rgb(.22,.3,.28);}}
static bool followInspectorClip(const Json& grid,Json& context){
    if(grid.value("active_show",Json())!=context.value("active_show",Json()))return false;
    if(!context.contains("clipId"))return true;
    for(const auto& row:grid["rows"])for(auto it=row["clips"].begin();it!=row["clips"].end();++it)if(it.value().value("id",Json())==context["clipId"]){context["row"]=row["id"];context["column"]=it.key();return true;}
    return false;
}
@interface VJInspectorBinding : NSObject { @public Json context,parameter; }
@end
@implementation VJInspectorBinding @end
static char inspectorBindingKey;
static VJInspectorBinding* binding(NSControl* control){return objc_getAssociatedObject(control,&inspectorBindingKey);}
static void bindInspector(NSView* view,const Json& context){
    if([view isKindOfClass:NSControl.class]){auto b=binding((NSControl*)view);if(!b)b=[[VJInspectorBinding alloc]init];b->context=context;objc_setAssociatedObject(view,&inspectorBindingKey,b,OBJC_ASSOCIATION_RETAIN_NONATOMIC);}
    for(NSView* child in view.subviews)bindInspector(child,context);
}
@interface VJAction : NSButton { @public Json command;std::string path; }
@end
@implementation VJAction @end
@interface VJFontTile : VJAction
@property(copy) NSString* sample;
@property(copy) NSString* face;
@end
@implementation VJFontTile
- (BOOL)isFlipped{return YES;}
- (void)drawRect:(NSRect)dirty {(void)dirty;[(self.state==NSControlStateValueOn?vj::style::hex(0x354651):vj::style::background())setFill];NSRectFill(self.bounds);[(self.state==NSControlStateValueOn?vj::style::accent():vj::style::border())setStroke];[NSBezierPath strokeRect:NSInsetRect(self.bounds,.5,.5)];auto p=[NSMutableParagraphStyle new];p.lineBreakMode=NSLineBreakByTruncatingTail;[self.sample drawInRect:NSMakeRect(6,5,self.bounds.size.width-12,28) withAttributes:@{NSFontAttributeName:self.font,NSForegroundColorAttributeName:vj::style::text(),NSParagraphStyleAttributeName:p}];[self.face drawInRect:NSMakeRect(6,34,self.bounds.size.width-12,16) withAttributes:@{NSFontAttributeName:vj::style::font(10),NSForegroundColorAttributeName:vj::style::secondary(),NSParagraphStyleAttributeName:p}];}
@end
@interface VJParameterSlider : NSSlider { @public Json parameter; }
@property(copy) void (^tracking)(BOOL);
@end
@implementation VJParameterSlider
- (void)mouseDown:(NSEvent*)event {
 if(!self.enabled)return;[self.window makeFirstResponder:self];if(self.tracking)self.tracking(YES);
 for(;;){auto p=[self convertPoint:event.locationInWindow fromView:nil];auto cell=(NSSliderCell*)self.cell;auto knob=[cell knobRectFlipped:self.isFlipped];double inset=(self.isVertical?knob.size.height:knob.size.width)/2;double length=(self.isVertical?self.bounds.size.height:self.bounds.size.width)-2*inset;double unit=std::clamp(((self.isVertical?p.y:p.x)-inset)/MAX(1,length),0.,1.);if(self.isVertical&&self.isFlipped)unit=1-unit;self.doubleValue=self.minValue+unit*(self.maxValue-self.minValue);[self setNeedsDisplay:YES];if(self.isContinuous||event.type==NSEventTypeLeftMouseUp)[self sendAction:self.action to:self.target];if(event.type==NSEventTypeLeftMouseUp)break;event=[self.window nextEventMatchingMask:NSEventMaskLeftMouseDragged|NSEventMaskLeftMouseUp untilDate:NSDate.distantFuture inMode:NSEventTrackingRunLoopMode dequeue:YES];if(!event)break;}
 if(self.tracking)self.tracking(NO);
}
@end
static double parameterUnit(const Json& spec,double v){double lo=spec.value("min",0.),hi=spec.value("max",1.);v=std::clamp(v,lo,hi);auto scale=spec.value("scale",std::string{});if(scale=="log"&&lo>0&&hi>lo)return std::log(v/lo)/std::log(hi/lo);if(scale=="exp"&&hi>lo)return std::cbrt((v-lo)/(hi-lo));return v;}
static double parameterValue(const Json& spec,double v){double lo=spec.value("min",0.),hi=spec.value("max",1.);auto scale=spec.value("scale",std::string{});if(scale=="log"&&lo>0&&hi>lo)v=lo*std::pow(hi/lo,v);else if(scale=="exp")v=lo+(hi-lo)*v*v*v;double step=spec.value("step",0.);if(step>0)v=lo+std::round((v-lo)/step)*step;return std::clamp(v,lo,hi);}
static std::array<double,9> poseMatrix(const std::array<double,3>& angles){
    constexpr double r=M_PI/180.;double cx=cos(angles[0]*r),cy=cos(angles[1]*r),cz=cos(angles[2]*r),sx=sin(angles[0]*r),sy=sin(angles[1]*r),sz=sin(angles[2]*r);
    return {cz*cy,cz*sy*sx-sz*cx,cz*sy*cx+sz*sx,sz*cy,sz*sy*sx+cz*cx,sz*sy*cx-cz*sx,-sy,cy*sx,cy*cx};
}
static std::array<double,3> rotatePose(std::array<double,3> pose,std::array<double,3> delta){
    auto a=poseMatrix(delta),b=poseMatrix(pose);std::array<double,9> m={};for(int r=0;r<3;++r)for(int c=0;c<3;++c)for(int k=0;k<3;++k)m[r*3+c]+=a[r*3+k]*b[k*3+c];double y=asin(std::clamp(-m[6],-1.,1.));constexpr double d=180./M_PI;
    return abs(cos(y))>1e-5?std::array<double,3>{atan2(m[7],m[8])*d,y*d,atan2(m[3],m[0])*d}:std::array<double,3>{atan2(-m[5],m[4])*d,y*d,0};
}
@interface VJPoseControl : NSControl { @public std::array<double,3> angles; }
@property(copy) void (^tracking)(BOOL);
@end
@implementation VJPoseControl { NSPoint _last;NSTimeInterval _commit; }
- (BOOL)isFlipped{return YES;}
- (BOOL)acceptsFirstResponder{return YES;}
- (void)drawRect:(NSRect)dirty {
    (void)dirty;[[NSColor colorWithWhite:.09 alpha:1]setFill];NSRectFill(self.bounds);auto m=poseMatrix(angles);std::array<std::array<double,3>,8> vertices={{{-1,-1,-1},{1,-1,-1},{1,1,-1},{-1,1,-1},{-1,-1,1},{1,-1,1},{1,1,1},{-1,1,1}}},points={};for(size_t i=0;i<8;++i)for(int r=0;r<3;++r)for(int k=0;k<3;++k)points[i][r]+=m[r*3+k]*vertices[i][k];
    std::array<std::array<int,4>,6> faces={{{0,3,2,1},{4,5,6,7},{0,4,7,3},{1,2,6,5},{0,1,5,4},{3,7,6,2}}};std::array<int,6> order={0,1,2,3,4,5};std::sort(order.begin(),order.end(),[&](int a,int b){double az=0,bz=0;for(int id:faces[a])az+=points[id][2];for(int id:faces[b])bz+=points[id][2];return az>bz;});
    std::array<NSColor*,6> colors={rgb(.41,.45,.49),rgb(.47,.60,.78),rgb(.55,.45,.47),rgb(.73,.49,.51),rgb(.45,.55,.49),rgb(.55,.70,.60)};NSArray* labels=@[@"−Z",@"+Z",@"−X",@"+X",@"−Y",@"+Y"];double scale=std::min(self.bounds.size.width,self.bounds.size.height)*.25;
    for(int face:order){auto path=[NSBezierPath bezierPath];NSPoint center=NSZeroPoint;bool first=true;for(int id:faces[face]){auto p=NSMakePoint(NSMidX(self.bounds)+points[id][0]*scale,NSMidY(self.bounds)+points[id][1]*scale);center.x+=p.x/4;center.y+=p.y/4;if(first)[path moveToPoint:p];else[path lineToPoint:p];first=false;}[path closePath];[colors[face]setFill];[path fill];[NSColor.lightGrayColor setStroke];[path stroke];if(path.bounds.size.width>12&&path.bounds.size.height>12)[labels[face] drawAtPoint:NSMakePoint(center.x-7,center.y-7) withAttributes:@{NSFontAttributeName:[NSFont boldSystemFontOfSize:11],NSForegroundColorAttributeName:NSColor.blackColor}];}
    if(self.window.firstResponder==self){[NSColor.keyboardFocusIndicatorColor setStroke];[NSBezierPath strokeRect:NSInsetRect(self.bounds,1,1)];}
}
- (void)mouseDown:(NSEvent*)event {[self.window makeFirstResponder:self];_last=[self convertPoint:event.locationInWindow fromView:nil];_commit=0;if(self.tracking)self.tracking(YES);[self setNeedsDisplay:YES];}
- (void)mouseDragged:(NSEvent*)event {auto point=[self convertPoint:event.locationInWindow fromView:nil];double dx=point.x-_last.x,dy=point.y-_last.y;_last=point;angles=rotatePose(angles,(event.modifierFlags&NSEventModifierFlagShift)?std::array<double,3>{0,0,dx*.6}:std::array<double,3>{dy*.6,-dx*.6,0});[self setNeedsDisplay:YES];if(event.timestamp-_commit>=.07){_commit=event.timestamp;[self sendAction:self.action to:self.target];}}
- (void)mouseUp:(NSEvent*)event {(void)event;[self sendAction:self.action to:self.target];if(self.tracking)self.tracking(NO);}
- (void)keyDown:(NSEvent*)event {std::array<double,3> delta={};if(event.keyCode==126)delta[0]=-3;else if(event.keyCode==125)delta[0]=3;else if(event.keyCode==123)delta[1]=3;else if(event.keyCode==124)delta[1]=-3;else{[super keyDown:event];return;}if((event.modifierFlags&NSEventModifierFlagShift)&&delta[1]){delta[2]=-delta[1];delta[1]=0;}angles=rotatePose(angles,delta);[self setNeedsDisplay:YES];[self sendAction:self.action to:self.target];}
@end
static NSFont* previewFont(const std::string& name){
    static const std::map<std::string,std::string> files={{"Archivo Black","ArchivoBlack"},{"Bebas Neue","BebasNeue"},{"Bungee","Bungee"},{"DM Serif Display","DMSerifDisplay"},{"Lobster","Lobster"},{"Monoton","Monoton"},{"Pacifico","Pacifico"},{"Permanent Marker","PermanentMarker"},{"Press Start 2P","PressStart2P"},{"Special Elite","SpecialElite"}};
    auto found=files.find(name);if(found==files.end())return [NSFont systemFontOfSize:14];auto path=vj::defaultTextFontRoot()/(found->second+".ttf");auto url=[NSURL fileURLWithPath:text(path.string())];auto descriptors=CTFontManagerCreateFontDescriptorsFromURL((__bridge CFURLRef)url);NSFont* result=nil;if(descriptors&&CFArrayGetCount(descriptors)){auto font=CTFontCreateWithFontDescriptor((CTFontDescriptorRef)CFArrayGetValueAtIndex(descriptors,0),name=="Press Start 2P"?11:15,nullptr);result=CFBridgingRelease(font);}if(descriptors)CFRelease(descriptors);return result?:[NSFont systemFontOfSize:14];
}

@interface VJInspectorStack : NSStackView
@end
@implementation VJInspectorStack
- (BOOL)isFlipped{return YES;}
@end
@interface VJCanvas : NSView <NSDraggingSource> { @public Json document;std::string selectedRow,selectedColumn,selectedSurface;bool mapper;uint64_t revision;double zoom;NSPoint pan; }
@property(strong) VJClipThumbnails* thumbnails;
@property(copy) void (^choose)(NSString*,NSString*);
@property(copy) void (^editSurface)(NSString*,NSData*);
@property(copy) void (^activate)(NSString*,NSString*,NSString*);
@property(copy) NSString* bus;
@property(copy) void (^gridCommand)(Json);
@end
@implementation VJCanvas { BOOL _space,_panning,_moving;NSPoint _start,_panStart;Json _original,_dragPayload;NSString* _launchColumn;NSString* _launchBank;NSRect _dropBounds;BOOL _rowTracking;NSPoint _hover;NSTrackingArea* _hoverTracking; }
- (instancetype)initWithFrame:(NSRect)frame{self=[super initWithFrame:frame];if(self){zoom=1;pan=NSZeroPoint;[self registerForDraggedTypes:@[@"com.vibe.clip",@"com.vibe.grid-order"]];}return self;}
- (void)updateTrackingAreas {[super updateTrackingAreas];if(_hoverTracking)[self removeTrackingArea:_hoverTracking];_hoverTracking=[[NSTrackingArea alloc]initWithRect:NSZeroRect options:NSTrackingMouseMoved|NSTrackingMouseEnteredAndExited|NSTrackingActiveInKeyWindow|NSTrackingInVisibleRect owner:self userInfo:nil];[self addTrackingArea:_hoverTracking];}
- (void)mouseMoved:(NSEvent*)event {_hover=[self convertPoint:event.locationInWindow fromView:nil];[self setNeedsDisplay:YES];}
- (void)mouseExited:(NSEvent*)event {(void)event;_hover=NSMakePoint(-1,-1);[self setNeedsDisplay:YES];}
- (void)viewDidMoveToSuperview {[super viewDidMoveToSuperview];auto clip=self.enclosingScrollView.contentView;clip.postsBoundsChangedNotifications=YES;[[NSNotificationCenter defaultCenter] removeObserver:self name:NSViewBoundsDidChangeNotification object:nil];[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(scrolled:) name:NSViewBoundsDidChangeNotification object:clip];}
- (void)dealloc {[[NSNotificationCenter defaultCenter] removeObserver:self];}
- (void)scrolled:(NSNotification*)n {(void)n;for(NSView* row in self.subviews){auto frame=row.frame;frame.origin.x=NSMinX(self.visibleRect);row.frame=frame;row.hidden=NSMinY(frame)<NSMinY(self.visibleRect)+25;}[self setNeedsDisplay:YES];}
- (void)refreshRows {
 if(_rowTracking||[self.window.firstResponder isKindOfClass:NSTextView.class])return;
 for(NSView* view in [self.subviews copy])[view removeFromSuperview];int i=0;
 for(auto it=document["rows"].rbegin();it!=document["rows"].rend();++it,++i){const auto& row=*it;auto panel=[[NSView alloc]initWithFrame:NSMakeRect(NSMinX(self.visibleRect),25+i*113,150,112)];[self addSubview:panel];
 auto name=[[NSTextField alloc]initWithFrame:NSMakeRect(22,83,76,23)];name.stringValue=text(row["name"]);name.identifier=@"name";[panel addSubview:name];auto mute=[NSButton checkboxWithTitle:@"" target:self action:@selector(rowEdited:)];mute.frame=NSMakeRect(2,83,20,23);mute.state=row.value("enabled",true)?NSControlStateValueOn:NSControlStateValueOff;mute.identifier=@"enabled";[panel addSubview:mute];
 for(int direction:{1,-1}){auto move=[NSButton buttonWithTitle:direction>0?@"↑":@"↓" target:self action:@selector(rowEdited:)];move.frame=NSMakeRect(direction>0?101:124,83,22,23);move.identifier=direction>0?@"up":@"down";[panel addSubview:move];}
 std::string rid=row["id"],column=rid==selectedRow?selectedColumn:document["selections"].value(self.bus?self.bus.UTF8String:"program",Json::object()).value(rid,std::string{});bool filled=row["clips"].contains(column);Json context={{"row",rid},{"column",column},{"active_show",document["active_show"]},{"revision",revision}};if(filled)context["clipId"]=row["clips"][column]["id"];
 auto blend=[[VJPopup alloc]initWithFrame:NSMakeRect(4,51,142,23) pullsDown:NO];[blend addItemsWithTitles:@[@"normal",@"add",@"screen",@"multiply",@"subtract"]];if(filled)[blend selectItemWithTitle:text(row["clips"][column].value("blend",row.value("blend",std::string("normal"))))];blend.enabled=filled;blend.identifier=@"blend";[panel addSubview:blend];
 auto opacity=[[VJParameterSlider alloc]initWithFrame:NSMakeRect(4,17,142,23)];opacity.minValue=0;opacity.maxValue=1;opacity.doubleValue=filled?row["clips"][column].value("opacity",1.):1;opacity.enabled=filled;opacity.identifier=@"opacity";opacity.continuous=YES;__weak VJCanvas* weak=self;opacity.tracking=^(BOOL active){VJCanvas* owner=weak;if(owner)owner->_rowTracking=active;};[panel addSubview:opacity];
 for(NSControl* control in panel.subviews){control.target=self;control.action=@selector(rowEdited:);auto b=[[VJInspectorBinding alloc]init];b->context=context;objc_setAssociatedObject(control,&inspectorBindingKey,b,OBJC_ASSOCIATION_RETAIN_NONATOMIC);}vj::style::apply(panel);
 }[self scrolled:nil];
}
- (void)rowEdited:(NSControl*)control {auto b=binding(control);if(!b||!self.gridCommand)return;Json command=b->context;command.erase("clipId");auto key=std::string(control.identifier.UTF8String);if(key=="name"||key=="enabled"){command["action"]="set_row";command[key]=key=="name"?Json(control.stringValue.UTF8String):Json(((NSButton*)control).state==NSControlStateValueOn);}else if(key=="up"||key=="down"){command["action"]="move_row";command["dir"]=key=="up"?1:-1;}else{command["action"]="set_clip";command[key]=key=="blend"?Json(((NSPopUpButton*)control).titleOfSelectedItem.UTF8String):Json(control.doubleValue);}self.gridCommand(command);}
- (BOOL)isFlipped{return YES;}
- (BOOL)acceptsFirstResponder{return YES;}
- (NSRect)mapBounds{return NSMakeRect(30+pan.x,30+pan.y,(self.bounds.size.width-60)*zoom,(self.bounds.size.height-60)*zoom);}
- (void)drawRect:(NSRect)dirty {
    (void)dirty;[vj::style::background() setFill];NSRectFill(self.bounds);
    NSDictionary* attrs=@{NSFontAttributeName:vj::style::font(),NSForegroundColorAttributeName:rgb(.87,.89,.89)};
    if(mapper){
        if(!document.contains("project"))return;const auto bounds=[self mapBounds];[[NSColor blackColor] setFill];NSRectFill(bounds);
        for(const auto& rect:document["project"]["rects"]){NSBezierPath* path=[NSBezierPath bezierPath];bool first=true;for(const auto& p:rect["corners"]){NSPoint v=NSMakePoint(bounds.origin.x+p[0].get<double>()*bounds.size.width,bounds.origin.y+p[1].get<double>()*bounds.size.height);if(first)[path moveToPoint:v];else[path lineToPoint:v];first=false;}[path closePath];
            [rgb(.09,.18,.15) setFill];[path fill];[(rect["id"]==selectedSurface?rgb(.3,1,.65):rgb(.35,.45,.4)) setStroke];path.lineWidth=rect["id"]==selectedSurface?2:1;[path stroke];[text(rect.value("name",std::string("Surface"))) drawAtPoint:NSMakePoint(path.bounds.origin.x+6,path.bounds.origin.y+6) withAttributes:attrs];
        }return;
    }
    if(!document.contains("rows"))return;
    auto visible=self.visibleRect;const auto bus=self.bus?self.bus.UTF8String:"program";bool running=document["running"].value(bus,false);int ri=0;
    for(auto it=document["rows"].rbegin();it!=document["rows"].rend();++it,++ri){const auto& row=*it;double y=25+ri*113;int ci=0;for(const auto& column:document["columns"]){auto cid=column["id"].get<std::string>();NSRect bounds=NSMakeRect(150+ci++*117,y,116,112);if(!NSIntersectsRect(bounds,visible))continue;bool filled=row["clips"].contains(cid),selected=row["id"]==selectedRow&&cid==selectedColumn;std::string rid=row["id"];bool bankA=filled&&document["selections"].value(bus,Json::object()).value(rid,std::string{})==cid,bankB=filled&&document["selections_b"].value(bus,Json::object()).value(rid,std::string{})==cid,muted=!row.value("enabled",true);bool missing=false;if(filled){const auto& clip=row["clips"][cid];missing=clip.value("nativeImportUnsupported",false)||(clip.contains("mediaStatus")&&!clip["mediaStatus"].value("available",false));}
        [vj::style::panel() setFill];NSRectFill(bounds);if(filled){auto poster=[self.thumbnails imageForClip:row["clips"][cid]];auto thumb=NSMakeRect(bounds.origin.x,bounds.origin.y,116,84);if(poster){[NSGraphicsContext saveGraphicsState];[NSBezierPath clipRect:thumb];auto size=poster.size;double scale=std::max(116./std::max(1.,size.width),84./std::max(1.,size.height));[poster drawInRect:NSMakeRect(NSMidX(thumb)-size.width*scale/2,NSMidY(thumb)-size.height*scale/2,size.width*scale,size.height*scale) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:muted?.35:1 respectFlipped:YES hints:nil];[NSGraphicsContext restoreGraphicsState];}
        auto nameRect=NSMakeRect(bounds.origin.x,bounds.origin.y+84,116,26);[(muted?vj::style::hex(0x4c402d):bankA?vj::style::hex(0x303d2c):bankB?vj::style::hex(0x152c46):vj::style::panel()) setFill];NSRectFill(nameRect);if(bankA&&bankB){[vj::style::hex(0x152c46) setFill];NSRectFill(NSMakeRect(nameRect.origin.x+58,nameRect.origin.y,58,26));}auto para=[NSMutableParagraphStyle new];para.lineBreakMode=NSLineBreakByTruncatingTail;[text(row["clips"][cid].value("name",std::string("Clip"))) drawInRect:NSInsetRect(nameRect,5,5) withAttributes:@{NSFontAttributeName:vj::style::font(11),NSForegroundColorAttributeName:bankA&&!bankB?vj::style::hex(0x9bc88a):bankB&&!bankA?vj::style::hex(0x579bff):vj::style::text(),NSParagraphStyleAttributeName:para}];
        if(selected||NSPointInRect(_hover,bounds)){[[@"×" description] drawAtPoint:NSMakePoint(bounds.origin.x+97,bounds.origin.y+4) withAttributes:attrs];}
        if(bankA||bankB){double width=bankA&&bankB?58:116;[(running?vj::style::hex(bankA?0x9bc88a:0x579bff):vj::style::secondary()) setFill];NSRectFill(NSMakeRect(bounds.origin.x+2,bounds.origin.y+107,width-4,3));if(bankA&&bankB){[vj::style::hex(0x579bff) setFill];NSRectFill(NSMakeRect(bounds.origin.x+58,bounds.origin.y+107,56,3));}}
        NSString* state=missing?@"Unavailable":muted?@"Muted":(bankA||bankB)?(running?(bankA&&bankB?@"A + B":bankA?@"A":@"B"):@"Stopped"):@"";[state drawAtPoint:NSMakePoint(bounds.origin.x+6,bounds.origin.y+66) withAttributes:@{NSFontAttributeName:vj::style::font(10),NSForegroundColorAttributeName:missing?vj::style::hex(0xe59186):vj::style::text()}];}
        if(!filled)[@"+" drawAtPoint:NSMakePoint(NSMidX(bounds)-6,NSMidY(bounds)-12) withAttributes:@{NSFontAttributeName:vj::style::font(21),NSForegroundColorAttributeName:vj::style::secondary()}];
        [(selected?vj::style::accent():vj::style::panel()) setStroke];auto border=[NSBezierPath bezierPathWithRect:NSInsetRect(bounds,.5,.5)];border.lineWidth=selected?2:1;[border stroke];
    }}
    // Frozen headers are painted last; row widgets track the horizontal origin.
    [vj::style::panel() setFill];NSRectFill(NSMakeRect(visible.origin.x,visible.origin.y,visible.size.width,25));NSRectFill(NSMakeRect(visible.origin.x,visible.origin.y,150,visible.size.height));int ci=0;for(const auto& column:document["columns"]){double x=150+ci++*117;if(x+116<=visible.origin.x+150)continue;[text(column["name"]) drawInRect:NSMakeRect(std::max(x,visible.origin.x+150)+5,visible.origin.y+5,106,20) withAttributes:@{NSFontAttributeName:vj::style::font(10),NSForegroundColorAttributeName:vj::style::secondary()}];[@"⋯" drawAtPoint:NSMakePoint(x+98,visible.origin.y+2) withAttributes:attrs];}
    if(!NSIsEmptyRect(_dropBounds)){[rgb(.4,1,.65) setStroke];NSBezierPath* hint=[NSBezierPath bezierPathWithRect:_dropBounds];hint.lineWidth=3;[hint stroke];}
}
- (NSMenu*)menuForEvent:(NSEvent*)event {
    if(mapper)return nil;auto point=[self convertPoint:event.locationInWindow fromView:nil];int column=int((point.x-150)/117);if(column<0||column>=int(document["columns"].size()))return nil;
    auto menu=[[NSMenu alloc]initWithTitle:@"Column"];std::string cid=document["columns"][column]["id"];
    for(NSArray* spec in @[@[@"Rename…",@"rename_column"],@[@"Move left",@"left"],@[@"Move right",@"right"],@[@"Delete column",@"delete_column"]]){auto item=[[NSMenuItem alloc]initWithTitle:spec[0] action:@selector(columnMenu:) keyEquivalent:@""];item.target=self;auto b=[[VJInspectorBinding alloc]init];b->context={{"action",[spec[1] UTF8String]},{"column",cid},{"active_show",document["active_show"]},{"revision",revision},{"name",document["columns"][column]["name"]}};objc_setAssociatedObject(item,&inspectorBindingKey,b,OBJC_ASSOCIATION_RETAIN_NONATOMIC);[menu addItem:item];}return menu;
}
- (void)columnMenu:(NSMenuItem*)sender {auto b=(VJInspectorBinding*)objc_getAssociatedObject(sender,&inspectorBindingKey);if(!b||!self.gridCommand)return;auto command=b->context;auto action=command["action"].get<std::string>();auto name=command["name"].get<std::string>();command.erase("name");if(action=="rename_column"){auto dialog=[[NSAlert alloc]init];dialog.messageText=@"Column name";[dialog addButtonWithTitle:@"Save"];[dialog addButtonWithTitle:@"Cancel"];auto field=[[NSTextField alloc]initWithFrame:NSMakeRect(0,0,240,24)];field.stringValue=text(name);dialog.accessoryView=field;if([dialog runModal]!=NSAlertFirstButtonReturn)return;command["name"]=field.stringValue.UTF8String;}else if(action=="left"||action=="right"){command["action"]="move_column";command["dir"]=action=="left"?-1:1;}self.gridCommand(command);}
- (void)mouseDown:(NSEvent*)event {
    [self.window makeFirstResponder:self];auto point=[self convertPoint:event.locationInWindow fromView:nil];_start=point;_original=Json();_dragPayload=Json();_launchColumn=nil;
    if(mapper){
        if(_space){_panning=YES;_panStart=pan;return;}
        auto bounds=[self mapBounds];NSPoint uv=NSMakePoint((point.x-bounds.origin.x)/bounds.size.width,(point.y-bounds.origin.y)/bounds.size.height);
        selectedSurface.clear();for(const auto& rect:document["project"]["rects"]){NSBezierPath* path=[NSBezierPath bezierPath];bool first=true;for(const auto& p:rect["corners"]){NSPoint v=NSMakePoint(p[0],p[1]);if(first)[path moveToPoint:v];else[path lineToPoint:v];first=false;}[path closePath];if([path containsPoint:uv]){selectedSurface=rect["id"];_original=rect["corners"];}}
        _moving=!selectedSurface.empty();if(self.choose)self.choose(text(selectedSurface),@"");[self setNeedsDisplay:YES];return;
    }
    int row=static_cast<int>((point.y-25)/113),column=static_cast<int>((point.x-150)/117);
    if(point.y<NSMinY(self.visibleRect)+25&&column>=0&&column<int(document["columns"].size())&&point.x-(150+column*117)>96){auto menu=[self menuForEvent:event];if(menu)[NSMenu popUpContextMenu:menu withEvent:event forView:self];return;}
    const NSString* bank=(event.modifierFlags&NSEventModifierFlagOption)?@"B":@"A";
    if(point.y<NSMinY(self.visibleRect)+25&&point.x>=NSMinX(self.visibleRect)+150&&column>=0&&column<static_cast<int>(document["columns"].size()))_dragPayload={{"kind","column"},{"column",document["columns"][column]["id"]},{"active_show",document["active_show"]}};
    if(point.y<NSMinY(self.visibleRect)+25){if(point.x>=NSMinX(self.visibleRect)+150&&column>=0&&column<static_cast<int>(document["columns"].size())&&self.activate){_launchColumn=text(document["columns"][column]["id"]);_launchBank=(NSString*)bank;}return;}
    if(row<0||row>=static_cast<int>(document["rows"].size()))return;
    row=static_cast<int>(document["rows"].size())-1-row;selectedRow=document["rows"][row]["id"];
    if(point.x<NSMinX(self.visibleRect)+150){auto selected=document["selections"].value(self.bus?self.bus.UTF8String:"program",Json::object());selectedColumn=selected.value(selectedRow,document["columns"][0]["id"].get<std::string>());}
    else{if(column<0||column>=static_cast<int>(document["columns"].size()))return;selectedColumn=document["columns"][column]["id"];}
    if(point.x<NSMinX(self.visibleRect)+150)_dragPayload={{"kind","row"},{"row",selectedRow},{"active_show",document["active_show"]}};
    else if(document["rows"][row]["clips"].contains(selectedColumn)){const auto& clip=document["rows"][row]["clips"][selectedColumn];_dragPayload={{"effect",clip["gen"]},{"params",clip["params"]},{"name",clip["name"]}};}
    if(point.x>=NSMinX(self.visibleRect)+150&&point.x-(150+column*117)>92&&point.y-(25+(int(document["rows"].size())-1-row)*113)<25&&document["rows"][row]["clips"].contains(selectedColumn)&&self.gridCommand){self.gridCommand({{"action","delete_clip"},{"row",selectedRow},{"column",selectedColumn},{"active_show",document["active_show"]},{"revision",revision}});return;}
    if(self.choose)self.choose(text(selectedRow),text(selectedColumn));
    if(point.x>=NSMinX(self.visibleRect)+150&&(event.modifierFlags&(NSEventModifierFlagCommand|NSEventModifierFlagOption))&&document["rows"][row]["clips"].contains(selectedColumn)&&self.activate)self.activate(text(selectedRow),text(selectedColumn),(NSString*)bank);
    [self setNeedsDisplay:YES];
}
- (void)mouseDragged:(NSEvent*)event {
    auto point=[self convertPoint:event.locationInWindow fromView:nil];
    if(!mapper){
        if(!_dragPayload.is_object()||hypot(point.x-_start.x,point.y-_start.y)<5)return;
        _launchColumn=nil;auto item=[[NSPasteboardItem alloc] init];[item setString:text(_dragPayload.dump()) forType:_dragPayload.contains("kind")?@"com.vibe.grid-order":@"com.vibe.clip"];
        auto drag=[[NSDraggingItem alloc] initWithPasteboardWriter:item];auto icon=[NSImage imageWithSystemSymbolName:@"square.stack" accessibilityDescription:@"Clip"];
        [drag setDraggingFrame:NSMakeRect(_start.x-12,_start.y-12,24,24) contents:icon];[self beginDraggingSessionWithItems:@[drag] event:event source:self];_dragPayload=Json();return;
    }
    if(_panning){pan=NSMakePoint(_panStart.x+point.x-_start.x,_panStart.y+point.y-_start.y);[self setNeedsDisplay:YES];return;}
    if(!_moving||_original.is_null())return;auto bounds=[self mapBounds];double dx=(point.x-_start.x)/bounds.size.width,dy=(point.y-_start.y)/bounds.size.height;
    double minx=1,miny=1,maxx=0,maxy=0;for(const auto& p:_original){minx=std::min(minx,p[0].get<double>());maxx=std::max(maxx,p[0].get<double>());miny=std::min(miny,p[1].get<double>());maxy=std::max(maxy,p[1].get<double>());}dx=std::clamp(dx,-minx,1-maxx);dy=std::clamp(dy,-miny,1-maxy);
    for(auto& rect:document["project"]["rects"])if(rect["id"]==selectedSurface){rect["corners"]=_original;for(auto& p:rect["corners"]){p[0]=p[0].get<double>()+dx;p[1]=p[1].get<double>()+dy;}}
    [self setNeedsDisplay:YES];
}
- (void)mouseUp:(NSEvent*)event {
    (void)event;if(_launchColumn&&self.activate){self.activate(@"",_launchColumn,_launchBank);_launchColumn=nil;}if(_moving&&!_original.is_null())for(const auto& rect:document["project"]["rects"])if(rect["id"]==selectedSurface&&rect["corners"]!=_original&&self.editSurface){auto s=rect["corners"].dump();self.editSurface(text(selectedSurface),[NSData dataWithBytes:s.data() length:s.size()]);}
    _moving=NO;_panning=NO;_original=Json();
}
- (void)keyDown:(NSEvent*)event {
    if(mapper){if([event.characters isEqualToString:@" "]){_space=YES;[[NSCursor openHandCursor] set];}else[super keyDown:event];return;}
    const auto flags=event.modifierFlags;
    if((event.keyCode==51||event.keyCode==117)&&!(flags&(NSEventModifierFlagCommand|NSEventModifierFlagOption|NSEventModifierFlagControl))){
        if(!event.isARepeat&&self.gridCommand&&!selectedRow.empty()&&!selectedColumn.empty())self.gridCommand({{"action","delete_cell"},{"row",selectedRow},{"column",selectedColumn}});return;
    }
    if(event.keyCode>=123&&event.keyCode<=126&&!document["rows"].empty()&&!document["columns"].empty()){
        int r=0,c=0;for(int i=0;i<int(document["rows"].size());i++)if(document["rows"][i]["id"]==selectedRow)r=i;
        for(int i=0;i<int(document["columns"].size());i++)if(document["columns"][i]["id"]==selectedColumn)c=i;
        if(event.keyCode==123)c--;if(event.keyCode==124)c++;if(event.keyCode==125)r--;if(event.keyCode==126)r++;
        r=std::clamp(r,0,int(document["rows"].size())-1);c=std::clamp(c,0,int(document["columns"].size())-1);
        if(self.choose)self.choose(text(document["rows"][r]["id"]),text(document["columns"][c]["id"]));return;
    }
    [super keyDown:event];
}
- (BOOL)performKeyEquivalent:(NSEvent*)event {
    if(!mapper&&!event.isARepeat&&(event.modifierFlags&NSEventModifierFlagCommand)&&[event.charactersIgnoringModifiers.lowercaseString isEqualToString:@"z"]){if(self.gridCommand)self.gridCommand({{"action",event.modifierFlags&NSEventModifierFlagShift?"redo":"undo"}});return YES;}return [super performKeyEquivalent:event];
}
- (void)copy:(id)sender {
    (void)sender;for(const auto& row:document["rows"])if(row["id"]==selectedRow&&row["clips"].contains(selectedColumn)){
        const auto& clip=row["clips"][selectedColumn];Json payload={{"effect",clip["gen"]},{"params",clip["params"]},{"name",clip["name"]}};
        [NSPasteboard.generalPasteboard clearContents];[NSPasteboard.generalPasteboard setString:text(payload.dump()) forType:@"com.vibe.clip"];return;
    }
}
- (void)paste:(id)sender {
    (void)sender;NSString* raw=[NSPasteboard.generalPasteboard stringForType:@"com.vibe.clip"];if(!raw||!self.gridCommand||selectedRow.empty()||selectedColumn.empty())return;
    auto payload=Json::parse(raw.UTF8String,nullptr,false);if(!payload.is_object())return;
    payload.update({{"action","put_clip"},{"row",selectedRow},{"column",selectedColumn}});self.gridCommand(payload);
}
- (NSDragOperation)draggingSession:(NSDraggingSession*)session sourceOperationMaskForDraggingContext:(NSDraggingContext)context {(void)session;return context==NSDraggingContextWithinApplication?NSDragOperationCopy|NSDragOperationMove:NSDragOperationNone;}
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {return [self draggingUpdated:sender];}
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender {
    if(mapper)return NSDragOperationNone;auto pt=[self convertPoint:sender.draggingLocation fromView:nil];
    int r=int((pt.y-25)/113),c=int((pt.x-150)/117);bool order=[sender.draggingPasteboard stringForType:@"com.vibe.grid-order"]!=nil;
    if(order){_dropBounds=NSMakeRect(0,std::max(0.,25.+r*113.),self.bounds.size.width,2);[self setNeedsDisplay:YES];return NSDragOperationMove;}
    if(pt.x<150||pt.y<25||r<0||r>=int(document["rows"].size())||c<0||c>=int(document["columns"].size()))return NSDragOperationNone;
    _dropBounds=NSMakeRect(150+c*117,25+r*113,116,112);[self setNeedsDisplay:YES];return NSDragOperationCopy;
}
- (void)draggingExited:(id<NSDraggingInfo>)sender {(void)sender;_dropBounds=NSZeroRect;[self setNeedsDisplay:YES];}
- (void)concludeDragOperation:(id<NSDraggingInfo>)sender {[self draggingExited:sender];}
- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    [self draggingExited:sender];if(!self.gridCommand)return NO;auto pt=[self convertPoint:sender.draggingLocation fromView:nil];
    int visual=int((pt.y-25)/113),column=int((pt.x-150)/117);NSString* raw=[sender.draggingPasteboard stringForType:@"com.vibe.grid-order"];
    if(raw){auto command=Json::parse(raw.UTF8String,nullptr,false);if(!command.is_object())return NO;
        if(command.value("kind",std::string{})=="row"){
            if(pt.y<25||visual<0||visual>=int(document["rows"].size()))return NO;
            command.update({{"action","move_row"},{"target",document["rows"][document["rows"].size()-1-visual]["id"]},{"position",pt.y-(25+visual*113)<56.5?"above":"below"}});
        }else{
            if(pt.x<150||column<0||column>=int(document["columns"].size()))return NO;
            command.update({{"action","move_column"},{"target",document["columns"][column]["id"]},{"position",pt.x-(150+column*117)<58.5?"before":"after"}});
        }command.erase("kind");self.gridCommand(command);return YES;
    }
    raw=[sender.draggingPasteboard stringForType:@"com.vibe.clip"];if(!raw||pt.y<25||pt.x<150||visual<0||visual>=int(document["rows"].size())||column<0||column>=int(document["columns"].size()))return NO;
    auto command=Json::parse(raw.UTF8String,nullptr,false);if(!command.is_object()||(!command.contains("effect")&&!command.contains("subpatchID")))return NO;
    const auto row=document["rows"][document["rows"].size()-1-visual]["id"],col=document["columns"][column]["id"];
    command.update({{"action","put_clip"},{"row",row},{"column",col}});self.gridCommand(command);if(self.choose)self.choose(text(row),text(col));return YES;
}
- (void)keyUp:(NSEvent*)event{if([event.characters isEqualToString:@" "]){_space=NO;[[NSCursor arrowCursor] set];}else[super keyUp:event];}
- (void)scrollWheel:(NSEvent*)event{if(!mapper){[super scrollWheel:event];return;}zoom=std::clamp(zoom*std::exp(-event.scrollingDeltaY*.015),.25,4.);[self setNeedsDisplay:YES];}
@end

// Fixed rectangles keep rendering, clipping and event dispatch in agreement.
@interface VJComposeMonitors : NSView
@property(strong) NSArray<VJPreview*>* previews;
@property(strong) NSArray<NSTextField*>* labels;
- (instancetype)initWithModel:(vj::Model*)model;
@end
@implementation VJComposeMonitors
- (instancetype)initWithModel:(vj::Model*)model {if((self=[super initWithFrame:NSZeroRect])){NSMutableArray* previews=[NSMutableArray array];NSMutableArray* labels=[NSMutableArray array];for(NSString* bank in @[@"A",@"B",@""]){auto preview=[[VJPreview alloc]initWithFrame:NSZeroRect model:model];[preview setMonitorBank:bank];[self addSubview:preview];[previews addObject:preview];auto label=[NSTextField labelWithString:bank.length?bank:@"Out"];label.font=vj::style::font(11);[self addSubview:label];[labels addObject:label];}_previews=previews;_labels=labels;}return self;}
- (BOOL)isFlipped{return YES;}
- (void)drawRect:(NSRect)rect {(void)rect;[vj::style::background() setFill];NSRectFill(self.bounds);}
- (void)layout {[super layout];double available=MAX(0,self.bounds.size.width-32),unit=available/2.55,out=unit*.55;if(out<110){out=110;unit=MAX(0,(available-out)/2);}double x=8;for(NSUInteger i=0;i<3;++i){double column=i==2?out:unit,height=MAX(0,MIN(MIN(180,column*9/16),self.bounds.size.height-28)),width=MIN(column,height*16/9),left=x+(column-width)/2,y=MAX(4,(self.bounds.size.height-height-20)/2);_labels[i].frame=NSMakeRect(left,y,width,17);_labels[i].textColor=i==0?vj::style::hex(0x9bc88a):i==1?vj::style::hex(0x579bff):vj::style::secondary();_previews[i].frame=NSMakeRect(left,y+20,width,height);x+=column+8;}}
@end
// Anchor the show list below the field instead of centering the selected item
// over the field as AppKit's default popup tracking does.
@interface VJShowPicker : VJPopup @end
@implementation VJShowPicker @end

@interface VJFlowBar : NSView
@property(nonatomic) CGFloat spacing;
@property(nonatomic) BOOL noWrap;
@property(nonatomic) BOOL plain;
@property(nonatomic) NSEdgeInsets padding;
- (void)addItem:(NSView*)view width:(CGFloat)width;
@end
@implementation VJFlowBar { CGFloat _height; }
- (instancetype)initWithFrame:(NSRect)frame {if((self=[super initWithFrame:frame])){_spacing=6;_padding=NSEdgeInsetsMake(5,8,5,8);_height=36;}return self;}
- (BOOL)isFlipped{return YES;}
- (void)addItem:(NSView*)view width:(CGFloat)width {view.translatesAutoresizingMaskIntoConstraints=YES;view.frame=NSMakeRect(0,0,width,26);[self addSubview:view];self.needsLayout=YES;}
- (NSSize)intrinsicContentSize {return NSMakeSize(NSViewNoIntrinsicMetric,_height);}
- (void)layout {[super layout];CGFloat x=self.padding.left,y=self.padding.top;for(NSView* view in self.subviews){auto size=view.frame.size;if(!self.noWrap&&x>self.padding.left&&x+size.width>self.bounds.size.width-self.padding.right){x=self.padding.left;y+=26+self.spacing;}view.frame=NSMakeRect(x,y,size.width,self.noWrap?size.height:26);x+=size.width+self.spacing;}CGFloat height=y+26+self.padding.bottom;if(height!=_height){_height=height;[self invalidateIntrinsicContentSize];}}
- (void)drawRect:(NSRect)rect {(void)rect;if(self.plain)return;[vj::style::background() setFill];NSRectFill(self.bounds);[vj::style::border() setFill];NSRectFill(NSMakeRect(0,self.bounds.size.height-1,self.bounds.size.width,1));}
@end

static BOOL checkHitTargets(NSView* root) {
    BOOL valid=YES;NSUInteger checked=0;
    std::function<void(NSView*)> inspect=[&](NSView* view){if(view.isHiddenOrHasHiddenAncestor)return;
        if([view isKindOfClass:NSControl.class]){auto control=(NSControl*)view;BOOL interactive=[view isKindOfClass:NSButton.class]||[view isKindOfClass:NSSlider.class]||([view isKindOfClass:NSTextField.class]&&((NSTextField*)view).isEditable);if(interactive&&control.enabled){auto visible=view.visibleRect;if(!NSIsEmptyRect(visible)&&NSContainsRect(visible,NSInsetRect(view.bounds,1,1))){NSPoint point=NSMakePoint(NSMidX(view.bounds),NSMidY(view.bounds));auto hit=[root hitTest:[view convertPoint:point toView:root.superview]];if((hit!=view&&![hit isDescendantOf:view])||view.bounds.size.height<16||view.bounds.size.width<12){NSLog(@"Unreachable control %@ %@ bounds %@ hit %@",view.className,control.stringValue,NSStringFromRect(view.bounds),hit.className);valid=NO;}++checked;}}
        }if([view isKindOfClass:NSSearchField.class])return; // Its glyphs belong to the composite hit target.
        for(NSView* child in view.subviews)inspect(child);
    };inspect(root);NSLog(@"Hit targets: %lu checked, %@",(unsigned long)checked,valid?@"pass":@"FAIL");return valid;
}
@interface VJPatchLoopbackDelegate : NSObject <NSURLSessionTaskDelegate>
@end
@implementation VJPatchLoopbackDelegate
- (void)URLSession:(NSURLSession*)session task:(NSURLSessionTask*)task willPerformHTTPRedirection:(NSHTTPURLResponse*)response newRequest:(NSURLRequest*)request completionHandler:(void (^)(NSURLRequest*))completion {
    completion(nil);
}
@end

using PatchInventory=std::shared_ptr<const Json>;
static Json patchRows(NSArray* rows) {
    if(!rows.count)return Json::array();
    NSData* data=[NSJSONSerialization dataWithJSONObject:rows options:0 error:nil];
    if(!data)return Json::array();
    const auto* begin=static_cast<const uint8_t*>(data.bytes);
    auto parsed=Json::parse(begin,begin+data.length,nullptr,false);
    return parsed.is_array()?std::move(parsed):Json::array();
}
static void appendPatchRows(Json& result,std::set<std::string>& seen,const Json& rows) {
    for(const auto& row:rows){
        if(!row.is_object()||!row.contains("id")||!row["id"].is_string())continue;
        if(seen.insert(row["id"].get<std::string>()).second)result.push_back(row);
    }
}
@implementation VJApplication {
    vj::Model* _model;unsigned short _port;NSWindow* _window;NSStackView* _root;NSStackView* _toolbar;NSStackView* _inspector;
    PatchInventory _standaloneOutputs,_standalonePalettes;
    std::shared_ptr<const std::set<std::string>> _standaloneIDs;
    Json _retainedPatchIDs;
    std::string _paletteShape;
    BOOL _paletteRequest,_outputsRequest,_mergingPatchOutputs;
    NSTimeInterval _nextPeerOutputs,_nextPeerPalettes,_nextPatchMerge,_nextPaletteMerge;
    NSURLSession* _paletteSession;
    PatchEditorController* _patch;NSView* _patchContainer;BOOL _patchActive;NSError* _patchError;
    NSSplitView* _workspaceSplit;NSView* _composerPane;BOOL _splitMode;CGFloat _splitFraction;id _paneMonitor;NSLayoutConstraint* _gridMinHeight;NSTimer* _faderPoll;
    VJControls* _controlsView;bool _controls;VJPerformanceBar* _performance;
    VJOutputs* _outputs;BOOL _checking;NSString* _address;VJLibrary* _library;VJClipSearch* _clipSearch;NSLayoutConstraint* _libraryWidth;NSLayoutConstraint* _inspectorWidth;NSLayoutConstraint* _previewHeight;NSTextField* _playhead;VJParameterSlider* _seek;std::string _mediaClip,_mediaItem,_seekMediaItem;
    VJMetaMapping* _metaView;VJMapper* _mapperView;NSStackView* _composerBody;VJComposeMonitors* _monitors;VJSidePanel* _libraryPanel;VJSidePanel* _clipPanel;NSStackView* _nav;VJFlowBar* _outStrip;NSLayoutConstraint* _outStripHeight;VJCanvas* _canvas;VJPreview* _preview;NSTextField* _status;NSPopUpButton* _out;NSPopUpButton* _show;NSPopUpButton* _effect;NSPopUpButton* _bank;NSPopUpButton* _projector;
    VJParameterSlider* _fade;BOOL _faderTracking,_faderPending;uint64_t _faderGeneration;std::string _outStripShape;NSButton* _transport;NSButton* _faderSync;id _keyboardMonitor;bool _inspectorDirty;NSScrollView* _inspectorScroll;std::string _inspectorShape;NSTimer* _poll;Json _snapshot;uint64_t _revision;bool _mapping,_editing;BOOL _selectionPending,_closing;uint64_t _selectionGeneration;std::string _row,_column,_surface,_mid;
}
- (instancetype)initWithModel:(vj::Model*)model port:(unsigned short)port address:(NSString*)address{self=[super init];if(self){_model=model;_port=port;_address=[address copy];_revision=UINT64_MAX;_mid="1";}return self;}
- (NSStackView*)stack:(NSUserInterfaceLayoutOrientation)orientation {return vj::style::stack(orientation);}
- (NSTextField*)label:(NSString*)value {return vj::style::label(value);}
- (NSButton*)button:(NSString*)title action:(SEL)action {return vj::style::button(title,self,action);}
- (VJAction*)command:(NSString*)title body:(Json)body path:(std::string)path {auto b=[VJAction buttonWithTitle:title target:self action:@selector(perform:)];b.font=vj::style::font(11);b->command=std::move(body);b->path=std::move(path);return b;}
- (NSTextField*)nameField:(const Json&)value scope:(NSString*)scope {
    auto field=[[NSTextField alloc] initWithFrame:NSMakeRect(0,0,190,24)];field.stringValue=text(value);field.identifier=scope;field.target=self;field.action=@selector(rename:);[field.widthAnchor constraintEqualToConstant:190].active=YES;return field;
}
- (void)applicationDidFinishLaunching:(NSNotification*)notification {(void)notification;if(_checking)return;
    NSString* page=[NSUserDefaults.standardUserDefaults stringForKey:@"VJWorkspacePage"]?:@"Compose";
    [self build];
    NSDictionary* actions=@{@"Mapping":@"mapping:",@"Compose":@"compose:",@"Patch":@"patch:",@"Lights":@"lights:",@"Mixer":@"mix:",@"Settings":@"settings:",@"Compose + patch":@"toggleComposerPatch:",@"Meta Mapping":@"mapping:",@"patch":@"patch:",@"LEDs":@"leds:",@"DMX":@"dmx:",@"Mix":@"mix:"};
    NSString* action=actions[page]?:@"compose:";[NSApp sendAction:NSSelectorFromString(action) to:self from:nil];
    [_window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];}
- (void)build {
    VJInstallControlStyle();
    _window=[[NSWindow alloc] initWithContentRect:NSMakeRect(100,100,1250,790) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    _window.releasedWhenClosed=NO;_window.delegate=self;if(!_checking)[_window setFrameAutosaveName:@"VJNativeWorkspace"];
    _window.title=[@"VJ — " stringByAppendingString:@(_model->stateRoot().filename().c_str())];_window.minSize=NSMakeSize(900,620);_window.appearance=[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];_window.backgroundColor=vj::style::background();
    _root=[self stack:NSUserInterfaceLayoutOrientationVertical];_root.edgeInsets=NSEdgeInsetsMake(0,0,0,0);_root.spacing=0;_root.wantsLayer=YES;_root.layer.backgroundColor=vj::style::background().CGColor;_root.translatesAutoresizingMaskIntoConstraints=NO;[_window.contentView addSubview:_root];
    [NSLayoutConstraint activateConstraints:@[[_root.leadingAnchor constraintEqualToAnchor:_window.contentView.leadingAnchor],[_root.trailingAnchor constraintEqualToAnchor:_window.contentView.trailingAnchor],[_root.topAnchor constraintEqualToAnchor:_window.contentView.topAnchor],[_root.bottomAnchor constraintEqualToAnchor:_window.contentView.bottomAnchor]]];
    auto nav=[self stack:NSUserInterfaceLayoutOrientationHorizontal];_nav=nav;nav.spacing=1;nav.edgeInsets=NSEdgeInsetsMake(5,8,5,8);nav.wantsLayer=YES;nav.layer.backgroundColor=vj::style::panel().CGColor;auto brand=[self label:@"VJ"];brand.font=vj::style::font(16);[nav addArrangedSubview:brand];[nav setCustomSpacing:10 afterView:brand];
    for(NSArray* item in @[@[@"Mapping",@"mapping:"],@[@"Compose",@"compose:"],@[@"Patch",@"patch:"],@[@"Lights",@"lights:"],@[@"Mixer",@"mix:"],@[@"Settings",@"settings:"]]){auto button=[self button:item[0] action:NSSelectorFromString(item[1])];button.identifier=[@"tab-" stringByAppendingString:item[0]];button.buttonType=NSButtonTypePushOnPushOff;button.state=[item[0] isEqualToString:@"Compose"]?NSControlStateValueOn:NSControlStateValueOff;button.font=vj::style::font(12);[nav addArrangedSubview:button];}
    [nav addArrangedSubview:[self button:@"Projector preview" action:@selector(projectorPreview:)]];
    auto spacer=[[NSView alloc]init];[nav addArrangedSubview:spacer];[spacer.widthAnchor constraintGreaterThanOrEqualToConstant:10].active=YES;auto showLabel=[self label:@"Show"];showLabel.textColor=NSColor.secondaryLabelColor;[nav addArrangedSubview:showLabel];[nav setCustomSpacing:6 afterView:showLabel];auto showLibrary=[[VJShowLibraryPicker alloc]initWithRoot:_model->stateRoot()];showLibrary.identifier=@"show-library";showLibrary.font=vj::style::font(12);[nav addArrangedSubview:showLibrary];[_root addArrangedSubview:nav];[nav.widthAnchor constraintEqualToAnchor:_root.widthAnchor].active=YES;[nav.heightAnchor constraintEqualToConstant:38].active=YES;
    _toolbar=[self stack:NSUserInterfaceLayoutOrientationVertical];_toolbar.spacing=0;
    _out=[[VJPopup alloc] initWithFrame:NSZeroRect pullsDown:NO];_out.target=self;_out.action=@selector(outChanged:);
    _show=[[VJShowPicker alloc] initWithFrame:NSZeroRect pullsDown:NO];_show.target=self;_show.action=@selector(showChanged:);
    _bank=[[VJPopup alloc] initWithFrame:NSZeroRect pullsDown:NO];[_bank addItemsWithTitles:@[@"A",@"B"]];
    _projector=[[VJPopup alloc] initWithFrame:NSZeroRect pullsDown:NO];[_projector addItemsWithTitles:@[@"Projector 1",@"Projector 2",@"Projector 3",@"Projector 4"]];_projector.target=self;_projector.action=@selector(projectorChanged:);
    _faderSync=[self button:@"Fader detached" action:@selector(faderSync:)];_faderSync.buttonType=NSButtonTypePushOnPushOff;
    _fade=[VJParameterSlider sliderWithValue:0 minValue:0 maxValue:1 target:self action:@selector(fade:)];_fade.continuous=YES;_fade.accessibilityLabel=@"A/B crossfade";
    __weak VJApplication* faderOwner=self;_fade.tracking=^(BOOL active){VJApplication* owner=faderOwner;if(!owner)return;owner->_faderTracking=active;if(!active){owner->_revision=UINT64_MAX;[owner refresh];}};
    _monitors=[[VJComposeMonitors alloc]initWithModel:_model];_preview=_monitors.previews[0];_previewHeight=[_monitors.heightAnchor constraintEqualToConstant:180];_previewHeight.active=YES;
    _workspaceSplit=[[NSSplitView alloc]init];_workspaceSplit.vertical=NO;_workspaceSplit.dividerStyle=NSSplitViewDividerStyleThin;_workspaceSplit.delegate=self;_workspaceSplit.identifier=@"composer-patch-split";_splitFraction=[NSUserDefaults.standardUserDefaults doubleForKey:@"VJWorkspaceSplitFraction"];if(_splitFraction<.1||_splitFraction>.9)_splitFraction=.5;[_root addArrangedSubview:_workspaceSplit];[_workspaceSplit.widthAnchor constraintEqualToAnchor:_root.widthAnchor].active=YES;
    _composerPane=[[NSView alloc]init];[_workspaceSplit addArrangedSubview:_composerPane];
    auto body=[self stack:NSUserInterfaceLayoutOrientationHorizontal];_composerBody=body;body.spacing=0;body.alignment=NSLayoutAttributeTop;body.translatesAutoresizingMaskIntoConstraints=NO;[_composerPane addSubview:body];
    [NSLayoutConstraint activateConstraints:@[[body.leadingAnchor constraintEqualToAnchor:_composerPane.leadingAnchor],[body.trailingAnchor constraintEqualToAnchor:_composerPane.trailingAnchor],[body.topAnchor constraintEqualToAnchor:_composerPane.topAnchor],[body.bottomAnchor constraintEqualToAnchor:_composerPane.bottomAnchor]]];
    auto center=[self stack:NSUserInterfaceLayoutOrientationVertical];center.spacing=0;_library=[[VJLibrary alloc]initWithFrame:NSMakeRect(0,0,210,600) model:_model];_libraryPanel=[[VJSidePanel alloc]init];_libraryPanel.title=@"Library";_libraryPanel.body=_library;_libraryPanel.collapsed=[NSUserDefaults.standardUserDefaults boolForKey:@"vj-native-library-collapsed"];[body addArrangedSubview:_libraryPanel];_libraryWidth=[_libraryPanel.widthAnchor constraintEqualToConstant:210];_libraryWidth.active=YES;[body addArrangedSubview:center];[center.widthAnchor constraintGreaterThanOrEqualToConstant:280].active=YES;[center addArrangedSubview:_monitors];[center addArrangedSubview:_toolbar];for(NSView* view in @[_monitors,_toolbar])[view.widthAnchor constraintEqualToAnchor:center.widthAnchor].active=YES;
    _canvas=[[VJCanvas alloc] initWithFrame:NSMakeRect(0,0,850,380)];__weak VJCanvas* weakCanvas=_canvas;_canvas.thumbnails=[[VJClipThumbnails alloc] initWithModel:_model redraw:^{[weakCanvas setNeedsDisplay:YES];}];
    auto scroll=[[NSScrollView alloc] initWithFrame:NSZeroRect];scroll.documentView=_canvas;scroll.hasVerticalScroller=YES;scroll.hasHorizontalScroller=YES;[center addArrangedSubview:scroll];[scroll.widthAnchor constraintEqualToAnchor:center.widthAnchor].active=YES;_gridMinHeight=[scroll.heightAnchor constraintGreaterThanOrEqualToConstant:240];_gridMinHeight.active=YES;[center.heightAnchor constraintEqualToAnchor:body.heightAnchor].active=YES;
    _inspector=[[VJInspectorStack alloc] initWithFrame:NSMakeRect(0,0,195,400)];_inspector.translatesAutoresizingMaskIntoConstraints=NO;_inspector.orientation=NSUserInterfaceLayoutOrientationVertical;_inspector.alignment=NSLayoutAttributeLeading;_inspector.spacing=6;_inspector.edgeInsets=NSEdgeInsetsMake(8,8,8,8);
    auto inspectorScroll=[[NSScrollView alloc] initWithFrame:NSZeroRect];_inspectorScroll=inspectorScroll;inspectorScroll.documentView=_inspector;inspectorScroll.hasVerticalScroller=YES;inspectorScroll.scrollerStyle=NSScrollerStyleOverlay;
    _clipPanel=[[VJSidePanel alloc]init];_clipPanel.title=@"Clip";_clipPanel.body=inspectorScroll;_clipPanel.collapsed=[NSUserDefaults.standardUserDefaults boolForKey:@"vj-native-inspector-collapsed"];
    [body addArrangedSubview:_clipPanel];_inspectorWidth=[_clipPanel.widthAnchor constraintEqualToConstant:300];_inspectorWidth.active=YES;[_clipPanel.heightAnchor constraintEqualToAnchor:center.heightAnchor].active=YES;[_libraryPanel.heightAnchor constraintEqualToAnchor:center.heightAnchor].active=YES;[_inspector.widthAnchor constraintEqualToAnchor:inspectorScroll.contentView.widthAnchor].active=YES;
    _mapperView=[[VJMapper alloc] initWithFrame:NSMakeRect(0,0,1150,600) model:_model];__weak VJApplication* mapperOwner=self;
    _mapperView.outputAction=^(NSString* mid){VJApplication* owner=mapperOwner;if(owner)[owner->_outputs showForWindow:owner->_window projector:mid];};[_root addArrangedSubview:_mapperView];[_mapperView.widthAnchor constraintEqualToAnchor:_root.widthAnchor constant:0].active=YES;_mapperView.hidden=YES;
    _metaView=[[VJMetaMapping alloc]initWithFrame:NSMakeRect(0,0,1150,600) model:_model];[_root addArrangedSubview:_metaView];[_metaView.widthAnchor constraintEqualToAnchor:_root.widthAnchor].active=YES;_metaView.hidden=YES;
    _controlsView=[[VJControls alloc] initWithFrame:NSMakeRect(0,0,1150,600) model:_model];[_root addArrangedSubview:_controlsView];[_controlsView.widthAnchor constraintEqualToAnchor:_root.widthAnchor constant:0].active=YES;_controlsView.hidden=YES;
    _patchContainer=[[NSView alloc]init];_patchContainer.identifier=@"patch-editor-root";_patchContainer.hidden=YES;
    _status=[self label:@""];_status.hidden=YES;_status.lineBreakMode=NSLineBreakByTruncatingTail;[_root addArrangedSubview:_status];[_status.widthAnchor constraintEqualToAnchor:_root.widthAnchor].active=YES;
    _performance=[[VJPerformanceBar alloc]initWithModel:_model];[_root addArrangedSubview:_performance];[_performance.widthAnchor constraintEqualToAnchor:_root.widthAnchor].active=YES;
    __weak VJApplication* weak=self;
    _libraryPanel.toggle=^{[weak toggleLibrary:nil];};_clipPanel.toggle=^{[weak toggleInspector:nil];};
    _controlsView.settingsAction=^(NSString* action){if([action isEqualToString:@"Outputs…"])[weak outputs:nil];else if([action isEqualToString:@"Network…"])[weak network:nil];};
    [_library setLivePreviewsEnabled:!_checking];_library.sourcesChanged=^{VJApplication* owner=weak;if(!owner||owner->_editing)return;owner->_inspectorShape.clear();[owner inspector];};
    _library.inventoryChanged=^{VJApplication* owner=weak;if(owner&&owner->_clipSearch.window.visible)[owner->_clipSearch updateItems:[owner->_library searchItems]];};
    _library.insert=^(Json item){VJApplication* owner=weak;if(!owner)return;if(owner->_row.empty()||owner->_column.empty()){owner->_status.stringValue=@"Select a clip slot";owner->_status.hidden=NO;return;}item.update({{"action","put_clip"},{"row",owner->_row},{"column",owner->_column}});[owner submit:item path:"/api/v1/grid" method:"POST"];};_library.browse=^{[weak media:nil];};_library.assignOutput=^(Json item,NSView* anchor){[weak assignPatchOutput:item anchor:anchor];};
    _canvas.choose=^(NSString* row,NSString* column){VJApplication* owner=weak;if(!owner)return;owner->_row=row.UTF8String;owner->_column=column.UTF8String;owner->_canvas->selectedRow=owner->_row;owner->_canvas->selectedColumn=owner->_column;[owner->_canvas setNeedsDisplay:YES];owner->_selectionPending=YES;auto generation=++owner->_selectionGeneration;
        Json command={{"action","select_cell"},{"bus",[owner bus]},{"row",owner->_row},{"column",owner->_column},{"active_show",owner->_snapshot["state"]["grid"]["active_show"]},{"revision",owner->_revision}};
        VJSubmitUiCommand(owner->_model,"POST","/api/v1/grid",command,^(const vj::Reply& reply){VJApplication* current=weak;if(!current||current->_closing||generation!=current->_selectionGeneration)return;current->_selectionPending=NO;current->_revision=UINT64_MAX;if(reply.status>=300){current->_status.hidden=NO;current->_status.stringValue=text(reply.body.value("error",std::string("Selection failed")));}[current refresh];});
        dispatch_async(dispatch_get_main_queue(),^{VJApplication* current=weak;if(current&&!current->_closing&&generation==current->_selectionGeneration)[current inspector];});
    };
    _canvas.gridCommand=^(Json body){VJApplication* self=weak;if(self)[self submit:body path:"/api/v1/grid" method:"POST"];};
    _canvas.activate=^(NSString* row,NSString* column,NSString* bank){VJApplication* self=weak;if(!self)return;Json command={{"action",row.length?"toggle_clip":"launch_column"},{"bus",[self bus]},{"column",column.UTF8String},{"bank",bank.UTF8String}};if(row.length)command["row"]=row.UTF8String;[self submit:command path:"/api/v1/grid" method:"POST"];};
    _canvas.editSurface=^(NSString* surface,NSData* data){VJApplication* self=weak;if(!self)return;auto corners=Json::parse(std::string(static_cast<const char*>(data.bytes),data.length));[self submit:{{"corners",corners},{"revision",self->_snapshot["mappings"][self->_mid]["revision"]}} path:"/api/v1/mappings/"+self->_mid+"/rects/"+surface.UTF8String method:"PATCH"];};
    _keyboardMonitor=[NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent*(NSEvent* event){
        VJApplication* owner=weak;if(!owner||event.window!=owner->_window||owner->_window.attachedSheet)return event;
        auto modifiers=event.modifierFlags&(NSEventModifierFlagCommand|NSEventModifierFlagShift|NSEventModifierFlagControl|NSEventModifierFlagOption);
        if(event.keyCode==19&&modifiers==(NSEventModifierFlagCommand|NSEventModifierFlagShift)){if(!event.isARepeat)[owner toggleComposerPatch:nil];return nil;}
        auto responder=owner->_window.firstResponder;
        if(owner->_splitMode){NSView* focused=[responder isKindOfClass:NSView.class]?(NSView*)responder:nil;if([responder isKindOfClass:NSTextView.class]&&((NSTextView*)responder).isFieldEditor){id delegate=((NSTextView*)responder).delegate;if([delegate isKindOfClass:NSView.class])focused=delegate;}
            if([focused isDescendantOf:owner->_patchContainer]){owner->_patchActive=YES;[owner->_patch setEditorFocused:YES];}
            else if([focused isDescendantOf:owner->_composerPane]){owner->_patchActive=NO;[owner->_patch setEditorFocused:NO];}}
        if(owner->_patchActive)return event;
        if(!owner->_metaView.hidden)return [owner->_metaView handleKeyEvent:event]?nil:event;
        if([owner handleClipSearchKey:event])return nil;
        if([responder isKindOfClass:NSTextView.class])return event;if(owner->_mapping&&[owner->_mapperView handleKeyEvent:event])return nil;if([responder isKindOfClass:NSPopUpButton.class])return event;
        auto flags=event.modifierFlags;auto key=event.charactersIgnoringModifiers.lowercaseString;
        if(owner->_mapping||owner->_controls||owner->_composerBody.isHiddenOrHasHiddenAncestor)return event;
        if((flags&NSEventModifierFlagCommand)&&!(flags&NSEventModifierFlagOption)&&[key isEqualToString:@"z"]){if(!event.isARepeat)[owner changeHistory:(flags&NSEventModifierFlagShift)?"redo":"undo"];return nil;}
        if((event.keyCode==51||event.keyCode==117)&&!(flags&(NSEventModifierFlagCommand|NSEventModifierFlagControl|NSEventModifierFlagOption))){if(!event.isARepeat&&!owner->_row.empty()&&!owner->_column.empty())[owner submit:{{"action","delete_cell"},{"row",owner->_row},{"column",owner->_column}} path:"/api/v1/grid" method:"POST"];return nil;}return event;
    }];
    _paneMonitor=[NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown|NSEventMaskRightMouseDown handler:^NSEvent*(NSEvent* event){
        VJApplication* owner=weak;if(!owner||!owner->_splitMode||event.window!=owner->_window||owner->_window.attachedSheet)return event;
        auto point=[owner->_workspaceSplit convertPoint:event.locationInWindow fromView:nil];
        if(NSPointInRect(point,owner->_patchContainer.frame)&&!owner->_patchActive){owner->_patchActive=YES;[owner->_clipSearch cancel];[owner->_patch setEditorActive:YES];}
        else if(NSPointInRect(point,owner->_composerPane.frame)&&owner->_patchActive){owner->_patchActive=NO;[owner->_patch setEditorFocused:NO];[owner->_window makeFirstResponder:owner->_canvas];}
        return event;
    }];
    auto edit=[NSApp.mainMenu itemWithTitle:@"Edit"].submenu;if(edit&&![edit itemWithTitle:@"Undo"]){auto undo=[[NSMenuItem alloc]initWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"];undo.target=nil;[edit insertItem:undo atIndex:0];auto redo=[[NSMenuItem alloc]initWithTitle:@"Redo" action:@selector(redo:) keyEquivalent:@"z"];redo.keyEquivalentModifierMask=NSEventModifierFlagCommand|NSEventModifierFlagShift;redo.target=nil;[edit insertItem:redo atIndex:1];[edit insertItem:NSMenuItem.separatorItem atIndex:2];}
    if(edit&&![edit itemWithTitle:@"Find Clip…"]){auto find=[[NSMenuItem alloc]initWithTitle:@"Find Clip…" action:@selector(findClip:) keyEquivalent:@"f"];find.target=self;[edit addItem:find];}
    auto windowMenu=[[NSMenu alloc]initWithTitle:@"Window"];auto windowItem=[[NSMenuItem alloc]initWithTitle:@"Window" action:nil keyEquivalent:@""];windowItem.submenu=windowMenu;[NSApp.mainMenu addItem:windowItem];
    auto splitItem=[[NSMenuItem alloc]initWithTitle:@"Composer / Patch Split" action:@selector(toggleComposerPatch:) keyEquivalent:@"2"];splitItem.target=self;splitItem.keyEquivalentModifierMask=NSEventModifierFlagCommand|NSEventModifierFlagShift;[windowMenu addItem:splitItem];auto remoteItem=[[NSMenuItem alloc]initWithTitle:@"Phone Remote…" action:@selector(showRemote:) keyEquivalent:@""];remoteItem.target=self;[windowMenu addItem:remoteItem];
    _outputs=[[VJOutputs alloc] initWithModel:_model allowOutputs:!_checking];
    [_preview setPublicationEnabled:!_checking];
    _poll=[NSTimer scheduledTimerWithTimeInterval:.2 repeats:YES block:^(NSTimer*){[weak refresh];}];
    _faderPoll=[NSTimer timerWithTimeInterval:1./60 repeats:YES block:^(NSTimer*){VJApplication* owner=weak;if(!owner||owner->_closing)return;[owner refreshPatchOutputs];owner->_model->setPatchAPCOwned(owner->_patch.ownsHostAPC);owner->_model->setPatchCrossfaderFollow(owner->_patch.followsHostCrossfader);auto apcMessages=owner->_model->takePatchAPCMessages();if(!apcMessages.empty()){NSMutableArray* messages=[NSMutableArray arrayWithCapacity:apcMessages.size()];for(auto message:apcMessages)[messages addObject:@[@(message[0]),@(message[1]),@(message[2])]];[owner->_patch receiveHostAPC:messages];}owner->_model->setPatchChannelFaderFollow(owner->_patch.followsHostChannelFaders);auto channels=owner->_model->hardwareChannelFaders();NSMutableArray<NSNumber*>* levels=[NSMutableArray arrayWithCapacity:8];for(auto value:channels)[levels addObject:@(value)];[owner->_patch receiveHostChannelFaders:levels];auto hardware=owner->_model->hardwareFaderValue();if(hardware)[owner->_patch receiveHostFader:@(*hardware)];if(owner->_composerBody.isHiddenOrHasHiddenAncestor||owner->_faderTracking||owner->_faderPending)return;if(auto value=owner->_model->crossfadeValue([owner bus]);value&&owner->_fade.doubleValue!=*value){owner->_fade.doubleValue=*value;[owner refreshFaderLabels];}}];[[NSRunLoop mainRunLoop]addTimer:_faderPoll forMode:NSRunLoopCommonModes];[self toolbar];[self refresh];vj::style::apply(_root);if(!_checking)[self ensurePatch];
}
- (void)toolbar {
    _outStripShape.clear();
    for(NSView* view in [_toolbar.arrangedSubviews copy]){[_toolbar removeArrangedSubview:view];[view removeFromSuperview];}
    _outStrip=[[VJFlowBar alloc]init];_outStrip.noWrap=YES;_outStrip.padding=NSEdgeInsetsMake(8,10,8,10);auto outScroll=[[NSScrollView alloc]init];outScroll.scrollerStyle=NSScrollerStyleOverlay;outScroll.hasHorizontalScroller=YES;outScroll.documentView=_outStrip;[_toolbar addArrangedSubview:outScroll];[outScroll.widthAnchor constraintEqualToAnchor:_toolbar.widthAnchor].active=YES;_outStripHeight=[outScroll.heightAnchor constraintEqualToConstant:58];_outStripHeight.active=YES;
    auto bar=[[VJFlowBar alloc]init];[_toolbar addArrangedSubview:bar];[bar.widthAnchor constraintEqualToAnchor:_toolbar.widthAnchor].active=YES;
    _transport=[self button:@"■" action:@selector(transport:)];_transport.toolTip=@"Start / Stop";[bar addItem:_transport width:28];
    auto showGroup=[self stack:NSUserInterfaceLayoutOrientationHorizontal];showGroup.spacing=1;
    [showGroup addArrangedSubview:_show];[_show.widthAnchor constraintEqualToConstant:140].active=YES;
    auto newShow=[self button:@"+ New" action:@selector(newShow:)];newShow.toolTip=@"New set";[showGroup addArrangedSubview:newShow];[newShow.widthAnchor constraintEqualToConstant:52].active=YES;
    auto showActions=[self button:@"⋯" action:@selector(showActions:)];showActions.toolTip=@"Set actions";[showGroup addArrangedSubview:showActions];[showActions.widthAnchor constraintEqualToConstant:28].active=YES;
    for(NSView* child in showGroup.arrangedSubviews)[child.heightAnchor constraintEqualToConstant:vj::style::controlHeight].active=YES;
    [bar addItem:showGroup width:222];
    auto divider=[[NSBox alloc]init];divider.boxType=NSBoxSeparator;[bar addItem:divider width:1];
    for(NSString* kind in @[@"Layer",@"Column"]){auto group=[self stack:NSUserInterfaceLayoutOrientationHorizontal];group.spacing=1;auto minus=[self button:@"−" action:@selector(removeGridItem:)];minus.identifier=kind;[minus.widthAnchor constraintEqualToConstant:22].active=YES;[group addArrangedSubview:minus];auto title=[self label:kind];title.font=vj::style::font(10);[group addArrangedSubview:title];auto plus=[self command:@"+" body:{{"action",[kind isEqualToString:@"Layer"]?"add_row":"add_column"}} path:"/api/v1/grid"];[plus.widthAnchor constraintEqualToConstant:22].active=YES;[group addArrangedSubview:plus];[bar addItem:group width:[kind isEqualToString:@"Layer"]?82:92];}
    vj::style::apply(_toolbar);
}
- (void)removeGridItem:(NSControl*)sender {BOOL layer=[sender.identifier isEqualToString:@"Layer"];if(layer?_row.empty():_column.empty())return;[self submit:layer?Json{{"action","delete_row"},{"row",_row}}:Json{{"action","delete_column"},{"column",_column}} path:"/api/v1/grid" method:"POST"];}
- (void)selectOutTab:(NSButton*)sender {for(NSMenuItem* item in _out.itemArray)if([item.representedObject isEqualToString:sender.identifier]){[_out selectItem:item];break;}[self outChanged:_out];}
- (void)resizeOuts:(NSButton*)sender {auto count=_snapshot["state"]["grid"]["running"].size();if(sender.tag<0&&count<=1)return;[self submit:{{"count",int(count)+int(sender.tag)}} path:"/api/v1/outputs" method:"PUT"];}
- (void)refreshOutStrip {
    if(_faderTracking)return;
    Json structure=Json::array();for(NSMenuItem* item in _out.itemArray){auto bus=std::string([item.representedObject UTF8String]);auto out=bus=="program"?"out1":bus;structure.push_back({bus,item.title.UTF8String,item==_out.selectedItem,_snapshot["outputs"].value(out,Json::object()).value("destinations",Json::array())});}
    if(structure.dump()==_outStripShape)return;_outStripShape=structure.dump();
    // Retain the fader and its containing view throughout continuous tracking.
    for(NSView* view in [_outStrip.subviews copy])[view removeFromSuperview];
    double height=42;
    for(NSMenuItem* item in _out.itemArray){auto group=[self stack:NSUserInterfaceLayoutOrientationVertical];group.spacing=4;auto button=[self button:item.title action:@selector(selectOutTab:)];button.identifier=item.representedObject;button.buttonType=NSButtonTypePushOnPushOff;button.state=item==_out.selectedItem?NSControlStateValueOn:NSControlStateValueOff;[group addArrangedSubview:button];[button.widthAnchor constraintEqualToConstant:95].active=YES;
        std::string bus=[item.representedObject UTF8String];auto out=bus=="program"?"out1":bus;auto destinations=_snapshot["outputs"].value(out,Json::object()).value("destinations",Json::array());std::string lines;for(const auto& destination:destinations){if(!lines.empty())lines+="\n";auto kind=destination.value("kind",std::string{});lines+=(kind=="led"?"LED · ":kind=="trace"?"Trace · ":"")+destination.value("name",std::string{})+(destination.value("enabled",true)?"":" · Off");}if(lines.empty())lines="—";
        auto routes=[self label:text(lines)];routes.font=vj::style::font(10);routes.textColor=vj::style::secondary();routes.toolTip=routes.stringValue;routes.usesSingleLineMode=NO;routes.cell.wraps=NO;routes.lineBreakMode=NSLineBreakByTruncatingTail;[group addArrangedSubview:routes];[routes.widthAnchor constraintEqualToConstant:95].active=YES;double groupHeight=30+std::max(size_t(1),destinations.size())*14;[routes.heightAnchor constraintEqualToConstant:groupHeight-30].active=YES;[_outStrip addItem:group width:95];group.frame=NSMakeRect(0,0,95,groupHeight);height=std::max(height,groupHeight);
    }
    for(int direction:{1,-1}){auto button=[self button:direction>0?@"+":@"−" action:@selector(resizeOuts:)];button.tag=direction;[_outStrip addItem:button width:24];}
    [_outStrip addItem:[self label:@"A"] width:9];[_outStrip addItem:_fade width:150];[_outStrip addItem:[self label:@"B"] width:9];[_outStrip addItem:_faderSync width:112];double width=20;for(NSView* view in _outStrip.subviews)width+=view.frame.size.width+6;_outStrip.frame=NSMakeRect(0,0,width,height+16);_outStripHeight.constant=height+16;vj::style::apply(_outStrip);
}
- (void)selectNavigation:(NSString*)title {if(!_checking)[NSUserDefaults.standardUserDefaults setObject:title forKey:@"VJWorkspacePage"];_metaView.hidden=![title isEqualToString:@"Meta Mapping"];[self setWorkspaceLayout:[title isEqual:@"Compose"]?0:[title isEqual:@"Patch"]?1:3];if(![title isEqual:@"Patch"]&&_patchActive){_patchActive=NO;[_patch setEditorActive:NO];_patchContainer.hidden=YES;_window.minSize=NSMakeSize(900,620);[_window makeFirstResponder:nil];}for(NSView* view in _nav.arrangedSubviews)if([view isKindOfClass:NSButton.class]&&[view.identifier hasPrefix:@"tab-"]){((NSButton*)view).state=[view.identifier isEqualToString:[@"tab-" stringByAppendingString:title]]?NSControlStateValueOn:NSControlStateValueOff;[view setNeedsDisplay:YES];}}
- (std::string)bus {NSString* item=_out.selectedItem.representedObject;return item?[item UTF8String]:"program";}
- (void)assignPatchOutput:(Json)item anchor:(NSView*)anchor {
    auto snapshot=_model->presentationSnapshot();Json clip;
    for(const auto& row:snapshot["state"]["grid"]["rows"])if(row["id"]==_row&&row["clips"].contains(_column))clip=row["clips"][_column];
    auto menu=[NSMenu new];
    if(clip.is_object())for(const auto& effect:_model->effectCatalog())if(effect["name"]==clip["gen"])for(const auto& p:effect["parameters"]){
        bool palette=item["patchType"]=="palette";if(palette?!p.value("paletteSource",false):(p["kind"]!="float"||effect.value("vector",false)||clip["gen"].get<std::string>().starts_with("external_")))continue;
        Json command={{"action","set_clip"},{"row",_row},{"column",_column}};auto key=p["name"].get<std::string>();
        if(item.contains("subpatchID")){
            command.update({{"subpatchID",item["subpatchID"]},{"outputID",item["outputID"]},{"parameter",key},{"revision",snapshot["revision"]},{"active_show",snapshot["state"]["grid"]["active_show"]}});
        }else if(palette)command["params"]={{key,item["patchID"]}};else{auto bindings=clip.value("patchControls",Json::object());bindings[key]={{"source",item["patchID"]},{"min",p["min"]},{"max",p["max"]}};command["patchControls"]=bindings;}
        auto entry=[[NSMenuItem alloc]initWithTitle:text(p.value("label",key)) action:@selector(assignPatchParameter:) keyEquivalent:@""];entry.target=self;entry.representedObject=text(command.dump());[menu addItem:entry];
    }
    if(!menu.numberOfItems){auto entry=[[NSMenuItem alloc]initWithTitle:@"No compatible parameter" action:nil keyEquivalent:@""];entry.enabled=NO;[menu addItem:entry];}
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0,anchor.bounds.size.height) inView:anchor];
}
- (void)assignPatchParameter:(NSMenuItem*)sender {[self submit:Json::parse([sender.representedObject UTF8String]) path:"/api/v1/grid" method:"POST"];}
- (void)fetchStandalonePatchRows:(BOOL)palettes {
    if(!_paletteSession){
        auto config=NSURLSessionConfiguration.ephemeralSessionConfiguration;
        config.timeoutIntervalForRequest=1;config.timeoutIntervalForResource=1;
        config.connectionProxyDictionary=@{};config.URLCache=nil;
        _paletteSession=[NSURLSession sessionWithConfiguration:config delegate:[VJPatchLoopbackDelegate new] delegateQueue:nil];
    }
    NSString* value=NSProcessInfo.processInfo.environment[@"PATCH_API_PORT"];
    NSInteger port=value?value.integerValue:9417;
    NSInteger embeddedPort=[NSProcessInfo.processInfo.environment[@"VJ_PATCH_API_PORT"]?:@"9418" integerValue];
    if(port<1||port>65535||port==embeddedPort)return;
    if(palettes)_paletteRequest=YES;else _outputsRequest=YES;
    NSURL* url=[NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%ld/v1/%@",(long)port,palettes?@"palettes":@"outputs"]];
    auto session=_paletteSession;
    auto previous=palettes?_standalonePalettes:_standaloneOutputs;
    __weak VJApplication* weak=self;
    auto receive=^(NSData* data,NSURLResponse* response,NSError* error){
        PatchInventory found;
        if(!error&&[(NSHTTPURLResponse*)response statusCode]==200&&data.length){
            const auto* begin=static_cast<const uint8_t*>(data.bytes);
            auto object=Json::parse(begin,begin+data.length,nullptr,false);
            if(object.is_object()&&object.contains("sources")&&object["sources"].is_array())
                found=std::make_shared<const Json>(std::move(object["sources"]));
        }
        bool online=bool(found);
        if(!online&&previous){
            auto offline=std::make_shared<Json>(Json::array());
            for(const auto& row:*previous){
                if(!row.is_object()||!row.contains("id"))continue;
                auto item=Json::object();
                for(const auto* key:{"id","name","nodeID","outputID","type","kind","listed","colorSpace"})
                    if(row.contains(key))item[key]=row[key];
                item["available"]=false;item["active"]=false;
                offline->push_back(std::move(item));
            }
            found=offline;
        }
        auto ids=std::make_shared<std::set<std::string>>();
        if(!palettes&&found)for(const auto& row:*found)
            if(row.is_object()&&row.contains("id")&&row["id"].is_string())ids->insert(row["id"].get<std::string>());
        dispatch_async(dispatch_get_main_queue(),^{
            VJApplication* owner=weak;if(!owner||owner->_closing)return;
            if(palettes){owner->_standalonePalettes=found;owner->_paletteRequest=NO;}
            else{owner->_standaloneOutputs=found;owner->_standaloneIDs=ids;owner->_outputsRequest=NO;}
            if(!online){
                auto retry=NSProcessInfo.processInfo.systemUptime+1.;
                if(palettes)owner->_nextPeerPalettes=retry;else owner->_nextPeerOutputs=retry;
            }
        });
    };
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        NSString* token=[NSString stringWithContentsOfFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Patch/api-token"] encoding:NSUTF8StringEncoding error:nil];
        token=[token stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if(!token.length){receive(nil,nil,nil);return;}
        auto request=[NSMutableURLRequest requestWithURL:url];
        [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
        dispatch_async(dispatch_get_main_queue(),^{
            VJApplication* owner=weak;if(!owner||owner->_closing)return;
            [[session dataTaskWithRequest:request completionHandler:receive] resume];
        });
    });
}
- (void)refreshPatchOutputs {
    const auto now=NSProcessInfo.processInfo.systemUptime;
    if(_closing||_mergingPatchOutputs||now<_nextPatchMerge)return;
    auto refs=_model->patchReferences();
    if(_patch&&refs!=_retainedPatchIDs){
        NSMutableArray* ids=[NSMutableArray arrayWithCapacity:refs.size()];
        for(const auto& id:refs)[ids addObject:text(id)];
        [_patch retainPublishedOutputs:ids];_retainedPatchIDs=refs;
    }
    // Dormant catalogs need only discovery updates. Active bindings carry live control and recipe values.
    bool active=!refs.empty();
    _nextPatchMerge=now+(active?1./30.:.2);
    bool usesPeer=_standaloneIDs&&std::any_of(refs.begin(),refs.end(),[&](const Json& id){
        return id.is_string()&&_standaloneIDs->contains(id.get_ref<const std::string&>());
    });
    if(!_checking&&!_outputsRequest&&now>=_nextPeerOutputs){
        _nextPeerOutputs=now+(usesPeer?1./25.:.5);
        [self fetchStandalonePatchRows:NO];
    }
    if(!_checking&&!_paletteRequest&&now>=_nextPeerPalettes){
        _nextPeerPalettes=now+1.;[self fetchStandalonePatchRows:YES];
    }
    const bool palettes=now>=_nextPaletteMerge;
    if(palettes)_nextPaletteMerge=now+.2;
    NSArray* embedded=_patch.publishedOutputs,*embeddedPalettes=palettes?_patch.paletteSources:nil;
    auto peer=_standaloneOutputs,peerPalettes=_standalonePalettes;
    _mergingPatchOutputs=YES;
    __weak VJApplication* weak=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        auto outputs=std::make_shared<Json>(Json::array()),colors=std::make_shared<Json>(Json::array());
        std::set<std::string> ids;
        appendPatchRows(*outputs,ids,patchRows(embedded));
        if(peer)appendPatchRows(*outputs,ids,*peer);
        std::string shape;
        if(palettes){
            ids.clear();
            appendPatchRows(*colors,ids,patchRows(embeddedPalettes));
            if(peerPalettes)appendPatchRows(*colors,ids,*peerPalettes);
            for(const auto& output:*outputs)if(output.value("type",std::string{})=="palette"&&ids.insert(output["id"]).second){
                auto color=output;color["kind"]="patch";colors->push_back(std::move(color));
            }
            auto metadata=*colors;for(auto& source:metadata)source.erase("colors");
            shape=metadata.dump();
        }
        dispatch_async(dispatch_get_main_queue(),^{
            VJApplication* owner=weak;if(!owner||owner->_closing)return;
            owner->_mergingPatchOutputs=NO;
            owner->_model->setPatchOutputs(std::move(*outputs));
            if(palettes){
                owner->_model->setPaletteSources(*colors);
                if(shape!=owner->_paletteShape){owner->_paletteShape=shape;owner->_inspectorDirty=true;}
            }
        });
    });
}
- (void)refresh {
    [self refreshPatchOutputs];
    [_outputs refresh];if(_patchActive&&!_splitMode)return;
    if(_controls)[_controlsView refresh];
    if(!_metaView.hidden){[_metaView refresh];return;}
    if(_mapping)[_mapperView refresh];
    const bool editingText=[_window.firstResponder isKindOfClass:NSTextView.class]&&((NSTextView*)_window.firstResponder).isFieldEditor;
    auto sharedState=_model->presentationSnapshotShared();const auto& state=*sharedState;BOOL narrow=_window.contentView.bounds.size.width<=1100;_libraryWidth.constant=_libraryPanel.collapsed?36:narrow?170:210;_inspectorWidth.constant=_clipPanel.collapsed?36:narrow?250:300;double centerWidth=_window.contentView.bounds.size.width-_libraryWidth.constant-_inspectorWidth.constant;_previewHeight.constant=_splitMode?112:36+std::min(180.,std::max(0.,(centerWidth-32)/2.55*9/16));[self refreshPlayhead:state];uint64_t revision=state["revision"];if(revision==_revision){if(_inspectorDirty&&!_editing&&!editingText){_inspectorDirty=false;[self inspector];}return;}_snapshot=state;_revision=revision;
    const auto& grid=_snapshot["state"]["grid"];auto selected=grid.value("control_focus",Json::object()).value("bus",std::string("program"));[_out removeAllItems];
    for(size_t i=1;i<=grid["running"].size();++i){const std::string key=i==1?"program":"out"+std::to_string(i);[_out addItemWithTitle:text("Out "+std::to_string(i))];_out.lastItem.representedObject=text(key);if(key==selected)[_out selectItem:_out.lastItem];}
    for(VJPreview* preview in _monitors.previews)[preview setBus:text([self bus])];_transport.title=grid["running"].value([self bus],false)?@"■":@"▶";
    [_show removeAllItems];for(const auto& show:grid["shows"]){[_show addItemWithTitle:text(show["name"])];_show.lastItem.representedObject=text(show["id"]);if(show["id"]==grid["active_show"])[_show selectItem:_show.lastItem];}
    if(!_faderTracking&&!_faderPending)if(auto value=_model->crossfadeValue([self bus]))_fade.doubleValue=*value;_faderSync.state=grid.value("fader_sync",false)?NSControlStateValueOn:NSControlStateValueOff;
    [self refreshFaderLabels];[self refreshOutStrip];
    const auto focus=grid.value("control_focus",Json::object());if(!_selectionPending){_row=focus.value("row",std::string{});_column=focus.value("column",std::string{});}
    _canvas->revision=revision;_canvas->document=_mapping?_snapshot["mappings"][_mid]:grid;_canvas->mapper=_mapping;_canvas->selectedSurface=_surface;_canvas->selectedRow=_row;_canvas->selectedColumn=_column;_canvas.bus=text([self bus]);[_canvas.thumbnails setContext:_snapshot bus:text([self bus])];
    [_canvas setFrameSize:NSMakeSize(_mapping?850:std::max(280.,150.+grid["columns"].size()*117.),_mapping?420:std::max(240.,25.+grid["rows"].size()*113.))];[_canvas setNeedsDisplay:YES];
    _status.hidden=YES;[_canvas refreshRows];[_library setContext:_snapshot bus:text([self bus]) target:text([self libraryTarget:grid])];if(!_editing&&!_faderTracking){_inspectorDirty=false;[self inspector];}else _inspectorDirty=true;
}
- (void)refreshFaderLabels {
    double fade=_fade.doubleValue;NSArray* statuses=@[fade==1?@"A · Standby":fade==0?@"A · Live":[NSString stringWithFormat:@"A · %.0f%%",(1-fade)*100],fade==0?@"B · Standby":fade==1?@"B · Live":[NSString stringWithFormat:@"B · %.0f%%",fade*100],_snapshot["state"]["grid"]["running"].value([self bus],false)?@"Out · Live":@"Out · Stopped"];
    for(NSUInteger i=0;i<statuses.count;++i)_monitors.labels[i].stringValue=statuses[i];_faderSync.title=_faderSync.state==NSControlStateValueOn?@"Fader attached":@"Fader detached";
}
- (std::string)libraryTarget:(const Json&)grid {std::string rowName,columnName;for(const auto& row:grid["rows"])if(row["id"]==_row)rowName=row["name"];for(const auto& column:grid["columns"])if(column["id"]==_column)columnName=column["name"];return rowName.empty()?"":rowName+" · "+columnName;}
- (void)inspector {
    auto inspectorScroll=_inspector.enclosingScrollView;const auto scrollOrigin=inspectorScroll.contentView.bounds.origin;
    const auto& grid=_snapshot["state"]["grid"];Json shape={{"inspectorWidth",int(_clipPanel.frame.size.width)},{"mapping",_mapping},{"show",grid["active_show"]},{"row",_row},{"column",_column},{"bus",[self bus]},{"midiMappings",_snapshot["state"].value("midi",Json::object()).value("mappings",Json::array())},{"midiLearning",_snapshot["state"].value("midi",Json::object()).value("learning",Json())}};
    for(const auto& row:grid["rows"])if(row["id"]==_row&&row["clips"].contains(_column)){auto clip=row["clips"][_column];shape["clip"]=clip["id"];shape["clipName"]=clip["name"];shape["rowName"]=row["name"];shape["gen"]=clip["gen"];for(auto key:{"items","file","loop_mode","line_ends","pulse_mode","pulse_start","pulse_end","content","italic"})if(clip["params"].contains(key))shape[key]=clip["params"][key];for(auto key:{"nativeImportUnsupported","mediaStatus","textStatus"})if(clip.contains(key))shape[key]=clip[key];}
    shape["mediaSelection"]={_mediaClip,_mediaItem};
    shape["paletteSources"]=_paletteShape;
    for(const auto& row:grid["rows"])if(row["id"]==_row&&row["clips"].contains(_column))shape["patchControls"]=row["clips"][_column].value("patchControls",Json::object());
    Json patchShape=Json::array();for(const auto& item:_model->patchOutputs())patchShape.push_back({item["id"],item["name"],item["type"],item["listed"],item["available"]});shape["patchSources"]=patchShape;
    const auto key=shape.dump();if(!_mapping&&key==_inspectorShape){[self updateInspectorValues];return;}if([_window.firstResponder isKindOfClass:NSTextView.class]&&((NSTextView*)_window.firstResponder).isFieldEditor){_inspectorDirty=true;return;}_inspectorShape=key;
    _seek=nil;_playhead=nil;_seekMediaItem.clear();for(NSView* v in [_inspector.arrangedSubviews copy]){[_inspector removeArrangedSubview:v];[v removeFromSuperview];}
    if(_mapping){[_inspector addArrangedSubview:[self label:@"Surface"]];for(const auto& rect:_snapshot["mappings"][_mid]["project"]["rects"])if(rect["id"]==_surface){[_inspector addArrangedSubview:[self label:text(rect.value("name",std::string("Surface")))]];}return;}
    _clipPanel.title=@"Clip";
    if(_row.empty()||_column.empty()){[_inspector addArrangedSubview:[self label:@"Clip"]];return;}
    for(const auto& row:grid["rows"])if(row["id"]==_row){_clipPanel.title=text(std::string(_out.titleOfSelectedItem.UTF8String)+" · "+row["name"].get<std::string>());auto rename=[self button:@"Rename layer" action:@selector(renameSelected:)];rename.identifier=@"row";[_inspector addArrangedSubview:rename];if(!row["clips"].contains(_column))[_inspector addArrangedSubview:[self label:@"Empty slot"]];}
    Json context={{"active_show",_snapshot["state"]["grid"]["active_show"]},{"bus",[self bus]},{"row",_row},{"column",_column}};
    for(const auto& row:_snapshot["state"]["grid"]["rows"])if(row["id"]==_row&&row["clips"].contains(_column)){
        const auto& clip=row["clips"][_column];context["clipId"]=clip["id"];
        auto bindings=clip.value("patchControls",Json::object());


        auto actions=[[VJFlowBar alloc]init];actions.padding=NSEdgeInsetsMake(0,0,8,0);actions.spacing=5;actions.plain=YES;[_inspector addArrangedSubview:actions];[actions.widthAnchor constraintEqualToAnchor:_inspector.widthAnchor constant:-16].active=YES;
        for(const auto* bank:{"A","B"}){auto key=std::string(bank)=="A"?"selections":"selections_b";bool active=grid[key].value([self bus],Json::object()).value(_row,std::string{})==_column;[actions addItem:[self command:text(std::string(active?"Unset ":"Set ")+bank) body:{{"action","toggle_clip"},{"bank",bank},{"row",_row},{"column",_column}} path:"/api/v1/grid"] width:54];}
        auto rename=[self button:@"Rename" action:@selector(renameSelected:)];rename.identifier=@"clip";[actions addItem:rename width:57];[actions addItem:[self button:@"Duplicate" action:@selector(duplicateClip:)] width:65];[actions addItem:[self command:@"Clear slot" body:{{"action","delete_clip"},{"row",_row},{"column",_column}} path:"/api/v1/grid"] width:65];
        auto clipTitle=[self label:text(clip["name"])];clipTitle.font=vj::style::font(13);[_inspector addArrangedSubview:clipTitle];
        if(_patch && clip.value("gen",std::string{}).starts_with("patch_")){
            NSString* source=text(clip.at("params").value("source",std::string{}));
            if(source.length){
                if(NSView* controls=[_patch controlsForPublishedOutput:source]){
                    [_inspector addArrangedSubview:controls];
                    [controls.widthAnchor constraintEqualToAnchor:_inspector.widthAnchor constant:-16].active=YES;
                }
                NSButton* edit=[self button:@"Open in Patch" action:@selector(openClipPatch:)];
                edit.identifier=source;[_inspector addArrangedSubview:edit];
                [_inspector addArrangedSubview:[self command:@"Make Independent" body:{{"action","make_independent"}} path:"/api/v1/grid"]];
            }
        }
        if(!bindings.empty()){
            auto group=vj::style::section(@"Patch controls");
            for(auto it=bindings.begin();it!=bindings.end();++it){auto source=it.value().value("source",std::string{}),name=source;for(const auto& output:_model->patchOutputs())if(output["id"]==source)name=output.value("name",source);auto next=bindings;next.erase(it.key());[group addArrangedSubview:[self command:text(it.key()+" · "+name+" ×") body:{{"action","set_clip"},{"patchControls",next}} path:"/api/v1/grid"]];}
            [_inspector addArrangedSubview:group];[group.widthAnchor constraintEqualToAnchor:_inspector.widthAnchor constant:-16].active=YES;
        }
        for(const auto& note:clip.value("conversionNotes",Json::array()))
            [_inspector addArrangedSubview:[self label:text(note.get<std::string>())]];
        if(clip.value("nativeImportUnsupported",false))[_inspector addArrangedSubview:[self label:@"Unavailable effect"]];
        if(clip["gen"].get<std::string>().starts_with("external_")){auto update=[self button:@"Update animation…" action:@selector(importAnimation:)];update.identifier=@"update-animation";[_inspector addArrangedSubview:update];}
        if(clip["gen"]=="video"){
            auto controls=[self stack:NSUserInterfaceLayoutOrientationHorizontal];controls.distribution=NSStackViewDistributionFillEqually;controls.spacing=6;
            for(const auto* operation:{"play","pause","stop"})[controls addArrangedSubview:[self command:text(operation) body:{{"action","video_transport"},{"operation",operation},{"row",_row},{"column",_column}} path:"/api/v1/grid"]];
            [_inspector addArrangedSubview:controls];[controls.widthAnchor constraintEqualToAnchor:_inspector.widthAnchor constant:-16].active=YES;[_inspector addArrangedSubview:[self label:@"Seek"]];
            auto seek=[VJParameterSlider sliderWithValue:clip["params"].value("position",0.0) minValue:0 maxValue:1 target:self action:@selector(videoSeek:)];_seek=seek;__weak VJApplication* weak=self;seek.tracking=^(BOOL active){VJApplication* owner=weak;if(owner)owner->_editing=active;};seek.identifier=@"_position";seek.continuous=NO;[seek.widthAnchor constraintEqualToConstant:190].active=YES;[_inspector addArrangedSubview:seek];_playhead=[self label:@"— / —"];[_inspector addArrangedSubview:_playhead];
        }
        if(clip.contains("mediaStatus")&&!clip["mediaStatus"].value("available",false))[_inspector addArrangedSubview:[self label:@"Media missing"]];
        if(clip.contains("textStatus")&&!clip["textStatus"].value("available",false))[_inspector addArrangedSubview:[self label:text(clip["textStatus"].value("error",std::string("Text unavailable")))]];

        auto blend=[[VJPopup alloc] initWithFrame:NSZeroRect pullsDown:NO];[blend addItemsWithTitles:@[@"normal",@"add",@"screen",@"multiply",@"subtract"]];[blend selectItemWithTitle:text(clip.value("blend",row.value("blend",std::string("normal"))))];blend.identifier=@"_blend";blend.target=self;blend.action=@selector(blendChanged:);auto blendRow=[self stack:NSUserInterfaceLayoutOrientationHorizontal];[blendRow addArrangedSubview:[self label:@"Blend"]];[blendRow addArrangedSubview:blend];[blend.widthAnchor constraintEqualToConstant:94].active=YES;[_inspector addArrangedSubview:blendRow];[blendRow.widthAnchor constraintEqualToAnchor:_inspector.widthAnchor constant:-16].active=YES;
        // How collections set to follow lay out this Out while this cell is on top.
        auto layout=[[VJPopup alloc] initWithFrame:NSZeroRect pullsDown:NO];[layout addItemsWithTitles:@[@"auto",@"repeat",@"span"]];[layout selectItemWithTitle:text(clip.value("collectionLayout",std::string("auto")))];layout.identifier=@"_collection_layout";layout.target=self;layout.action=@selector(collectionLayoutChanged:);layout.toolTip=@"auto: sources repeat, effects follow the layer below";auto layoutRow=[self stack:NSUserInterfaceLayoutOrientationHorizontal];[layoutRow addArrangedSubview:[self label:@"Collection layout"]];[layoutRow addArrangedSubview:layout];[layout.widthAnchor constraintEqualToConstant:94].active=YES;[_inspector addArrangedSubview:layoutRow];[layoutRow.widthAnchor constraintEqualToAnchor:_inspector.widthAnchor constant:-16].active=YES;
        auto opacity=[[VJParameterSlider alloc]init];opacity.identifier=@"_opacity";opacity.minValue=0;opacity.maxValue=1;opacity.doubleValue=clip.value("opacity",1.);opacity.continuous=YES;opacity.target=self;opacity.action=@selector(opacity:);__weak VJApplication* weak=self;opacity.tracking=^(BOOL tracking){VJApplication* owner=weak;if(owner){owner->_editing=tracking;if(!tracking){owner->_inspectorDirty=true;[owner refresh];}}};auto opacityRow=[[VJParameterRow alloc]init];opacityRow.name=[self label:@"Blend amount"];opacityRow.name.font=vj::style::font(11);opacityRow.name.textColor=vj::style::secondary();opacityRow.control=opacity;opacityRow.value=[[NSTextField alloc]init];opacityRow.value.identifier=@"_opacity_value";opacityRow.value.font=vj::style::font(11);opacityRow.value.alignment=NSTextAlignmentRight;opacityRow.value.stringValue=[NSString stringWithFormat:@"%.3g",opacity.doubleValue];opacityRow.value.target=self;opacityRow.value.action=@selector(opacity:);[opacityRow addSubview:opacityRow.value];opacityRow.reset=[self command:@"↺" body:{{"action","set_clip"},{"opacity",1.}} path:"/api/v1/grid"];[opacityRow addSubview:opacityRow.reset];[opacityRow addSubview:opacityRow.name];[opacityRow addSubview:opacity];[_inspector addArrangedSubview:opacityRow];[opacityRow.widthAnchor constraintEqualToAnchor:_inspector.widthAnchor constant:-16].active=YES;[opacityRow.heightAnchor constraintEqualToConstant:vj::style::controlHeight].active=YES;
        for(const auto& effect:_model->effectCatalog())if(effect["name"]==clip["gen"]){
            const auto generator=clip["gen"].get<std::string>();
            auto parameters=effect["parameters"];auto performance=effect.value("performanceParameters",Json::array());
            auto order=[&](const Json& p){auto i=std::find(performance.begin(),performance.end(),p["name"]);return i==performance.end()?int(performance.size()):int(i-performance.begin());};
            std::stable_sort(parameters.begin(),parameters.end(),[&](const Json& a,const Json& b){return order(a)<order(b);});
            std::array<double,2> labelHeights={14,14},controlHeights={0,0};double slotWidth=MAX(25,(_clipPanel.frame.size.width-19)/4-16);auto paragraph=[NSMutableParagraphStyle new];paragraph.lineBreakMode=NSLineBreakByWordWrapping;
            for(const auto& p:parameters){int index=order(p);if(index>=8||index>=int(performance.size()))continue;auto title=text(std::to_string(index+1)+" · "+p.value("label",p["name"].get<std::string>()));auto bounds=[title boundingRectWithSize:NSMakeSize(slotWidth,200) options:NSStringDrawingUsesLineFragmentOrigin attributes:@{NSFontAttributeName:vj::style::font(11),NSParagraphStyleAttributeName:paragraph}];labelHeights[index/4]=MAX(labelHeights[index/4],ceil(bounds.size.height)+2);controlHeights[index/4]=MAX(controlHeights[index/4],p["kind"]=="float"?50:25);}
            NSMutableArray<NSStackView*>* slots=[NSMutableArray array];NSStackView* performancePanel=nil;if(!performance.empty()){performancePanel=[self stack:NSUserInterfaceLayoutOrientationVertical];performancePanel.spacing=1;performancePanel.wantsLayer=YES;performancePanel.layer.backgroundColor=vj::style::border().CGColor;[_inspector addArrangedSubview:performancePanel];[performancePanel.widthAnchor constraintEqualToAnchor:_inspector.widthAnchor constant:-16].active=YES;}if(!performance.empty())for(int y=0;y<2;++y){auto row=[self stack:NSUserInterfaceLayoutOrientationHorizontal];row.spacing=1;row.distribution=NSStackViewDistributionFillEqually;row.wantsLayer=YES;row.layer.backgroundColor=vj::style::border().CGColor;[performancePanel addArrangedSubview:row];[row.widthAnchor constraintEqualToAnchor:performancePanel.widthAnchor].active=YES;[row.heightAnchor constraintEqualToConstant:y*4<int(performance.size())?labelHeights[y]+controlHeights[y]+14:30].active=YES;for(int x=0;x<4;++x){auto slot=[self stack:NSUserInterfaceLayoutOrientationVertical];slot.edgeInsets=NSEdgeInsetsMake(7,5,7,5);slot.wantsLayer=YES;slot.layer.backgroundColor=vj::style::panel().CGColor;[row addArrangedSubview:slot];[slot.heightAnchor constraintEqualToAnchor:row.heightAnchor].active=YES;[slots addObject:slot];}}
            for(int i=0;i<int(slots.count);++i)if(i>=int(performance.size())){auto empty=[self label:text(std::to_string(i+1)+" · —")];empty.font=vj::style::font(11);empty.textColor=vj::style::secondary();[slots[i] addArrangedSubview:empty];}
            for(const auto& parameter:parameters){
                const auto key=parameter["name"].get<std::string>(),kind=parameter["kind"].get<std::string>();auto value=clip["params"].value(key,parameter["default"]);int index=order(parameter);BOOL perf=index<8&&index<int(performance.size());
                NSStackView* container=perf?slots[index]:_inspector;
                if(key=="seek_nonce"||(!perf&&generator=="video"&&(key=="position"||key=="playing")))continue;
                auto label=parameter.value("label",key);if(perf)label=std::to_string(index+1)+" · "+label;
                if(kind=="media_list"){
                    auto items=value;vj::identifyMediaItems(items);
                    if(clip["id"]!=_mediaClip){_mediaClip=clip["id"];_mediaItem.clear();}
                    if(std::none_of(items.begin(),items.end(),[&](const Json& item){return item["id"]==_mediaItem;})){_mediaItem.clear();for(const auto& item:items)if(item["type"]=="video"){_mediaItem=item["id"];break;}}
                    for(size_t i=0;i<items.size();++i){
                        auto line=[[VJFlowBar alloc]init];line.plain=YES;line.padding=NSEdgeInsetsMake(0,0,0,0);line.spacing=3;
                        auto title=[self button:text(std::filesystem::path(items[i]["file"].get<std::string>()).filename().string()) action:@selector(selectCollectionMedia:)];title.buttonType=NSButtonTypePushOnPushOff;title.state=items[i]["id"]==_mediaItem?NSControlStateValueOn:NSControlStateValueOff;title.toolTip=text(items[i]["file"]);title.identifier=text(items[i]["id"]);title.cell.lineBreakMode=NSLineBreakByTruncatingMiddle;[line addItem:title width:140];
                        for(int direction:{-1,1,0}){auto next=items;if(direction==0)next.erase(next.begin()+i);else {int target=int(i)+direction;if(target<0||target>=int(next.size()))continue;std::swap(next[i],next[target]);}[line addItem:[self command:direction==0?@"×":direction<0?@"↑":@"↓" body:{{"action","set_clip"},{"params",{{"items",next}}}} path:"/api/v1/grid"] width:22];}
                        [container addArrangedSubview:line];[line.widthAnchor constraintEqualToAnchor:container.widthAnchor constant:-16].active=YES;
                    }
                    [container addArrangedSubview:[self button:@"Add media…" action:@selector(addCollectionMedia:)]];
                    for(const auto& item:items)if(item["id"]==_mediaItem&&item["type"]=="video"){
                        auto params=item.value("params",Json::object());auto group=vj::style::section(@"Selected video");[container addArrangedSubview:group];[group.widthAnchor constraintEqualToAnchor:container.widthAnchor constant:-16].active=YES;
                        auto controls=[self stack:NSUserInterfaceLayoutOrientationHorizontal];controls.spacing=4;
                        for(const auto* op:{"play","pause","stop"})[controls addArrangedSubview:[self command:text(op) body:{{"action","video_transport"},{"operation",op},{"item_id",_mediaItem}} path:"/api/v1/grid"]];[group addArrangedSubview:controls];
                        for(const auto* key:{"position","loop_start","loop_end"}){
                            bool seek=std::string(key)=="position";auto line=[self stack:NSUserInterfaceLayoutOrientationHorizontal];line.spacing=4;
                            auto label=[self label:seek?@"Scrub":std::string(key)=="loop_start"?@"Start %":@"End %"];[line addArrangedSubview:label];[label.widthAnchor constraintEqualToConstant:48].active=YES;
                            double value=params.value(key,std::string(key)=="loop_end"?1.:0.);auto slider=[VJParameterSlider sliderWithValue:value minValue:0 maxValue:1 target:self action:@selector(collectionVideoChanged:)];slider.continuous=NO;slider.identifier=text(key);slider.accessibilityLabel=seek?@"Video scrub position":label.stringValue;
                            auto b=[[VJInspectorBinding alloc]init];b->parameter={{"item_id",_mediaItem},{"key",key}};objc_setAssociatedObject(slider,&inspectorBindingKey,b,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                            __weak VJApplication* weak=self;slider.tracking=^(BOOL active){VJApplication* owner=weak;if(owner){owner->_editing=active;if(!active){owner->_inspectorDirty=true;[owner refresh];}}};[line addArrangedSubview:slider];[slider.widthAnchor constraintGreaterThanOrEqualToConstant:80].active=YES;
                            if(seek){_seek=slider;_seekMediaItem=_mediaItem;}
                            else {auto field=[[NSTextField alloc]init];field.stringValue=[NSString stringWithFormat:@"%.2f",value*100];field.alignment=NSTextAlignmentRight;field.font=vj::style::font(11);field.target=self;field.action=@selector(collectionVideoChanged:);field.accessibilityLabel=label.stringValue;auto fb=[[VJInspectorBinding alloc]init];fb->parameter=b->parameter;objc_setAssociatedObject(field,&inspectorBindingKey,fb,OBJC_ASSOCIATION_RETAIN_NONATOMIC);[line addArrangedSubview:field];[field.widthAnchor constraintEqualToConstant:52].active=YES;}
                            [group addArrangedSubview:line];[line.widthAnchor constraintEqualToAnchor:group.widthAnchor constant:-16].active=YES;
                        }
                        _playhead=[self label:@"— / —"];[group addArrangedSubview:_playhead];
                        [group addArrangedSubview:[self command:@"Reset range" body:{{"action","video_transport"},{"operation","range"},{"item_id",_mediaItem},{"loop_start",0},{"loop_end",1}} path:"/api/v1/grid"]];
                    }
                    continue;
                }
                if(kind=="choice"&&key=="font"&&generator=="text"){
                    auto heading=[self label:@"Font"];heading.font=vj::style::font(11);heading.textColor=vj::style::secondary();[container addArrangedSubview:heading];auto sample=clip["params"].value("content",std::string("Aa 123"));auto newline=sample.find('\n');if(newline!=std::string::npos)sample.resize(newline);if(sample.empty())sample="Aa 123";NSStackView* pair=nil;int n=0;
                    for(const auto& font:parameter["choices"]){if(n++%2==0){pair=[self stack:NSUserInterfaceLayoutOrientationHorizontal];pair.spacing=4;pair.distribution=NSStackViewDistributionFillEqually;[container addArrangedSubview:pair];[pair.widthAnchor constraintEqualToAnchor:container.widthAnchor constant:-16].active=YES;}auto button=[[VJFontTile alloc]init];button->command={{"action","set_clip"},{"params",{{"font",font}}}};button->path="/api/v1/grid";button.target=self;button.action=@selector(perform:);button.face=text(font);button.sample=text(sample);button.title=text(font);button.buttonType=NSButtonTypePushOnPushOff;button.state=font==value?NSControlStateValueOn:NSControlStateValueOff;button.font=previewFont(font.get<std::string>());if(clip["params"].value("italic",false))button.font=[NSFontManager.sharedFontManager convertFont:button.font toHaveTrait:NSItalicFontMask];button.accessibilityLabel=text(font);[pair addArrangedSubview:button];[button.heightAnchor constraintEqualToConstant:54].active=YES;}continue;
                }
                auto rowView=[[VJParameterRow alloc]init];rowView.performance=perf;rowView.labelHeight=perf?labelHeights[index/4]:20;rowView.name=[self label:text(label)];rowView.name.font=vj::style::font(11);rowView.name.textColor=vj::style::secondary();rowView.name.lineBreakMode=NSLineBreakByTruncatingTail;rowView.name.toolTip=text(label);if(perf){rowView.name.usesSingleLineMode=NO;rowView.name.cell.wraps=YES;rowView.name.lineBreakMode=NSLineBreakByWordWrapping;}[rowView addSubview:rowView.name];[container addArrangedSubview:rowView];[rowView.widthAnchor constraintEqualToAnchor:container.widthAnchor constant:perf?-10:container==_inspector?-16:0].active=YES;[rowView.heightAnchor constraintEqualToConstant:perf?labelHeights[index/4]+controlHeights[index/4]:28].active=YES;
                NSControl* control=nil;
                if(kind=="float"){
                    auto slider=[[VJParameterSlider alloc]init];slider->parameter=parameter;auto scale=parameter.value("scale",std::string{});BOOL nonlinear=scale=="log"||scale=="exp";slider.minValue=nonlinear?0:parameter.value("min",0.);slider.maxValue=nonlinear?1:parameter.value("max",1.);slider.doubleValue=parameterUnit(parameter,value.get<double>());slider.continuous=YES;__weak VJApplication* weak=self;slider.tracking=^(BOOL tracking){VJApplication* owner=weak;if(!owner)return;owner->_editing=tracking;if(!tracking){owner->_inspectorDirty=true;[owner refresh];}};control=slider;
                    auto field=[[NSTextField alloc]init];field.font=vj::style::font(perf?10:11);field.alignment=NSTextAlignmentRight;field.stringValue=[NSString stringWithFormat:@"%.3g",value.get<double>()];field.identifier=text(key);field.target=self;field.action=@selector(parameterChanged:);auto b=[[VJInspectorBinding alloc]init];b->parameter=parameter;objc_setAssociatedObject(field,&inspectorBindingKey,b,OBJC_ASSOCIATION_RETAIN_NONATOMIC);rowView.value=field;[rowView addSubview:field];double reset=parameter.value("min",0.)<0&&parameter.value("max",1.)>0?0:parameter.value("default",parameter.value("min",0.));rowView.reset=[self command:reset==0?@"0":@"↺" body:{{"action","set_clip"},{"params",{{key,reset}}}} path:"/api/v1/grid"];rowView.reset.toolTip=text("Reset "+label);[rowView addSubview:rowView.reset];
                }else if(kind=="color"){auto well=[[VJFlatColorWell alloc]init];well.color=color({{"params",{{"color",value}}}});control=well;
                }else if((effect.value("liveSource",false)&&(key=="source"||key=="device"))||kind=="choice"||parameter.contains("patchSource")||parameter.value("paletteSource",false)||parameter.value("mediaFile",false)){
                    auto popup=[[VJPopup alloc]initWithFrame:NSZeroRect pullsDown:NO];std::string current=value.is_string()?value.get<std::string>():value.dump();Json choices=Json::array();
                    if(parameter.contains("patchSource")){
                        for(const auto& source:_model->patchOutputs())if(source["type"]==parameter["patchSource"]&&(source.value("listed",false)||source["id"]==value))choices.push_back({{"label",source.value("name",std::string("Patch"))+(source.value("available",false)?"":" (unavailable)")},{"value",source["id"]}});
                    }
                    else if(parameter.value("paletteSource",false)){
                        choices.push_back({{"label","Theme / Custom"},{"value",""}});
                        for(const auto& source:_model->paletteSources())if(source.value("listed",true)||source["id"]==value)choices.push_back({{"label",source.value("name",std::string("Palette"))+(source.value("kind",std::string{})=="syphon"?" · Syphon":" · Patch")+(source.value("available",false)?"":" (unavailable)")},{"value",source["id"]}});
                        if(!current.empty())current+=" (unavailable)";
                    }
                    else if(effect.value("liveSource",false)&&(key=="source"||key=="device")){for(const auto& source:[_library sourcesForEffect:generator])choices.push_back({{"label",source.value("label",std::string("Camera"))},{"value",source.value("selection",source.value("device",std::string{}))}});auto saved=Json::parse(current,nullptr,false);if(saved.is_object())current=saved.value("app",std::string{})+(saved.value("app",std::string{}).empty()?"":" — ")+saved.value("name",std::string{});}
                    else if(parameter.value("mediaFile",false)){for(const auto& item:[_library filesForEffect:generator])choices.push_back({{"label",item["path"]},{"value",item["params"]["file"]}});current=std::filesystem::path(current).filename().string();}
                    else for(const auto& choice:parameter["choices"])choices.push_back({{"label",choice.is_string()?choice.get<std::string>():choice.dump()},{"value",choice}});
                    if(std::none_of(choices.begin(),choices.end(),[&](const Json& choice){return choice["value"]==value;}))choices.insert(choices.begin(),Json{{"label",current.empty()?(parameter.value("mediaFile",false)?"No file":"No source"):current},{"value",value}});
                    for(const auto& choice:choices){[popup addItemWithTitle:text(choice["label"])];popup.lastItem.representedObject=text(choice["value"].dump());if(choice["value"]==value)[popup selectItem:popup.lastItem];}if(parameter.value("mediaFile",false)){[popup.menu addItem:NSMenuItem.separatorItem];[popup addItemWithTitle:@"Choose file…"];popup.lastItem.representedObject=@"choose-media";}control=popup;
                }else if(key=="subtitle_track"){auto button=[self button:@"Subtitles…" action:@selector(subtitles:)];control=button;
                }else if(kind=="bool"){auto toggle=[NSButton checkboxWithTitle:@"" target:self action:@selector(parameterChanged:)];toggle.state=value.get<bool>()?NSControlStateValueOn:NSControlStateValueOff;control=toggle;
                }else{auto field=[[NSTextField alloc]init];field.stringValue=text(kind=="text"?value.get<std::string>():value.dump());control=field;}
                auto b=[[VJInspectorBinding alloc]init];b->parameter=parameter;objc_setAssociatedObject(control,&inspectorBindingKey,b,OBJC_ASSOCIATION_RETAIN_NONATOMIC);control.identifier=text(key);control.font=vj::style::font(11);if(key!="subtitle_track"){control.target=self;control.action=@selector(parameterChanged:);}control.accessibilityLabel=text(label);rowView.control=control;[rowView addSubview:control];
                if(bindings.contains(key)){control.enabled=NO;rowView.value.enabled=NO;rowView.reset.enabled=NO;control.toolTip=@"Patch control";}
                if(generator=="video"&&(key=="audio_enabled"||key=="audio_gain")&&clip["params"].value("loop_mode",std::string{})=="ping-pong"){control.enabled=NO;rowView.value.enabled=NO;}
            }
        }



    }
    vj::style::apply(_inspector);bindInspector(_inspector,context);[_inspector layoutSubtreeIfNeeded];[inspectorScroll.contentView scrollToPoint:scrollOrigin];[inspectorScroll reflectScrolledClipView:inspectorScroll.contentView];
}
- (void)toggleLibrary:(NSButton*)sender {(void)sender;_libraryPanel.collapsed=!_libraryPanel.collapsed;if(!_checking)[NSUserDefaults.standardUserDefaults setBool:_libraryPanel.collapsed forKey:@"vj-native-library-collapsed"];[self refresh];}
- (void)lights:(id)sender {[self selectNavigation:@"Lights"];[self controls:sender];[_controlsView showLights];}
- (void)leds:(id)sender {[self selectNavigation:@"Lights"];[self controls:sender];[_controlsView selectPage:3];}
- (void)dmx:(id)sender {[self selectNavigation:@"Lights"];[self controls:sender];[_controlsView selectPage:2];}
- (void)mix:(id)sender {[self selectNavigation:@"Mixer"];[self controls:sender];[_controlsView selectPage:0];}
- (void)settings:(id)sender {[self selectNavigation:@"Settings"];[self controls:sender];[_controlsView selectPage:1];}
- (void)refreshPlayhead:(const Json&)snapshot {
 if(!_seek||_editing||_composerBody.hidden)return;auto telemetry=_model->playbackRuntime();std::string source;const auto& outs=snapshot["outputs"];auto out=[self bus];if(out=="program")out="out1";if(outs.contains(out))for(const auto* bank:{"A","B"})for(const auto& layer:outs[out]["banks"][bank]["layers"])if(layer.value("grid_row",std::string{})==_row&&layer.value("grid_column",std::string{})==_column&&source.empty())source=layer.value("source_id",std::string{});
 if(!source.empty()&&!_seekMediaItem.empty())source+=":media:"+_seekMediaItem;
 for(const auto& item:telemetry["sources"])if(item.value("sourceId",std::string{})==source&&!source.empty()){double duration=item.value("durationSeconds",0.),position=item.value("playheadSeconds",0.);if(duration>0){_seek.doubleValue=item.value("loopPosition",0.);_playhead.stringValue=[NSString stringWithFormat:@"%d:%05.2f / %d:%05.2f",int(position/60),fmod(position,60),int(duration/60),fmod(duration,60)];}auto error=item.value("error",std::string{});if(!error.empty())_playhead.stringValue=text(error);return;}_playhead.stringValue=_seekMediaItem.empty()?@"— / —":@"Not on active output";
}
- (void)toggleInspector:(NSButton*)sender {(void)sender;_clipPanel.collapsed=!_clipPanel.collapsed;if(!_checking)[NSUserDefaults.standardUserDefaults setBool:_clipPanel.collapsed forKey:@"vj-native-inspector-collapsed"];[self refresh];}
- (void)updateInspectorValues {
    const auto& grid=_snapshot["state"]["grid"];Json row,clip,column;for(const auto& item:grid["rows"])if(item["id"]==_row){row=item;if(item["clips"].contains(_column))clip=item["clips"][_column];}for(const auto& item:grid["columns"])if(item["id"]==_column)column=item;
    std::function<void(NSView*)> update=[&](NSView* view){
        if([view isKindOfClass:NSControl.class]){auto control=(NSControl*)view;auto b=binding(control);auto key=control.identifier?std::string(control.identifier.UTF8String):std::string{};bool editing=[control isKindOfClass:NSTextField.class]&&((NSTextField*)control).currentEditor;
            if(!editing&&[control isKindOfClass:VJPoseControl.class]&&!clip.is_null()){auto pose=(VJPoseControl*)control;pose->angles={clip["params"].value("pose_x",0.),clip["params"].value("pose_y",0.),clip["params"].value("pose_z",0.)};[pose setNeedsDisplay:YES];}
            else if(!editing&&b&&b->parameter.contains("name")&&!clip.is_null()){auto spec=b->parameter;auto name=spec["name"].get<std::string>();auto value=clip["params"].value(name,spec["default"]);auto kind=spec.value("kind",std::string{});
                if(([control isKindOfClass:VJParameterSlider.class]||[control isKindOfClass:VJRotary.class])){control.doubleValue=parameterUnit(spec,value.get<double>());if([control isKindOfClass:VJRotary.class])((VJRotary*)control).valueLabel=text(value.dump());}
                else if([control isKindOfClass:NSColorWell.class])((NSColorWell*)control).color=color({{"params",{{"color",value}}}});
                else if([control isKindOfClass:NSPopUpButton.class]){for(NSMenuItem* item in ((NSPopUpButton*)control).itemArray)if([item.representedObject isEqualToString:text(value.dump())])[(NSPopUpButton*)control selectItem:item];}
                else if([control isKindOfClass:NSButton.class]&&kind=="bool")((NSButton*)control).state=value.get<bool>()?NSControlStateValueOn:NSControlStateValueOff;
                else if([control isKindOfClass:NSTextField.class])control.stringValue=kind=="float"?[NSString stringWithFormat:@"%.3g",value.get<double>()]:text(kind=="text"?value.get<std::string>():value.dump());
            }else if(!editing){if(key=="row"&&!row.is_null())control.stringValue=text(row["name"]);else if(key=="column"&&!column.is_null())control.stringValue=text(column["name"]);else if(key=="clip"&&!clip.is_null())control.stringValue=text(clip["name"]);else if(key=="_opacity"&&!clip.is_null())control.doubleValue=clip.value("opacity",1.);else if(key=="_opacity_value"&&!clip.is_null())control.stringValue=[NSString stringWithFormat:@"%.3g",clip.value("opacity",1.)];else if(key=="_enabled"&&!row.is_null())((NSButton*)control).state=row.value("enabled",true)?NSControlStateValueOn:NSControlStateValueOff;else if(key=="_blend"&&!clip.is_null())[(NSPopUpButton*)control selectItemWithTitle:text(clip.value("blend",row.value("blend",std::string("normal"))))];}
            if([control isKindOfClass:VJAction.class]){auto action=(VJAction*)control;if(action->command.value("action",std::string{})=="toggle_clip"){auto bank=action->command.value("bank",std::string("A"));bool active=grid[bank=="A"?"selections":"selections_b"].value([self bus],Json::object()).value(_row,std::string{})==_column;action.title=text(std::string(active?"Unset ":"Set ")+bank);}if(!clip.is_null()&&action->command.contains("params")&&action->command["params"].contains("font"))action.state=action->command["params"]["font"]==clip["params"].value("font",Json())?NSControlStateValueOn:NSControlStateValueOff;}
        }
        for(NSView* child in view.subviews)update(child);
    };update(_inspector);
}
- (VJAction*)midiButton:(const std::string&)parameter {
    const auto& grid=_snapshot["state"]["grid"];auto selections=grid["selections"].value([self bus],Json::object());int slot=0,selected=-1;for(const auto& row:grid["rows"]){auto rid=row["id"].get<std::string>();if(!selections.contains(rid)||!selections[rid].is_string()||!row["clips"].contains(selections[rid].get<std::string>()))continue;if(rid==_row)selected=slot;++slot;}
    Json target={{"kind","param"},{"bus",[self bus]},{"slot",std::max(0,selected)},{"param",parameter}};auto midi=_snapshot["state"].value("midi",Json::object());bool learning=midi.value("learning",Json())==target,mapped=false;for(const auto& m:midi.value("mappings",Json::array()))if(m.value("type",std::string{})=="cc"&&m.value("bus",std::string{})==[self bus]&&m.value("slot",-1)==selected&&m.value("param",std::string{})==parameter)mapped=true;
    auto button=[self command:learning?@"Cancel":mapped?@"MIDI ✓":@"MIDI" body:{{"action","midi_learn"},{"target",learning?Json():target}} path:"/api/v1/midi"];button.controlSize=NSControlSizeMini;button.font=vj::style::font(10);button.enabled=selected>=0;button.toolTip=selected<0?@"Set a clip in A to map this layer":learning?@"Cancel MIDI learn":@"Learn MIDI control";return button;
}
- (void)duplicateClip:(NSControl*)sender {
    auto b=binding(sender);if(!b)return;auto current=_model->presentationSnapshot();auto grid=current["state"]["grid"],context=b->context;if(!followInspectorClip(grid,context)){_status.hidden=NO;_status.stringValue=@"Set changed";return;}Json row;for(const auto& item:grid["rows"])if(item["id"]==context["row"])row=item;if(row.is_null())return;auto source=context["column"].get<std::string>();if(!row["clips"].contains(source)||row["clips"][source]["id"]!=context.value("clipId",Json())){_status.hidden=NO;_status.stringValue=@"Clip changed";return;}std::string column;for(const auto& item:grid["columns"])if(!row["clips"].contains(item["id"].get<std::string>())){column=item["id"];break;}
    if(column.empty()){auto created=_model->request("POST","/api/v1/grid",{{"action","add_column"},{"active_show",context["active_show"]},{"bus",context["bus"]},{"revision",current["revision"]}});if(created.status>=300){_status.hidden=NO;_status.stringValue=text(created.body.value("error",std::string("Column failed")));return;}column=created.body["result"]["id"];current=_model->presentationSnapshot();}
    auto copied=_model->request("POST","/api/v1/grid",{{"action","copy_clip"},{"active_show",context["active_show"]},{"bus",context["bus"]},{"row",context["row"]},{"source_column",source},{"column",column},{"revision",current["revision"]}});if(copied.status>=300){_status.hidden=NO;_status.stringValue=text(copied.body.value("error",std::string("Copy failed")));return;}
    [self submit:{{"action","select_cell"},{"active_show",context["active_show"]},{"bus",context["bus"]},{"row",context["row"]},{"column",column},{"revision",copied.body["revision"]}} path:"/api/v1/grid" method:"POST"];
}
- (BOOL)submitInspector:(Json)body sender:(NSControl*)sender {
    auto b=binding(sender);if(!b){_status.hidden=NO;_status.stringValue=@"Control unavailable";return NO;}auto current=_model->presentationSnapshot();const auto& grid=current["state"]["grid"];auto context=b->context;
    auto action=body.value("action",std::string{});bool clipAction=action=="make_independent"||action=="set_clip"||action=="delete_clip"||action=="video_transport"||action=="toggle_clip"||action=="launch_clip"||action=="put_clip";
    bool valid=grid["active_show"]==context["active_show"];if(valid&&clipAction){valid=followInspectorClip(grid,context);if(valid){body["row"]=context["row"];body["column"]=context["column"];}}
    if(!valid){_status.hidden=NO;_status.stringValue=@"Clip changed";_inspectorDirty=true;return NO;}
    for(auto key:{"active_show","bus","row","column"})if(!body.contains(key))body[key]=context[key];if(!body.contains("revision"))body["revision"]=current["revision"];[self submit:body path:"/api/v1/grid" method:"POST"];return YES;
}
- (vj::Reply)placeLibrarySubpatch:(const Json&)body {
    if(_closing||!_window)return {503,{{"error","Compose is unavailable"}}};
    auto stage=[&](const vj::LibraryOutputRequest& request)->vj::Reply {
        if(![self ensurePatch])return {503,{{"error",_patchError.localizedDescription.UTF8String?:"Patch unavailable"}}};
        NSError* error=nil;NSDictionary* placed;
        if(request.duplicate)placed=[_patch duplicatePublishedOutput:text(request.inputSource) error:&error];
        else if(!request.inputSource.empty())placed=[_patch instantiateLibrarySubpatch:text(request.templateID) outputID:text(request.outputID) inputSource:text(request.inputSource) error:&error];
        else placed=[_patch instantiateLibrarySubpatch:text(request.templateID) outputID:text(request.outputID) error:&error];
        if(!placed)return {400,{{"error",error.localizedDescription.UTF8String?:"Subpatch placement failed"}}};
        auto data=[NSJSONSerialization dataWithJSONObject:placed options:0 error:nil];
        return {200,Json::parse(std::string((const char*)data.bytes,data.length))};
    };
    auto finish=[&](const std::string& instance,bool commit)->vj::Reply {
        if(commit){[_patch commitLibrarySubpatch:text(instance)];[self refreshPatchOutputs];return {200};}
        NSError* error=nil;
        if(![_patch discardLibrarySubpatch:text(instance) error:&error])return {409,{{"error",error.localizedDescription.UTF8String?:"Could not remove subpatch"}}};
        return {200};
    };
    return vj::placeLibrarySubpatch(*_model,body,stage,finish);
}
- (void)submit:(Json)body path:(std::string)path method:(std::string)method {
    if(!body.contains("revision"))body["revision"]=_revision;
    if(path=="/api/v1/grid"){if(!body.contains("bus"))body["bus"]=[self bus];if(!body.contains("active_show"))body["active_show"]=_snapshot["state"]["grid"]["active_show"];}
    std::string coalescingKey;const auto action=body.value("action",std::string{});
    if(path=="/api/v1/grid"&&(action=="set_crossfade"||(action=="set_clip"&&body.contains("params")))){auto shape=body;shape.erase("revision");shape.erase("value");if(shape.contains("params"))for(auto& value:shape["params"])value=nullptr;coalescingKey=path+shape.dump();}
    __weak VJApplication* weak=self;VJSubmitUiCommand(_model,method,path,body,^(const vj::Reply& reply){VJApplication* owner=weak;if(!owner||owner->_closing)return;if(reply.status<200||reply.status>=300){owner->_status.hidden=NO;owner->_status.stringValue=text(reply.body.value("error",std::string("Command failed")));return;}[owner refresh];},coalescingKey);

}
- (void)perform:(VJAction*)sender {
    auto b=binding(sender);if(b&&sender->path=="/api/v1/grid"){[self submitInspector:sender->command sender:sender];return;}
    if(b&&sender->path=="/api/v1/midi"&&!sender->command.value("target",Json()).is_null()){
        auto current=_model->presentationSnapshot();const auto& grid=current["state"]["grid"];if(grid["active_show"]!=b->context["active_show"]){_status.hidden=NO;_status.stringValue=@"Set changed";return;}auto bus=b->context["bus"].get<std::string>();auto selected=grid["selections"].value(bus,Json::object());int slot=0;for(const auto& row:grid["rows"]){auto rid=row["id"].get<std::string>();if(!selected.contains(rid)||!selected[rid].is_string()||!row["clips"].contains(selected[rid].get<std::string>()))continue;if(row["id"]==b->context["row"]){auto command=sender->command;command["target"]["slot"]=slot;command["revision"]=current["revision"];[self submit:command path:sender->path method:"POST"];return;}++slot;}_status.hidden=NO;_status.stringValue=@"Set a clip in A";return;
    }
    [self submit:sender->command path:sender->path method:"POST"];
}
- (void)changeHistory:(const char*)action {auto grid=_model->presentationSnapshot()["state"]["grid"];if(grid.value("history",Json::object()).value(std::string("can_")+action,false))[self submit:{{"action",action}} path:"/api/v1/grid" method:"POST"];}
- (void)undo:(id)sender {(void)sender;if(!_patchActive&&!_mapping&&!_controls)[self changeHistory:"undo"];}
- (void)redo:(id)sender {(void)sender;if(!_patchActive&&!_mapping&&!_controls)[self changeHistory:"redo"];}
- (BOOL)validateMenuItem:(NSMenuItem*)item {if(item.action==@selector(undo:)||item.action==@selector(redo:))return !_patchActive&&!_mapping&&!_controls&&_model->presentationSnapshot()["state"]["grid"].value("history",Json::object()).value(item.action==@selector(undo:)?"can_undo":"can_redo",false);return YES;}
- (void)compose:(id)sender {[self selectNavigation:@"Compose"];(void)sender;_controls=false;_controlsView.hidden=YES;_mapping=false;_mapperView.hidden=YES;_composerBody.hidden=NO;_monitors.hidden=NO;_preview.hidden=NO;_toolbar.hidden=NO;_revision=UINT64_MAX;[self toolbar];[self refresh];}
- (void)metaMapping:(id)sender {(void)sender;[self selectNavigation:@"Meta Mapping"];_controls=false;_mapping=false;_controlsView.hidden=YES;_mapperView.hidden=YES;_composerBody.hidden=YES;_monitors.hidden=YES;_preview.hidden=YES;_toolbar.hidden=YES;_metaView.hidden=NO;[_metaView refresh];[_metaView focusCanvas];}
- (void)mapping:(id)sender {[self selectNavigation:@"Mapping"];(void)sender;_controls=false;_controlsView.hidden=YES;_mapping=true;_mapperView.hidden=NO;_composerBody.hidden=YES;_monitors.hidden=YES;_preview.hidden=YES;_toolbar.hidden=YES;_revision=UINT64_MAX;[self toolbar];[self refresh];}
- (void)network:(id)sender {(void)sender;VJOpenNetwork(_model,_window,!_checking);}
- (void)calibrate:(id)sender {(void)sender;VJOpenCalibration(_model,_window);}
- (void)controls:(id)sender {(void)sender;_controls=true;_mapping=false;_controlsView.hidden=NO;_mapperView.hidden=YES;_composerBody.hidden=YES;_monitors.hidden=YES;_preview.hidden=YES;_toolbar.hidden=YES;[_controlsView refresh];}
- (void)projectorChanged:(id)sender {(void)sender;_mid=std::to_string(_projector.indexOfSelectedItem+1);_surface.clear();_revision=UINT64_MAX;[self refresh];}
- (void)outChanged:(id)sender {(void)sender;[_preview setBus:text([self bus])];[self submit:{{"action","select_out"},{"bus",[self bus]}} path:"/api/v1/grid" method:"POST"];_revision=UINT64_MAX;[self refresh];}
- (void)showActions:(NSButton*)sender {
    auto menu=[[NSMenu alloc]initWithTitle:@"Set actions"];
    for(NSArray* spec in @[@[@"Duplicate set",@"duplicateShow:"],@[@"Rename set…",@"renameShow:"],@[@"Delete set…",@"deleteShow:"],@[@"Import animation…",@"importAnimation:"]]){auto item=[[NSMenuItem alloc]initWithTitle:spec[0] action:NSSelectorFromString(spec[1]) keyEquivalent:@""];item.target=self;[menu addItem:item];}
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0,sender.isFlipped?sender.bounds.size.height+3:-3) inView:sender];
}
- (void)showChanged:(id)sender {(void)sender;[self submit:{{"action","select_show"},{"show",[_show.selectedItem.representedObject UTF8String]}} path:"/api/v1/grid" method:"POST"];}
- (void)transport:(id)sender {(void)sender;[self submit:{{"action","toggle_out"},{"bus",[self bus]}} path:"/api/v1/grid" method:"POST"];}
- (void)faderSync:(NSButton*)sender {[self submit:{{"action","set_fader_sync"},{"enabled",sender.state==NSControlStateValueOn}} path:"/api/v1/grid" method:"POST"];}
- (void)fade:(NSSlider*)sender {[self refreshFaderLabels];auto generation=++_faderGeneration;_faderPending=YES;auto bus=[self bus];Json command={{"action","set_crossfade"},{"bus",bus},{"value",sender.doubleValue},{"active_show",_snapshot["state"]["grid"]["active_show"]},{"revision",_snapshot["revision"]}};__weak VJApplication* weak=self;VJSubmitUiCommand(_model,"POST","/api/v1/grid",command,^(const vj::Reply& reply){VJApplication* owner=weak;if(!owner||owner->_closing||generation!=owner->_faderGeneration)return;owner->_faderPending=NO;if(reply.status>=300){owner->_status.hidden=NO;owner->_status.stringValue=text(reply.body.value("error",std::string("Fader failed")));}owner->_revision=UINT64_MAX;[owner refresh];},"crossfade:"+bus);}
- (void)launch:(id)sender {[self submitInspector:{{"action","launch_clip"},{"bank",_bank.indexOfSelectedItem==0?"A":"B"}} sender:sender];}
- (void)putClip:(id)sender {[self submitInspector:{{"action","put_clip"},{"effect",[_effect.selectedItem.representedObject UTF8String]}} sender:sender];}
- (BOOL)handleClipSearchKey:(NSEvent*)event {
    auto modifiers=event.modifierFlags&(NSEventModifierFlagCommand|NSEventModifierFlagShift|NSEventModifierFlagOption|NSEventModifierFlagControl);
    if(_mapping||_controls||_composerBody.isHiddenOrHasHiddenAncestor||event.window!=_window||_window.attachedSheet||modifiers!=NSEventModifierFlagCommand||![event.charactersIgnoringModifiers.lowercaseString isEqual:@"f"])return NO;
    if(!event.isARepeat)[self findClip:nil];return YES;
}
- (void)findClip:(id)sender {
    (void)sender;if(_mapping&&!_closing){[_mapperView findAction:sender];return;}if(_controls||_composerBody.isHiddenOrHasHiddenAncestor||_window.attachedSheet||_closing)return;
    if(_row.empty()||_column.empty()){_status.hidden=NO;_status.stringValue=@"Clip slot required";return;}
    [_clipSearch cancel];auto current=_model->presentationSnapshot();const auto& grid=current["state"]["grid"];
    Json context={{"active_show",grid["active_show"]},{"row",_row},{"column",_column},{"bus",[self bus]},{"clipId",nullptr}};
    std::string rowName=_row,columnName=_column;for(const auto& row:grid["rows"])if(row["id"]==_row){rowName=row["name"];if(row["clips"].contains(_column))context["clipId"]=row["clips"][_column]["id"];}
    for(const auto& column:grid["columns"])if(column["id"]==_column)columnName=column["name"];
    __weak VJApplication* weak=self;
    _clipSearch=[[VJClipSearch alloc]initWithItems:[_library searchItems] completion:^(Json item){
        VJApplication* owner=weak;if(!owner||owner->_closing)return;
        auto latest=owner->_model->presentationSnapshot();const auto& grid=latest["state"]["grid"];bool valid=false,columnExists=false;
        for(const auto& column:grid["columns"])columnExists|=column["id"]==context["column"];
        if(grid["active_show"]==context["active_show"]&&columnExists)for(const auto& row:grid["rows"])if(row["id"]==context["row"]){auto clip=row["clips"].value(context["column"].get<std::string>(),Json::object());valid=clip.value("id",Json())==context["clipId"];}
        if(!valid){owner->_status.hidden=NO;owner->_status.stringValue=@"Clip slot changed";return;}
        item.update({{"action","put_clip"},{"active_show",context["active_show"]},{"row",context["row"]},{"column",context["column"]},{"bus",context["bus"]},{"revision",latest["revision"]}});
        [owner submit:item path:"/api/v1/grid" method:"POST"];
    }];
    [_clipSearch showForWindow:_window target:text(rowName+" · "+columnName)];[_library refreshSearchItems];
}
- (void)media:(id)sender {
    (void)sender;if(_row.empty()||_column.empty()){_status.hidden=NO;_status.stringValue=@"Clip slot required";return;}
    Json context={{"active_show",_snapshot["state"]["grid"]["active_show"]},{"row",_row},{"column",_column}};for(const auto& row:_snapshot["state"]["grid"]["rows"])if(row["id"]==_row&&row["clips"].contains(_column))context["clipId"]=row["clips"][_column]["id"];
    __weak VJApplication* weak=self;
    VJChooseMedia(_model,_window,^(Json item){VJApplication* owner=weak;if(!owner)return;auto current=owner->_model->presentationSnapshot();auto target=context;if(!followInspectorClip(current["state"]["grid"],target)){owner->_status.hidden=NO;owner->_status.stringValue=@"Clip changed";return;}if(!context.contains("clipId"))for(const auto& row:current["state"]["grid"]["rows"])if(row["id"]==target["row"]&&row["clips"].contains(target["column"].get<std::string>())){owner->_status.hidden=NO;owner->_status.stringValue=@"Clip changed";return;}
        Json params={{"file",item["file"]}};if(item["type"]=="video")params["subtitle_track"]=item.value("subtitle_track",std::string{});
        [owner submit:{{"action","put_clip"},{"row",target["row"]},{"column",target["column"]},{"active_show",target["active_show"]},{"revision",current["revision"]},{"effect",item["type"]},{"name",item["name"]},{"params",params}} path:"/api/v1/grid" method:"POST"];
    });
}

- (Json)currentClipContext:(Json)context {
    auto snapshot=_model->presentationSnapshot();const auto& grid=snapshot["state"]["grid"];if(!context.is_object()||!context.contains("clipId")||!followInspectorClip(grid,context)){_status.hidden=NO;_status.stringValue=@"Clip changed";return Json();}
    for(const auto& row:grid["rows"])if(row["id"]==context["row"])context["clip"]=row["clips"][context["column"].get<std::string>()];context["revision"]=snapshot["revision"];return context;
}
- (void)commitClipParams:(Json)params context:(const Json&)context {
    [self submit:{{"action","set_clip"},{"active_show",context["active_show"]},{"bus",context["bus"]},{"row",context["row"]},{"column",context["column"]},{"revision",context["revision"]},{"params",params}} path:"/api/v1/grid" method:"POST"];
}
- (void)addCollectionMedia:(NSControl*)sender {
    auto b=binding(sender);if(!b)return;auto context=[self currentClipContext:b->context];if(context.is_null())return;__weak VJApplication* weak=self;
    VJChooseMediaItems(_model,_window,^(Json selected){VJApplication* owner=weak;if(!owner)return;auto current=[owner currentClipContext:context];if(current.is_null()||current["clip"]["gen"]!="media_collection")return;auto items=current["clip"]["params"].value("items",Json::array());vj::identifyMediaItems(items);for(const auto& item:selected)items.push_back({{"id",NSUUID.UUID.UUIDString.UTF8String},{"type",item["type"]},{"file",item["file"]}});[owner commitClipParams:{{"items",items}} context:current];});
}
- (void)selectCollectionMedia:(NSControl*)sender {
    auto b=binding(sender);if(!b)return;auto current=[self currentClipContext:b->context];if(current.is_null())return;_mediaClip=current["clip"]["id"];_mediaItem=sender.identifier.UTF8String;_inspectorDirty=true;[self refresh];
}
- (void)collectionVideoChanged:(NSControl*)sender {
    auto b=binding(sender);if(!b)return;auto key=b->parameter["key"].get<std::string>();double value=sender.doubleValue;
    if([sender isKindOfClass:NSTextField.class]){auto scan=[NSScanner scannerWithString:sender.stringValue];if(![scan scanDouble:&value]||!scan.isAtEnd||!std::isfinite(value)||value<0||value>100){_status.hidden=NO;_status.stringValue=@"Enter a percentage from 0 to 100";return;}value/=100.;}
    Json command={{"action","video_transport"},{"item_id",b->parameter["item_id"]},{"operation",key=="position"?"seek":"range"},{key,value}};
    [self submitInspector:command sender:sender];_inspectorDirty=true;
}
- (void)replaceMedia:(NSControl*)sender {
    auto b=binding(sender);if(!b)return;auto context=[self currentClipContext:b->context];if(context.is_null())return;__weak VJApplication* weak=self;
    VJChooseMedia(_model,_window,^(Json item){VJApplication* owner=weak;if(!owner)return;auto current=[owner currentClipContext:context];if(current.is_null())return;if(item["type"]!=current["clip"]["gen"]){owner->_status.hidden=NO;owner->_status.stringValue=text("Choose "+current["clip"]["gen"].get<std::string>()+" media");return;}[owner commitClipParams:{{"file",item["file"]}} context:current];});
}
- (void)opacity:(NSControl*)sender {if([sender isKindOfClass:NSTextField.class]){double value;auto scan=[NSScanner scannerWithString:sender.stringValue];if(![scan scanDouble:&value]||!scan.isAtEnd||!std::isfinite(value)||value<0||value>1){_status.hidden=NO;_status.stringValue=@"Blend amount: 0–1";return;}}if([sender.superview isKindOfClass:VJParameterRow.class])((VJParameterRow*)sender.superview).value.stringValue=[NSString stringWithFormat:@"%.3g",sender.doubleValue];bool tracking=_editing;_editing=true;[self submitInspector:{{"action","set_clip"},{"opacity",sender.doubleValue}} sender:sender];_editing=tracking;_inspectorDirty=true;}
- (void)videoSeek:(NSSlider*)sender {[self submitInspector:{{"action","video_transport"},{"operation","seek"},{"position",sender.doubleValue}} sender:sender];}
- (void)projectorPreview:(id)sender {(void)sender;[_outputs showPreviewForWindow:_window];}
- (void)outputs:(id)sender {(void)sender;[_outputs showForWindow:_window];}
- (void)importAnimation:(NSControl*)sender {
    auto panel=[NSOpenPanel openPanel];panel.title=@"Animation · JSON + WASM";panel.allowsMultipleSelection=YES;panel.canChooseDirectories=NO;panel.allowedFileTypes=@[@"json",@"wasm"];
    if([panel runModal]!=NSModalResponseOK)return;NSURL* manifestURL=nil;NSURL* moduleURL=nil;
    for(NSURL* url in panel.URLs){if([url.pathExtension.lowercaseString isEqualToString:@"json"]&&!manifestURL)manifestURL=url;else if([url.pathExtension.lowercaseString isEqualToString:@"wasm"]&&!moduleURL)moduleURL=url;else{_status.hidden=NO;_status.stringValue=@"Select one JSON manifest and one WASM module";return;}}
    if(!manifestURL||!moduleURL){_status.hidden=NO;_status.stringValue=@"JSON manifest and WASM module required";return;}
    try{
        NSData* manifest=[NSData dataWithContentsOfURL:manifestURL];NSNumber* size;[moduleURL getResourceValue:&size forKey:NSURLFileSizeKey error:nil];if(size.unsignedLongLongValue>2*1024*1024)throw std::runtime_error("Module exceeds 2 MiB");NSData* module=[NSData dataWithContentsOfURL:moduleURL];
        if(!manifest||!module)throw std::runtime_error("Cannot read animation files");auto schema=Json::parse(std::string(static_cast<const char*>(manifest.bytes),manifest.length));
        Json body={{"manifest",schema},{"wasmBase64",[module base64EncodedStringWithOptions:0].UTF8String}};std::string method="POST",path="/api/v1/animations";
        if([sender.identifier isEqualToString:@"update-animation"]){auto gen=std::string([_effect.selectedItem.representedObject UTF8String]);if(!gen.starts_with("external_"))throw std::runtime_error("Uploaded animation required");path+="/"+gen.substr(9);auto current=_model->request("GET",path);if(current.status!=200)throw std::runtime_error("Animation unavailable");body["revision"]=current.body["revision"];method="PUT";}
        auto result=_model->request(method,path,body);if(result.status>=300)throw std::runtime_error(result.body.value("error",std::string("Animation import failed")));_revision=UINT64_MAX;[self refresh];
        for(NSMenuItem* item in _effect.itemArray)if([item.representedObject isEqualToString:text(result.body["effect"])])[_effect selectItem:item];_status.hidden=NO;_status.stringValue=text(result.body["manifest"]["name"]);
    }catch(const std::exception& error){_status.hidden=NO;_status.stringValue=text(error.what());}
}
- (void)collectionLayoutChanged:(NSPopUpButton*)sender {_editing=true;[self submitInspector:{{"action","set_clip"},{"collectionLayout",sender.titleOfSelectedItem.UTF8String}} sender:sender];_editing=false;}
- (void)blendChanged:(NSPopUpButton*)sender {_editing=true;[self submitInspector:{{"action","set_clip"},{"blend",sender.titleOfSelectedItem.UTF8String}} sender:sender];_editing=false;}
- (void)renameSelected:(NSControl*)sender {
    auto bound=binding(sender);if(!bound)return;auto context=bound->context;auto grid=_model->presentationSnapshot()["state"]["grid"];if(!followInspectorClip(grid,context))return;BOOL row=[sender.identifier isEqualToString:@"row"];std::string current;for(const auto& r:grid["rows"])if(r["id"]==context["row"]){if(row)current=r["name"];else if(r["clips"].contains(context["column"].get<std::string>()))current=r["clips"][context["column"].get<std::string>()]["name"];}
    auto dialog=[[NSAlert alloc]init];dialog.messageText=row?@"Layer name":@"Clip name";[dialog addButtonWithTitle:@"Save"];[dialog addButtonWithTitle:@"Cancel"];auto field=[[NSTextField alloc]initWithFrame:NSMakeRect(0,0,260,24)];field.stringValue=text(current);dialog.accessoryView=field;if([dialog runModal]==NSAlertFirstButtonReturn)[self submitInspector:{{"action",row?"set_row":"set_clip"},{"name",field.stringValue.UTF8String}} sender:sender];
}
- (void)rename:(NSTextField*)sender {
    std::string scope=sender.identifier.UTF8String;
    Json command={{"action",scope=="column"?"rename_column":scope=="row"?"set_row":"set_clip"},{"name",sender.stringValue.UTF8String}};
    _editing=true;[self submitInspector:command sender:sender];_editing=false;
}
- (void)layerEnabled:(NSButton*)sender {_editing=true;[self submitInspector:{{"action","set_row"},{"enabled",sender.state==NSControlStateValueOn}} sender:sender];_editing=false;}
- (void)stopLayer:(id)sender {[self submitInspector:{{"action","stop_row"},{"bank",_bank.indexOfSelectedItem==0?"A":"B"}} sender:sender];}
- (void)moveColumn:(int)direction sender:(NSControl*)sender {
    auto b=binding(sender);const auto column=b?b->context.value("column",_column):_column;
    const auto& columns=_snapshot["state"]["grid"]["columns"];
    for(int i=0;i<static_cast<int>(columns.size());++i)if(columns[i]["id"]==column){int target=i+direction;if(target<0||target>=static_cast<int>(columns.size()))return;[self submitInspector:{{"action","move_column"},{"column",column},{"target",columns[target]["id"]},{"position",direction<0?"before":"after"}} sender:sender];return;}
}
- (void)columnLeft:(id)sender {[self moveColumn:-1 sender:sender];}
- (void)columnRight:(id)sender {[self moveColumn:1 sender:sender];}
- (void)subtitles:(NSControl*)sender {
    auto b=binding(sender);if(!b)return;auto context=[self currentClipContext:b->context];if(context.is_null()||context["clip"]["gen"]!="video")return;auto clip=context["clip"];__weak VJApplication* weak=self;
    VJChooseSubtitles(_model,_window,clip["params"].value("file",std::string{}),clip["params"].value("subtitle_track",std::string{}),^(std::string track){VJApplication* owner=weak;if(!owner)return;auto current=[owner currentClipContext:context];if(current.is_null())return;if(current["clip"]["params"].value("file",Json())!=clip["params"].value("file",Json())){owner->_status.hidden=NO;owner->_status.stringValue=@"Media changed";return;}[owner commitClipParams:{{"subtitle_track",track}} context:current];});
}
- (void)liveSource:(NSControl*)sender {
    auto b=binding(sender);if(!b)return;auto context=[self currentClipContext:b->context];if(context.is_null())return;auto clip=context["clip"];auto gen=clip["gen"].get<std::string>();std::string key=gen=="usb_webcam"?"device":"source";__weak VJApplication* weak=self;
    VJChooseLiveSource(_model,_window,gen,clip["params"].value(key,std::string{}),^(Json source){VJApplication* owner=weak;if(!owner)return;auto current=[owner currentClipContext:context];if(current.is_null())return;[owner commitClipParams:{{key,source.at("selection")}} context:current];});
}
- (BOOL)isTextParameter:(NSString*)key {
    for(const auto& row:_snapshot["state"]["grid"]["rows"])if(row["id"]==_row&&row["clips"].contains(_column))
        for(const auto& effect:_model->effectCatalog())if(effect["name"]==row["clips"][_column]["gen"])
            for(const auto& parameter:effect["parameters"])if(parameter["name"]==key.UTF8String)return parameter["kind"]=="text";
    return NO;
}
- (void)parameterChanged:(NSControl*)sender {
    Json value;auto b=binding(sender);if(!b)return;if([sender isKindOfClass:NSPopUpButton.class]&&[((NSPopUpButton*)sender).selectedItem.representedObject isEqualToString:@"choose-media"]){[self updateInspectorValues];[self replaceMedia:sender];return;}
    if(([sender isKindOfClass:VJParameterSlider.class]||[sender isKindOfClass:VJRotary.class])){value=parameterValue(b->parameter,sender.doubleValue);if([sender isKindOfClass:VJRotary.class])((VJRotary*)sender).valueLabel=text(value.dump());}
    else if([sender isKindOfClass:[NSColorWell class]]){NSColor* c=[((NSColorWell*)sender).color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];char hex[8];snprintf(hex,sizeof(hex),"#%02x%02x%02x",(int)lround(c.redComponent*255),(int)lround(c.greenComponent*255),(int)lround(c.blueComponent*255));value=hex;}
    else if([sender isKindOfClass:[NSPopUpButton class]])value=Json::parse([((NSPopUpButton*)sender).selectedItem.representedObject UTF8String]);
    else if([sender isKindOfClass:[NSButton class]])value=((NSButton*)sender).state==NSControlStateValueOn;
    else if([sender isKindOfClass:[NSTextField class]]&&b->parameter.value("kind",std::string{})=="text")value=std::string(sender.stringValue.UTF8String);
    else{try{std::string raw=sender.stringValue.UTF8String;size_t used;double number=std::stod(raw,&used);if(used!=raw.size()||!std::isfinite(number))throw std::runtime_error("Invalid number");value=number;}catch(...){_status.hidden=NO;_status.stringValue=@"Invalid number";return;}}
    bool tracking=_editing;_editing=true;if([sender.identifier isEqualToString:@"position"])[self submitInspector:{{"action","video_transport"},{"operation","seek"},{"position",value}} sender:sender];else [self submitInspector:{{"action","set_clip"},{"params",{{sender.identifier.UTF8String,value}}}} sender:sender];_editing=tracking;_inspectorDirty=true;
    if([sender.superview isKindOfClass:VJParameterRow.class])((VJParameterRow*)sender.superview).value.stringValue=[NSString stringWithFormat:@"%.3g",value.is_number()?value.get<double>():0.];
}
- (void)newShow:(id)sender {(void)sender;[self submit:{{"action","create_show"}} path:"/api/v1/grid" method:"POST"];_row.clear();_column.clear();[self inspector];}
- (void)duplicateShow:(id)sender {(void)sender;[self submit:{{"action","duplicate_show"}} path:"/api/v1/grid" method:"POST"];_row.clear();_column.clear();[self inspector];}
- (void)renameShow:(id)sender {
    (void)sender;auto dialog=[[NSAlert alloc] init];dialog.messageText=@"Set name";[dialog addButtonWithTitle:@"Save"];[dialog addButtonWithTitle:@"Cancel"];
    auto field=[[NSTextField alloc] initWithFrame:NSMakeRect(0,0,260,24)];field.stringValue=_show.titleOfSelectedItem;dialog.accessoryView=field;
    if([dialog runModal]==NSAlertFirstButtonReturn)[self submit:{{"action","rename_show"},{"name",field.stringValue.UTF8String}} path:"/api/v1/grid" method:"POST"];
}
- (void)deleteShow:(id)sender {
    (void)sender;auto dialog=[[NSAlert alloc] init];dialog.messageText=[NSString stringWithFormat:@"Delete “%@”?",_show.titleOfSelectedItem];[dialog addButtonWithTitle:@"Cancel"];[dialog addButtonWithTitle:@"Delete"];
    if([dialog runModal]==NSAlertSecondButtonReturn)[self submit:{{"action","delete_show"}} path:"/api/v1/grid" method:"POST"];
}
- (void)outputCount:(id)sender {
    (void)sender;auto dialog=[[NSAlert alloc] init];dialog.messageText=@"Outputs";[dialog addButtonWithTitle:@"Apply"];[dialog addButtonWithTitle:@"Cancel"];
    auto count=[[VJPopup alloc] initWithFrame:NSMakeRect(0,0,160,26) pullsDown:NO];for(int i=1;i<=20;++i)[count addItemWithTitle:text(std::to_string(i))];[count selectItemAtIndex:_snapshot["state"]["grid"]["running"].size()-1];dialog.accessoryView=count;
    if([dialog runModal]==NSAlertFirstButtonReturn)[self submit:{{"count",count.indexOfSelectedItem+1}} path:"/api/v1/outputs" method:"PUT"];
}
- (void)addSurface:(id)sender {(void)sender;[self submit:{{"revision",_snapshot["mappings"][_mid]["revision"]}} path:"/api/v1/mappings/"+_mid+"/rects" method:"POST"];}
- (void)resetView:(id)sender {(void)sender;_canvas->zoom=1;_canvas->pan=NSZeroPoint;[_canvas setNeedsDisplay:YES];}
- (void)setWorkspaceLayout:(NSInteger)mode {
    if(_splitMode&&_workspaceSplit.bounds.size.height>0)_splitFraction=_composerPane.frame.size.height/_workspaceSplit.bounds.size.height;
    _splitMode=mode==2;if(mode!=1&&mode!=2){[_patch setEditorActive:NO];_patchContainer.hidden=YES;_patchActive=NO;_window.minSize=NSMakeSize(900,620);}
    _gridMinHeight.constant=_splitMode?100:240;
    for(NSView* pane in [_workspaceSplit.arrangedSubviews copy]){[_workspaceSplit removeArrangedSubview:pane];[pane removeFromSuperview];}
    if(mode==0||mode==2)[_workspaceSplit addArrangedSubview:_composerPane];
    if(mode==1||mode==2)[_workspaceSplit addArrangedSubview:_patchContainer];
    _composerBody.hidden=mode!=0&&mode!=2;_patchContainer.hidden=mode!=1&&mode!=2;
    _workspaceSplit.hidden=mode==3;
    [_workspaceSplit adjustSubviews];
}
- (void)showRemote:(id)sender {(void)sender;
    auto remote=_model->snapshot()["state"].value("remote",Json::object());auto alert=[[NSAlert alloc]init];alert.messageText=@"Phone Remote";[alert addButtonWithTitle:@"Done"];
    std::string url;for(const auto& item:remote.value("urls",Json::array()))if(auto u=item.get<std::string>();u.find("//127.")==std::string::npos&&u.find("[::1]")==std::string::npos){url=u;break;}
    if(url.empty()){alert.informativeText=text(remote.value("error",std::string("No LAN address")));[alert runModal];return;}
    alert.informativeText=text(url);[alert addButtonWithTitle:@"Copy Link"];
    auto qr=[CIFilter filterWithName:@"CIQRCodeGenerator"];[qr setValue:[text(url) dataUsingEncoding:NSUTF8StringEncoding] forKey:@"inputMessage"];[qr setValue:@"M" forKey:@"inputCorrectionLevel"];
    if(auto output=[qr.outputImage imageByApplyingTransform:CGAffineTransformMakeScale(8,8)]){auto rep=[NSCIImageRep imageRepWithCIImage:output];auto image=[[NSImage alloc]initWithSize:rep.size];[image addRepresentation:rep];auto view=[NSImageView imageViewWithImage:image];view.frame=NSMakeRect(0,0,rep.size.width,rep.size.height);alert.accessoryView=view;}
    if([alert runModal]==NSAlertSecondButtonReturn){[NSPasteboard.generalPasteboard clearContents];[NSPasteboard.generalPasteboard setString:text(url) forType:NSPasteboardTypeString];}
}
- (void)toggleComposerPatch:(id)sender {
    (void)sender;if(_splitMode){[self compose:nil];return;}
    if(![self ensurePatch]){auto alert=[NSAlert alertWithError:_patchError];[alert beginSheetModalForWindow:_window completionHandler:nil];return;}
    [self compose:nil];[self setWorkspaceLayout:2];_patchContainer.hidden=NO;_patchActive=NO;
    _window.minSize=NSMakeSize(1100,740);auto frame=_window.frame;if(frame.size.width<1100||frame.size.height<740){frame.size.width=MAX(1100,frame.size.width);frame.size.height=MAX(740,frame.size.height);[_window setFrame:frame display:YES];}
    _revision=UINT64_MAX;[self refresh];[_window.contentView layoutSubtreeIfNeeded];[_workspaceSplit adjustSubviews];[_workspaceSplit setPosition:_workspaceSplit.bounds.size.height*_splitFraction ofDividerAtIndex:0];
    if(!_checking)[NSUserDefaults.standardUserDefaults setObject:@"Compose + patch" forKey:@"VJWorkspacePage"];
    [_patch setEditorVisible:YES];[_patch frameGraph];[_patch setEditorFocused:NO];[_window makeFirstResponder:_canvas];
    for(NSView* view in _nav.arrangedSubviews)if([view.identifier isEqual:@"tab-Patch"])((NSButton*)view).state=NSControlStateValueOn;
}
- (CGFloat)splitView:(NSSplitView*)split constrainMinCoordinate:(CGFloat)proposed ofSubviewAt:(NSInteger)index {(void)split;(void)proposed;(void)index;return 320;}
- (CGFloat)splitView:(NSSplitView*)split constrainMaxCoordinate:(CGFloat)proposed ofSubviewAt:(NSInteger)index {(void)proposed;(void)index;return MAX(320,split.bounds.size.height-240);}
- (BOOL)splitView:(NSSplitView*)split canCollapseSubview:(NSView*)view {(void)split;(void)view;return NO;}
- (NSRect)splitView:(NSSplitView*)split effectiveRect:(NSRect)effective forDrawnRect:(NSRect)drawn ofDividerAtIndex:(NSInteger)index {(void)split;(void)drawn;(void)index;return NSInsetRect(effective,0,-5);}
- (BOOL)ensurePatch {
    if(_patch)return YES;
    NSString* session=getenv("VJ_PATCH_SESSION")?@(getenv("VJ_PATCH_SESSION")):[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/VJ Native Development/Patch/session.json"];
    auto port=getenv("VJ_PATCH_API_PORT")?atoi(getenv("VJ_PATCH_API_PORT")):9418;
    NSError* error=nil;_patch=[[PatchEditorController alloc]initWithWindow:_window sessionURL:[NSURL fileURLWithPath:session] apiPort:port error:&error];_patchError=error;
    if(!_patch){NSLog(@"Patch: %@",_patchError);return NO;}
    [_preview setProcessorController:_patch];
    auto view=_patch.view;view.translatesAutoresizingMaskIntoConstraints=NO;[_patchContainer addSubview:view];
    [NSLayoutConstraint activateConstraints:@[[view.leadingAnchor constraintEqualToAnchor:_patchContainer.leadingAnchor],[view.trailingAnchor constraintEqualToAnchor:_patchContainer.trailingAnchor],[view.topAnchor constraintEqualToAnchor:_patchContainer.topAnchor],[view.bottomAnchor constraintEqualToAnchor:_patchContainer.bottomAnchor]]];
    return YES;
}
- (void)openClipPatch:(NSButton*)sender {
    [self patch:nil];
    [_patch focusPublishedOutput:sender.identifier];
}
- (void)patch:(id)sender {
    (void)sender;if(_patchActive&&!_splitMode)return;
    if(![self ensurePatch]){auto alert=[NSAlert alertWithError:_patchError];[alert beginSheetModalForWindow:_window completionHandler:nil];return;}
    [_clipSearch cancel];[self selectNavigation:@"Patch"];_patchActive=YES;_controls=false;_mapping=false;
    _controlsView.hidden=YES;_mapperView.hidden=YES;_composerBody.hidden=YES;_monitors.hidden=YES;_toolbar.hidden=YES;_status.hidden=YES;_patchContainer.hidden=NO;
    _window.minSize=NSMakeSize(1100,690);auto frame=_window.frame;if(frame.size.width<1100||frame.size.height<690){frame.size.width=MAX(1100,frame.size.width);frame.size.height=MAX(690,frame.size.height);[_window setFrame:frame display:YES];}
    [_window.contentView layoutSubtreeIfNeeded];[_workspaceSplit adjustSubviews];[_patch setEditorActive:YES];
}
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication*)sender {return _patch?[_patch shouldTerminateApplication:sender]:NSTerminateNow;}
- (BOOL)windowShouldClose:(NSWindow*)sender {if(sender==_window){[NSApp terminate:nil];return NO;}return YES;}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender {(void)sender;return YES;}
- (void)applicationWillTerminate:(NSNotification*)notification {(void)notification;if(!_checking){if(_splitMode&&_workspaceSplit.bounds.size.height>0)[NSUserDefaults.standardUserDefaults setDouble:_composerPane.frame.size.height/_workspaceSplit.bounds.size.height forKey:@"VJWorkspaceSplitFraction"];[_window saveFrameUsingName:@"VJNativeWorkspace"];} _closing=YES;[_paletteSession invalidateAndCancel];[_patch stop];[_clipSearch cancel];[_performance stop];VJStopUiCommands(_model);if(_keyboardMonitor){[NSEvent removeMonitor:_keyboardMonitor];_keyboardMonitor=nil;}[_library stop];VJCloseNetworks(_model);VJCloseCalibrations(_model);[_canvas.thumbnails stop];[_poll invalidate];[_faderPoll invalidate];if(_paneMonitor){[NSEvent removeMonitor:_paneMonitor];_paneMonitor=nil;}[_controlsView stop];[_outputs stop];for(VJPreview* preview in _monitors.previews)[preview stop];[_mapperView stop];[_metaView stop];}
- (void)captureComposer:(NSString*)name {
    const char* directory=getenv("VJ_UI_CAPTURE_DIR");if(!directory)return;[_window.contentView layoutSubtreeIfNeeded];for(VJPreview* preview in _monitors.previews)[preview checkRendering];
    [[NSRunLoop mainRunLoop]runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.12]];[_window.contentView layoutSubtreeIfNeeded];[_window.contentView displayIfNeeded];
    auto bitmap=[_window.contentView bitmapImageRepForCachingDisplayInRect:_window.contentView.bounds];[_window.contentView cacheDisplayInRect:_window.contentView.bounds toBitmapImageRep:bitmap];[NSGraphicsContext saveGraphicsState];NSGraphicsContext.currentContext=[NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
    NSMutableArray<NSView*>* pending=[NSMutableArray arrayWithObject:_window.contentView];while(pending.count){NSView* view=pending.lastObject;[pending removeLastObject];if(view.isHiddenOrHasHiddenAncestor)continue;if([view isKindOfClass:VJPreview.class]){auto image=[(VJPreview*)view capturePresentation];if(image){auto rect=[view convertRect:view.bounds toView:_window.contentView];auto visible=[view convertRect:view.visibleRect toView:_window.contentView];double scale=MIN(rect.size.width/image.size.width,rect.size.height/image.size.height);auto target=NSMakeRect(NSMidX(rect)-image.size.width*scale/2,NSMidY(rect)-image.size.height*scale/2,image.size.width*scale,image.size.height*scale);[NSGraphicsContext saveGraphicsState];[NSBezierPath clipRect:visible];[image drawInRect:target fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];[NSGraphicsContext restoreGraphicsState];}}else [pending addObjectsFromArray:view.subviews];}[NSGraphicsContext restoreGraphicsState];
    [[NSFileManager defaultManager]createDirectoryAtPath:text(directory) withIntermediateDirectories:YES attributes:nil error:nil];[[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}]writeToFile:[text(directory)stringByAppendingPathComponent:[name stringByAppendingString:@".png"]] atomically:YES];
}
- (BOOL)checkInterface {
    _checking=YES;[NSApp finishLaunching];[self build];[_window.contentView layoutSubtreeIfNeeded];
    auto drain=[&]{auto limit=[NSDate dateWithTimeIntervalSinceNow:5];while(!VJUiCommandsIdle(_model)&&limit.timeIntervalSinceNow>0)[[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.002]];};
    BOOL result=YES;auto check=[&](NSString* name,BOOL passed){NSLog(@"Interface %@: %@",name,passed?@"pass":@"FAIL");result=passed&&result;};
    // Exercise the actual navigation buttons while AppKit owns a field editor.
    // Direct selectPage calls in a non-key window missed this regression.
    [_window makeKeyAndOrderFront:nil];
    if(getenv("VJ_CHECK_PATCH_ONLY")){
        check(@"Isolated Patch session supplied",getenv("VJ_PATCH_SESSION")!=nullptr);
        if(getenv("VJ_PATCH_SESSION")){
            auto spin=[&](double seconds){auto end=[NSDate dateWithTimeIntervalSinceNow:seconds];while(end.timeIntervalSinceNow>0)[[NSRunLoop mainRunLoop]runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];};
            NSButton* tab=nil;for(NSView* view in _nav.arrangedSubviews)if([view.identifier isEqual:@"tab-patch"])tab=(NSButton*)view;
            check(@"White Patch tab after Settings",tab&&[tab.title isEqual:@"Patch"]&&[tab.contentTintColor isEqual:NSColor.whiteColor]&&[_nav.arrangedSubviews indexOfObject:tab]==7);
            [tab performClick:nil];spin(1);
            check(@"Patch editor embedded in VJ",_patch&&_patch.active&&_patch.view.window==_window&&!_patchContainer.hidden&&_composerBody.hidden);
            NSLog(@"Workspace %@ pane %@ editor %@ root %@",NSStringFromRect(_workspaceSplit.frame),NSStringFromRect(_patchContainer.frame),NSStringFromRect(_patch.view.frame),NSStringFromRect(_root.frame));
            check(@"Patch editor fills tab",_patch.view.bounds.size.width>1000&&_patch.view.bounds.size.height>500);
            check(@"Patch menu owns editor shortcuts",[NSApp.mainMenu itemWithTitle:@"Graph"]!=nil&&[NSApp.mainMenu itemWithTitle:@"File"]!=nil);
            auto searchKey=[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:NSEventModifierFlagCommand timestamp:0 windowNumber:_window.windowNumber context:nil characters:@"f" charactersIgnoringModifiers:@"f" isARepeat:NO keyCode:3];[NSApp sendEvent:searchKey];spin(.15);
            NSWindow* palette=nil;for(NSWindow* win in NSApp.windows)if([win.title isEqual:@"Add Node"]&&win.visible)palette=win;
            check(@"Command-F opens Patch node search",palette!=nil);[palette close];[_window makeKeyAndOrderFront:nil];
            NSDictionary* graphBefore=[_patch.state[@"graph"] copy];
            auto selectKey=[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:NSEventModifierFlagCommand timestamp:0 windowNumber:_window.windowNumber context:nil characters:@"a" charactersIgnoringModifiers:@"a" isARepeat:NO keyCode:0];
            auto layoutKey=[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:NSEventModifierFlagCommand|NSEventModifierFlagShift timestamp:0 windowNumber:_window.windowNumber context:nil characters:@"A" charactersIgnoringModifiers:@"a" isARepeat:NO keyCode:0];
            check(@"Shift-Command-A runs Patch Auto Layout",[NSApp.mainMenu performKeyEquivalent:layoutKey]&&![_patch.state[@"graph"] isEqual:graphBefore]);
            auto undoItem=[[NSApp.mainMenu itemWithTitle:@"Edit"].submenu itemWithTitle:@"Undo"];[NSApp sendAction:undoItem.action to:undoItem.target from:undoItem];
            check(@"Auto Layout undo preserves graph",[_patch.state[@"graph"] isEqual:graphBefore]);
            auto textField=[[NSTextField alloc]initWithFrame:NSMakeRect(20,20,200,24)];textField.stringValue=@"Select this text";[_patch.view addSubview:textField];[_window makeFirstResponder:textField];
            [NSApp.mainMenu performKeyEquivalent:selectKey];auto fieldEditor=(NSTextView*)_window.firstResponder;
            check(@"Command-A selects text without laying out graph",[fieldEditor isKindOfClass:NSTextView.class]&&fieldEditor.selectedRange.length==textField.stringValue.length&&[_patch.state[@"graph"] isEqual:graphBefore]);
            [textField removeFromSuperview];[_window makeFirstResponder:_patch.view];
            auto splitKey=[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:NSEventModifierFlagCommand|NSEventModifierFlagShift timestamp:0 windowNumber:_window.windowNumber context:nil characters:@"2" charactersIgnoringModifiers:@"2" isARepeat:NO keyCode:19];
            auto dispatchKey=[&](NSEvent* key){[NSApp postEvent:key atStart:YES];auto queued=[NSApp nextEventMatchingMask:NSEventMaskKeyDown untilDate:[NSDate dateWithTimeIntervalSinceNow:.05] inMode:NSDefaultRunLoopMode dequeue:YES];if(queued)[NSApp sendEvent:queued];};
            dispatchKey(splitKey);check(@"Command-Shift-2 opens split from Patch",_splitMode);if(!_splitMode)[self toggleComposerPatch:nil];spin(.15);
            auto top=[_composerPane convertRect:_composerPane.bounds toView:nil],bottom=[_patchContainer convertRect:_patchContainer.bounds toView:nil];
            NSLog(@"Split workspace %@ composer %@ Patch %@",NSStringFromRect(_workspaceSplit.frame),NSStringFromRect(top),NSStringFromRect(bottom));
            check(@"Composer above Patch with usable pane sizes",!_composerBody.isHiddenOrHasHiddenAncestor&&!_patchContainer.isHiddenOrHasHiddenAncestor&&NSMinY(top)>=NSMaxY(bottom)&&top.size.height>=319&&bottom.size.height>=239);
            auto clickPane=[&](NSView* pane){auto point=[pane convertPoint:NSMakePoint(5,5) toView:nil];for(auto type:{NSEventTypeLeftMouseUp,NSEventTypeLeftMouseDown}){auto mouse=[NSEvent mouseEventWithType:type location:point modifierFlags:0 timestamp:0 windowNumber:_window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];[NSApp postEvent:mouse atStart:YES];}for(int i=0;i<2;++i){auto queued=[NSApp nextEventMatchingMask:NSEventMaskLeftMouseDown|NSEventMaskLeftMouseUp untilDate:[NSDate dateWithTimeIntervalSinceNow:.03] inMode:NSDefaultRunLoopMode dequeue:YES];if(queued)[NSApp sendEvent:queued];}};
            clickPane(_patchContainer);check(@"Clicking Patch gives it keyboard and menus",_patchActive&&_patch.active&&[NSApp.mainMenu itemWithTitle:@"Graph"]!=nil);
            clickPane(_composerPane);check(@"Clicking Composer restores its keyboard and menus",!_patchActive&&!_patch.active&&[NSApp.mainMenu itemWithTitle:@"Graph"]==nil&&!_patchContainer.isHiddenOrHasHiddenAncestor);
            auto height=_composerPane.frame.size.height;[_workspaceSplit setPosition:height+30 ofDividerAtIndex:0];spin(.1);
            check(@"Split divider resizes panes",std::abs(_composerPane.frame.size.height-height)>10);
            bool previewsInside=true;for(VJPreview* preview in _monitors.previews)previewsInside=previewsInside&&NSContainsRect(_monitors.bounds,preview.frame);
            check(@"Compact previews stay above fader controls",previewsInside&&checkHitTargets(_composerBody));
            [self captureComposer:@"composer-patch-split"];
            dispatchKey(splitKey);check(@"Command-Shift-2 restores Composer",!_splitMode&&_patchContainer.hidden&&!_composerBody.hidden);
            [self toggleComposerPatch:nil];spin(.1);check(@"Split retains Patch graph",[_patch.state[@"graph"] isEqual:graphBefore]);
            [self patch:nil];spin(.1);check(@"Patch tab exits split",!_splitMode&&_patch.active&&_composerBody.hidden);
            auto before=_patch.renderedFrames;[NSThread sleepForTimeInterval:.5];auto advanced=_patch.renderedFrames-before;
            NSLog(@"Patch worker advanced %ld frames with UI blocked",(long)advanced);check(@"Patch rendering independent of UI thread",advanced>=8);
            [self captureComposer:@"patch-tab"];
            [self compose:nil];spin(.2);before=_patch.renderedFrames;spin(.5);
            check(@"Patch keeps rendering while Composer is visible",!_patch.active&&_patchContainer.hidden&&_patch.renderedFrames-before>=8);
            check(@"VJ menus restored",[NSApp.mainMenu itemWithTitle:@"Graph"]==nil&&[[NSApp.mainMenu itemWithTitle:@"Edit"].submenu itemWithTitle:@"Find Clip…"]!=nil);
            Json source;for(int attempt=0;attempt<60&&source.is_null();++attempt){syphon_poll();for(const auto& entry:syphon_sources())if(entry.value("name",std::string{})==std::string([_patch.state[@"streams"][0][@"name"] UTF8String]))source=entry;spin(.05);}
            check(@"Embedded Metal Syphon output discovered",source.is_object());
            if(source.is_object()){
                auto thumbnails=[[VJClipThumbnails alloc]initWithModel:_model redraw:^{}];
                Json clip={{"id","embedded-patch-check"},{"gen","syphon"},{"params",{{"source",source["selection"]}}}};
                NSImage* image=nil;auto end=[NSDate dateWithTimeIntervalSinceNow:6];while(!image&&end.timeIntervalSinceNow>0){image=[thumbnails imageForClip:clip];spin(.03);}
                auto bitmap=(NSBitmapImageRep*)image.representations.firstObject;bool colored=false;if(bitmap)for(NSInteger y=0;y<bitmap.pixelsHigh&&!colored;++y)for(NSInteger x=0;x<bitmap.pixelsWide&&!colored;++x){auto pixel=bitmap.bitmapData+y*bitmap.bytesPerRow+x*bitmap.samplesPerPixel;colored=pixel[0]>20||pixel[1]>20||pixel[2]>20;}
                check(@"VJ receives nonblack embedded Patch pixels",colored);[thumbnails stop];
            }
            check(@"Patch closes with autosave and no confirmation",[_patch shouldTerminateApplication:NSApp]==NSTerminateNow);
            [_patch saveSession];
            auto data=[NSData dataWithContentsOfFile:@(getenv("VJ_PATCH_SESSION"))];NSDictionary* session=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            check(@"Embedded graph and editor session persisted",[session[@"graph"] isEqual:_patch.state[@"graph"]]&&session[@"editor"]!=nil);
            if([session[@"file"] isKindOfClass:NSString.class]){NSDictionary* savedProject=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:session[@"file"]] options:0 error:nil];check(@"Named Patch autosaves its project file",[savedProject isEqual:session[@"graph"]]);}
            [self patch:nil];spin(.1);check(@"Returning to Patch retains its graph",[_patch.state[@"graph"] isEqual:session[@"graph"]]);
            [self compose:nil];[_patch stop];spin(.1);before=_patch.renderedFrames;spin(.15);check(@"Closing embedded runtime stops its render clock",_patch.renderedFrames==before);
            [_patch.view removeFromSuperview];_patch=nil;check(@"Embedded session reopens",[self ensurePatch]);spin(.2);
            check(@"Reopen restores graph and canvas",[_patch.state[@"graph"] isEqual:session[@"graph"]]&&[_patch.state[@"editor"] isEqual:session[@"editor"]]);
            [_patch stop];[_patch.view removeFromSuperview];_patch=nil;
            NSMutableDictionary* untitled=[session mutableCopy];untitled[@"file"]=NSNull.null;untitled[@"dirty"]=@YES;untitled[@"projectName"]=@"Untitled recovery check";
            [[NSJSONSerialization dataWithJSONObject:untitled options:0 error:nil]writeToFile:@(getenv("VJ_PATCH_SESSION")) atomically:YES];
            check(@"Untitled Patch reopens",[self ensurePatch]);
            check(@"Untitled Patch closes without a Save dialog",[_patch shouldTerminateApplication:NSApp]==NSTerminateNow);
            NSDictionary* recovered=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@(getenv("VJ_PATCH_SESSION"))] options:0 error:nil];
            check(@"Untitled autosave retains graph and identity",[recovered[@"graph"] isEqual:session[@"graph"]]&&[recovered[@"projectName"] isEqual:@"Untitled recovery check"]&&recovered[@"file"]==NSNull.null);

        }
    }else if(getenv("VJ_CHECK_POSTERS_ONLY")){

        auto checks=VJCheckHeldPatchThumbnails(_model);for(auto it=checks.begin();it!=checks.end();++it)check(text(it.key()),it.value());
        auto stability=VJCheckThumbnailStability(_model);check(@"Static effects stay stable during edits",stability["stableDuringSpeedEdits"]);check(@"Camera previews stay disabled",stability["cameraThumbnailDisabled"]);
    }else if(getenv("VJ_CHECK_SEARCH_ONLY")){
        auto deadline=[NSDate dateWithTimeIntervalSinceNow:5];while([_library searchItems].empty()&&deadline.timeIntervalSinceNow>0)[[NSRunLoop mainRunLoop]runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]];
        auto grid=_model->presentationSnapshot()["state"]["grid"];auto row=grid["rows"][0]["id"].get<std::string>(),column=grid["columns"][0]["id"].get<std::string>();
        _canvas.choose(text(row),text(column));drain();[_window makeFirstResponder:_canvas];
        auto key=[&](NSWindow* window,NSString* characters,unsigned short code,NSEventModifierFlags flags){return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:flags timestamp:0 windowNumber:window.windowNumber context:nil characters:characters charactersIgnoringModifiers:characters isARepeat:NO keyCode:code];};
        auto find=key(_window,@"f",3,NSEventModifierFlagCommand);[NSApp sendEvent:find];
        check(@"Command F opens clip search",_clipSearch.window.visible);
        if(_clipSearch.window.visible){
            auto checks=[_clipSearch checkInteractions];for(auto it=checks.begin();it!=checks.end();++it)check(text(it.key()),it.value());
            if(grid["columns"].size()>1){_canvas.choose(text(row),text(grid["columns"][1]["id"]));drain();}
            [NSApp sendEvent:key(_clipSearch.window,@"\r",36,0)];drain();auto updated=_model->presentationSnapshot()["state"]["grid"];
            check(@"Enter inserts into the original slot",updated["rows"][0]["clips"][column].value("gen",std::string{})=="plasma");
            check(@"Enter dismisses clip search",!_clipSearch.window.visible);
            [_window makeKeyAndOrderFront:nil];_canvas.choose(text(row),text(column));drain();[NSApp sendEvent:find];auto before=_model->revision();
            [NSApp sendEvent:key(_clipSearch.window,@"\x1b",53,0)];check(@"Escape closes without inserting",!_clipSearch.window.visible&&before==_model->revision());
            [_window makeKeyAndOrderFront:nil];[NSApp sendEvent:find];[NSApp postEvent:[NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:NSMakePoint(5,5) modifierFlags:0 timestamp:0 windowNumber:_window.windowNumber context:nil eventNumber:1 clickCount:1 pressure:0] atStart:YES];[NSApp sendEvent:[NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:NSMakePoint(5,5) modifierFlags:0 timestamp:0 windowNumber:_window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1]];check(@"Outside click dismisses search",!_clipSearch.window.visible);
            [self mapping:nil];check(@"Clip search leaves mapper shortcuts alone",![self handleClipSearchKey:find]);[self compose:nil];
            // A remote replacement while search is open must not be overwritten.
            [_window makeKeyAndOrderFront:nil];_canvas.choose(text(row),text(column));drain();[NSApp sendEvent:find];[_clipSearch checkInteractions];
            _model->request("POST","/api/v1/grid",{{"action","delete_clip"},{"row",row},{"column",column}});
            _model->request("POST","/api/v1/grid",{{"action","put_clip"},{"row",row},{"column",column},{"effect","text"}});
            [NSApp sendEvent:key(_clipSearch.window,@"\r",36,0)];drain();
            check(@"Search rejects a changed target slot",_model->presentationSnapshot()["state"]["grid"]["rows"][0]["clips"][column]["gen"]=="text"&&[_status.stringValue isEqual:@"Clip slot changed"]);
        }
    }else if(getenv("VJ_CHECK_PERFORMANCE_ONLY")){
        NSMutableArray<VJPreview*>* projectorViews=[NSMutableArray array];
        const int projectorCount=getenv("VJ_PERFORMANCE_PROJECTORS")?std::clamp(atoi(getenv("VJ_PERFORMANCE_PROJECTORS")),1,4):4;
        for(int i=1;i<=projectorCount;i++){auto view=[[VJPreview alloc]initWithFrame:NSMakeRect(0,0,1920,1080) model:_model];[view setSingleMonitor:YES];[view setMapping:text(std::to_string(i))];[view setOutputSize:NSMakeSize(1920,1080)];[projectorViews addObject:view];}
        auto runFor=[&](double seconds){[[NSRunLoop mainRunLoop]runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];};
        const auto rows=_model->snapshot()["state"]["grid"]["rows"];Json measurements=Json::array();
        for(int active:{1,4,8,16}){
            int index=0;for(const auto& row:rows)_model->request("POST","/api/v1/grid",{{"action","set_row"},{"row",row["id"]},{"enabled",index++<active}});
            runFor(3);Json samples=Json::array();
            for(int sample=0;sample<5;sample++){runFor(1.05);auto stats=_model->request("GET","/api/v1/stats");samples.push_back(stats.body);}
            auto metrics=samples.back()["renderer"]["metrics"];check(text(std::to_string(active)+" video decoders active"),metrics["engine"]["sourceCount"]==active);check(@"Performance FPS is measured",metrics.value("fps",0.)>0&&metrics.contains("frameMs"));
            for(const auto& source:metrics["engine"]["sources"])check(@"Performance video decode succeeds",source.value("error",std::string{}).empty()&&source.value("width",0)>0);
            measurements.push_back({{"projectors",projectorCount},{"size",{1920,1080}},{"videos",active},{"samples",samples}});
        }
        auto before=_model->snapshot()["state"]["renderer"]["sequence"].get<uint64_t>();
        [NSThread sleepForTimeInterval:1.25]; // Deliberate test-only main-thread stall.
        auto after=_model->snapshot()["state"]["renderer"]["sequence"].get<uint64_t>();
        check(@"Render clock survives a blocked UI",after>before+10);runFor(1.2);
        auto stats=_model->request("GET","/api/v1/stats");check(@"UI stall is reported through API",stats.body.value("ui",Json::object()).value("maxDelayMs",0.)>=1000);
        check(@"Performance bar stays at the bottom",_performance.frame.size.height==26&&_root.arrangedSubviews.lastObject==_performance);
        if(auto path=getenv("VJ_PERFORMANCE_RESULTS")){Json report={{"phases",measurements},{"stall",{{"framesBefore",before},{"framesAfter",after},{"ui",stats.body["ui"]}}}};[text(report.dump(2))writeToFile:text(path) atomically:YES encoding:NSUTF8StringEncoding error:nil];}
        [self captureComposer:@"performance-bar"];for(VJPreview* view in projectorViews)[view stop];
    }else if(getenv("VJ_CHECK_CHOOSERS_ONLY")){
        std::function<NSButton*(NSView*)> cancel=[&](NSView* view)->NSButton*{if([view isKindOfClass:NSButton.class]&&[((NSButton*)view).title isEqual:@"Cancel"])return (NSButton*)view;for(NSView* child in view.subviews)if(auto result=cancel(child))return result;return nil;};
        for(NSString* kind in @[@"media",@"ndi",@"syphon",@"usb_webcam",@"subtitles"]){
            if([kind isEqual:@"media"])VJChooseMedia(_model,_window,^(Json){});
            else if([kind isEqual:@"subtitles"])VJChooseSubtitles(_model,_window,"missing-ui-fixture.mp4","",^(std::string){});
            else VJChooseLiveSource(_model,_window,kind.UTF8String,"",^(Json){});
            [[NSRunLoop mainRunLoop]runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.3]];auto sheet=_window.attachedSheet;[sheet.contentView layoutSubtreeIfNeeded];check([kind stringByAppendingString:@" chooser stable root"],sheet&&![sheet.contentView isKindOfClass:NSStackView.class]&&NSWidth(sheet.contentView.bounds)>=450);check([kind stringByAppendingString:@" chooser hit targets"],checkHitTargets(sheet.contentView));
            if(auto directory=getenv("VJ_UI_CAPTURE_DIR")){[[NSFileManager defaultManager]createDirectoryAtPath:text(directory) withIntermediateDirectories:YES attributes:nil error:nil];auto view=sheet.contentView;auto bitmap=[view bitmapImageRepForCachingDisplayInRect:view.bounds];[view cacheDisplayInRect:view.bounds toBitmapImageRep:bitmap];[[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}]writeToFile:[text(directory)stringByAppendingPathComponent:[kind stringByAppendingString:@"-chooser.png"]] atomically:YES];}
            auto button=cancel(sheet.contentView);[button performClick:nil];[[NSRunLoop mainRunLoop]runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.2]];check([kind stringByAppendingString:@" chooser Cancel dismisses"],button&&_window.attachedSheet==nil);
        }
    }else{
    if(!getenv("VJ_CHECK_PARITY_ONLY")&&!getenv("VJ_CHECK_MAPPER_ONLY"))for(NSInteger pass=1;pass<2;++pass)for(NSArray* destination in @[@[@"Settings",@1],@[@"DMX",@2],@[@"LEDs",@3],@[@"Mix",@0]]){
        [self mix:nil];drain();[_window.contentView layoutSubtreeIfNeeded];std::function<NSTextField*(NSView*)> editable=[&](NSView* view)->NSTextField*{if(view.isHiddenOrHasHiddenAncestor)return nil;if([view isKindOfClass:NSTextField.class]&&((NSTextField*)view).isEditable&&((NSTextField*)view).isEnabled&&!NSIsEmptyRect(view.visibleRect))return (NSTextField*)view;for(NSView* child in view.subviews)if(auto found=editable(child))return found;return nil;};NSTextField* field=editable(_controlsView);
        [field selectText:nil];check(@"Navigation field editor active",field.currentEditor!=nil);
        if(field){
            NSText* editor=field.currentEditor;NSString* savedText=[editor.string copy];editor.string=@"editing";
            auto master=_model->presentationSnapshot()["state"]["mix"]["led_master"];
            auto update=_model->request("POST","/api/v1/mix",{{"led_master",master==.37?.38:.37}});
            [_controlsView refresh];
            check(@"Background refresh preserves page editing",update.status<300&&field.currentEditor==editor&&[editor.string isEqualToString:@"editing"]);
            editor.string=savedText;_model->request("POST","/api/v1/mix",{{"led_master",master}});
        }
        NSString* identifier=[@"tab-" stringByAppendingString:destination[0]];NSButton* button=nil;for(NSView* view in _nav.arrangedSubviews)if([view.identifier isEqual:identifier])button=(NSButton*)view;
        [button performClick:nil];
        check([NSString stringWithFormat:@"%@ navigation immediate",destination[0]],[_controlsView checkPage:[destination[1]integerValue]]);
        drain();[_window.contentView layoutSubtreeIfNeeded];
        check([NSString stringWithFormat:@"%@ navigation from %@ field",destination[0],@"page"],button&&button.state==NSControlStateValueOn&&[_controlsView checkPage:[destination[1]integerValue]]);
        if(pass==1)[self captureComposer:[@"navigation-" stringByAppendingString:[destination[0]lowercaseString]]];
    }
    [_window makeFirstResponder:nil];[self compose:nil];
    if(getenv("VJ_CHECK_PARITY_ONLY")){
        [self settings:nil];drain();[_window.contentView layoutSubtreeIfNeeded];
        std::function<NSButton*(NSView*)> findNetwork=[&](NSView* view)->NSButton*{if([view isKindOfClass:NSButton.class]&&[((NSButton*)view).title isEqual:@"Network…"])return (NSButton*)view;for(NSView* child in view.subviews)if(auto found=findNetwork(child))return found;return nil;};
        auto network=findNetwork(_controlsView);check(@"Settings Network action exists",network!=nil);[network performClick:nil];
        auto networkResults=VJCheckNetwork(_model);for(auto& item:networkResults.items())check(text(item.key()),item.value().get<bool>());
        auto parityResults=[_controlsView checkParity];for(auto& item:parityResults.items())check(text(item.key()),item.value().get<bool>());
        for(NSInteger page=0;page<4;++page){if(page==0)[self mix:nil];else if(page==1)[self settings:nil];else if(page==2)[self dmx:nil];else [self leds:nil];drain();[_window.contentView layoutSubtreeIfNeeded];check([NSString stringWithFormat:@"Parity page %ld geometry",(long)page],[_controlsView checkLayout]);[self captureComposer:[NSString stringWithFormat:@"parity-page-%ld",(long)page]];if(page==1||page==2||page==3){[_controlsView checkScrollToEnd];[self captureComposer:[NSString stringWithFormat:@"parity-page-%ld-bottom",(long)page]];}}
    }
    if(getenv("VJ_CHECK_PARITY_ONLY")||getenv("VJ_CHECK_MAPPER_ONLY")){
        [self mapping:nil];drain();auto results=[_mapperView checkObjectParity];for(auto& item:results.items())check(text(item.key()),item.value().get<bool>());check(@"Mapper rendering",[_mapperView checkRendering]);[_window.contentView layoutSubtreeIfNeeded];[self captureComposer:@"mapping-objects"];
        auto fullSize=_window.contentView.frame.size;[_window setContentSize:NSMakeSize(900,700)];[_window.contentView layoutSubtreeIfNeeded];check(@"Mapper compact hit targets",checkHitTargets(_window.contentView));[self captureComposer:@"mapping-compact"];[_window setContentSize:fullSize];[_window.contentView layoutSubtreeIfNeeded];
        auto assignmentResults=[_outputs checkAssignment:_window];for(auto& item:assignmentResults.items())check(text(item.key()),item.value().get<bool>());
        auto traceResults=VJCheckTraceThumbnails(_model);for(auto& item:traceResults.items())check(text(item.key()),item.value().get<bool>());
    }
    if(!getenv("VJ_CHECK_NAVIGATION_ONLY")&&!getenv("VJ_CHECK_PARITY_ONLY")&&!getenv("VJ_CHECK_MAPPER_ONLY")){
    check(@"Compose construction",_window.contentView.subviews.count==1&&_toolbar.arrangedSubviews.count==2&&_canvas->document.contains("rows"));check(@"Compose rendering",[_preview checkRendering]);check(@"Mapper selection",VJCheckMapperSelection());
    [self mapping:nil];[_window.contentView layoutSubtreeIfNeeded];check(@"Mapping",_mapperView.frame.size.width>500&&_mapperView.frame.size.height>300&&[_mapperView checkRendering]);check(@"Mapping selected inspector",[_mapperView checkSelectionInterface]);check(@"Mapping hit targets",checkHitTargets(_window.contentView));[self captureComposer:@"mapping"];
    [self controls:nil];[_window.contentView layoutSubtreeIfNeeded];check(@"Controls geometry",_controlsView.frame.size.width>500&&_controlsView.frame.size.height>200);for(NSInteger page=0;page<5;++page){if(page==0)[self mix:nil];else if(page==1||page==4)[self settings:nil];else if(page==2)[self dmx:nil];else [self leds:nil];[_window.contentView layoutSubtreeIfNeeded];check([NSString stringWithFormat:@"Controls %ld layout",(long)page],[_controlsView checkLayout]);check([NSString stringWithFormat:@"Controls %ld hit targets",(long)page],checkHitTargets(_window.contentView));if(page<4)[self captureComposer:@[@"mix",@"settings",@"dmx",@"leds"][page]];if(page==1||page==2){check([NSString stringWithFormat:@"Controls %ld scroll and reset",(long)page],[_controlsView checkScrollToEnd]);[self captureComposer:page==1?@"settings-bottom":@"dmx-bottom"];}}
    check(@"Calibrate intentionally hidden",[_nav.arrangedSubviews filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSView* view,NSDictionary*){return [view.identifier isEqualToString:@"tab-Calibrate"];}]].count==0);
    [self compose:nil];_libraryPanel.collapsed=NO;_clipPanel.collapsed=NO;[_window.contentView layoutSubtreeIfNeeded];
    for(NSValue* value in @[[NSValue valueWithSize:NSMakeSize(1440,900)],[NSValue valueWithSize:NSMakeSize(1280,800)],[NSValue valueWithSize:NSMakeSize(1000,700)]]){
        [_window setContentSize:value.sizeValue];[self refresh];for(int i=0;i<3;++i)[_window.contentView layoutSubtreeIfNeeded];
        NSLog(@"Parity layout %.0fx%.0f: library %.0f inspector %.0f body %@",value.sizeValue.width,value.sizeValue.height,_libraryPanel.frame.size.width,_clipPanel.frame.size.width,NSStringFromRect(_composerBody.frame));check(@"Compose layout",fabs(_window.contentView.bounds.size.width-value.sizeValue.width)<2&&fabs(_composerBody.frame.size.width-value.sizeValue.width)<2&&_clipPanel.frame.size.width>=248);check(@"Compose hit targets",checkHitTargets(_window.contentView));
        [[NSRunLoop mainRunLoop]runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.2]];[self captureComposer:[NSString stringWithFormat:@"compose-%.0fx%.0f",value.sizeValue.width,value.sizeValue.height]];
    }
    auto originalShow=_snapshot["state"]["grid"]["active_show"];auto originalRow=_row,originalColumn=_column;
    [self newShow:nil];drain();[self refresh];auto newShowID=_snapshot["state"]["grid"]["active_show"];check(@"New show action",newShowID!=originalShow&&_show.numberOfItems>1);
    auto showMenu=[(VJShowPicker*)_show selectionMenu];for(NSMenuItem* item in showMenu.itemArray)if([item.representedObject isEqual:text(originalShow)]){[NSApp sendAction:item.action to:item.target from:item];break;}drain();[self refresh];check(@"Show list switches shows",_snapshot["state"]["grid"]["active_show"]==originalShow);
    _row=originalRow;_column=originalColumn;[self inspector];
    for(int i=0;i<6;++i){[_preview checkRendering];auto started=std::chrono::steady_clock::now();auto column=_snapshot["state"]["grid"]["columns"][i%_snapshot["state"]["grid"]["columns"].size()]["id"].get<std::string>();_canvas.choose(text(_row),text(column));[_canvas displayIfNeeded];if(getenv("VJ_PROFILE_UI"))NSLog(@"UI clip selection to display %.2f ms",std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-started).count());drain();check(@"Selection committed",VJUiCommandsIdle(_model)&&_model->presentationSnapshot()["state"]["grid"]["control_focus"]["column"]==column);}
    // A burst keeps the final value, shares our own revision chain, and still
    // rejects a stale edit after an external command intervenes.
    __block int commandErrors=0;auto burstRevision=_model->revision();auto savedMaster=_model->presentationSnapshot()["state"]["mix"]["video_master"];
    for(int i=0;i<80;++i)VJSubmitUiCommand(_model,"POST","/api/v1/mix",{{"video_master",double(i)/100},{"revision",burstRevision}},^(const vj::Reply& reply){if(reply.status>=300)++commandErrors;},"check-video-master");
    drain();check(@"Continuous command final value",commandErrors==0&&VJUiCommandsIdle(_model)&&_model->presentationSnapshot()["state"]["mix"]["video_master"]==.79);
    auto stale=_model->revision();_model->request("POST","/api/v1/mix",{{"video_master",savedMaster}});__block int conflictStatus=0;
    VJSubmitUiCommand(_model,"POST","/api/v1/mix",{{"video_master",.5},{"revision",stale}},^(const vj::Reply& reply){conflictStatus=reply.status;});drain();check(@"External revision conflict",conflictStatus==409);
    auto libraryChecks=VJCheckLibraryStructure();check(@"Library folders and source payload",libraryChecks["folders"].get<bool>()&&libraryChecks["dragIdentity"].get<bool>());
    [self refresh];[_window.contentView layoutSubtreeIfNeeded];NSView* faderParent=_fade.superview;auto point=[_fade convertPoint:NSMakePoint(15,NSMidY(_fade.bounds)) toView:nil];auto end=[_fade convertPoint:NSMakePoint(_fade.bounds.size.width-15,NSMidY(_fade.bounds)) toView:nil];
    auto mouse=[&](NSEventType type,NSPoint p){return [NSEvent mouseEventWithType:type location:p modifierFlags:0 timestamp:0 windowNumber:_window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];};
    [NSApp postEvent:mouse(NSEventTypeLeftMouseDragged,end) atStart:NO];[NSApp postEvent:mouse(NSEventTypeLeftMouseUp,end) atStart:NO];[_fade mouseDown:mouse(NSEventTypeLeftMouseDown,point)];drain();
    NSLog(@"Fader frame %@ UI %.3f model %s",NSStringFromRect(_fade.frame),_fade.doubleValue,_model->presentationSnapshot()["state"]["grid"]["crossfade"][[self bus]].dump().c_str());
    check(@"A/B fader actual drag",_fade.superview==faderParent&&_fade.doubleValue>.8&&_model->presentationSnapshot()["state"]["grid"]["crossfade"][[self bus]].get<double>()>.8);
    [NSApp postEvent:mouse(NSEventTypeLeftMouseDragged,point) atStart:NO];[NSApp postEvent:mouse(NSEventTypeLeftMouseUp,point) atStart:NO];[_fade mouseDown:mouse(NSEventTypeLeftMouseDown,end)];drain();check(@"A/B fader reverse drag",_fade.doubleValue<.2&&_model->presentationSnapshot()["state"]["grid"]["crossfade"][[self bus]].get<double>()<.2);
    __block BOOL ndiDiscovered=NO,syphonDiscovered=NO;
    if(getenv("VJ_CHECK_LIVE_PREVIEWS"))for(const auto& item:VJCheckLiveClipPreviews(^(Json sources,BOOL prepare){if(prepare){dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{for(const auto* kind:{"ndi","syphon"}){auto reply=_model->request("GET",std::string("/api/v1/sources/")+kind);bool found=false;auto expected=Json::parse(sources[kind][0]["selection"].get<std::string>());for(const auto& source:reply.body.value("sources",Json::array())){auto selection=Json::parse(source.value("selection",std::string{}),nullptr,false);found|=selection.is_object()&&(std::string(kind)=="ndi"?selection.value("name",std::string{})==expected.value("name",std::string{}):selection.value("uuid",std::string{})==expected.value("uuid",std::string{}));}BOOL isNdi=std::string(kind)=="ndi";dispatch_async(dispatch_get_main_queue(),^{if(isNdi)ndiDiscovered=found;else syphonDiscovered=found;});}});auto result=[_library checkInteractions:sources];check(@"Library source drag writers",result["sourceDrags"].get<bool>());check(@"Library folder navigation",result["folderNavigation"].get<bool>());[_library setLivePreviewsEnabled:YES];}else{check(@"NDI automatic discovery",ndiDiscovered);check(@"Syphon automatic discovery",syphonDiscovered);check(@"Library live thumbnail cells",[_library readyLivePreviewCount]==2);[self captureComposer:@"library-live-sources"];[_library setLivePreviewsEnabled:NO];}}))check(text("Live preview "+item["effect"].get<std::string>()),item["frame"].get<bool>()&&item["pixels"].get<bool>());
    auto stability=VJCheckThumbnailStability(_model);check(@"Posters stable during speed edits",stability["stableDuringSpeedEdits"].get<bool>());check(@"Camera thumbnails do not capture",stability["cameraThumbnailDisabled"].get<bool>());
    auto thumbChecks=VJCheckClipThumbnailRendering(_model);for(const auto& item:thumbChecks["checks"])check(text("Preview "+item["effect"].get<std::string>()),item["rendered"].get<bool>()&&item["nonblack"].get<bool>());
    auto previousCount=_snapshot["state"]["grid"]["running"].size();check(@"20-Out fixture",_model->request("PUT","/api/v1/outputs",{{"count",20}}).status<300);[self refresh];[_window.contentView layoutSubtreeIfNeeded];check(@"20-Out scroll",_outStrip.frame.size.width>_outStrip.enclosingScrollView.contentView.bounds.size.width&&_outStrip.enclosingScrollView.frame.size.height<160&&_canvas.enclosingScrollView.frame.size.height>=240);check(@"20-Out hit targets",checkHitTargets(_window.contentView));_model->request("PUT","/api/v1/outputs",{{"count",previousCount}});[self refresh];
    for(const auto* effect:{"plasma","cube","video","text","ndi","syphon","usb_webcam","triangulate_faces"}){Json params=Json::object();if(std::string(effect)=="video"){auto files=[_library filesForEffect:"video"];if(!files.empty())params=files[0]["params"];}auto placed=_model->request("POST","/api/v1/grid",{{"action","put_clip"},{"row",_row},{"column",_column},{"effect",effect},{"params",params}});check(text(std::string(effect)+" inspector fixture"),placed.status<300);[self refresh];for(int i=0;i<3;++i)[_window.contentView layoutSubtreeIfNeeded];check(text(std::string(effect)+" inspector hit targets"),checkHitTargets(_window.contentView));[self captureComposer:text(std::string("inspector-")+effect)];}
    [self toggleLibrary:nil];[self toggleInspector:nil];[_window.contentView layoutSubtreeIfNeeded];check(@"Collapsed rails",_libraryPanel.frame.size.width==36&&_clipPanel.frame.size.width==36);[self captureComposer:@"compose-collapsed"];[self toggleLibrary:nil];[self toggleInspector:nil];
    // A normal AppKit button action must reach the public model command.
    auto wasRunning=_model->presentationSnapshot()["state"]["grid"]["running"].value([self bus],false);[_transport performClick:nil];drain();check(@"Transport click",_model->presentationSnapshot()["state"]["grid"]["running"].value([self bus],false)!=wasRunning);[_transport performClick:nil];drain();
    auto outputCheck=[[VJPreview alloc]initWithFrame:NSMakeRect(0,0,640,360) model:_model];[outputCheck setMapping:@"1"];[outputCheck setOutputSize:NSMakeSize(640,360)];check(@"Output 640",[outputCheck checkRendering]);[outputCheck setOutputSize:NSMakeSize(480,270)];check(@"Output 480",[outputCheck checkRendering]);[outputCheck stop];
    }
    }
    _closing=YES;[_paletteSession invalidateAndCancel];[_patch stop];[_clipSearch cancel];[_performance stop];VJStopUiCommands(_model);if(_keyboardMonitor){[NSEvent removeMonitor:_keyboardMonitor];_keyboardMonitor=nil;}[_library stop];VJCloseNetworks(_model);VJCloseCalibrations(_model);[_canvas.thumbnails stop];[_poll invalidate];[_faderPoll invalidate];if(_paneMonitor){[NSEvent removeMonitor:_paneMonitor];_paneMonitor=nil;}[_controlsView stop];[_outputs stop];for(VJPreview* preview in _monitors.previews)[preview stop];[_mapperView stop];[_window close];return result;
}

@end

vj::Reply VJPlaceLibrarySubpatch(const vj::Json& command){
    // HTTP workers can arrive during teardown. Cancel unstarted main-thread work on timeout.
    struct Placement {std::atomic<bool> claimed{false};vj::Reply reply;};
    auto state=std::make_shared<Placement>();auto done=dispatch_semaphore_create(0);
    auto body=command;
    auto place=^{
        if(state->claimed.exchange(true))return;
        auto app=(VJApplication*)NSApp.delegate;
        state->reply=app?[app placeLibrarySubpatch:body]:vj::Reply(503,{{"error","Compose is unavailable"}});
        dispatch_semaphore_signal(done);
    };
    if(NSThread.isMainThread){place();return state->reply;}
    dispatch_async(dispatch_get_main_queue(),place);
    if(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC))){
        if(!state->claimed.exchange(true))return {503,{{"error","Compose is busy"}}};
        dispatch_semaphore_wait(done,DISPATCH_TIME_FOREVER);
    }
    return state->reply;
}
