#include <sstream>
#import "mapper.hpp"
#import "native_clip_search.hpp"
#include "native_async.hpp"
#import "preview.hpp"
#import "native_style.hpp"
#include <algorithm>
#include <cmath>
#include <set>
#include <optional>
#include "mapping_collections.hpp"
#include "mapping_model.hpp"
#include "trace_model.hpp"
#include "mapping_geometry.hpp"
#include "mapping_canvas.hpp"
#include "../../native-renderer/src/rounded_surface.hpp"
using vj::Json;
static NSString* ms(const std::string& s){return [NSString stringWithUTF8String:s.c_str()]?:@"";}
static NSColor* mc(double r,double g,double b){return [NSColor colorWithSRGBRed:r green:g blue:b alpha:1];}
static NSStackView* stack(NSUserInterfaceLayoutOrientation orientation){return vj::style::stack(orientation);}
static NSTextField* label(NSString* value){auto f=[NSTextField labelWithString:value];f.font=vj::style::font(11);f.textColor=vj::style::secondary();return f;}
static bool has(const Json& values,const Json& value){return std::find(values.begin(),values.end(),value)!=values.end();}
static NSBezierPath* polygon(const Json& points,NSRect b){auto path=[NSBezierPath bezierPath];bool first=true;for(const auto& p:points){NSPoint v=NSMakePoint(b.origin.x+p[0].get<double>()*b.size.width,b.origin.y+p[1].get<double>()*b.size.height);if(first)[path moveToPoint:v];else[path lineToPoint:v];first=false;}[path closePath];return path;}

static vj::CanvasRect cr(NSRect r){return {r.origin.x,r.origin.y,r.size.width,r.size.height};}
static vj::CanvasPoint cp(NSPoint p){return {p.x,p.y};}
static surface_curvature::Settings curveSettings(const Json& rect){return vj::mappingCurveSettings(rect);}
static Json surfaceOutline(const Json& rect,NSRect bounds){return vj::mappingSurfaceOutline(rect,bounds.size.width/bounds.size.height);}
static void drawSubdivision(const Json& cells,NSRect bounds,bool fill){
    auto screen=[&](const Json& p){return NSMakePoint(bounds.origin.x+p[0].get<double>()*bounds.size.width,bounds.origin.y+p[1].get<double>()*bounds.size.height);};
    for(size_t i=0;i<cells.size();i++){
        auto path=polygon(cells[i]["corners"],bounds);
        if(fill){NSColor* color=mc(.25,.65,.9);if(cells[i].contains("color")){unsigned rgb=0;std::istringstream hex(cells[i]["color"].get<std::string>().substr(1));hex>>std::hex>>rgb;color=mc((rgb>>16&255)/255.,(rgb>>8&255)/255.,(rgb&255)/255.);}[[color colorWithAlphaComponent:cells[i].contains("color")?.25:i%2?.13:.06] setFill];[path fill];}
        [[NSColor colorWithWhite:0 alpha:.8] setStroke];path.lineWidth=3;[path stroke];[mc(.72,.84,.9) setStroke];path.lineWidth=1;[path stroke];
    }
    if(cells.empty())return;
    // The first tile identifies the grid origin and its two local axes, even
    // when the parent is rotated or has a strong perspective adjustment.
    auto axis=[&](int corner,NSColor* color,NSString* title){
        auto a=screen(cells[0]["axes"][0]),b=screen(cells[0]["axes"][corner]);
        double dx=b.x-a.x,dy=b.y-a.y,length=std::hypot(dx,dy);if(length<1)return;
        dx/=length;dy/=length;auto path=[NSBezierPath bezierPath];[path moveToPoint:a];[path lineToPoint:b];[path moveToPoint:NSMakePoint(b.x-8*dx+4*dy,b.y-8*dy-4*dx)];[path lineToPoint:b];[path lineToPoint:NSMakePoint(b.x-8*dx-4*dy,b.y-8*dy+4*dx)];[color setStroke];path.lineWidth=3;[path stroke];
        [title drawAtPoint:NSMakePoint((a.x+b.x)/2+5,(a.y+b.y)/2-16) withAttributes:@{NSFontAttributeName:vj::style::font(11),NSForegroundColorAttributeName:color,NSBackgroundColorAttributeName:[NSColor colorWithWhite:.06 alpha:.9]}];
    };
    axis(1,mc(.25,.8,1),@"Columns");axis(2,mc(1,.68,.28),@"Rows");if(cells[0]["axes"].size()==4)axis(3,mc(.3,.9,.5),@"Depth");
    auto origin=screen(cells[0]["axes"][0]);[NSColor.whiteColor setFill];[[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(origin.x-3,origin.y-3,6,6)]fill];
}
@interface VJSubdivisionDiagram : NSView { @public Json cells;double aspect; }
@end
@implementation VJSubdivisionDiagram
- (BOOL)isFlipped{return YES;}
- (void)drawRect:(NSRect)dirty{
    (void)dirty;[vj::style::background() setFill];NSRectFill(self.bounds);if(cells.empty())return;
    double low[2]={INFINITY,INFINITY},high[2]={-INFINITY,-INFINITY};for(const auto& cell:cells)for(const auto& p:cell["corners"])for(int a=0;a<2;a++){double n=p[a].get<double>()*(a?1:aspect);low[a]=std::min(low[a],n);high[a]=std::max(high[a],n);}
    double scale=std::min((self.bounds.size.width-56)/std::max(1e-9,high[0]-low[0]),(self.bounds.size.height-48)/std::max(1e-9,high[1]-low[1]));
    NSRect b=NSMakeRect((self.bounds.size.width-(high[0]-low[0])*scale)/2-low[0]*scale,(self.bounds.size.height-(high[1]-low[1])*scale)/2-low[1]*scale,aspect*scale,scale);
    drawSubdivision(cells,b,true);
}
@end
static bool ownedSurface(const Json& mapping,const Json& id){return vj::mappingOwnedSurface(mapping,id);}
static double edgeDistance(const Json& points,NSRect b,NSPoint cursor){return vj::mappingEdgeDistance(points,cr(b),cp(cursor));}
static Json editCorners(const Json& rect,const Json& mapping){return vj::mappingEditCorners(rect,mapping);}
static Json screenMatrix(const Json& corners){return vj::mappingScreenMatrix(corners);}
static Json projectPoint(const Json& matrix,double x,double y){return vj::mappingProjectPoint(matrix,x,y);}
static bool generatedSurface(const Json& mapping,const Json& id){return vj::mappingGeneratedSurface(mapping,id);}
static Json rotationTarget(const Json& mapping,const Json& selected){return vj::mappingRotationTarget(mapping,selected);}
struct MapRotationHandle { NSPoint point,anchor; };
static std::optional<MapRotationHandle> rotationHandle(const Json& mapping,const Json& selected,const Json& target,NSRect bounds,NSRect viewport){auto handle=vj::mappingRotationHandle(mapping,selected,target,cr(bounds),cr(viewport));if(!handle)return std::nullopt;return MapRotationHandle{NSMakePoint(handle->point.x,handle->point.y),NSMakePoint(handle->anchor.x,handle->anchor.y)};}
static Json geometryOperations(const Json& source,const Json& updates){return vj::mappingGeometryOperations(source,updates);}

@interface VJMapCanvas : NSView { @public Json mapping,selected,selectedTrace;CGFloat zoom;NSPoint pan;std::string addingPin,positioningContent;NSImage* liveImage;Json subdivisionCells; }
@property(copy) NSMenu* (^contextMenu)(NSEvent*);
@property(copy) void (^selection)(const Json&);
@property(copy) BOOL (^placeSurface)(const Json&);
@property(copy) BOOL (^placeBox)(const Json&);
@property(copy) BOOL (^placeCircle)(const Json&,double);
@property(copy) void (^placementStatus)(NSString*);
@property(copy) void (^traceSelection)(const Json&);
@property(copy) void (^traceGeometry)(const Json&,const Json&);
@property(copy) void (^surfaceProperty)(const Json&,const Json&);
@property(copy) void (^curveEdgeSelection)(const std::string&);
@property(copy) void (^collectionProperty)(const Json&,const Json&);
@property(copy) void (^geometry)(const Json&);
@property(copy) void (^geometryPreview)(const Json&,uint64_t);
@property(copy) void (^markerPreview)(const Json&,uint64_t);
@property(copy) void (^clearPreview)(void);
@property(copy) void (^translation)(const Json&,const Json&);
@property(copy) void (^removeSelection)(void);
@property(copy) void (^history)(BOOL);
- (void)beginPlacement;
- (void)beginBoxPlacement;
- (void)beginCirclePlacement;
- (void)updateBoxPlacement:(NSEvent*)event;
- (void)updateBoxPreview;
- (void)beginQuickTransform;
- (void)cancelPlacement;
- (void)reset;
- (void)zoomBy:(double)factor;
- (void)fitSelection;
- (BOOL)interacting;
- (Json)checkPreviewCadence;
- (Json)checkRotationHandles;
@end
@implementation VJMapCanvas {BOOL _placingCircle;BOOL _placingBox,_boxCursorVisible;Json _boxCenters;NSPoint _boxCursor; NSTrackingArea* _placeTracking;BOOL _placing,_quickTransform,_adjusting,_placeVisible,_placementClick;Json _placeCorners,_placeOriginal,_placeUpdates;NSPoint _placeCenter,_followOffset,_adjustStart,_adjustVector;double _placeSize,_placeAngle,_adjustSize,_adjustAngle; BOOL _space,_panDrag;NSPoint _start,_panStart;vj::MappingCanvasGesture _gesture; }
- (instancetype)initWithFrame:(NSRect)frame{self=[super initWithFrame:frame];if(self){zoom=1;pan=NSZeroPoint;selected=Json::array();mapping=Json::object();}return self;}
- (NSMenu*)menuForEvent:(NSEvent*)event {return self.contextMenu?self.contextMenu(event):[super menuForEvent:event];}
- (BOOL)isFlipped{return YES;}
- (BOOL)acceptsFirstResponder{return YES;}
- (BOOL)interacting{return _placingBox||_quickTransform||_gesture.dragging()||_panDrag||_gesture.marquee();}
- (NSRect)mapBounds{CGFloat w=std::max(100.,self.bounds.size.width-64),h=std::max(100.,self.bounds.size.height-64);double ratio=mapping.contains("project")?vj::mappingCanvasAspect(mapping["project"]):16./9.;if(w/h>ratio)w=h*ratio;else h=w/ratio;return NSMakeRect((self.bounds.size.width-w)/2+pan.x,(self.bounds.size.height-h)/2+pan.y,w*zoom,h*zoom);}
- (void)reset{[self cancelPlacement];zoom=1;pan=NSZeroPoint;[self setNeedsDisplay:YES];}
- (void)setViewCenter:(NSPoint)center zoom:(double)value {zoom=1;pan=NSZeroPoint;auto base=[self mapBounds];zoom=std::clamp(value,.004,4.);pan=NSMakePoint(self.bounds.size.width/2-base.origin.x-center.x*base.size.width*zoom,self.bounds.size.height/2-base.origin.y-center.y*base.size.height*zoom);[self setNeedsDisplay:YES];}
- (void)zoomBy:(double)factor {auto bounds=[self mapBounds];NSPoint center=NSMakePoint((self.bounds.size.width/2-bounds.origin.x)/bounds.size.width,(self.bounds.size.height/2-bounds.origin.y)/bounds.size.height);[self setViewCenter:center zoom:zoom*factor];}
- (void)fitSelection {double low[2]={0,0},high[2]={1,1};auto include=[&](const Json& points){for(const auto& p:points)for(int i=0;i<2;i++){low[i]=std::min(low[i],p[i].get<double>());high[i]=std::max(high[i],p[i].get<double>());}};for(const auto& r:mapping["project"]["rects"])if(has(selected,r["id"]))include(r["corners"]);for(const auto& t:mapping["project"].value("traces",Json::array()))if(t["id"]==selectedTrace)include(t["points"]);[self setViewCenter:NSMakePoint((low[0]+high[0])/2,(low[1]+high[1])/2) zoom:1./(std::max(high[0]-low[0],high[1]-low[1])*1.25)];}
- (void)drawRect:(NSRect)dirty{(void)dirty;[vj::style::background() setFill];NSRectFill(self.bounds);auto bounds=[self mapBounds];[[NSColor blackColor] setFill];NSRectFill(bounds);if(liveImage)[liveImage drawInRect:bounds fromRect:NSZeroRect operation:NSCompositingOperationCopy fraction:1 respectFlipped:YES hints:nil];[mc(.25,.28,.3) setStroke];[[NSBezierPath bezierPathWithRect:bounds] stroke];if(!mapping.contains("project"))return;
    auto attrs=@{NSFontAttributeName:[NSFont systemFontOfSize:11],NSForegroundColorAttributeName:mc(.8,.85,.83)};
    // Draw every fill first. A full-frame overlay must never cover the
    // outlines or handles of surfaces earlier in the project order.
    for(const auto& rect:mapping["project"]["rects"]){
        if(!vj::mappingEditorVisible(mapping,rect["id"]))continue;bool active=has(selected,rect["id"]),muted=rect.value("source",std::string{})=="none",overlay=rect.value("kind",std::string{})=="overlay";
        auto path=polygon(surfaceOutline(rect,bounds),bounds);
        if(!liveImage){[(muted?mc(.08,.08,.08):overlay?mc(.11,.10,.14):mc(.075,.14,.12)) setFill];[path fill];}
        if(overlay&&active){[[vj::style::overlay() colorWithAlphaComponent:.095] setFill];[path fill];}
    }
    for(const auto& rect:mapping["project"]["rects"]){if(!vj::mappingEditorVisible(mapping,rect["id"]))continue;bool active=has(selected,rect["id"]),overlay=rect.value("kind",std::string{})=="overlay";auto path=polygon(surfaceOutline(rect,bounds),bounds);
        if(overlay){CGFloat dash[]={8,5};[path setLineDash:dash count:2 phase:0];}
        // A dark backing keeps the editor outline legible over bright video.
        [[NSColor colorWithWhite:0 alpha:.8] setStroke];path.lineWidth=active?4:3;[path stroke];
        [(overlay?vj::style::overlay():active?mc(.27,.95,.58):mc(.24,.75,.47)) setStroke];path.lineWidth=active?2:1.5;[path stroke];if(rect.value("fold",false)&&rect["corners"].size()==6){auto seam=[NSBezierPath bezierPath];for(int i:{1,4}){const auto& p=rect["corners"][i];NSPoint v=NSMakePoint(bounds.origin.x+p[0].get<double>()*bounds.size.width,bounds.origin.y+p[1].get<double>()*bounds.size.height);if(i==1)[seam moveToPoint:v];else [seam lineToPoint:v];}[seam stroke];}

        if(active){[(overlay?vj::style::overlay():mc(.27,.95,.58)) setFill];for(const auto& p:editCorners(rect,mapping)){NSRect handle=NSMakeRect(bounds.origin.x+p[0].get<double>()*bounds.size.width-3,bounds.origin.y+p[1].get<double>()*bounds.size.height-3,6,6);NSRectFill(handle);}if(rect.value("mode",std::string{})=="grid"){NSRect marker=NSMakeRect(NSMidX(path.bounds)-3,NSMidY(path.bounds)-3,6,6);NSRectFill(marker);}}
    }
    if(auto handle=rotationHandle(mapping,selected,rotationTarget(mapping,selected),bounds,self.visibleRect)){auto at=handle->point;[mc(.55,.42,.25) setStroke];auto stem=[NSBezierPath bezierPath];[stem moveToPoint:handle->anchor];[stem lineToPoint:at];[stem stroke];[mc(.9,.62,.26) setFill];[[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(at.x-10,at.y-10,20,20)] fill];[@"↻" drawAtPoint:NSMakePoint(at.x-6,at.y-8) withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:15],NSForegroundColorAttributeName:[NSColor blackColor]}];}
    if(selected.size()==1)for(const auto& rect:mapping["project"]["rects"])if(has(selected,rect["id"])&&rect["corners"].size()==4&&!rect.value("fold",false)&&!generatedSurface(mapping,rect["id"])){try{auto matrix=screenMatrix(rect["corners"]);auto c=curveSettings(rect);for(int side=0;side<4;side++){auto uv=surface_curvature::pin_uv(side,.5),local=surface_curvature::point(uv[0],uv[1],c);auto p=projectPoint(matrix,local[0],local[1]);NSPoint at=NSMakePoint(bounds.origin.x+p[0].get<double>()*bounds.size.width,bounds.origin.y+p[1].get<double>()*bounds.size.height);[(rect.value("kind",std::string{})=="overlay"?vj::style::overlay():mc(.35,.65,.95)) setFill];[[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(at.x-5,at.y-5,10,10)] fill];[(@[@"T",@"R",@"B",@"L"])[side] drawAtPoint:NSMakePoint(at.x+7,at.y-6) withAttributes:attrs];}}catch(...){} }
    if(selected.size()==1)for(const auto& rect:mapping["project"]["rects"])if(has(selected,rect["id"])&&rect["corners"].size()==4&&!rect.value("fold",false)){try{auto curve=rect.value("curvature",Json::object());if(!curve.is_object())continue;auto pins=curve.value("pins",Json::object());if(!pins.is_object())continue;auto matrix=screenMatrix(rect["corners"]);for(const auto& pin:pins.value("points",Json::array())){auto p=projectPoint(matrix,pin["target"][0],pin["target"][1]);NSPoint at=NSMakePoint(bounds.origin.x+p[0].get<double>()*bounds.size.width,bounds.origin.y+p[1].get<double>()*bounds.size.height);auto diamond=[NSBezierPath bezierPath];[diamond moveToPoint:NSMakePoint(at.x,at.y-5)];[diamond lineToPoint:NSMakePoint(at.x+5,at.y)];[diamond lineToPoint:NSMakePoint(at.x,at.y+5)];[diamond lineToPoint:NSMakePoint(at.x-5,at.y)];[diamond closePath];[(rect.value("kind",std::string{})=="overlay"?vj::style::overlay():pins.value("enabled",true)&&pin.value("enabled",true)?mc(.95,.65,.22):mc(.4,.4,.4)) setFill];[diamond fill];}}catch(...){} }
    for(const auto& trace:mapping["project"].value("traces",Json::array())){
        if(!vj::mappingEditorVisible(mapping,trace["id"],true))continue;bool active=trace["id"]==selectedTrace,enabled=trace.value("enabled",true);auto path=[NSBezierPath bezierPath];bool first=true;NSPoint center=NSZeroPoint;
        for(const auto& p:trace["points"]){NSPoint v=NSMakePoint(bounds.origin.x+p[0].get<double>()*bounds.size.width,bounds.origin.y+p[1].get<double>()*bounds.size.height);if(first)[path moveToPoint:v];else[path lineToPoint:v];first=false;center.x+=v.x/trace["points"].size();center.y+=v.y/trace["points"].size();}
        path.lineCapStyle=NSLineCapStyleRound;path.lineJoinStyle=NSLineJoinStyleRound;path.lineWidth=std::max(2.,trace.value("width",.015)*bounds.size.height);[(enabled?mc(.18,.4,.43):mc(.15,.16,.17)) setStroke];if(!liveImage)[path stroke];path.lineWidth=active?2:1;[(active?mc(.3,.95,.65):mc(.5,.7,.7)) setStroke];[path stroke];

        if(active){[mc(.3,.95,.65) setFill];for(const auto& p:trace["points"]){auto handle=[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(bounds.origin.x+p[0].get<double>()*bounds.size.width-4,bounds.origin.y+p[1].get<double>()*bounds.size.height-4,8,8)];[handle fill];}NSRectFill(NSMakeRect(center.x-3,center.y-3,6,6));}
    }
    if(_placingBox){
        const std::array<NSColor*,3> colors={mc(0,1,1),mc(1,0,1),mc(1,1,0)};
        for(size_t i=0;i<_boxCenters.size();i++){auto p=_boxCenters[i];NSPoint at=NSMakePoint(bounds.origin.x+p[0].get<double>()*bounds.size.width,bounds.origin.y+p[1].get<double>()*bounds.size.height);[colors[i]setFill];[[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(at.x-4,at.y-4,8,8)]fill];[ms(std::to_string(i+1)) drawAtPoint:NSMakePoint(at.x+8,at.y-7) withAttributes:@{NSFontAttributeName:vj::style::font(12),NSForegroundColorAttributeName:colors[i]}];}
        if(_boxCursorVisible){NSPoint at=NSMakePoint(bounds.origin.x+_boxCursor.x*bounds.size.width,bounds.origin.y+_boxCursor.y*bounds.size.height);[NSColor.whiteColor setFill];[[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(at.x-4,at.y-4,8,8)]fill];}
    }
    if(_placeVisible){[[NSColor whiteColor]setStroke];if(_placing){CGFloat circle=_placeSize*.5*bounds.size.height;auto p=_placingCircle?[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(bounds.origin.x+_placeCenter.x*bounds.size.width-circle,bounds.origin.y+_placeCenter.y*bounds.size.height-circle,circle*2,circle*2)]:polygon(_placeCorners,bounds);p.lineWidth=2;[p stroke];[[NSColor whiteColor]setFill];[[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(bounds.origin.x+_placeCenter.x*bounds.size.width-3.5,bounds.origin.y+_placeCenter.y*bounds.size.height-3.5,7,7)]fill];}else for(auto& u:_placeUpdates){auto p=polygon(u["corners"],bounds);p.lineWidth=2;[p stroke];}}
    if(!subdivisionCells.empty())drawSubdivision(subdivisionCells,bounds,false);
    if(_gesture.marquee()){auto m=_gesture.marqueeRect();auto marquee=NSMakeRect(m.x,m.y,m.w,m.h);[[mc(.2,.7,.5) colorWithAlphaComponent:.14] setFill];NSRectFill(marquee);[mc(.3,.85,.6) setStroke];[[NSBezierPath bezierPathWithRect:marquee] stroke];}
}
- (void)updateTrackingAreas {[super updateTrackingAreas];if(_placeTracking)[self removeTrackingArea:_placeTracking];_placeTracking=[[NSTrackingArea alloc]initWithRect:NSZeroRect options:NSTrackingMouseMoved|NSTrackingMouseEnteredAndExited|NSTrackingActiveInKeyWindow|NSTrackingInVisibleRect owner:self userInfo:nil];[self addTrackingArea:_placeTracking];}
- (void)cancelPlacement {_placing=_quickTransform=_adjusting=_placeVisible=_placingBox=_boxCursorVisible=_placingCircle=NO;_placeCorners=Json::array();_boxCenters=Json::array();if(self.placementStatus)self.placementStatus(@"Geometry preview");if(self.clearPreview)self.clearPreview();[self setNeedsDisplay:YES];}
- (void)beginBoxPlacement {
    [self cancelPlacement];if(mapping["project"]["rects"].size()>125){if(self.placementStatus)self.placementStatus(@"Place box · Surface limit reached");return;}_placingBox=YES;_boxCenters=Json::array();_boxCursor=NSMakePoint(.5,.5);_boxCursorVisible=YES;addingPin.clear();
    [self.window makeFirstResponder:self];self.window.acceptsMouseMovedEvents=YES;
    if(self.placementStatus)self.placementStatus(@"Place box · Cyan 1/3");[self updateBoxPreview];
}
- (void)updateBoxPlacement:(NSEvent*)event {
    auto b=[self mapBounds];auto p=[self convertPoint:event.locationInWindow fromView:nil];_boxCursorVisible=NSPointInRect(p,b);
    if(_boxCursorVisible)_boxCursor=NSMakePoint((p.x-b.origin.x)/b.size.width,(p.y-b.origin.y)/b.size.height);
    [self updateBoxPreview];
}
- (void)updateBoxPreview {
    if(!_placingBox)return;Json markers=Json::array();double aspect=vj::mappingCanvasAspect(mapping["project"]);Json points=_boxCenters;
    if(_boxCursorVisible)points.push_back({_boxCursor.x,_boxCursor.y});
    const char* colors[]={"#00ffff","#ff00ff","#ffff00","#ffffff"};
    for(size_t i=0;i<points.size();i++){
        double x=points[i][0],y=points[i][1],rx=.004/aspect,ry=.004;Json corners=Json::array();
        for(auto d:std::array<std::array<int,2>,4>{{{-1,-1},{1,-1},{1,1},{-1,1}}})corners.push_back({std::clamp(x+d[0]*rx,0.,1.),std::clamp(y+d[1]*ry,0.,1.)});
        markers.push_back({{"id","box-center-preview-"+std::to_string(i)},{"name","Face center"},{"kind","surface"},{"source","out1"},{"mode","grid"},{"graphic","wireframe"},{"config",{{"color",i<_boxCenters.size()?colors[i]:"#ffffff"},{"centerOnly",true}}},{"corners",corners},{"uvs",{{0,1},{1,1},{1,0},{0,0}}},{"blend","normal"},{"fit","stretch"}});
    }
    if(self.markerPreview)self.markerPreview(markers,mapping.value("revision",uint64_t(0)));[self setNeedsDisplay:YES];
}
- (void)beginPlacement {
 [self cancelPlacement];_placing=YES;addingPin.clear();_placeSize=_placeSize>0?_placeSize:.06;_placeAngle=0;_followOffset=NSZeroPoint;_placeCenter=NSMakePoint(.5,.5);_placeCorners=Json::array();[self.window makeFirstResponder:self];self.window.acceptsMouseMovedEvents=YES;
}
// Place circle reuses surface placement: the square preview is the circle's bounding box.
- (void)beginCirclePlacement {[self beginPlacement];_placingCircle=YES;}
- (void)beginQuickTransform {
 [self cancelPlacement];if(selected.empty())return;_placeOriginal=mapping;_placeUpdates=Json::array();double x=0,y=0;size_t count=0;for(auto& r:mapping["project"]["rects"])if(has(selected,r["id"]))for(auto& p:editCorners(r,mapping)){x+=p[0].get<double>();y+=p[1].get<double>();++count;}if(!count)return;_placeCenter=NSMakePoint(x/count,y/count);_quickTransform=YES;_adjusting=NO;[self.window makeFirstResponder:self];self.window.acceptsMouseMovedEvents=YES;
}
- (void)updatePlacement:(NSEvent*)event {
 if(!_placing&&!_quickTransform)return;auto b=[self mapBounds];auto point=[self convertPoint:event.locationInWindow fromView:nil];if(!NSPointInRect(point,self.bounds)){if(self.clearPreview)self.clearPreview();_placeVisible=NO;return;}
 const BOOL shift=(event.modifierFlags&NSEventModifierFlagShift)!=0;NSPoint cursor=NSMakePoint((point.x-b.origin.x)/b.size.width,(point.y-b.origin.y)/b.size.height);
 if(_placing&&!_adjusting){_placeCenter=NSMakePoint(cursor.x+_followOffset.x,cursor.y+_followOffset.y);}
 if((shift||_quickTransform)&&!_adjusting){_adjusting=YES;_adjustStart=point;_adjustSize=_placeSize;_adjustAngle=_placeAngle;auto center=NSMakePoint(b.origin.x+_placeCenter.x*b.size.width,b.origin.y+_placeCenter.y*b.size.height);_adjustVector=NSMakePoint(point.x-center.x,point.y-center.y);if(std::hypot(_adjustVector.x,_adjustVector.y)<12)_adjustVector=NSMakePoint(std::max(24.,_placing?_placeSize*b.size.height:48.),0);}
 if(_adjusting){double vx=_adjustVector.x+point.x-_adjustStart.x,vy=_adjustVector.y+point.y-_adjustStart.y;double scale=std::clamp(std::hypot(vx,vy)/std::hypot(_adjustVector.x,_adjustVector.y),.05,20.);double angle=std::atan2(vy,vx)-std::atan2(_adjustVector.y,_adjustVector.x);
  if(_placing){_placeSize=std::clamp(_adjustSize*scale,.003,1.);_placeAngle=_adjustAngle+angle;}
  else{_placeUpdates=Json::array();for(auto& r:_placeOriginal["project"]["rects"])if(has(selected,r["id"])){auto corners=editCorners(r,_placeOriginal);for(auto& p:corners){double dx=(p[0].get<double>()-_placeCenter.x)*b.size.width,dy=(p[1].get<double>()-_placeCenter.y)*b.size.height;p=Json::array({_placeCenter.x+scale*(dx*std::cos(angle)-dy*std::sin(angle))/b.size.width,_placeCenter.y+scale*(dx*std::sin(angle)+dy*std::cos(angle))/b.size.height});}_placeUpdates.push_back({{"id",r["id"]},{"corners",corners}});}}
  if(_placing&&!shift){_adjusting=NO;_followOffset=NSMakePoint(_placeCenter.x-cursor.x,_placeCenter.y-cursor.y);}
 }
 auto project=mapping["project"];
 if(_placing){_placeCorners=Json::array();double aspect=b.size.width/b.size.height;for(auto p:std::array<NSPoint,4>{{{-1,-1},{1,-1},{1,1},{-1,1}}})_placeCorners.push_back({_placeCenter.x+_placeSize*.5*(p.x*std::cos(_placeAngle)-p.y*std::sin(_placeAngle))/aspect,_placeCenter.y+_placeSize*.5*(p.x*std::sin(_placeAngle)+p.y*std::cos(_placeAngle))});project["rects"].push_back({{"id","placement-preview"},{"name",_placingCircle?"Place circle":"Place surface"},{"kind","surface"},{"source","out1"},{"mode","grid"},{"graphic","wireframe"},{"config",{{"color","#ffffff"},{"thickness",3},{"centerDot",true}}},{"corners",_placeCorners},{"uvs",{{0,1},{1,1},{1,0},{0,0}}},{"blend","normal"},{"fit","stretch"}});}
 else{try{for(const auto& operation:geometryOperations(_placeOriginal,_placeUpdates)){auto action=operation["action"].get<std::string>();if(action.starts_with("collections/"))vj::requestMappingCollection(project,"PATCH",action.substr(12),operation["body"]);else for(auto& r:project["rects"])for(auto& u:operation["body"]["rects"])if(r["id"]==u["id"])vj::editMappingGeometry(r,u);}vj::normalizeMappingCollections(project);}catch(...){return;}}
 _placeVisible=YES;if(self.geometryPreview)self.geometryPreview(project,mapping.value("revision",uint64_t(0)));[self setNeedsDisplay:YES];
}
- (void)mouseMoved:(NSEvent*)event {if(_placingBox)[self updateBoxPlacement:event];else [self updatePlacement:event];}
- (void)flagsChanged:(NSEvent*)event {if(_placing)[self updatePlacement:event];else[super flagsChanged:event];}
- (void)mouseExited:(NSEvent*)event {(void)event;if(_placingBox){_boxCursorVisible=NO;[self updateBoxPreview];return;}if(_placing||_quickTransform){_placeVisible=NO;if(self.clearPreview)self.clearPreview();[self setNeedsDisplay:YES];}}
- (void)mouseDown:(NSEvent*)event{[self.window makeFirstResponder:self];
    if(_placingBox){
        _placementClick=YES;[self updateBoxPlacement:event];if(!_boxCursorVisible)return;
        _boxCenters.push_back({_boxCursor.x,_boxCursor.y});
        if(_boxCenters.size()==3){
            auto centers=_boxCenters;if(self.clearPreview)self.clearPreview();
            if(self.placeBox&&self.placeBox(centers)){[self beginBoxPlacement];if(_placingBox)[self updateBoxPlacement:event];return;}
            _boxCenters.erase(_boxCenters.end()-1);[self updateBoxPreview];return;
        }
        if(self.placementStatus)self.placementStatus(_boxCenters.size()==1?@"Place box · Magenta 2/3":@"Place box · Yellow 3/3");[self updateBoxPreview];return;
    }

 if(_placing||_quickTransform){_placementClick=YES;[self updatePlacement:event];if(!_placeVisible)return;if(_placing){auto corners=_placeCorners;if(self.clearPreview)self.clearPreview();if(_placingCircle?(self.placeCircle&&self.placeCircle(Json::array({_placeCenter.x,_placeCenter.y}),_placeSize*.5)):(self.placeSurface&&self.placeSurface(corners))){_placeVisible=NO;_adjusting=NO;_followOffset=NSZeroPoint;}}else{auto updates=_placeUpdates;[self cancelPlacement];if(self.geometry&&!updates.empty())self.geometry(updates);}[self setNeedsDisplay:YES];return;}
_start=[self convertPoint:event.locationInWindow fromView:nil];_panStart=pan;
    if(_space||event.buttonNumber==2){_panDrag=YES;[[NSCursor closedHandCursor] set];return;}
    [self bindGestureActions];const auto flags=event.modifierFlags;
    _gesture.down([self gestureDoc],cp(_start),cr([self mapBounds]),cr(self.visibleRect),int(event.clickCount),{(flags&NSEventModifierFlagShift)!=0,(flags&NSEventModifierFlagCommand)!=0,(flags&(NSEventModifierFlagShift|NSEventModifierFlagCommand|NSEventModifierFlagControl))!=0});
    if(_gesture.contentDrag())[[NSCursor closedHandCursor] set];
    [self setNeedsDisplay:YES];
}
- (vj::MappingCanvasDoc)gestureDoc {return {mapping,selected,selectedTrace,addingPin,positioningContent};}
- (void)bindGestureActions {__weak VJMapCanvas* weak=self;
    _gesture.actions={
        .selection=[weak](const Json& ids){VJMapCanvas* owner=weak;if(owner&&owner.selection)owner.selection(ids);},
        .traceSelection=[weak](const Json& id){VJMapCanvas* owner=weak;if(owner&&owner.traceSelection)owner.traceSelection(id);},
        .geometry=[weak](const Json& updates){VJMapCanvas* owner=weak;if(owner&&owner.geometry)owner.geometry(updates);},
        .traceGeometry=[weak](const Json& id,const Json& points){VJMapCanvas* owner=weak;if(owner&&owner.traceGeometry)owner.traceGeometry(id,points);},
        .surfaceProperty=[weak](const Json& id,const Json& patch){VJMapCanvas* owner=weak;if(owner&&owner.surfaceProperty)owner.surfaceProperty(id,patch);},
        .collectionProperty=[weak](const Json& id,const Json& patch){VJMapCanvas* owner=weak;if(owner&&owner.collectionProperty)owner.collectionProperty(id,patch);},
        .translation=[weak](const Json& ids,const Json& delta){VJMapCanvas* owner=weak;if(owner&&owner.translation)owner.translation(ids,delta);},
        .curveEdgeSelection=[weak](const std::string& side){VJMapCanvas* owner=weak;if(owner&&owner.curveEdgeSelection)owner.curveEdgeSelection(side);}};
}
- (void)otherMouseDown:(NSEvent*)e{[self mouseDown:e];}
- (void)otherMouseDragged:(NSEvent*)e{[self mouseDragged:e];}
- (void)otherMouseUp:(NSEvent*)e{[self mouseUp:e];}
- (void)updateGeometryDrag:(NSEvent*)event{auto point=[self convertPoint:event.locationInWindow fromView:nil];
    if(_panDrag){pan=NSMakePoint(_panStart.x+point.x-_start.x,_panStart.y+point.y-_start.y);[self setNeedsDisplay:YES];return;}
    _gesture.drag([self gestureDoc],cp(point),cr([self mapBounds]),(event.modifierFlags&NSEventModifierFlagShift)!=0);[self setNeedsDisplay:YES];
}
- (void)mouseDragged:(NSEvent*)event {if(_placingBox){[self updateBoxPlacement:event];return;}
    if(_placing||_quickTransform){[self updatePlacement:event];return;}
    [self updateGeometryDrag:event];
    // The model is a latest-value mailbox, sampled by the 60 Hz renderer.
    // Dropping pointer events at 30 Hz introduced visible steps and lost the
    // last position when the pointer paused between preview deadlines.
    if(!_panDrag&&self.geometryPreview)if(auto preview=_gesture.preview([self gestureDoc]))self.geometryPreview(preview->first,preview->second);
}
- (void)mouseUp:(NSEvent*)event {if(_placingBox){_placementClick=NO;return;}if(_placementClick){_placementClick=NO;return;}if(_placing||_quickTransform)return;[self finishGeometryDrag:event];if(self.clearPreview)self.clearPreview();}
- (void)finishGeometryDrag:(NSEvent*)event{auto point=[self convertPoint:event.locationInWindow fromView:nil];
    if(_panDrag){pan=NSMakePoint(_panStart.x+point.x-_start.x,_panStart.y+point.y-_start.y);_panDrag=NO;}
    else{const bool content=_gesture.contentDrag();_gesture.up([self gestureDoc],cp(point),cr([self mapBounds]),(event.modifierFlags&NSEventModifierFlagShift)!=0);if(content){[[NSCursor openHandCursor] set];[self setNeedsDisplay:YES];return;}}
    [self setNeedsDisplay:YES];[(_space?[NSCursor openHandCursor]:[NSCursor arrowCursor]) set];
}
- (void)scrollWheel:(NSEvent*)e{if(_quickTransform)return;auto point=[self convertPoint:e.locationInWindow fromView:nil];auto before=[self mapBounds];double factor=std::clamp(zoom*std::exp(-e.scrollingDeltaY*.012),.004,4.)/zoom;zoom*=factor;auto after=[self mapBounds];pan.x+=point.x-(after.origin.x+(point.x-before.origin.x)*factor);pan.y+=point.y-(after.origin.y+(point.y-before.origin.y)*factor);[self setNeedsDisplay:YES];}
- (BOOL)resignFirstResponder{[self cancelPlacement];_space=NO;[[NSCursor arrowCursor] set];return [super resignFirstResponder];}
- (void)keyDown:(NSEvent*)e{if(_placingBox&&(e.keyCode==51||e.keyCode==117)){if(!_boxCenters.empty())_boxCenters.erase(_boxCenters.end()-1);if(self.placementStatus)self.placementStatus(_boxCenters.empty()?@"Place box · Cyan 1/3":@"Place box · Magenta 2/3");[self updateBoxPreview];return;}if(e.keyCode==53){[self cancelPlacement];if(self.clearPreview)self.clearPreview();_gesture.cancel([self gestureDoc]);addingPin.clear();_panDrag=NO;[self setNeedsDisplay:YES];return;}if((e.modifierFlags&NSEventModifierFlagCommand)&&[e.charactersIgnoringModifiers.lowercaseString isEqualToString:@"a"]){selected=Json::array();for(const auto& r:mapping["project"]["rects"])if(vj::mappingEditorVisible(mapping,r["id"]))selected.push_back(r["id"]);if(self.selection)self.selection(selected);[self setNeedsDisplay:YES];return;}if(e.keyCode>=123&&e.keyCode<=126&&selectedTrace.is_string()){double dx=0,dy=0,step=(e.modifierFlags&NSEventModifierFlagShift)?10.:1.;if(e.keyCode<=124)dx=step*(e.keyCode==123?-1:1)/1920.;else dy=step*(e.keyCode==126?-1:1)/1080.;for(const auto& trace:mapping["project"].value("traces",Json::array()))if(trace["id"]==selectedTrace){auto points=trace["points"];for(auto& p:points)p=Json::array({std::clamp(p[0].get<double>()+dx,0.,1.),std::clamp(p[1].get<double>()+dy,0.,1.)});if(self.traceGeometry)self.traceGeometry(trace["id"],points);return;}}if(!positioningContent.empty()&&e.keyCode>=123&&e.keyCode<=126){
    for(const auto& rect:mapping["project"]["rects"])if(rect["id"]==positioningContent){auto position=rect.value("contentPosition",Json::array({.5,.5}));int axis=e.keyCode<=124?0:1;double step=(e.modifierFlags&NSEventModifierFlagShift)?.001:.01;position[axis]=std::clamp(position[axis].get<double>()+(e.keyCode==123||e.keyCode==126?step:-step),0.,1.);if(self.surfaceProperty)self.surfaceProperty(rect["id"],{{"contentPosition",position}});return;}return;
}if(e.keyCode>=123&&e.keyCode<=126&&!selected.empty()){double delta[2]={0,0},step=(e.modifierFlags&NSEventModifierFlagShift)?10.:1.;delta[e.keyCode<=124?0:1]=step*(e.keyCode==123||e.keyCode==126?-1:1)/(e.keyCode<=124?1920.:1080.);if(self.translation){self.translation(selected,Json::array({delta[0],delta[1]}));return;}double lo[2]={1,1},hi[2]={0,0};for(const auto& r:mapping["project"]["rects"])if(has(selected,r["id"]))for(const auto& p:r["corners"])for(int a=0;a<2;a++){lo[a]=std::min(lo[a],p[a].get<double>());hi[a]=std::max(hi[a],p[a].get<double>());}for(int a=0;a<2;a++)delta[a]=std::clamp(delta[a],-lo[a],1-hi[a]);Json updates=Json::array();for(const auto& r:mapping["project"]["rects"])if(has(selected,r["id"])){Json points=r["corners"];for(auto& p:points)for(int a=0;a<2;a++)p[a]=p[a].get<double>()+delta[a];updates.push_back({{"id",r["id"]},{"corners",points}});}if(self.geometry)self.geometry(updates);return;}if([e.characters isEqualToString:@" "]){_space=YES;[[NSCursor openHandCursor] set];return;}if(e.keyCode==51||e.keyCode==117){if(self.removeSelection)self.removeSelection();return;}if((e.modifierFlags&NSEventModifierFlagCommand)&&[e.charactersIgnoringModifiers.lowercaseString isEqualToString:@"z"]){if(self.history)self.history((e.modifierFlags&NSEventModifierFlagShift)!=0);return;}[super keyDown:e];}
- (void)keyUp:(NSEvent*)e{if([e.characters isEqualToString:@" "]){_space=NO;[[NSCursor arrowCursor] set];}else [super keyUp:e];}
- (Json)checkRotationHandles {
    Json checks=Json::object();mapping=vj::Model::initial()["mappings"]["1"];selected=Json::array({"corner-fixture"});
    auto bounds=[self mapBounds];const double dx=45/bounds.size.width,dy=45/bounds.size.height;
    mapping["project"]["rects"]=Json::array({{{"id","corner-fixture"},{"corners",{{.5+dx,.5},{.5,.5+dy},{.5-dx,.5},{.5,.5-dy}}}}});
    mapping["project"]["collections"]=Json::array({{{"id","fixture"},{"kind","boxes"},{"boxes",Json::array({{{"id","box"}}})},{"faces",Json::array({{{"rectId","corner-fixture"},{"boxId","box"}}})}}});
    const auto event=[&](NSPoint at,NSEventModifierFlags flags=0){return [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:[self convertPoint:at toView:nil] modifierFlags:flags timestamp:0 windowNumber:0 context:nil eventNumber:0 clickCount:1 pressure:1];};
    const NSPoint corner=NSMakePoint(NSMidX(bounds)+45,NSMidY(bounds));
    [self mouseDown:event(corner)];checks["Corner at former rotation position starts a corner drag"]=_gesture.corner()==0&&!_gesture.rotating()&&_gesture.dragging();[self finishGeometryDrag:event(corner)];
    bool separated=true,reachable=true;int placements=0;
    for(double scale:{.05,.25,1.,2.,4.})for(NSPoint offset:{NSZeroPoint,NSMakePoint(-220,-160),NSMakePoint(220,160)}){
        zoom=scale;pan=offset;auto b=[self mapBounds];auto target=rotationTarget(mapping,selected);auto handle=rotationHandle(mapping,selected,target,b,self.bounds);if(!handle)continue;++placements;
        reachable&=NSPointInRect(handle->point,NSInsetRect(self.bounds,14,14));
        for(const auto& p:mapping["project"]["rects"][0]["corners"])separated&=std::hypot(handle->point.x-b.origin.x-p[0].get<double>()*b.size.width,handle->point.y-b.origin.y-p[1].get<double>()*b.size.height)>=28;
    }
    checks["Rotation stays separate from corners across zoom and pan"]=separated&&placements==15;checks["Rotation stays visible at canvas edges"]=reachable;
    zoom=1;pan=NSZeroPoint;auto handle=rotationHandle(mapping,selected,rotationTarget(mapping,selected),[self mapBounds],self.bounds);
    if(handle){[self mouseDown:event(handle->point)];checks["Outside rotation control remains draggable"]=_gesture.dragging()&&_gesture.rotating()&&_gesture.corner()==-1;[self finishGeometryDrag:event(handle->point)];}else checks["Outside rotation control remains draggable"]=false;
    // Exercise real collection geometry as well as the exact legacy collision.
    mapping=vj::Model::initial()["mappings"]["1"];vj::requestMappingCollection(mapping["project"],"POST","",{{"kind","boxes"},{"preset","stack"}});
    auto collection=mapping["project"]["collections"].back();auto face=collection["faces"][0];selected=Json::array({face["rectId"]});
    for(const auto& rect:mapping["project"]["rects"])if(rect["id"]==selected[0]){auto p=rect["corners"][0];auto at=NSMakePoint(bounds.origin.x+p[0].get<double>()*bounds.size.width,bounds.origin.y+p[1].get<double>()*bounds.size.height);[self mouseDown:event(at,NSEventModifierFlagShift)];checks["Shift corner still scales the complete box"]=_gesture.dragging()&&_gesture.scaling()&&!_gesture.rotating();[self finishGeometryDrag:event(at)];break;}
    handle=rotationHandle(mapping,selected,rotationTarget(mapping,selected),bounds,self.bounds);
    if(handle){[self mouseDown:event(handle->point)];auto next=event(NSMakePoint(handle->point.x+20,handle->point.y+10));[self updateGeometryDrag:next];checks["Outside rotation drag updates real box geometry"]=_gesture.moved()&&_gesture.rotationUpdated();[self finishGeometryDrag:next];}else checks["Outside rotation drag updates real box geometry"]=false;
    return checks;
}
- (Json)checkPreviewCadence {
    // Called on a detached fixture canvas by --check-ui. Deliver a burst as an
    // actual mouse can, then pause: the projector must see its final position.
    mapping=vj::Model::initial()["mappings"]["1"];selected=Json::array({"rect-1"});
    auto bounds=[self mapBounds];_start=NSMakePoint(NSMidX(bounds),NSMidY(bounds));
    _gesture.beginTranslation([self gestureDoc],cp(_start),selected);
    __block int updates=0,commits=0,clears=0;__block Json latest,offset;
    self.geometryPreview=^(const Json& project,uint64_t){++updates;latest=project;};
    self.translation=^(const Json&,const Json& delta){++commits;offset=delta;};
    self.clearPreview=^{++clears;};
    auto event=[&](NSEventType type,double x){return [NSEvent mouseEventWithType:type location:[self convertPoint:NSMakePoint(_start.x+x,_start.y) toView:nil] modifierFlags:0 timestamp:0 windowNumber:0 context:nil eventNumber:0 clickCount:1 pressure:1];};
    for(int i=0;i<12;++i)[self mouseDragged:event(NSEventTypeLeftMouseDragged,4+i)];
    Json checks={{"Mapper publishes every pointer event without a 30 Hz gate",updates==12},
                 {"Mapper paused pointer retains its latest preview",latest==mapping["project"]},
                 {"Mapper pointer previews do not commit geometry",commits==0}};
    [self mouseUp:event(NSEventTypeLeftMouseUp,20)];
    checks["Mapper mouse-up commits the final pointer position once"]=commits==1&&offset.is_array()&&std::abs(offset[0].get<double>()-20/bounds.size.width)<1e-9&&clears==1;
    return checks;
}
@end
// Matches fine-controls.js: preserve thumb offset, quantize to the declared
// step, and apply Shift only to newly travelled pointer distance.
@interface VJMapCurveSlider : NSSlider<VJReusableControl>
@property double valueStep;
@property(weak) NSTextField* numberField;
@property(copy) void (^beginEdit)(void);
@property(copy) BOOL (^changeValue)(double);
@property(copy) void (^endEdit)(BOOL);
@end
@implementation VJMapCurveSlider
- (void)updateBindingsFrom:(NSControl*)control {auto next=(VJMapCurveSlider*)control;self.valueStep=next.valueStep;self.beginEdit=next.beginEdit;self.changeValue=next.changeValue;self.endEdit=next.endEdit;}
- (void)applyValue:(double)value {
    double next=std::clamp(self.minValue+std::round((value-self.minValue)/self.valueStep)*self.valueStep,self.minValue,self.maxValue);
    if(next!=self.doubleValue&&(!self.changeValue||self.changeValue(next))){self.doubleValue=next;self.numberField.stringValue=[NSString stringWithFormat:@"%.2f",next];}
}
- (void)mouseDown:(NSEvent*)event {

    if(!self.enabled)return;
    [self.window makeFirstResponder:self];if(self.beginEdit)self.beginEdit();
    const double length=std::max(1.,self.bounds.size.width-16.);
    double coordinate=[self convertPoint:event.locationInWindow fromView:nil].x;
    double value=self.doubleValue,fraction=(coordinate-8.)/length;
    if(!(event.modifierFlags&NSEventModifierFlagShift)&&std::abs(fraction-(value-self.minValue)/(self.maxValue-self.minValue))*length>10){
        value=self.minValue+std::clamp(fraction,0.,1.)*(self.maxValue-self.minValue);[self applyValue:value];
    }
    BOOL cancelled=NO;
    for(;;){
        auto next=[NSApp nextEventMatchingMask:NSEventMaskLeftMouseDragged|NSEventMaskLeftMouseUp|NSEventMaskFlagsChanged|NSEventMaskKeyDown untilDate:[NSDate dateWithTimeIntervalSinceNow:.1] inMode:NSEventTrackingRunLoopMode dequeue:YES];
        if(!next){if(!self.window||!NSApp.active){cancelled=YES;break;}continue;}
        if(next.type==NSEventTypeKeyDown){if(next.keyCode==53){cancelled=YES;break;}continue;}
        if(next.type==NSEventTypeFlagsChanged)continue;
        const double position=[self convertPoint:next.locationInWindow fromView:nil].x;
        value=std::clamp(value+(position-coordinate)/length*(self.maxValue-self.minValue)*((next.modifierFlags&NSEventModifierFlagShift)?.1:1.),self.minValue,self.maxValue);
        coordinate=position;[self applyValue:value];
        if(next.type==NSEventTypeLeftMouseUp)break;
    }
    if(self.endEdit)self.endEdit(cancelled);
}
- (void)keyDown:(NSEvent*)event {
    if(event.keyCode>=123&&event.keyCode<=126){if(self.beginEdit)self.beginEdit();[self applyValue:self.doubleValue+((event.keyCode==123||event.keyCode==125)?-1:1)*self.valueStep];if(self.endEdit)self.endEdit(NO);return;}
    [super keyDown:event];
}
@end
@interface VJMapOutline : NSOutlineView
@property(copy) NSMenu* (^contextMenu)(NSEvent*);
@end
@implementation VJMapOutline
- (NSMenu*)menuForEvent:(NSEvent*)event {return self.contextMenu?self.contextMenu(event):[super menuForEvent:event];}
@end
@interface VJMapName : NSTextField
@property(strong) NSDictionary* item;
@end
@implementation VJMapName @end

@interface VJMapNodeButton : NSButton
@property(strong) NSDictionary* item;
@end
@implementation VJMapNodeButton @end
@interface VJMapObjectCell : NSTableCellView
@property(strong) VJMapName* name;
@property(strong) NSTextField* detail;
@property(strong) VJMapNodeButton* mute;
@property(strong) VJMapNodeButton* eye;
@property(strong) VJMapNodeButton* more;
@property(strong) NSDictionary* item;
@end
@implementation VJMapObjectCell
- (BOOL)isFlipped{return YES;}
- (void)layout {[super layout];CGFloat w=self.bounds.size.width;for(NSView* parent=self.superview;parent;parent=parent.superview)if([parent isKindOfClass:NSClipView.class]){w=std::min(w,NSMaxX([self convertRect:parent.bounds fromView:parent]));break;}self.more.frame=NSMakeRect(w-36,9,32,32);self.mute.frame=NSMakeRect(w-72,9,32,32);self.eye.frame=NSMakeRect(w-(self.mute.hidden?72:108),9,32,32);CGFloat textWidth=std::max(20.,w-(self.mute.hidden?80:116));self.name.frame=NSMakeRect(7,7,textWidth,19);self.detail.frame=NSMakeRect(7,27,textWidth,16);}
- (void)drawRect:(NSRect)dirty {(void)dirty;BOOL collection=[self.item[@"kind"] isEqual:@"collection"],overlay=[self.item[@"overlay"] boolValue];if(collection){[vj::style::hex(0x182334) setFill];NSRectFill(self.bounds);}[(overlay?vj::style::overlay():vj::style::border()) setStroke];[[NSBezierPath bezierPathWithRect:NSInsetRect(self.bounds,.5,.5)] stroke];if(overlay){[vj::style::overlay() setFill];NSRectFill(NSMakeRect(0,0,2,self.bounds.size.height));}for(NSView* parent=self.superview;parent;parent=parent.superview)if([parent isKindOfClass:NSTableRowView.class]){if(((NSTableRowView*)parent).selected){[(overlay?vj::style::overlay():vj::style::accent()) setFill];NSRectFill(NSMakeRect(0,0,3,self.bounds.size.height));}break;}self.detail.textColor=overlay?vj::style::overlay():vj::style::secondary();}
@end
@interface VJProjectorTab : NSButton
@property(copy) NSString* destination;
@end
@implementation VJProjectorTab
- (BOOL)isFlipped{return NO;}
- (void)drawRect:(NSRect)dirty {(void)dirty;BOOL selected=self.state==NSControlStateValueOn;[(selected?vj::style::panel():vj::style::background()) setFill];NSRectFill(self.bounds);auto paragraph=[[NSMutableParagraphStyle alloc]init];paragraph.lineBreakMode=NSLineBreakByTruncatingTail;paragraph.alignment=NSTextAlignmentCenter;[self.title drawInRect:NSMakeRect(5,24,self.bounds.size.width-10,18) withAttributes:@{NSFontAttributeName:vj::style::font(12),NSForegroundColorAttributeName:vj::style::text(),NSParagraphStyleAttributeName:paragraph}];[(self.destination?:@"No display") drawInRect:NSMakeRect(5,7,self.bounds.size.width-10,15) withAttributes:@{NSFontAttributeName:vj::style::font(10),NSForegroundColorAttributeName:vj::style::secondary(),NSParagraphStyleAttributeName:paragraph}];if(selected){[vj::style::accent() setFill];NSRectFill(NSMakeRect(0,0,self.bounds.size.width,2));}}
@end
static NSString* projectorDestination(const Json& state,const std::string& mid) {
    auto runtime=state.value("output_status",Json::object());auto status=runtime.value("projectors",Json::object()).value(mid,Json::object());NSMutableArray* names=[NSMutableArray array];
    auto display=state.value("display_assignments",Json::object()).value(mid,Json::object());
    if(display.value("enabled",false)){auto id=display.value("displayId",std::string{}),name=id;for(const auto& item:runtime.value("displays",Json::array()))if(item.value("displayId",std::string{})==id)name=item.value("name",id);auto connection=status.value("display",Json::object()).value("status",std::string("disconnected"));[names addObject:ms(name+(connection=="active"?"":" · "+connection))];}
    auto ndi=state.value("ndi_projectors",Json::object()).value(mid,Json::object());if(ndi.value("enabled",false)){auto connection=status.value("ndi",Json::object()).value("status",std::string("disconnected"));[names addObject:ms("NDI · "+ndi.value("name",std::string("Projector ")+mid)+(connection=="active"?"":" · "+connection))];}
    return names.count?[names componentsJoinedByString:@" + "]:@"No display";
}

static Json visibleMapperSelection(const Json& mapping,const Json& ids){Json result=Json::array();for(const auto& id:ids)if(vj::mappingEditorVisible(mapping,id))result.push_back(id);return result;}
static NSDictionary* decorateMapperNode(NSDictionary* node,const Json& mapping){auto result=[node mutableCopy];BOOL visible=NO,hidden=NO;for(NSString* id in node[@"ids"]){BOOL shown=vj::mappingEditorVisible(mapping,Json(id.UTF8String));visible|=shown;hidden|=!shown;}if([node[@"kind"] isEqual:@"trace"]){visible=vj::mappingEditorVisible(mapping,Json([node[@"id"] UTF8String]),true);hidden=!visible;}result[@"mapperHidden"]=@(hidden&&!visible);if(hidden)result[@"detail"]=[(node[@"detail"]?:@"") stringByAppendingString:visible?@" · Partial":@" · Hidden"];if(node[@"children"]){NSMutableArray* children=[NSMutableArray array];for(NSDictionary* child in node[@"children"])[children addObject:decorateMapperNode(child,mapping)];result[@"children"]=children;}return result;}
@interface VJMapStack : NSStackView @end
@implementation VJMapStack
- (BOOL)isFlipped{return YES;}
@end
@interface VJMapper()<NSOutlineViewDataSource,NSOutlineViewDelegate>
@end
@interface VJMapper () <NSPopoverDelegate,NSTextFieldDelegate>
- (NSString*)subdivisionError;
- (void)subdivisionButton;
- (void)updateSubdivision;
- (Json)boxSubdivisionTarget;
@end
@implementation VJMapper {std::string _circleCollection;VJClipSearch* _actionSearch;NSPopover* _subdividePopover;VJSubdivisionDiagram* _subdivideDiagram;NSTextField* _subdivideColumns;NSTextField* _subdivideRows;NSTextField* _subdivideDepth;Json _subdivideBoxTarget;NSTextField* _subdivideCount;NSButton* _subdivideApply;Json _subdivideSurface;std::string _subdivideMid;uint64_t _subdivideRevision;int _subdivideOrientation;VJPreview* _projected;VJPreview* _editor;NSTimer* _canvasTimer;Json _editorState;vj::Model* _model;std::string _previewOwner,_previewMid,_mid,_collection,_box,_point,_trace,_loadedLayoutKey;NSMutableSet* _collapsed;NSMutableSet* _openSections;VJFlatColorWell* _patternColor;std::string _inspectorSelectionKey,_inspectorSignature;NSUInteger _inspectorBuilds,_inspectorReuses;NSInteger _clipboardChange;NSUInteger _pasteCount;NSPopover* _layoutsPopover;NSButton* _loadLayoutButton;NSButton* _updateLayoutButton;NSPopUpButton* _layoutActions;NSTextField* _currentLayout;Json _snapshot,_map,_layouts,_selection;uint64_t _revision,_visibilityRevision;NSButton* _soloButton;NSButton* _showAllButton;BOOL _refreshing,_curveTracking,_selectionPending,_revealSelectionPending;uint64_t _selectionGeneration;Json _curveBefore,_curvePatch;std::string _curveKey,_curveSide;NSOutlineView* _outline;NSArray* _nodes;VJMapCanvas* _canvas;NSPopUpButton* _projector;NSPopUpButton* _layout;NSPopUpButton* _target;NSTextField* _layoutName;NSTextField* _status;NSStackView* _inspector;NSStackView* _projectorTabs;NSStackView* _layoutTools;NSPopUpButton* _rotation;NSButton* _boundsGrid;NSButton* _outputEnabled;}
- (instancetype)initWithFrame:(NSRect)frame model:(vj::Model*)model{self=[super initWithFrame:frame];if(self){_model=model;_previewOwner="native-mapper-"+std::string(NSUUID.UUID.UUIDString.UTF8String);_mid=std::string(([[NSUserDefaults standardUserDefaults] stringForKey:@"VJMapperProjector"]?:@"1").UTF8String);_revision=UINT64_MAX;_visibilityRevision=UINT64_MAX;_selection=Json::array();_openSections=[NSMutableSet set];_collapsed=[NSMutableSet setWithArray:[[NSUserDefaults standardUserDefaults] arrayForKey:@"VJMapperCollapsed"]?:@[]];[self build];[self refresh];}return self;}
- (NSButton*)button:(NSString*)title action:(SEL)action{return vj::style::button(title,self,action);}
- (void)build {
    self.wantsLayer=YES;self.layer.backgroundColor=vj::style::panel().CGColor;
    auto root=stack(NSUserInterfaceLayoutOrientationVertical);root.spacing=0;root.translatesAutoresizingMaskIntoConstraints=NO;[self addSubview:root];
    [NSLayoutConstraint activateConstraints:@[[root.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],[root.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],[root.topAnchor constraintEqualToAnchor:self.topAnchor],[root.bottomAnchor constraintEqualToAnchor:self.bottomAnchor]]];
    auto bar=stack(NSUserInterfaceLayoutOrientationHorizontal);bar.spacing=6;bar.edgeInsets=NSEdgeInsetsMake(5,8,5,8);[root addArrangedSubview:bar];[bar.widthAnchor constraintEqualToAnchor:root.widthAnchor].active=YES;[bar.heightAnchor constraintEqualToConstant:58].active=YES;
    _projector=[[VJPopup alloc]initWithFrame:NSZeroRect pullsDown:NO];_projector.target=self;_projector.action=@selector(projector:);
    _projectorTabs=stack(NSUserInterfaceLayoutOrientationHorizontal);_projectorTabs.spacing=1;[bar addArrangedSubview:_projectorTabs];auto assign=[self button:@"Assign…" action:@selector(assignProjector:)];assign.toolTip=@"Assign selected projector";[bar addArrangedSubview:assign];
    [bar addArrangedSubview:[self button:@"Layouts ⌄" action:@selector(toggleLayouts:)]];
    _currentLayout=label(@"Custom mapping");_currentLayout.lineBreakMode=NSLineBreakByTruncatingTail;[_currentLayout.widthAnchor constraintLessThanOrEqualToConstant:180].active=YES;
    auto spacer=[[NSView alloc]init];[bar addArrangedSubview:spacer];[spacer.widthAnchor constraintGreaterThanOrEqualToConstant:4].active=YES;[spacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    _outputEnabled=[self button:@"Output" action:@selector(outputEnabled:)];_outputEnabled.buttonType=NSButtonTypePushOnPushOff;_outputEnabled.accessibilityLabel=@"Projector output enabled";[bar addArrangedSubview:_outputEnabled];
    _boundsGrid=[self button:@"Projector grid" action:@selector(boundsGrid:)];_boundsGrid.buttonType=NSButtonTypePushOnPushOff;[bar addArrangedSubview:_boundsGrid];
    _rotation=[[VJPopup alloc]initWithFrame:NSZeroRect pullsDown:NO];[_rotation addItemsWithTitles:@[@"0°",@"90°",@"180°",@"270°"]];_rotation.target=self;_rotation.action=@selector(rotation:);[bar addArrangedSubview:_rotation];[_rotation.widthAnchor constraintEqualToConstant:65].active=YES;[_rotation.heightAnchor constraintEqualToConstant:vj::style::controlHeight].active=YES;
    _layoutTools=vj::style::section(@"Layouts");
    auto saved=vj::style::propertyRow(@"Saved",64);[_layoutTools addArrangedSubview:saved];_layout=[[VJPopup alloc]initWithFrame:NSZeroRect pullsDown:NO];_layout.target=self;_layout.action=@selector(chosenLayout:);[saved addArrangedSubview:_layout];[_layout.widthAnchor constraintEqualToConstant:244].active=YES;[_layout.heightAnchor constraintEqualToConstant:vj::style::controlHeight].active=YES;
    auto loadActions=stack(NSUserInterfaceLayoutOrientationHorizontal);[_layoutTools addArrangedSubview:loadActions];_loadLayoutButton=[self button:@"Load" action:@selector(loadLayout:)];_updateLayoutButton=[self button:@"Update saved" action:@selector(updateLayout:)];[loadActions addArrangedSubview:_loadLayoutButton];[loadActions addArrangedSubview:_updateLayoutButton];
    auto name=vj::style::propertyRow(@"Name",64);[_layoutTools addArrangedSubview:name];_layoutName=[[NSTextField alloc]init];_layoutName.placeholderString=@"Layout name";[_layoutName.widthAnchor constraintEqualToConstant:244].active=YES;[_layoutName.heightAnchor constraintEqualToConstant:vj::style::controlHeight].active=YES;[name addArrangedSubview:_layoutName];
    auto saveActions=stack(NSUserInterfaceLayoutOrientationHorizontal);[_layoutTools addArrangedSubview:saveActions];[saveActions addArrangedSubview:[self button:@"Save as…" action:@selector(saveLayout:)]];auto layoutActions=[[VJPopup alloc]initWithFrame:NSZeroRect pullsDown:YES];_layoutActions=layoutActions;layoutActions.menu.autoenablesItems=NO;[layoutActions addItemWithTitle:@"Manage…"];for(NSArray* item in @[@[@"Rename",@"rename"],@[@"Delete",@"delete"],@[@"Import…",@"import"],@[@"Export…",@"export"]]){[layoutActions addItemWithTitle:item[0]];layoutActions.lastItem.representedObject=item[1];layoutActions.lastItem.target=self;layoutActions.lastItem.action=@selector(layoutAction:);}[saveActions addArrangedSubview:layoutActions];[layoutActions.heightAnchor constraintEqualToConstant:vj::style::controlHeight].active=YES;
    _layoutsPopover=vj::style::popover(_layoutTools,NSMakeSize(340,216));
    auto body=stack(NSUserInterfaceLayoutOrientationHorizontal);body.spacing=1;body.alignment=NSLayoutAttributeTop;body.wantsLayer=YES;body.layer.backgroundColor=vj::style::border().CGColor;[root addArrangedSubview:body];[body.widthAnchor constraintEqualToAnchor:root.widthAnchor].active=YES;[body.heightAnchor constraintGreaterThanOrEqualToConstant:390].active=YES;[body setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationVertical];
    auto sidebar=stack(NSUserInterfaceLayoutOrientationVertical);sidebar.spacing=0;sidebar.wantsLayer=YES;sidebar.layer.backgroundColor=vj::style::panel().CGColor;[body addArrangedSubview:sidebar];[sidebar.widthAnchor constraintEqualToConstant:280].active=YES;[sidebar.heightAnchor constraintEqualToAnchor:body.heightAnchor].active=YES;
    auto objectHeader=stack(NSUserInterfaceLayoutOrientationHorizontal);objectHeader.edgeInsets=NSEdgeInsetsMake(6,8,6,8);[sidebar addArrangedSubview:objectHeader];[objectHeader.widthAnchor constraintEqualToAnchor:sidebar.widthAnchor].active=YES;
    auto objects=label(@"Surfaces & overlays");objects.font=vj::style::font(12);[objectHeader addArrangedSubview:objects];[objects.widthAnchor constraintEqualToConstant:182].active=YES;[objectHeader addArrangedSubview:[self button:@"+ Add" action:@selector(addObjectMenu:)]];
    auto actions=stack(NSUserInterfaceLayoutOrientationHorizontal);actions.spacing=3;actions.edgeInsets=NSEdgeInsetsMake(0,8,6,8);[sidebar addArrangedSubview:actions];for(NSArray* item in @[@[@"Group",@"group:"],@[@"⋯",@"selectionMenu:"],@[@"Mute",@"mute:"],@[@"Delete",@"remove:"]])[actions addArrangedSubview:[self button:item[0] action:NSSelectorFromString(item[1])]];
    auto visibilityActions=stack(NSUserInterfaceLayoutOrientationHorizontal);visibilityActions.edgeInsets=NSEdgeInsetsMake(0,8,6,8);[sidebar addArrangedSubview:visibilityActions];_soloButton=[self button:@"Solo selected" action:@selector(soloMapper:)];_soloButton.buttonType=NSButtonTypePushOnPushOff;_showAllButton=[self button:@"Show all" action:@selector(showAllMapper:)];[visibilityActions addArrangedSubview:_soloButton];[visibilityActions addArrangedSubview:_showAllButton];
    auto scroll=[[NSScrollView alloc]init];scroll.hasVerticalScroller=YES;scroll.backgroundColor=vj::style::panel();_outline=[[VJMapOutline alloc]initWithFrame:NSMakeRect(0,0,220,300)];auto column=[[NSTableColumn alloc]initWithIdentifier:@"name"];column.width=200;column.minWidth=0;[_outline addTableColumn:column];_outline.autoresizingMask=NSViewWidthSizable;column.resizingMask=NSTableColumnAutoresizingMask;_outline.columnAutoresizingStyle=NSTableViewUniformColumnAutoresizingStyle;_outline.outlineTableColumn=column;_outline.headerView=nil;_outline.rowHeight=50;_outline.indentationPerLevel=12;_outline.style=NSTableViewStyleFullWidth;_outline.backgroundColor=vj::style::panel();_outline.allowsMultipleSelection=YES;_outline.dataSource=self;_outline.delegate=self;_outline.target=self;_outline.doubleAction=@selector(renameSelection:);scroll.documentView=_outline;[sidebar addArrangedSubview:scroll];[scroll.widthAnchor constraintEqualToAnchor:sidebar.widthAnchor].active=YES;[scroll.heightAnchor constraintGreaterThanOrEqualToConstant:200].active=YES;[scroll setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationVertical];
    _canvas=[[VJMapCanvas alloc]initWithFrame:NSMakeRect(0,0,600,420)];[body addArrangedSubview:_canvas];[_canvas.widthAnchor constraintGreaterThanOrEqualToConstant:240].active=YES;[_canvas.heightAnchor constraintEqualToAnchor:body.heightAnchor].active=YES;
    auto viewControls=stack(NSUserInterfaceLayoutOrientationHorizontal);viewControls.translatesAutoresizingMaskIntoConstraints=NO;[_canvas addSubview:viewControls];[NSLayoutConstraint activateConstraints:@[[viewControls.leadingAnchor constraintEqualToAnchor:_canvas.leadingAnchor constant:8],[viewControls.topAnchor constraintEqualToAnchor:_canvas.topAnchor constant:8]]];
    for(NSArray* spec in @[@[@"−",@"zoomOut:",@"Zoom out"],@[@"+",@"zoomIn:",@"Zoom in"],@[@"Fit selection",@"fitSelection:",@"Fit selection"]]){auto button=[self button:spec[0] action:NSSelectorFromString(spec[1])];button.toolTip=spec[2];button.accessibilityLabel=spec[2];if([spec[0]length]==1)[button.widthAnchor constraintEqualToConstant:30].active=YES;[viewControls addArrangedSubview:button];}
    [viewControls addArrangedSubview:[self button:@"Reset view" action:@selector(reset:)]];
    auto right=stack(NSUserInterfaceLayoutOrientationVertical);right.spacing=0;right.wantsLayer=YES;right.layer.backgroundColor=vj::style::panel().CGColor;[body addArrangedSubview:right];[right.widthAnchor constraintEqualToConstant:260].active=YES;[right.heightAnchor constraintEqualToAnchor:body.heightAnchor].active=YES;
    auto selectionHeader=label(@"Selection");selectionHeader.font=vj::style::font(12);auto header=stack(NSUserInterfaceLayoutOrientationHorizontal);header.edgeInsets=NSEdgeInsetsMake(10,8,10,8);[header addArrangedSubview:selectionHeader];[right addArrangedSubview:header];[header.heightAnchor constraintEqualToConstant:40].active=YES;
    auto inspectorScroll=[[NSScrollView alloc]init];inspectorScroll.hasVerticalScroller=YES;inspectorScroll.backgroundColor=vj::style::panel();_inspector=[[VJMapStack alloc]initWithFrame:NSMakeRect(0,0,260,500)];_inspector.translatesAutoresizingMaskIntoConstraints=NO;_inspector.orientation=NSUserInterfaceLayoutOrientationVertical;_inspector.alignment=NSLayoutAttributeLeading;_inspector.spacing=6;_inspector.edgeInsets=NSEdgeInsetsMake(8,10,12,10);inspectorScroll.documentView=_inspector;[right addArrangedSubview:inspectorScroll];[inspectorScroll.widthAnchor constraintEqualToAnchor:right.widthAnchor].active=YES;[_inspector.widthAnchor constraintEqualToAnchor:inspectorScroll.contentView.widthAnchor].active=YES;[inspectorScroll.heightAnchor constraintGreaterThanOrEqualToConstant:200].active=YES;[inspectorScroll setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationVertical];
    _editor=[[VJPreview alloc]initWithFrame:NSMakeRect(0,0,640,360) model:_model];[_editor setReadbackConsumer:_canvas];_projected=[[VJPreview alloc]initWithFrame:NSMakeRect(0,0,240,135) model:_model];
    _status=label(@"Geometry preview");auto statusLine=stack(NSUserInterfaceLayoutOrientationHorizontal);statusLine.edgeInsets=NSEdgeInsetsMake(0,8,0,8);[statusLine addArrangedSubview:_currentLayout];[statusLine addArrangedSubview:_status];[sidebar addArrangedSubview:statusLine];[statusLine.widthAnchor constraintEqualToAnchor:sidebar.widthAnchor].active=YES;[_status setContentCompressionResistancePriority:250 forOrientation:NSLayoutConstraintOrientationHorizontal];[_status.heightAnchor constraintEqualToConstant:vj::style::controlHeight].active=YES;__weak VJMapper* weak=self;_canvas.placeBox=^BOOL(const Json& centers){VJMapper* owner=weak;if(!owner)return NO;BOOL ok=[owner send:@"POST" action:@"collections" body:{{"kind","boxes"},{"faceCenters",centers}}];owner->_canvas->mapping=owner->_map;return ok;};_canvas.placeCircle=^BOOL(const Json& center,double radius){VJMapper* owner=weak;if(!owner)return NO;
        Json points=Json::array();bool existing=false;for(const auto& c:owner->_map["project"]["collections"])if(c["id"]==owner->_circleCollection&&c.value("kind",std::string{})=="points"){points=c["points"];existing=true;}
        Json point={{"id","circle-"+std::string(NSUUID.UUID.UUIDString.UTF8String).substr(0,8)},{"name","Circle "+std::to_string(points.size()+1)},{"position",center},{"radius",radius}};points.push_back(point);
        BOOL ok=existing?[owner send:@"PATCH" action:[@"collections/" stringByAppendingString:ms(owner->_circleCollection)] body:{{"points",points}}]:[owner send:@"POST" action:@"collections" body:{{"kind","points"},{"name","Circles"},{"shape","circle"},{"radius",radius},{"points",points}}];
        if(ok&&!existing)for(const auto& c:owner->_map["project"]["collections"])if(c.value("kind",std::string{})=="points")for(const auto& p:c["points"])if(p["id"]==point["id"])owner->_circleCollection=c["id"].get<std::string>();
        owner->_canvas->mapping=owner->_map;return ok;};_canvas.placementStatus=^(NSString* status){VJMapper* owner=weak;if(owner)owner->_status.stringValue=status;};_canvas.placeSurface=^BOOL(const Json& corners){VJMapper* owner=weak;if(!owner)return NO;BOOL ok=[owner send:@"POST" action:@"rects" body:{{"name","Surface"},{"corners",corners},{"mode","grid"},{"graphic","wireframe"},{"config",{{"color","#ffffff"},{"thickness",3}}}}];owner->_canvas->mapping=owner->_map;return ok;};_canvas.selection=^(const Json& ids){VJMapper* owner=weak;if(!owner)return;owner->_revealSelectionPending=YES;[owner select:ids];[owner revealSidebarSelection];};_canvas.traceSelection=^(const Json& id){VJMapper* owner=weak;if(!owner)return;owner->_revealSelectionPending=YES;[owner selectTrace:id];[owner revealSidebarSelection];};_canvas.traceGeometry=^(const Json& id,const Json& points){[weak send:@"PATCH" action:ms("traces/"+id.get<std::string>()) body:{{"points",points}}];};_canvas.geometryPreview=^(const Json& project,uint64_t revision){[weak previewProject:project revision:revision];};_canvas.markerPreview=^(const Json& markers,uint64_t revision){VJMapper* owner=weak;if(!owner)return;owner->_previewMid=owner->_mid;VJSubmitUiCommand(owner->_model,"POST","/api/v1/mappings/"+owner->_mid+"/preview",{{"_owner",owner->_previewOwner},{"clientId",owner->_previewOwner},{"baseRevision",revision},{"markers",markers}},nil,"mapper-preview:"+owner->_mid+":"+std::to_string(revision));};_canvas.clearPreview=^{[weak clearProjectedPreview];};_canvas.geometry=^(const Json& rects){VJMapper* owner=weak;if(!owner)return;[owner applyGeometry:rects];};_canvas.curveEdgeSelection=^(const std::string& side){VJMapper* owner=weak;if(owner){owner->_curveSide=side;[owner->_openSections addObject:@"Curvature"];[owner inspect];}};_canvas.surfaceProperty=^(const Json& id,const Json& patch){[weak send:@"PATCH" action:ms("rects/"+id.get<std::string>()) body:patch];};_canvas.collectionProperty=^(const Json& id,const Json& patch){[weak send:@"PATCH" action:ms("collections/"+id.get<std::string>()) body:patch];};_canvas.translation=^(const Json& ids,const Json& delta){[weak send:@"POST" action:@"move-surfaces" body:{{"rectIds",ids},{"offset",delta}}];};_canvas.removeSelection=^{[weak remove:nil];};_canvas.history=^(BOOL redo){if(redo)[weak redo:nil];else [weak undo:nil];};_canvas.contextMenu=^NSMenu*(NSEvent* event){return [weak canvasMenu:event];};((VJMapOutline*)_outline).contextMenu=^NSMenu*(NSEvent* event){return [weak sidebarMenu:event];};_canvasTimer=[NSTimer timerWithTimeInterval:1./15 repeats:YES block:^(NSTimer*){[weak editorTick];}];[[NSRunLoop mainRunLoop] addTimer:_canvasTimer forMode:NSRunLoopCommonModes];
}
- (NSView*)layoutPopoverView {return _layoutTools;}
- (void)zoomIn:(id)sender {(void)sender;[_canvas zoomBy:1.4];}
- (void)zoomOut:(id)sender {(void)sender;[_canvas zoomBy:1./1.4];}
- (void)fitSelection:(id)sender {(void)sender;[_canvas fitSelection];}
- (void)toggleLayouts:(NSButton*)sender {if(_layoutsPopover.shown)[_layoutsPopover close];else [_layoutsPopover showRelativeToRect:sender.bounds ofView:sender preferredEdge:NSRectEdgeMaxY];}
- (void)assignProjector:(id)sender {(void)sender;if(self.outputAction)self.outputAction(ms(_mid));}
- (void)projectorTab:(NSButton*)sender {for(NSMenuItem* item in _projector.itemArray)if([item.representedObject isEqual:sender.identifier]){[_projector selectItem:item];break;}[self projector:nil];}
- (NSMenu*)creationMenu {
    auto menu=[[NSMenu alloc]initWithTitle:@"Add object"];
    for(NSArray* spec in @[@[@"Place surface",@"placeSurface:",@""],@[@"Place box",@"placeBox:",@""],@[@"Place circle",@"placeCircle:",@""],@[@"Surface",@"addSurface:",@""],@[@"Hemisphere",@"addHemisphere:",@""],@[@"Surface collection",@"createCollection:",@"planar"],@[@"Points",@"createCollection:",@"points"],@[@"Box",@"createCollection:",@"boxes"],@[@"Box stack",@"createCollection:",@"stack"],@[@"Overlay",@"addOverlay:",@""],@[@"Trace",@"addTrace:",@""]]){auto item=[[NSMenuItem alloc]initWithTitle:spec[0] action:NSSelectorFromString(spec[1]) keyEquivalent:@""];item.target=self;item.representedObject=spec[2];[menu addItem:item];}
    return menu;
}
- (void)addObjectMenu:(NSButton*)sender {[[self creationMenu] popUpMenuPositioningItem:nil atLocation:NSMakePoint(0,-3) inView:sender];}
- (void)selectionMenu:(NSButton*)sender {auto menu=[[NSMenu alloc]initWithTitle:@"Selection actions"];for(NSArray* spec in @[@[@"Scale & rotate",@"quickTransform:"],@[@"Duplicate",@"duplicate:"],@[@"Ungroup",@"ungroup:"],@[@"Rename…",@"renameSelection:"]]){auto item=[[NSMenuItem alloc]initWithTitle:spec[0] action:NSSelectorFromString(spec[1]) keyEquivalent:@""];item.target=self;[menu addItem:item];}[menu addItem:[NSMenuItem separatorItem]];[self addArrangeItems:menu];[menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0,-3) inView:sender];}
- (void)propertyRow:(NSString*)title control:(NSControl*)control {
    auto row=stack(NSUserInterfaceLayoutOrientationHorizontal);row.spacing=vj::style::gap;auto name=vj::style::label(title,YES);name.toolTip=title;[name.widthAnchor constraintEqualToConstant:vj::style::inspectorLabel].active=YES;[row addArrangedSubview:name];[row addArrangedSubview:control];[control.heightAnchor constraintEqualToConstant:vj::style::controlHeight].active=YES;[control.widthAnchor constraintEqualToAnchor:row.widthAnchor constant:-(vj::style::inspectorLabel+vj::style::gap)].active=YES;[_inspector addArrangedSubview:row];[row.widthAnchor constraintEqualToAnchor:_inspector.widthAnchor constant:-20].active=YES;[row.heightAnchor constraintEqualToConstant:vj::style::propertyHeight].active=YES;control.font=vj::style::font();control.accessibilityLabel=title;
}
- (void)previewProject:(const Json&)project revision:(uint64_t)revision {
    _previewMid=_mid;
    VJSubmitUiCommand(_model,"POST","/api/v1/mappings/"+_mid+"/preview",{{"_owner",_previewOwner},{"clientId",_previewOwner},{"baseRevision",revision},{"project",project}},nil,"mapper-preview:"+_mid+":"+std::to_string(revision));
}
- (void)clearProjectedPreview {
    if(_previewMid.empty())return;
    // Ordered after queued previews, so a cancelled drag cannot reappear later.
    VJSubmitUiCommand(_model,"DELETE","/api/v1/mappings/"+_previewMid+"/preview",{{"_owner",_previewOwner}},nil);_previewMid.clear();
}
- (BOOL)send:(NSString*)method action:(NSString*)action body:(Json)body{body["revision"]=_map["revision"];auto result=_model->request(method.UTF8String,"/api/v1/mappings/"+_mid+"/"+action.UTF8String,body);if(result.status>=300){auto error=ms(result.body.value("error",std::string("Command failed")));_inspectorSignature.clear();_revision=UINT64_MAX;[self refresh];_status.stringValue=error;_canvas->mapping=_map;[_canvas setNeedsDisplay:YES];return NO;}_map=_model->snapshot()["mappings"][_mid];_revision=UINT64_MAX;if(result.body.contains("traceId")&&[method isEqualToString:@"POST"])[self selectTrace:result.body["traceId"]];else if(result.body.contains("rectId"))[self select:Json::array({result.body["rectId"]})];else if(result.body.contains("collectionId")){Json ids=Json::array();for(const auto& c:_map["project"]["collections"])if(c["id"]==result.body["collectionId"])for(const auto& f:c["faces"])ids.push_back(f["rectId"]);if([method isEqualToString:@"POST"]&&!ids.empty())[self select:ids];else [self refresh];}else [self refresh];return YES;}
// Reveal only on deliberate canvas selection, never on periodic refresh.
- (void)collectSidebarSelection:(NSArray*)nodes ancestors:(NSArray*)ancestors paths:(NSMutableArray*)paths {
    for(NSDictionary* node in nodes){
        NSArray* ids=node[@"ids"];BOOL match=NO;
        if(!_trace.empty())match=[node[@"kind"] isEqual:@"trace"]&&_trace==[node[@"id"] UTF8String];
        else if(ids.count){match=YES;for(NSString* id in ids)match&=has(_selection,std::string(id.UTF8String));if(ids.count==1&&[node[@"children"] count])match=NO;}
        NSArray* path=[ancestors arrayByAddingObject:node];
        if(match)[paths addObject:path];else if([node[@"children"] count])[self collectSidebarSelection:node[@"children"] ancestors:path paths:paths];
    }
}
- (void)revealSidebarSelection {
    NSMutableArray* paths=[NSMutableArray array];[self collectSidebarSelection:_nodes ancestors:@[] paths:paths];
    BOOL refreshing=_refreshing;_refreshing=YES;
    for(NSArray* path in paths)for(NSUInteger i=0;i+1<path.count;i++){NSDictionary* parent=path[i];[_collapsed removeObject:[self expansionKey:parent]];[_outline expandItem:parent];}
    NSMutableIndexSet* rows=[NSMutableIndexSet indexSet];NSInteger anchor=-1;
    for(NSArray* path in paths){NSDictionary* node=path.lastObject;NSInteger row=[_outline rowForItem:node];if(row<0)continue;[rows addIndex:row];if(anchor<0)anchor=row;if(!_selection.empty())for(NSString* id in node[@"ids"])if(_selection.back()==std::string(id.UTF8String))anchor=row;}
    [_outline selectRowIndexes:rows byExtendingSelection:NO];
    if(anchor>=0)[_outline scrollRowToVisible:anchor];
    _refreshing=refreshing;if(paths.count)[[NSUserDefaults standardUserDefaults] setObject:_collapsed.allObjects forKey:@"VJMapperCollapsed"];
}
- (void)select:(const Json&)ids{_selection=ids;if(ids.size()!=1||ids[0]!=_canvas->addingPin)_canvas->addingPin.clear();_trace.clear();_canvas->selectedTrace=nullptr;[self resolveOwner];[self updateMapperVisibilityControls];_canvas->selected=visibleMapperSelection(_map,ids);[_canvas setNeedsDisplay:YES];[self inspect];auto mid=_mid;auto generation=++_selectionGeneration;_selectionPending=YES;__weak VJMapper* weak=self;VJSubmitUiCommand(_model,"PUT","/api/v1/mappings/"+mid+"/selection",{{"rectIds",ids}},^(const vj::Reply& reply){VJMapper* owner=weak;if(!owner||owner->_mid!=mid||owner->_selectionGeneration!=generation)return;owner->_selectionPending=NO;if(reply.status>=300)owner->_status.stringValue=ms(reply.body.value("error",std::string("Selection failed")));owner->_revision=UINT64_MAX;[owner refresh];});}
- (void)selectTrace:(const Json&)id {_trace=id.is_string()?id.get<std::string>():"";_canvas->addingPin.clear();_selection=Json::array();_canvas->selected=Json::array();_canvas->selectedTrace=vj::mappingEditorVisible(_map,id,true)?id:Json();_collection.clear();_box.clear();_point.clear();[self updateMapperVisibilityControls];[_canvas setNeedsDisplay:YES];[self inspect];auto mid=_mid;auto generation=++_selectionGeneration;_selectionPending=YES;__weak VJMapper* weak=self;VJSubmitUiCommand(_model,"PUT","/api/v1/mappings/"+mid+"/selection",{{"traceId",id}},^(const vj::Reply& reply){VJMapper* owner=weak;if(!owner||owner->_mid!=mid||owner->_selectionGeneration!=generation)return;owner->_selectionPending=NO;if(reply.status>=300)owner->_status.stringValue=ms(reply.body.value("error",std::string("Selection failed")));owner->_revision=UINT64_MAX;[owner refresh];});}
- (void)refresh{if(_curveTracking||_selectionPending)return;auto sharedSnapshot=_model->presentationSnapshotShared();const auto& snapshot=*sharedSnapshot;if(snapshot["revision"]==_revision&&snapshot.value("editorVisibilityRevision",uint64_t{})==_visibilityRevision)return;if([_canvas interacting])return;BOOL editing=[self.window.firstResponder isKindOfClass:[NSTextView class]]&&((NSTextView*)self.window.firstResponder).isFieldEditor;if(editing)return;_snapshot=snapshot;_revision=snapshot["revision"];_visibilityRevision=snapshot.value("editorVisibilityRevision",uint64_t{});if(!snapshot["mappings"].contains(_mid))_mid=snapshot["mappings"].begin().key();_map=snapshot["mappings"][_mid];[_projected setMapping:ms(_mid)];[_editor setMapping:ms(_mid)];_selection=_map.value("selectedRectIds",Json::array());auto selectedTrace=_map["project"].value("selectedTraceId",Json());_trace=selectedTrace.is_string()?selectedTrace.get<std::string>():"";_canvas->selectedTrace=vj::mappingEditorVisible(_map,selectedTrace,true)?selectedTrace:Json();_canvas->mapping=_map;_canvas->selected=visibleMapperSelection(_map,_selection);if(_selection.size()!=1||_selection[0]!=_canvas->addingPin)_canvas->addingPin.clear();if(_selection.size()!=1||_selection[0]!=_canvas->positioningContent)_canvas->positioningContent.clear();for(const auto& rect:_map["project"]["rects"])if(rect["id"]==_canvas->positioningContent&&(rect.value("kind",std::string("surface"))=="overlay"?rect.value("fit",std::string("stretch"))!="fill":rect.value("contentFit",std::string("inherit"))!="cover"))_canvas->positioningContent.clear();[_canvas setNeedsDisplay:YES];_refreshing=YES;
    [_projector removeAllItems];for(auto it=snapshot["mappings"].begin();it!=snapshot["mappings"].end();++it){[_projector addItemWithTitle:ms("Projector "+it.key())];_projector.lastItem.representedObject=ms(it.key());if(it.key()==_mid)[_projector selectItem:_projector.lastItem];}
    if(_projectorTabs.arrangedSubviews.count!=_projector.itemArray.count){for(NSView* view in [_projectorTabs.arrangedSubviews copy]){[_projectorTabs removeArrangedSubview:view];[view removeFromSuperview];}for(NSUInteger index=0;index<_projector.itemArray.count;++index){auto tab=[[VJProjectorTab alloc]init];tab.target=self;tab.action=@selector(projectorTab:);tab.buttonType=NSButtonTypePushOnPushOff;auto width=[tab.widthAnchor constraintEqualToConstant:122];width.priority=749;width.active=YES;[tab.widthAnchor constraintGreaterThanOrEqualToConstant:84].active=YES;[tab.heightAnchor constraintEqualToConstant:46].active=YES;[_projectorTabs addArrangedSubview:tab];}}
    for(NSUInteger i=0;i<_projector.itemArray.count;++i){auto item=_projector.itemArray[i];auto tab=(VJProjectorTab*)_projectorTabs.arrangedSubviews[i];tab.title=item.title;tab.identifier=item.representedObject;tab.destination=projectorDestination(snapshot["state"],[item.representedObject UTF8String]);tab.toolTip=[NSString stringWithFormat:@"%@ — %@",item.title,tab.destination];tab.accessibilityLabel=tab.toolTip;tab.state=item==_projector.selectedItem?NSControlStateValueOn:NSControlStateValueOff;tab.needsDisplay=YES;}
    _outputEnabled.state=_map["project"]["output"].value("enabled",true)?NSControlStateValueOn:NSControlStateValueOff;_outputEnabled.title=_outputEnabled.state==NSControlStateValueOn?@"Output on":@"Output off";[_rotation selectItemAtIndex:_map["project"]["output"].value("rotation",0)/90];_boundsGrid.state=_map["project"]["output"].value("boundsGrid",false)?NSControlStateValueOn:NSControlStateValueOff;
    if(_layouts!=snapshot["mappingLayouts"]){_layouts=snapshot["mappingLayouts"];NSString* previous=_layout.selectedItem.representedObject;[_layout removeAllItems];[_layout addItemWithTitle:@"Unsaved"];_layout.lastItem.representedObject=@"";for(const auto& layout:_layouts.value("layouts",Json::array())){[_layout addItemWithTitle:ms(layout["name"])];_layout.lastItem.representedObject=ms(layout["id"]);if([previous isEqualToString:ms(layout["id"])])[_layout selectItem:_layout.lastItem];}
    }
    std::string activeKey=_mid+":";if(_map.contains("layout")&&!_map["layout"].is_null()){const auto& layout=_map["layout"];activeKey+=layout["id"].get<std::string>();_currentLayout.stringValue=ms(layout["name"].get<std::string>()+(layout.value("modified",false)?" · Edited":""));if(activeKey!=_loadedLayoutKey){_layoutName.stringValue=ms(layout["name"]);for(NSMenuItem* item in _layout.itemArray)if([item.representedObject isEqualToString:ms(layout["id"])])[_layout selectItem:item];}}else{_currentLayout.stringValue=@"Custom mapping";if(activeKey!=_loadedLayoutKey)_layoutName.stringValue=@"";}_loadedLayoutKey=activeKey;[self updateLayoutActions];
    [self rebuildOutline];if(_revealSelectionPending){[self revealSidebarSelection];_revealSelectionPending=NO;}_refreshing=NO;[self resolveOwner];
    [self inspect];_status.stringValue=[NSString stringWithFormat:@"  %lu selected",(unsigned long)_selection.size()];vj::style::apply(self);
}
- (NSInteger)outlineView:(NSOutlineView*)view numberOfChildrenOfItem:(id)item{(void)view;return item?[item[@"children"] count]:_nodes.count;}
- (id)outlineView:(NSOutlineView*)view child:(NSInteger)index ofItem:(id)item{(void)view;return item?item[@"children"][index]:_nodes[index];}
- (BOOL)outlineView:(NSOutlineView*)view isItemExpandable:(id)item{(void)view;return [item[@"children"] count]>0;}
- (NSView*)outlineView:(NSOutlineView*)view viewForTableColumn:(NSTableColumn*)column item:(id)item {
    (void)view;(void)column;auto cell=[[VJMapObjectCell alloc]initWithFrame:NSMakeRect(0,0,260,50)];cell.item=item;
    auto field=[[VJMapName alloc]init];field.stringValue=item[@"name"];field.item=item;field.editable=NO;field.selectable=NO;field.bordered=NO;field.drawsBackground=NO;field.lineBreakMode=NSLineBreakByTruncatingTail;field.font=vj::style::font(12);field.toolTip=item[@"name"];field.target=self;field.action=@selector(rename:);cell.name=field;[cell addSubview:field];
    cell.detail=label(item[@"detail"]?:@"");cell.detail.lineBreakMode=NSLineBreakByTruncatingTail;[cell addSubview:cell.detail];
    for(NSString* title in @[@"M",@"⋯"]){auto button=[[VJMapNodeButton alloc]init];button.title=title;button.item=item;button.target=self;button.action=[title isEqual:@"M"]?@selector(rowMute:):@selector(rowMenu:);button.bezelStyle=NSBezelStyleSmallSquare;button.font=vj::style::font(12);[cell addSubview:button];if([title isEqual:@"M"]){cell.mute=button;button.buttonType=NSButtonTypePushOnPushOff;button.state=[item[@"muted"] boolValue]?NSControlStateValueOn:NSControlStateValueOff;button.hidden=![item[@"canMute"] boolValue];button.toolTip=[item[@"muted"] boolValue]?@"Unmute projector output":@"Mute projector output";}else {cell.more=button;button.toolTip=@"Object actions";}button.accessibilityLabel=[NSString stringWithFormat:@"%@ %@",button.toolTip,item[@"name"]];}
    auto eye=[[VJMapNodeButton alloc]init];eye.item=item;eye.target=self;eye.action=@selector(rowVisibility:);eye.bezelStyle=NSBezelStyleSmallSquare;eye.image=[NSImage imageWithSystemSymbolName:[item[@"mapperHidden"] boolValue]?@"eye.slash":@"eye" accessibilityDescription:nil];eye.imagePosition=NSImageOnly;eye.toolTip=[item[@"mapperHidden"] boolValue]?@"Show in Mapper":@"Hide in Mapper";eye.accessibilityLabel=[NSString stringWithFormat:@"%@ %@",eye.toolTip,item[@"name"]];eye.enabled=[item[@"ids"] count]>0||[item[@"kind"] isEqual:@"trace"];cell.eye=eye;[cell addSubview:eye];cell.name.alphaValue=cell.detail.alphaValue=[item[@"mapperHidden"] boolValue]?.4:1.;return cell;
}
- (void)rowMenu:(VJMapNodeButton*)sender {[[self objectMenu:sender.item] popUpMenuPositioningItem:nil atLocation:NSMakePoint(0,-3) inView:sender];}
- (void)changeMapperVisibility:(Json)body {
    auto mid=_mid;__weak VJMapper* weak=self;VJSubmitUiCommand(_model,"POST","/api/v1/mappings/"+mid+"/editor-visibility",body,^(const vj::Reply& reply){VJMapper* owner=weak;if(!owner||owner->_mid!=mid)return;if(reply.status>=300)owner->_status.stringValue=ms(reply.body.value("error",std::string("Visibility failed")));owner->_visibilityRevision=UINT64_MAX;[owner refresh];});
}
- (void)nodeMapperVisibility:(NSDictionary*)node solo:(BOOL)solo {Json ids=Json::array(),traces=Json::array();for(NSString* id in node[@"ids"])ids.push_back(id.UTF8String);if([node[@"kind"] isEqual:@"trace"])traces.push_back([node[@"id"] UTF8String]);[self changeMapperVisibility:{{"action",solo?"solo":[node[@"mapperHidden"] boolValue]?"show":"hide"},{"rectIds",ids},{"traceIds",traces}}];}
- (void)rowVisibility:(VJMapNodeButton*)sender {[self nodeMapperVisibility:sender.item solo:NO];}
- (void)contextVisibility:(NSMenuItem*)sender {[self nodeMapperVisibility:sender.representedObject solo:NO];}
- (void)contextSolo:(NSMenuItem*)sender {[self nodeMapperVisibility:sender.representedObject solo:YES];}
- (void)soloMapper:(id)sender {(void)sender;auto state=_map.value("editorVisibility",Json::object());if(state.value("solo",false))[self changeMapperVisibility:{{"action","clear_solo"}}];else [self changeMapperVisibility:{{"action","solo"},{"rectIds",_selection},{"traceIds",_trace.empty()?Json::array():Json::array({_trace})}}];}
- (void)showAllMapper:(id)sender {(void)sender;[self changeMapperVisibility:{{"action","show_all"}}];}
- (void)updateMapperVisibilityControls {auto state=_map.value("editorVisibility",Json::object());BOOL solo=state.value("solo",false);_soloButton.title=solo?@"Exit solo":@"Solo selected";_soloButton.state=solo?NSControlStateValueOn:NSControlStateValueOff;_soloButton.enabled=solo||!_selection.empty()||!_trace.empty();_showAllButton.enabled=solo||!state.value("hiddenRectIds",Json::array()).empty()||!state.value("hiddenTraceIds",Json::array()).empty();}
- (void)rowMute:(VJMapNodeButton*)sender {
    NSDictionary* node=sender.item;BOOL muted=[node[@"muted"] boolValue];NSString* kind=node[@"kind"];
    if([kind isEqual:@"collection"]||[kind isEqual:@"trace"]){[self send:@"PATCH" action:[NSString stringWithFormat:@"%@/%@",[kind isEqual:@"collection"]?@"collections":@"traces",node[@"id"]] body:{{"enabled",bool(muted)}}];}
    else for(const auto& rect:_map["project"]["rects"])if(rect["id"]==std::string([node[@"id"] UTF8String])){Json patch={{"source",muted?rect.value("mutedSource",std::string("out1")):"none"}};Json operation={{"method","PATCH"},{"action","rects/"+std::string([node[@"id"] UTF8String])},{"body",patch}};[self send:@"POST" action:@"batch" body:{{"operations",Json::array({operation})}}];break;}
}

- (void)outlineViewSelectionDidChange:(NSNotification*)note{(void)note;if(_refreshing)return;_revealSelectionPending=NO;NSDictionary* clicked=_outline.selectedRow>=0?[_outline itemAtRow:_outline.selectedRow]:nil;if([clicked[@"kind"] isEqualToString:@"trace"]){[self selectTrace:Json([clicked[@"id"] UTF8String])];return;}__block Json ids=Json::array();[_outline.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger index,BOOL* stop){(void)stop;NSDictionary* node=[self->_outline itemAtRow:index];for(NSString* id in node[@"ids"])if(!has(ids,std::string(id.UTF8String)))ids.push_back(id.UTF8String);}];[self select:ids];}
- (void)rename:(VJMapName*)sender{sender.editable=NO;NSString* kind=sender.item[@"kind"];if([kind isEqualToString:@"box"]||[kind isEqualToString:@"point"]){std::string cid=[sender.item[@"collection"] UTF8String],id=[sender.item[@"id"] UTF8String],key=[kind isEqualToString:@"box"]?"boxes":"points";for(const auto& c:_map["project"]["collections"])if(c["id"]==cid){auto values=c[key];for(auto& value:values)if(value["id"]==id)value["name"]=sender.stringValue.UTF8String;[self send:@"PATCH" action:ms("collections/"+cid) body:{{key,values}}];}return;}NSString* route=[kind isEqualToString:@"trace"]?@"traces":[kind isEqualToString:@"group"]?@"groups":[kind isEqualToString:@"collection"]?@"collections":@"rects";[self send:@"PATCH" action:[NSString stringWithFormat:@"%@/%@",route,sender.item[@"id"]] body:{{"name",sender.stringValue.UTF8String}}];}
- (Json)mixed:(const std::string&)key{Json result;bool first=true;for(const auto& r:_map["project"]["rects"])if(has(_selection,r["id"])){Json value=r.value(key,key=="graphic"?Json("grid"):key=="contentFit"?Json("inherit"):Json());if(first){result=value;first=false;}else if(result!=value)return nullptr;}return result;}
- (void)popup:(NSString*)title key:(NSString*)key values:(NSArray*)values{auto popup=[[VJPopup alloc] initWithFrame:NSZeroRect pullsDown:NO];popup.identifier=key;if([key isEqualToString:@"source"])popup.toolTip=@"⌘1–9: Out 1–9 · ⌘0: Out 10 · ⇧⌘1–0: Out 11–20";if([key isEqualToString:@"fit"]||[key isEqualToString:@"kind"]){for(const auto& c:_map["project"].value("collections",Json::array()))for(const auto& f:c["faces"])if(has(_selection,f["rectId"]))popup.enabled=NO;}popup.target=self;popup.action=@selector(property:);auto current=[self mixed:key.UTF8String];if(current.is_null()){[popup addItemWithTitle:@"Mixed"];popup.lastItem.representedObject=nil;}for(NSString* value in values){[popup addItemWithTitle:([key isEqualToString:@"mode"]&&[value isEqualToString:@"grid"])?@"pattern":value];popup.lastItem.representedObject=value;if(!current.is_null()&&current.is_string()&&[value isEqualToString:ms(current)]) [popup selectItem:popup.lastItem];}[self propertyRow:title control:popup];}
- (BOOL)section:(NSString*)title {BOOL open=[_openSections containsObject:title];auto button=vj::style::disclosure(title,open,self,@selector(toggleSection:));button.identifier=title;button.toolTip=[NSString stringWithFormat:@"%@ %@",open?@"Collapse":@"Expand",title];button.accessibilityLabel=button.toolTip;[_inspector addArrangedSubview:button];[button.widthAnchor constraintEqualToAnchor:_inspector.widthAnchor constant:-20].active=YES;return open;}
- (void)toggleSection:(NSButton*)sender {[_patternColor deactivate];if([_openSections containsObject:sender.identifier])[_openSections removeObject:sender.identifier];else [_openSections addObject:sender.identifier];[self inspect];[self layoutSubtreeIfNeeded];}
- (void)inspect {
    const auto selectionKey=_mid+":"+_collection+":"+_box+":"+_point+":"+_trace+":"+_selection.dump();
    if(_patternColor.isActive){if(selectionKey==_inspectorSelectionKey)return;[_patternColor deactivate];}
    Json context={{"selection",selectionKey},{"outputs",_snapshot["state"]["grid"]["running"].size()},{"projectors",_snapshot["mappings"].size()},{"curveSide",_curveSide},{"positioningContent",_canvas->positioningContent}};
    context["rects"]=Json::array();for(const auto& rect:_map["project"]["rects"])if(has(_selection,rect["id"]))context["rects"].push_back(rect);
    if(!_collection.empty())for(const auto& collection:_map["project"]["collections"])if(collection["id"]==_collection)context["collection"]=collection;
    if(!_trace.empty()){for(const auto& trace:_map["project"]["traces"])if(trace["id"]==_trace)context["trace"]=trace;context["fixtures"]=_snapshot["state"].value("fixtures",Json::array());}
    context["sections"]=Json::array();for(NSString* section in [[_openSections allObjects]sortedArrayUsingSelector:@selector(compare:)])context["sections"].push_back(section.UTF8String);
    auto signature=context.dump();if(signature==_inspectorSignature)return;
    _inspectorSignature=signature;_inspectorSelectionKey=selectionKey;++_inspectorBuilds;
    auto previous=_inspector;auto scroll=previous.enclosingScrollView;auto origin=scroll.contentView.bounds.origin;
    auto next=[[VJMapStack alloc]initWithFrame:previous.frame];next.translatesAutoresizingMaskIntoConstraints=NO;next.orientation=NSUserInterfaceLayoutOrientationVertical;next.alignment=NSLayoutAttributeLeading;next.spacing=vj::style::gap;next.edgeInsets=previous.edgeInsets;_inspector=next;_patternColor=nil;_target=nil;
    [self buildInspector];vj::style::apply(next);
    auto retained=(NSStackView*)VJReconcileView(previous,next);
    [NSAnimationContext beginGrouping];NSAnimationContext.currentContext.duration=0;NSAnimationContext.currentContext.allowsImplicitAnimation=NO;
    _inspector=retained;if(retained==previous){++_inspectorReuses;std::function<void(NSView*)> find=[&](NSView* view){if([view isKindOfClass:VJFlatColorWell.class])_patternColor=(VJFlatColorWell*)view;if([view.identifier isEqual:@"send-projector"])_target=(NSPopUpButton*)view;for(NSView* child in view.subviews)find(child);};find(retained);}else{scroll.documentView=retained;[retained.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor].active=YES;}
    [scroll layoutSubtreeIfNeeded];CGFloat maximum=MAX(0,NSHeight(retained.frame)-NSHeight(scroll.contentView.bounds));origin.y=std::clamp(origin.y,0.,maximum);[scroll.contentView scrollToPoint:origin];[scroll reflectScrolledClipView:scroll.contentView];[NSAnimationContext endGrouping];
}
- (void)modeChoices {
 auto mode=[self mixed:"mode"];auto row=stack(NSUserInterfaceLayoutOrientationHorizontal);row.identifier=@"surface-mode-row";row.spacing=4;
 auto group=vj::style::choiceGroup(@[@"Live",@"Pattern"],@[@"live",@"grid"],mode.is_string()?ms(mode):nil,self,@selector(modeChoice:));group.identifier=@"surface-mode";group.toolTip=@"⌘L: toggle Live / Pattern";for(NSButton* button in group.arrangedSubviews){button.toolTip=group.toolTip;button.accessibilityLabel=[@"Surface mode: " stringByAppendingString:button.title];}[row addArrangedSubview:group];[group.widthAnchor constraintEqualToConstant:132].active=YES;
 auto chooser=[[VJPopup alloc]initWithFrame:NSZeroRect pullsDown:NO];chooser.identifier=@"graphic";chooser.target=self;chooser.action=@selector(property:);chooser.accessibilityLabel=@"Alignment pattern";chooser.toolTip=@"Alignment pattern";chooser.enabled=mode!="live";
 auto graphic=[self mixed:"graphic"];bool boxes=false;for(auto& c:_map["project"].value("collections",Json::array()))if(c["id"]==_collection&&c["kind"]=="boxes"){boxes=true;if(!c.value("patternStyleExplicit",false))graphic="faces";}
 if(graphic.is_null()){[chooser addItemWithTitle:@"Mixed"];chooser.lastItem.enabled=NO;}
 for(NSArray* option in @[@[@"Solid",@"solid"],@[@"Grid",@"grid"],@[@"Outline",@"wireframe"],@[@"Alignment",@"alignment"]]){[chooser addItemWithTitle:option[0]];chooser.lastItem.representedObject=option[1];if(graphic==std::string([option[1] UTF8String]))[chooser selectItem:chooser.lastItem];}
 if(boxes){[chooser addItemWithTitle:@"Face colors"];chooser.lastItem.representedObject=@"faces";if(graphic=="faces")[chooser selectItem:chooser.lastItem];}
 [row addArrangedSubview:chooser];[chooser.widthAnchor constraintGreaterThanOrEqualToConstant:96].active=YES;[chooser.heightAnchor constraintEqualToConstant:36].active=YES;[_inspector addArrangedSubview:row];[row.widthAnchor constraintEqualToAnchor:_inspector.widthAnchor constant:-20].active=YES;
}
- (void)modeChoice:(NSButton*)sender {for(NSButton* button in ((NSStackView*)sender.superview).arrangedSubviews)button.state=button==sender?NSControlStateValueOn:NSControlStateValueOff;[self applySelectionProperty:"mode" value:std::string(sender.identifier.UTF8String)];}
- (BOOL)canUseObjectClipboard {return !self.isHiddenOrHasHiddenAncestor&&!self.window.attachedSheet&&![self.window.firstResponder isKindOfClass:NSTextView.class];}
- (void)copy:(id)sender {
    (void)sender;if(![self canUseObjectClipboard]||(_selection.empty()&&_trace.empty()))return;
    try{auto payload=vj::captureMappingClipboard(_map,_selection,_mid,_trace);auto board=NSPasteboard.generalPasteboard;[board clearContents];[board setString:ms(payload.dump()) forType:@"com.vibe.mapping-objects"];_clipboardChange=board.changeCount;_pasteCount=0;}
    catch(const std::exception& error){_status.stringValue=ms(error.what());}
}
- (void)paste:(id)sender {
    (void)sender;if(![self canUseObjectClipboard])return;auto board=NSPasteboard.generalPasteboard;auto raw=[board stringForType:@"com.vibe.mapping-objects"];if(!raw)return;
    auto payload=Json::parse(raw.UTF8String,nullptr,false);if(!payload.is_object())return;if(_clipboardChange!=board.changeCount){_clipboardChange=board.changeCount;_pasteCount=0;}
    auto mid=_mid;auto count=_pasteCount+1;__weak VJMapper* weak=self;
    VJSubmitUiCommand(_model,"POST","/api/v1/mappings/"+mid+"/paste",{{"revision",_map["revision"]},{"clipboard",payload},{"offset",.025*count}},^(const vj::Reply& reply){VJMapper* owner=weak;if(!owner||owner->_mid!=mid)return;if(reply.status>=300){owner->_status.stringValue=ms(reply.body.value("error",std::string("Paste failed")));return;}owner->_pasteCount=count;owner->_map=reply.body;owner->_revision=UINT64_MAX;if(reply.body.contains("traceId"))[owner selectTrace:reply.body["traceId"]];else [owner select:reply.body["rectIds"]];});
}
- (BOOL)validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)item {
    if(item.action==@selector(copy:))return [self canUseObjectClipboard]&&(!_selection.empty()||!_trace.empty());
    if(item.action==@selector(paste:))return [self canUseObjectClipboard]&&[NSPasteboard.generalPasteboard availableTypeFromArray:@[@"com.vibe.mapping-objects"]]!=nil;
    return YES;
}
- (void)findAction:(id)sender {
    (void)sender;if(self.isHiddenOrHasHiddenAncestor||!self.window||self.window.attachedSheet)return;
    [_actionSearch cancel];[_canvas cancelPlacement];[self refresh];
    Json items=Json::array();NSMutableArray<NSMenuItem*>* commands=[NSMutableArray array];
    auto append=[&](auto&& recurse,NSMenu* menu,NSString* section,NSString* prefix)->void {
        for(NSMenuItem* command in menu.itemArray){
            if(command.isSeparatorItem||!command.enabled)continue;
            NSString* name=[prefix stringByAppendingString:command.title];
            if(command.submenu){recurse(recurse,command.submenu,section,[name stringByAppendingString:@" → "]);continue;}
            if(!command.action)continue;
            items.push_back({{"name",name.UTF8String},{"effect",NSStringFromSelector(command.action).UTF8String},{"section",section.UTF8String},{"params",{{"index",commands.count}}}});[commands addObject:command];
        }
    };
    append(append,[self creationMenu],@"Create",@"");
    NSDictionary* selected=nil;
    for(NSInteger row=0;row<_outline.numberOfRows;row++){
        NSDictionary* node=[_outline itemAtRow:row];
        if(!_trace.empty()){if([node[@"kind"] isEqual:@"trace"]&&_trace==[node[@"id"] UTF8String]){selected=node;break;}continue;}
        if(_selection.empty()||[node[@"ids"] count]!=_selection.size())continue;
        bool matches=true;for(NSString* id in node[@"ids"])matches&=has(_selection,std::string(id.UTF8String));
        if(matches){selected=node;break;}
    }
    if(!selected&&!_selection.empty())selected=@{@"kind":@"rect",@"id":ms(_selection[0]),@"ids":@[ms(_selection[0])]};
    if(selected){auto menu=[self objectMenu:selected];
        // A multi-selection without a common object has no single name to edit.
        if(_selection.size()>1&&[selected[@"kind"] isEqual:@"rect"])[menu removeItem:[menu itemWithTitle:@"Rename"]];
        append(append,menu,@"Selection",@"");
    }
    const auto mid=_mid;const auto mapping=_map;
    __weak VJMapper* weak=self;
    _actionSearch=[[VJClipSearch alloc]initWithItems:items completion:^(Json item){
        VJMapper* owner=weak;if(!owner||owner.isHiddenOrHasHiddenAncestor)return;
        auto latest=owner->_model->presentationSnapshot();
        if(owner->_mid!=mid||!latest["mappings"].contains(mid)||latest["mappings"][mid]!=mapping){owner->_status.stringValue=@"Mapping changed — reopen Find action";return;}
        auto index=item["params"].value("index",size_t(-1));if(index>=commands.count)return;
        [owner.window makeKeyAndOrderFront:nil];[owner.window makeFirstResponder:owner->_canvas];
        NSMenuItem* command=commands[index];[NSApp sendAction:command.action to:command.target from:command];
    }];
    [_actionSearch setSearchTitle:@"Find action" placeholder:@"Search mapper actions"];
    [_actionSearch showForWindow:self.window target:ms("Projector "+_mid)];
}
- (BOOL)handleKeyEvent:(NSEvent*)event {
    const auto modifiers=event.modifierFlags&(NSEventModifierFlagShift|NSEventModifierFlagCommand|NSEventModifierFlagControl|NSEventModifierFlagOption);
    if(self.isHiddenOrHasHiddenAncestor||event.window!=self.window||self.window.attachedSheet||[self.window.firstResponder isKindOfClass:NSTextView.class])return NO;
    NSString* key=event.charactersIgnoringModifiers.lowercaseString;
    if(modifiers==NSEventModifierFlagCommand&&[key isEqual:@"f"]){if(!event.isARepeat)[self findAction:nil];return YES;}
    if(modifiers==NSEventModifierFlagCommand&&([key isEqual:@"c"]||[key isEqual:@"v"])){if(!event.isARepeat){if([key isEqual:@"c"])[self copy:nil];else [self paste:nil];}return YES;}
    if(_selection.empty()||!_trace.empty())return NO;
    // ⌘] / ⌘[ move one step; with Shift they go all the way to the front or back.
    if((modifiers&~NSEventModifierFlagShift)==NSEventModifierFlagCommand&&(event.keyCode==30||event.keyCode==33)){if(!event.isARepeat){const bool shift=modifiers&NSEventModifierFlagShift;[self arrangeSelection:event.keyCode==30?(shift?"front":"forward"):(shift?"back":"backward")];}return YES;}
    if(modifiers==0&&[key isEqual:@"r"]&&(self.window.firstResponder==_canvas||self.window.firstResponder==_outline)){if(!event.isARepeat)[self quickTransform:nil];return YES;}
    if(modifiers==NSEventModifierFlagCommand&&[key isEqual:@"l"]){if(!event.isARepeat)[self applySelectionProperty:"mode" value:[self mixed:"mode"]=="grid"?Json("live"):Json("grid")];return YES;}
    if(modifiers!=NSEventModifierFlagCommand&&modifiers!=(NSEventModifierFlagCommand|NSEventModifierFlagShift))return NO;
    // Shift changes the number row to punctuation, so remove it when decoding.
    key=[event charactersByApplyingModifiers:0];
    if(key.length!=1||[key characterAtIndex:0]<'0'||[key characterAtIndex:0]>'9')return NO;
    int out=[key characterAtIndex:0]-'0';if(!out)out=10;if(modifiers&NSEventModifierFlagShift)out+=10;
    if(out>int(_snapshot["state"]["grid"]["running"].size()))return YES;
    if(!event.isARepeat)[self applySelectionProperty:"source" value:"out"+std::to_string(out)];
    return YES;
}
- (void)buildInspector {
    if(!_trace.empty()){[self inspectTrace];return;}if(_selection.empty()){[_inspector addArrangedSubview:label(@"No selection")];return;}if(!_collection.empty()){[self inspectCollection];return;}[self modeChoices];[_inspector addArrangedSubview:label(_selection.size()==1?@"Surface":[NSString stringWithFormat:@"%lu surfaces",(unsigned long)_selection.size()])];NSMutableArray* sources=[NSMutableArray arrayWithObject:@"none"];for(size_t i=1;i<=_snapshot["state"]["grid"]["running"].size();i++)[sources addObject:ms("out"+std::to_string(i))];[self subdivisionButton];[self popup:@"Source" key:@"source" values:sources];[self popup:@"Kind" key:@"kind" values:@[@"surface",@"overlay"]];[self popup:@"Blend" key:@"blend" values:@[@"normal",@"add",@"screen",@"multiply",@"subtract"]];[self popup:@"Fit" key:@"fit" values:@[@"stretch",@"fit",@"fill"]];if([self mixed:"kind"]=="overlay")[self contentPositionControls];else{[self occludeToggle];[self hemisphereControls];}
    auto radius=[[NSTextField alloc] initWithFrame:NSMakeRect(0,0,175,24)];radius.identifier=@"cornerRadius";auto value=[self mixed:"cornerRadius"];radius.stringValue=value.is_number()?ms(Json(value.get<double>()*100).dump()):@"";radius.alignment=NSTextAlignmentRight;radius.enabled=YES;for(const auto& r:_map["project"]["rects"])if(has(_selection,r["id"])&&(r["corners"].size()!=4||r.value("fold",false)))radius.enabled=NO;radius.placeholderString=@"Mixed";radius.target=self;radius.action=@selector(property:);[self propertyRow:@"Radius (%)" control:radius];
    [self inspectPattern];if([self section:@"Object actions"]){_target=[[VJPopup alloc] initWithFrame:NSZeroRect pullsDown:NO];_target.identifier=@"send-projector";for(auto it=_snapshot["mappings"].begin();it!=_snapshot["mappings"].end();++it)if(it.key()!=_mid){[_target addItemWithTitle:ms("Projector "+it.key())];_target.lastItem.representedObject=ms(it.key());}[self propertyRow:@"Send to" control:_target];[_inspector addArrangedSubview:[self button:@"Send selected" action:@selector(sendSelected:)]];[_inspector addArrangedSubview:[self button:@"Duplicate" action:@selector(duplicate:)]];}if(_selection.size()==1)for(const auto& r:_map["project"]["rects"])if(r["id"]==_selection[0])[self traceControls:r.value("trace",Json::object()) scope:"rect" prefix:"/trace"];[self inspectGeometry];
}
- (void)occludeToggle{bool on=false,off=false;for(const auto& r:_map["project"]["rects"])if(has(_selection,r["id"]))(r.value("occlude",false)?on:off)=true;auto button=[NSButton checkboxWithTitle:@"Occlude" target:self action:@selector(occludeChanged:)];button.allowsMixedState=YES;button.state=on&&off?NSControlStateValueMixed:on?NSControlStateValueOn:NSControlStateValueOff;button.tag=off;for(const auto& r:_map["project"]["rects"])if(has(_selection,r["id"])&&ownedSurface(_map,r["id"]))button.enabled=NO;[_inspector addArrangedSubview:button];[button.widthAnchor constraintEqualToAnchor:_inspector.widthAnchor constant:-20].active=YES;[button.heightAnchor constraintEqualToConstant:vj::style::controlHeight].active=YES;}
- (void)hemisphereControls{if(_selection.size()!=1||![self section:@"Hemisphere"])return;for(const auto& r:_map["project"]["rects"])if(r["id"]==_selection[0]){
    auto h=r.value("hemisphere",Json());const bool on=h.is_object()&&h.value("enabled",true);if(!h.is_object())h=Json::object();
    const bool eligible=r["corners"].size()==4&&!r.value("fold",false)&&!ownedSurface(_map,r["id"]);
    if(eligible)[self toggle:@"Hemisphere" value:on binding:{{"scope","rect"},{"path","/hemisphere/enabled"}}];else{[_inspector addArrangedSubview:label(@"Hemisphere needs a four-corner independent surface")];return;}
    if(!on)return;
    [self field:@"Wrap" value:h.value("wrap",Json(1.)) binding:{{"scope","rect"},{"path","/hemisphere/wrap"}}];
    [self field:@"Feather" value:h.value("feather",Json(.04)) binding:{{"scope","rect"},{"path","/hemisphere/feather"}}];
    [self field:@"Inset" value:h.value("inset",Json(0.)) binding:{{"scope","rect"},{"path","/hemisphere/inset"}}];
    [self field:@"Edge boost" value:h.value("edgeBoost",Json(0.)) binding:{{"scope","rect"},{"path","/hemisphere/edgeBoost"}}];
}}
// A mixed selection turns occlusion on for all; the tag records whether any surface was off.
- (void)occludeChanged:(NSButton*)sender{[self applySelectionProperty:"occlude" value:sender.tag!=0];}
- (void)property:(NSControl*)sender{Json value;if([sender isKindOfClass:[NSPopUpButton class]]){NSString* item=((NSPopUpButton*)sender).selectedItem.representedObject;if(!item)return;value=item.UTF8String;}else{const char* raw=sender.stringValue.UTF8String;char* end=nullptr;double n=std::strtod(raw,&end);if(end==raw||*end||!std::isfinite(n)){_status.stringValue=@"Enter a number from 0 to 50";return;}value=[sender.identifier isEqualToString:@"cornerRadius"]?n/100:n;}[self applySelectionProperty:sender.identifier.UTF8String value:value];}
- (void)projector:(id)sender{(void)sender;_canvas->positioningContent.clear();[self clearProjectedPreview];++_selectionGeneration;_selectionPending=NO;_mid=[_projector.selectedItem.representedObject UTF8String];[[NSUserDefaults standardUserDefaults] setObject:ms(_mid) forKey:@"VJMapperProjector"];_revision=UINT64_MAX;[_canvas reset];[self refresh];}
- (void)add:(BOOL)overlay{[self send:@"POST" action:@"rects" body:{{"name",overlay?"Overlay":"Surface"},{"kind",overlay?"overlay":"surface"},{"corners",vj::defaultMappingSurfaceCorners(_map["project"])}}];}
- (void)placeBox:(id)sender{(void)sender;[_canvas beginBoxPlacement];}
// Each click adds a flat circle to one point collection: the selected one, or a new one on the first click.
- (void)placeCircle:(id)sender{(void)sender;_circleCollection.clear();for(const auto& c:_map["project"]["collections"])if(c.value("kind",std::string{})=="points")for(const auto& f:c["faces"])if(has(_selection,f["rectId"]))_circleCollection=c["id"].get<std::string>();[_canvas beginCirclePlacement];_status.stringValue=@"Place circle · Shift: size · Click: add · Esc: exit";}
- (void)placeSurface:(id)sender{(void)sender;[_canvas beginPlacement];_status.stringValue=@"Place · Shift: scale / rotate · Click: place · Esc: exit";}
- (void)quickTransform:(id)sender{(void)sender;[_canvas beginQuickTransform];_status.stringValue=@"Scale / rotate · Click: apply · Esc: cancel";}
- (void)addSurface:(id)sender{(void)sender;[self add:NO];}
- (void)addOverlay:(id)sender{(void)sender;[self add:YES];}
- (void)addHemisphere:(id)sender{(void)sender;const double h=.2,w=h/vj::mappingCanvasAspect(_map["project"]);[self send:@"POST" action:@"rects" body:{{"name","Hemisphere"},{"kind","surface"},{"fit","fill"},{"hemisphere",{{"enabled",true}}},{"corners",{{.5-w,.5-h},{.5+w,.5-h},{.5+w,.5+h},{.5-w,.5+h}}}}];}
- (void)addTrace:(id)sender{(void)sender;[self send:@"POST" action:@"traces" body:Json::object()];}
- (void)reset:(id)sender{(void)sender;[_canvas reset];}
- (void)undo:(id)sender{(void)sender;[self send:@"POST" action:@"undo" body:Json::object()];}
- (void)redo:(id)sender{(void)sender;[self send:@"POST" action:@"redo" body:Json::object()];}
- (void)group:(id)sender{(void)sender;if(_selection.size()<2)return;[self send:@"POST" action:@"groups" body:{{"name","Group"},{"rectIds",_selection}}];}
- (void)ungroup:(id)sender{(void)sender;Json ids=Json::array();for(const auto& group:_map["project"].value("groups",Json::array())){bool all=true;for(const auto& id:group["rectIds"])all&=has(_selection,id);if(all)ids.push_back(group["id"]);}for(const auto& id:ids)[self send:@"DELETE" action:ms("groups/"+id.get<std::string>()) body:Json::object()];}
- (void)remove:(id)sender{(void)sender;if(!_trace.empty()){[self send:@"DELETE" action:ms("traces/"+_trace) body:Json::object()];return;}if(!_selection.empty())[self send:@"DELETE" action:@"rects" body:{{"rectIds",_selection}}];}
- (void)mute:(id)sender{(void)sender;if(!_trace.empty()){for(const auto& trace:_map["project"]["traces"])if(trace["id"]==_trace){[self send:@"PATCH" action:ms("traces/"+_trace) body:{{"enabled",!trace.value("enabled",true)}}];return;}}if(_selection.empty())return;bool allMuted=true;for(const auto& r:_map["project"]["rects"])if(has(_selection,r["id"]))allMuted&=r.value("source",std::string{})=="none";Json operations=Json::array();std::set<std::string> owned;for(const auto& c:_map["project"].value("collections",Json::array())){bool selected=false;for(const auto& f:c["faces"]){owned.insert(f["rectId"]);selected|=has(_selection,f["rectId"]);}if(selected)operations.push_back({{"method","PATCH"},{"action","collections/"+c["id"].get<std::string>()},{"body",{{"enabled",allMuted}}}});}std::map<std::string,Json> sources;for(const auto& r:_map["project"]["rects"])if(has(_selection,r["id"])&&!owned.contains(r["id"])){std::string source=allMuted?r.value("mutedSource",std::string("out1")):"none";if(!sources.contains(source))sources[source]=Json::array();sources[source].push_back(r["id"]);}for(auto& [source,ids]:sources)operations.push_back({{"method","PATCH"},{"action","rects"},{"body",{{"rectIds",ids},{"source",source}}}});if(!operations.empty())[self send:@"POST" action:@"batch" body:{{"operations",operations}}];}
- (void)sendSelected:(id)sender{(void)sender;if(!_trace.empty()){if(_target.selectedItem)[self send:@"POST" action:@"copy-object" body:{{"kind","trace"},{"id",_trace},{"target",[_target.selectedItem.representedObject UTF8String]}}];return;}if(_target.selectedItem)[self copySelectionTo:std::string([_target.selectedItem.representedObject UTF8String])];}
// Rect order is stacking order: later surfaces are in front of earlier ones.
- (void)addArrangeItems:(NSMenu*)menu{for(NSArray* spec in @[@[@"Bring to Front",@"front",@"]",@YES],@[@"Bring Forward",@"forward",@"]",@NO],@[@"Send Backward",@"backward",@"[",@NO],@[@"Send to Back",@"back",@"[",@YES]]){auto item=[[NSMenuItem alloc]initWithTitle:spec[0] action:@selector(arrange:) keyEquivalent:spec[2]];item.keyEquivalentModifierMask=NSEventModifierFlagCommand|([spec[3] boolValue]?NSEventModifierFlagShift:0);item.representedObject=spec[1];item.target=self;[menu addItem:item];}}
- (void)arrange:(NSMenuItem*)sender{[self arrangeSelection:[sender.representedObject UTF8String]];}
- (void)arrangeSelection:(const std::string&)to{[self send:@"POST" action:@"arrange-surfaces" body:{{"rectIds",_selection},{"to",to}}];}
- (void)duplicate:(id)sender{(void)sender;NSDictionary* node=_outline.selectedRow>=0?[_outline itemAtRow:_outline.selectedRow]:nil;if([node[@"kind"] isEqualToString:@"collection"]){[self send:@"POST" action:@"copy-object" body:{{"kind","collection"},{"id",[node[@"id"] UTF8String]},{"target",_mid},{"offset",.02}}];return;}[self send:@"POST" action:@"copy-surfaces" body:{{"rectIds",_selection},{"target",_mid}}];}
- (void)loadLayout:(id)sender{(void)sender;[_layoutsPopover close];NSString* lid=_layout.selectedItem.representedObject;if(!lid.length)return;[self send:@"POST" action:@"load-layout" body:{{"layoutId",lid.UTF8String},{"libraryRevision",_layouts["revision"]}}];}
- (void)saveLayout:(id)sender{(void)sender;[self storeLayout:NO];}
- (void)updateLayout:(id)sender{(void)sender;[self storeLayout:YES];}
- (void)storeLayout:(BOOL)update{std::string path="/api/v1/mapping-layouts";if(update){NSString* chosen=_layout.selectedItem.representedObject;if(!chosen.length){_status.stringValue=@"Choose a layout";return;}path+="/"+std::string(chosen.UTF8String);}auto result=_model->request(update?"PUT":"POST",path,{{"name",_layoutName.stringValue.UTF8String},{"mappingId",_mid},{"revision",_map["revision"]},{"libraryRevision",_layouts["revision"]}});if(result.status>=300){_status.stringValue=ms(result.body.value("error",std::string("Save failed")));return;}_revision=UINT64_MAX;[self refresh];}
- (void)outputEnabled:(NSButton*)sender {[self send:@"PATCH" action:@"output" body:{{"enabled",sender.state==NSControlStateValueOn}}];}
- (void)boundsGrid:(NSButton*)sender {Json change={{"boundsGrid",sender.state==NSControlStateValueOn}};if(sender.state==NSControlStateValueOn)change["enabled"]=true;[self send:@"PATCH" action:@"output" body:change];}
- (void)rotation:(NSPopUpButton*)sender {[self send:@"PATCH" action:@"output" body:{{"rotation",sender.indexOfSelectedItem*90}}];}
- (Json)checkObjectParity {
    Json checks=Json::object();auto settle=[&]{auto until=[NSDate dateWithTimeIntervalSinceNow:3];while(_selectionPending&&until.timeIntervalSinceNow>0)[[NSRunLoop mainRunLoop]runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];_model->snapshot();_revision=UINT64_MAX;[self refresh];[self layoutSubtreeIfNeeded];};settle();
    // Shortcut checks below route to Out 2. A fresh isolated model starts with
    // one Out; establish the fixture instead of depending on an imported show.
    const auto initialOutputCount=_snapshot["state"]["grid"]["running"].size();
    if(initialOutputCount<2){_model->request("PUT","/api/v1/outputs",{{"count",2}});settle();}
    auto gestureFixture=[[VJMapCanvas alloc]initWithFrame:NSMakeRect(0,0,600,400)];checks.update([gestureFixture checkPreviewCadence]);auto handleFixture=[[VJMapCanvas alloc]initWithFrame:NSMakeRect(0,0,600,400)];checks.update([handleFixture checkRotationHandles]);
    checks["Mapper creates collection fixture"]=[self send:@"POST" action:@"collections" body:{{"kind","boxes"},{"name","Stage boxes"},{"preset","stack"}}];settle();
    checks["Mapper creates overlay fixture"]=[self send:@"POST" action:@"rects" body:{{"kind","overlay"},{"name","Purple overlay"},{"corners",{{.1,.1},{.42,.1},{.42,.4},{.1,.4}}}}];settle();
    auto find=[&](NSString* kind,BOOL overlay)->NSDictionary*{for(NSInteger row=0;row<_outline.numberOfRows;++row){NSDictionary* node=[_outline itemAtRow:row];if([node[@"kind"]isEqual:kind]&&(!overlay||[node[@"overlay"]boolValue]))return node;}return nil;};
    auto collection=find(@"collection",NO);auto overlay=find(@"rect",YES);checks["Mapper collection has counts and row controls"]=collection&&[collection[@"detail"]containsString:@"boxes"]&&[collection[@"canMute"]boolValue];
    if(collection){auto row=[_outline rowForItem:collection];auto cell=(VJMapObjectCell*)[_outline viewAtColumn:0 row:row makeIfNecessary:YES];auto before=_selection;[cell.mute performClick:nil];settle();auto muted=find(@"collection",NO);checks["Mapper collection mute preserves selection"]=[muted[@"muted"]boolValue]&&_selection==before;cell=(VJMapObjectCell*)[_outline viewAtColumn:0 row:[_outline rowForItem:muted] makeIfNecessary:YES];[cell.mute performClick:nil];settle();collection=find(@"collection",NO);checks["Mapper collection unmute restores faces"]=![collection[@"muted"]boolValue];auto count=_outline.numberOfRows;_refreshing=YES;[_outline collapseItem:collection];checks["Mapper collection collapse hides children"]=_outline.numberOfRows<count;[_outline expandItem:collection];checks["Mapper collection expansion restores children"]=_outline.numberOfRows==count;_refreshing=NO;}
    overlay=find(@"rect",YES);if(overlay){auto row=[_outline rowForItem:overlay];auto cell=(VJMapObjectCell*)[_outline viewAtColumn:0 row:row makeIfNecessary:YES];auto before=_selection;[cell.mute performClick:nil];settle();auto muted=find(@"rect",YES);checks["Mapper overlay mute preserves selection"]=[muted[@"muted"]boolValue]&&_selection==before;cell=(VJMapObjectCell*)[_outline viewAtColumn:0 row:[_outline rowForItem:muted] makeIfNecessary:YES];[cell.mute performClick:nil];settle();overlay=find(@"rect",YES);checks["Mapper overlay unmute restores source"]=![overlay[@"muted"]boolValue];auto menu=[self objectMenu:overlay];checks["Mapper object dropdown actions"]=[menu itemWithTitle:@"Rename"]&&[menu itemWithTitle:@"Send to projector"]&&[menu itemWithTitle:@"Delete"];settle();[_outline selectRowIndexes:[NSIndexSet indexSetWithIndex:[_outline rowForItem:find(@"rect",YES)]] byExtendingSelection:NO];settle();[self renameSelection:nil];checks["Mapper inline rename remains editable"]=[self.window.firstResponder isKindOfClass:NSTextView.class];[self.window makeFirstResponder:nil];}
    Json assignments={{"1",{{"displayId","parity-projector"},{"enabled",true}}}};checks["Mapper physical destination assignment"]=_model->request("PUT","/api/v1/display-assignments",{{"assignments",assignments}}).status<300;
    _model->setOutputRuntime({{"physicalAvailable",true},{"rendererConnected",true},{"displays",Json::array({{{"displayId","parity-projector"},{"name","Stage Epson"},{"width",1920},{"height",1080}}})},{"projectors",{{"1",{{"display",{{"active",true},{"displayId","parity-projector"}}}}}}}});settle();
    checks["Mapper physical destination name visible"]=[((VJProjectorTab*)_projectorTabs.arrangedSubviews[0]).destination isEqual:@"Stage Epson"];
    _model->setOutputRuntime({{"rendererConnected",false}});settle();checks["Mapper destination updates on disconnect"]=[((VJProjectorTab*)_projectorTabs.arrangedSubviews[0]).destination containsString:@"disconnected"];
    _model->request("PUT","/api/v1/ndi/projectors",{{"2",{{"enabled",true},{"name","Side wall"}}}});_model->setOutputRuntime({{"rendererConnected",true},{"ndiAvailable",true},{"projectors",{{"2",{{"ndi",{{"active",true}}}}}}}});settle();checks["Mapper NDI destination visible"]=[((VJProjectorTab*)_projectorTabs.arrangedSubviews[1]).destination isEqual:@"NDI · Side wall"];
    checks["Mapper unassigned projector labelled"]=[((VJProjectorTab*)_projectorTabs.arrangedSubviews[2]).destination isEqual:@"No display"];
    auto geometryBefore=_model->snapshot()["mappings"][_mid]["project"];auto viewBefore=[_canvas mapBounds];[self zoomIn:nil];auto bigger=[_canvas mapBounds];[self zoomOut:nil];auto restored=[_canvas mapBounds];checks["Mapper zoom buttons preserve center and reverse"]=bigger.size.width>viewBefore.size.width&&std::abs(restored.size.width-viewBefore.size.width)<.01&&std::abs(NSMidX(bigger)-NSMidX(viewBefore))<.01;[self fitSelection:nil];auto fitted=[_canvas mapBounds];checks["Mapper fit selection frames projector and selected objects"]=fitted.size.width<_canvas.bounds.size.width&&fitted.size.height<_canvas.bounds.size.height;checks["Mapper framing leaves projection geometry unchanged"]=_model->snapshot()["mappings"][_mid]["project"]==geometryBefore;[_canvas reset];
    [self layoutSubtreeIfNeeded];bool inside=true;for(NSInteger row=0;row<_outline.numberOfRows;++row){auto cell=(VJMapObjectCell*)[_outline viewAtColumn:0 row:row makeIfNecessary:YES];[cell layoutSubtreeIfNeeded];if(cell&&!cell.more.hidden){auto frame=[cell.more convertRect:cell.more.bounds toView:_outline.enclosingScrollView.contentView];inside&=NSMaxX(frame)<=_outline.enclosingScrollView.contentView.bounds.size.width+.5;}}checks["Mapper row menus stay inside sidebar"]=inside;
    auto current=find(@"rect",YES);if(current){std::string id=[current[@"id"]UTF8String];[self send:@"PATCH" action:ms("rects/"+id) body:{{"name","Shortcut check"}}];settle();auto key=[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:NSEventModifierFlagCommand timestamp:0 windowNumber:self.window.windowNumber context:nil characters:@"z" charactersIgnoringModifiers:@"z" isARepeat:NO keyCode:6];[_canvas keyDown:key];settle();checks["Mapper undo shortcut"]=[find(@"rect",YES)[@"name"]isEqual:@"Purple overlay"];auto redo=[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:NSEventModifierFlagCommand|NSEventModifierFlagShift timestamp:0 windowNumber:self.window.windowNumber context:nil characters:@"Z" charactersIgnoringModifiers:@"z" isARepeat:NO keyCode:6];[_canvas keyDown:redo];settle();checks["Mapper redo shortcut"]=[find(@"rect",YES)[@"name"]isEqual:@"Shortcut check"];[_canvas keyDown:key];settle();}
    auto sectionButton=[&](NSString* name)->NSButton*{for(NSView* v in _inspector.arrangedSubviews)if([v isKindOfClass:NSButton.class]&&[v.identifier isEqual:name])return (NSButton*)v;return nil;};
    std::function<int(NSView*,Class)> countClass=[&](NSView* view,Class kind){int count=[view isKindOfClass:kind]?1:0;for(NSView* child in view.subviews)count+=countClass(child,kind);return count;};
    auto capture=[&](NSView* view,NSString* name){if(auto path=getenv("VJ_UI_CAPTURE_DIR")){[view layoutSubtreeIfNeeded];auto bitmap=[view bitmapImageRepForCachingDisplayInRect:view.bounds];[view cacheDisplayInRect:view.bounds toBitmapImageRep:bitmap];[[NSFileManager defaultManager]createDirectoryAtPath:ms(path) withIntermediateDirectories:YES attributes:nil error:nil];[[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}]writeToFile:[ms(path)stringByAppendingPathComponent:name] atomically:YES];}};
    checks["Mapper advanced sections default closed"]=sectionButton(@"Curvature")&&sectionButton(@"Pattern")&&sectionButton(@"Trace")&&countClass(_inspector,VJMapCurveSlider.class)==0&&countClass(_inspector,NSColorWell.class)==0;
    [sectionButton(@"Curvature") performClick:nil];checks["Mapper Curvature expands controls"]=countClass(_inspector,VJMapCurveSlider.class)>=8;capture(_inspector.enclosingScrollView,@"mapper-curvature.png");[sectionButton(@"Curvature")performClick:nil];checks["Mapper Curvature collapses controls"]=countClass(_inspector,VJMapCurveSlider.class)==0;
    [sectionButton(@"Pattern")performClick:nil];auto well=_patternColor;checks["Mapper Pattern expands color and line controls"]=well!=nil;[well activate:YES];auto editor=well.editorView;[editor layoutSubtreeIfNeeded];checks["Color picker stays compact"]=well.isActive&&editor.frame.size.width==280&&editor.frame.size.height==302;checks["Color picker validates hex input"]=bool([well checkEditor]);capture(editor,@"color-picker.png");auto escape=[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:editor.window.windowNumber context:nil characters:@"\e" charactersIgnoringModifiers:@"\e" isARepeat:NO keyCode:53];[editor.window sendEvent:escape];checks["Color picker Escape dismisses"]=!well.isActive;[well activate:YES];well.color=vj::style::hex(0x8060c0);[well sendAction:well.action to:well.target];settle();checks["Mapper color picker edits selected pattern"]=[self patternValue:"color"]=="#8060c0";checks["Mapper refresh preserves active color picker"]=_patternColor==well&&well.isActive;[well deactivate];checks["Color picker closes"]=!well.isActive;[sectionButton(@"Pattern")performClick:nil];
    // Re-select equivalent surface forms without replacing their live controls.
    Json surfaces=Json::array();for(const auto& rect:_map["project"]["rects"])if(!ownedSurface(_map,rect["id"])&&rect["corners"].size()==4)surfaces.push_back(rect["id"]);
    if(surfaces.size()>=2){[self select:Json::array({surfaces[0]})];settle();auto form=_inspector;auto sourceRow=_inspector.arrangedSubviews[2];auto control=((NSStackView*)sourceRow).arrangedSubviews.lastObject;auto frame=control.frame;auto builds=_inspectorBuilds;auto started=std::chrono::steady_clock::now();[self select:Json::array({surfaces[1]})];double elapsed=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-started).count();BOOL reused=_inspector==form;settle();checks["Mapper surface selection retains inspector controls"]=bool(reused&&_inspector==form&&((NSStackView*)_inspector.arrangedSubviews[2]).arrangedSubviews.lastObject==control);checks["Mapper selection acknowledgement does not rebuild inspector"]=_inspectorBuilds==builds+1;checks["Mapper selection keeps field geometry"]=NSEqualRects(frame,control.frame);checks["Mapper immediate selection stays below 50 ms"]=elapsed<50;NSLog(@"Mapper local selection %.3f ms · %lu reused forms",elapsed,(unsigned long)_inspectorReuses);}
    if(surfaces.size()>=2){[sectionButton(@"Curvature")performClick:nil];[self select:Json::array({surfaces[0]})];settle();[self select:Json::array({surfaces[1]})];settle();VJMapCurveSlider* slider=nil;for(NSView* row in _inspector.arrangedSubviews)for(NSView* child in row.subviews)if([child isKindOfClass:VJMapCurveSlider.class]&&!slider)slider=(VJMapCurveSlider*)child;slider.beginEdit();[slider applyValue:12.3];BOOL valueUpdated=[slider.numberField.stringValue isEqual:@"12.30"];slider.endEdit(NO);settle();BOOL bound=NO;for(const auto& rect:_map["project"]["rects"])if(rect["id"]==surfaces[1])bound=std::abs(rect["curvature"].value("top",0.)-.123)<.0001;checks["Reused curvature controls update live value and selected surface"]=bool(valueUpdated&&bound);[sectionButton(@"Curvature")performClick:nil];}
    [self send:@"PATCH" action:@"output" body:{{"enabled",false},{"boundsGrid",false}}];settle();checks["Mapper disabled output is explicit"]=[_outputEnabled.title isEqual:@"Output off"];[_boundsGrid performClick:nil];settle();checks["Projector grid enables disabled output"]=_map["project"]["output"]["enabled"]==true&&_map["project"]["output"]["boundsGrid"]==true;
    if(surfaces.size()>=2){[self select:Json::array({surfaces[0],surfaces[1]})];settle();auto group=(NSStackView*)_inspector.arrangedSubviews.firstObject;checks["Live Pattern is the first surface control"]=[group.identifier isEqual:@"surface-mode"]&&group.arrangedSubviews.count==2;auto live=(NSButton*)group.arrangedSubviews[0];auto pattern=(NSButton*)group.arrangedSubviews[1];[pattern performClick:nil];settle();checks["Pattern button applies to surface multi-selection"]=[self mixed:"mode"]=="grid";[pattern performClick:nil];settle();checks["Selected mode stays selected on repeat click"]=pattern.state==NSControlStateValueOn&&live.state==NSControlStateValueOff;[live performClick:nil];settle();checks["Live button applies to surface multi-selection"]=[self mixed:"mode"]=="live";auto key=[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:NSEventModifierFlagCommand timestamp:0 windowNumber:self.window.windowNumber context:nil characters:@"l" charactersIgnoringModifiers:@"l" isARepeat:NO keyCode:37];[self.window makeFirstResponder:_canvas];BOOL handled=[self handleKeyEvent:key];settle();checks["Command L toggles Live to Pattern"]=handled&&[self mixed:"mode"]=="grid";[self handleKeyEvent:key];settle();checks["Command L toggles Pattern to Live"]=[self mixed:"mode"]=="live";[self send:@"PATCH" action:ms("rects/"+surfaces[0].get<std::string>()) body:{{"mode","grid"}}];settle();group=(NSStackView*)_inspector.arrangedSubviews.firstObject;checks["Mixed mode does not claim either selected state"]=((NSButton*)group.arrangedSubviews[0]).state==NSControlStateValueOff&&((NSButton*)group.arrangedSubviews[1]).state==NSControlStateValueOff;[self handleKeyEvent:key];settle();checks["Command L resolves mixed selection to Pattern"]=[self mixed:"mode"]=="grid";[self select:Json::array({surfaces[0]})];settle();NSTextField* field=nil;for(NSView* row in _inspector.arrangedSubviews)for(NSView* child in row.subviews)if([child isKindOfClass:NSTextField.class]&&((NSTextField*)child).editable)field=(NSTextField*)child;[field selectText:nil];checks["Command L leaves text editing alone"]=field.currentEditor&&![self handleKeyEvent:key];[self.window makeFirstResponder:_canvas];capture(_inspector.enclosingScrollView,@"mapper-live-pattern.png");}
    if(surfaces.size()>=2){
        auto key=[&](NSString* character,unsigned short code,NSEventModifierFlags modifiers=NSEventModifierFlagCommand){return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:modifiers timestamp:0 windowNumber:self.window.windowNumber context:nil characters:character charactersIgnoringModifiers:character isARepeat:NO keyCode:code];};
        [self select:Json::array({surfaces[0],surfaces[1]})];settle();[self.window makeFirstResponder:_canvas];
        [self handleKeyEvent:key(@"2",19)];settle();checks["Command number routes multiple surfaces"]=[self mixed:"source"]=="out2";
        [self select:Json::array({surfaces[0]})];settle();[self handleKeyEvent:key(@"1",18)];settle();
        bool unchanged=false;for(const auto& r:_map["project"]["rects"])if(r["id"]==surfaces[1])unchanged=r["source"]=="out2";
        checks["Command number routes only the selected surface"]=[self mixed:"source"]=="out1"&&unchanged;
        auto before=_map["revision"];[self handleKeyEvent:key(@"9",25)];settle();checks["Command number ignores inactive Outs"]=_map["revision"]==before;
        checks["Old Shift L shortcut is removed"]=![self handleKeyEvent:key(@"l",37,NSEventModifierFlagShift)];
        NSTextField* field=nil;for(NSView* row in _inspector.arrangedSubviews)for(NSView* child in row.subviews)if([child isKindOfClass:NSTextField.class]&&((NSTextField*)child).editable)field=(NSTextField*)child;
        [field selectText:nil];checks["Command number leaves text editing alone"]=field.currentEditor&&![self handleKeyEvent:key(@"2",19)];[self.window makeFirstResponder:_canvas];
        const auto outputCount=_snapshot["state"]["grid"]["running"].size();_model->request("PUT","/api/v1/outputs",{{"count",20}});settle();
        [self handleKeyEvent:key(@"0",29)];settle();checks["Command zero routes Out 10"]=[self mixed:"source"]=="out10";
        [self handleKeyEvent:key(@"!",18,NSEventModifierFlagCommand|NSEventModifierFlagShift)];settle();checks["Command Shift one routes Out 11"]=[self mixed:"source"]=="out11";
        [self handleKeyEvent:key(@")",29,NSEventModifierFlagCommand|NSEventModifierFlagShift)];settle();checks["Command Shift zero routes Out 20"]=[self mixed:"source"]=="out20";
        [self handleKeyEvent:key(@"1",18)];settle();_model->request("PUT","/api/v1/outputs",{{"count",outputCount}});settle();
        collection=find(@"collection",NO);if(collection){Json ids=Json::array();for(NSString* id in collection[@"ids"])ids.push_back(id.UTF8String);[self select:ids];settle();[self handleKeyEvent:key(@"2",19)];settle();bool routed=false;for(const auto& c:_map["project"]["collections"])if(c["id"]==std::string([collection[@"id"]UTF8String]))routed=c["content"]["source"]=="out2";checks["Command number routes the selected collection"]=routed;}
        [self select:Json::array({surfaces[0]})];settle();
    }
    auto canvasFrame=_canvas.frame;NSButton* layoutsButton=nil;std::function<void(NSView*)> locate=[&](NSView* view){if([view isKindOfClass:NSButton.class]&&[((NSButton*)view).title isEqual:@"Layouts ⌄"])layoutsButton=(NSButton*)view;for(NSView* child in view.subviews)locate(child);};locate(self);[layoutsButton performClick:nil];[self.window.contentView layoutSubtreeIfNeeded];checks["Layouts opens an anchored popover"]=_layoutsPopover.shown&&_layoutsPopover.contentSize.width==340;checks["Layouts does not move the mapper canvas"]=NSEqualRects(canvasFrame,_canvas.frame);capture(_layoutsPopover.contentViewController.view,@"mapper-layouts.png");auto layoutWindow=_layoutsPopover.contentViewController.view.window;[layoutWindow sendEvent:[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:layoutWindow.windowNumber context:nil characters:@"\e" charactersIgnoringModifiers:@"\e" isARepeat:NO keyCode:53]];checks["Layouts popover Escape dismisses"]=!_layoutsPopover.shown;
    if(initialOutputCount<2){_model->request("PUT","/api/v1/outputs",{{"count",initialOutputCount}});settle();}
    [self editorTick];return checks;
}
- (BOOL)checkSelectionInterface {
    if(_outline.numberOfRows<1)return NO;[_outline selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    auto until=[NSDate dateWithTimeIntervalSinceNow:3];while(_selectionPending&&until.timeIntervalSinceNow>0)[[NSRunLoop mainRunLoop]runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    [self layoutSubtreeIfNeeded];[self editorTick];return !_selection.empty()&&_inspector.arrangedSubviews.count>5;
}
- (BOOL)checkRendering {[self editorTick];if(![_projected checkRendering]||![_editor checkRendering])return NO;NSImage* image=[_editor mappingImage];auto bounds=[_canvas mapBounds];double width=std::clamp([_canvas convertRectToBacking:bounds].size.width,640.,1920.);NSSize expected=NSMakeSize(int(width),std::clamp(int(width*bounds.size.height/std::max(1.,bounds.size.width)),32,4320));return image&&NSEqualSizes(image.size,expected);}
- (void)stop {[_actionSearch cancel];if(!_previewMid.empty()){_model->request("DELETE","/api/v1/mappings/"+_previewMid+"/preview",{{"_owner",_previewOwner}});_previewMid.clear();}[_canvasTimer invalidate];_canvasTimer=nil;[_editor stop];[_projected stop];}
- (void)dealloc {[_canvasTimer invalidate];}
- (void)setHidden:(BOOL)hidden {[super setHidden:hidden];_editor.hidden=hidden;}
- (void)editorTick {if(self.isHiddenOrHasHiddenAncestor){[_canvas cancelPlacement];return;}auto size=[_canvas convertRectToBacking:[_canvas mapBounds]].size;double width=std::clamp(size.width,640.,1920.);[_editor setOutputSize:NSMakeSize(width,std::max(1.,width*size.height/std::max(1.,size.width)))];if(!_canvas->mapping.contains("project"))return;auto editorView=vj::mappingEditorView(_canvas->mapping,_mid);if(_editorState!=editorView){_editorState=std::move(editorView);[_editor setEditorMapping:_editorState];}_canvas->liveImage=[_editor mappingImage];[_canvas setNeedsDisplay:YES];}
- (void)rebuildOutline {
    // Preserve the clicked tree level when a collection and its only box
    // represent exactly the same surface selection.
    NSMutableSet* selectedKeys=[NSMutableSet set];Json treeSelection=Json::array();
    [_outline.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger index,BOOL* stop){(void)stop;NSDictionary* node=[self->_outline itemAtRow:index];[selectedKeys addObject:[NSString stringWithFormat:@"%@:%@",node[@"kind"],node[@"id"]]];}];
    for(NSInteger i=0;i<_outline.numberOfRows;i++)if([_outline.selectedRowIndexes containsIndex:i]){NSDictionary* node=[_outline itemAtRow:i];for(NSString* id in node[@"ids"])if(!has(treeSelection,std::string(id.UTF8String)))treeSelection.push_back(id.UTF8String);}
    bool preserveRows=_trace.empty()&&!treeSelection.empty()&&treeSelection.size()==_selection.size();for(const auto& id:treeSelection)preserveRows&=has(_selection,id);
    NSMutableArray* nodes=[NSMutableArray array];std::set<std::string> owned;
    auto idsFor=[](const Json& values){NSMutableArray* result=[NSMutableArray array];for(const auto& value:values)[result addObject:ms(value)];return result;};
    auto rectNode=[&](const Json& r){bool overlay=r.value("kind",std::string{})=="overlay",muted=r.value("source",std::string{})=="none",owned=ownedSurface(_map,r["id"]);auto source=r.value("source",std::string("out1"));if(source.starts_with("out"))source="Out "+source.substr(3);auto detail=(overlay?"Overlay · ":"Surface · ")+std::string(muted?"Muted":r.value("mode",std::string{})=="grid"?r.value("graphic",std::string("Grid")):source);return @{@"id":ms(r["id"]),@"name":ms(r["name"]),@"kind":@"rect",@"ids":@[ms(r["id"])],@"overlay":@(overlay),@"muted":@(muted),@"canMute":@(!owned),@"detail":ms(detail)};};
    for(const auto& c:_map["project"].value("collections",Json::array())){NSMutableArray* children=[NSMutableArray array];Json all=Json::array();for(const auto& f:c["faces"]){owned.insert(f["rectId"]);all.push_back(f["rectId"]);}if(c["kind"]=="boxes"){for(const auto& box:c["boxes"]){Json ids=Json::array();NSMutableArray* faces=[NSMutableArray array];for(const auto& f:c["faces"])if(f["boxId"]==box["id"]){ids.push_back(f["rectId"]);for(const auto& r:_map["project"]["rects"])if(r["id"]==f["rectId"])[faces addObject:rectNode(r)];}[children addObject:@{@"id":ms(box["id"]),@"name":ms(box["name"]),@"kind":@"box",@"collection":ms(c["id"]),@"ids":idsFor(ids),@"children":faces,@"detail":ms(std::to_string(ids.size())+" surfaces")}];}}else if(c["kind"]=="points"){for(const auto& p:c["points"])[children addObject:@{@"id":ms(p["id"]),@"name":ms(p["name"]),@"kind":@"point",@"collection":ms(c["id"]),@"ids":@[ms(c["id"].get<std::string>()+":"+p["id"].get<std::string>())]}];}else for(const auto& f:c["faces"])for(const auto& r:_map["project"]["rects"])if(r["id"]==f["rectId"])[children addObject:rectNode(r)];[nodes addObject:@{@"id":ms(c["id"]),@"name":ms(c["name"]),@"kind":@"collection",@"ids":idsFor(all),@"children":children,@"canMute":@YES,@"muted":@(!c.value("enabled",true)),@"detail":ms(std::to_string(children.count)+(c["kind"]=="boxes"?" boxes":c["kind"]=="points"?" points":" surfaces")+(c.value("enabled",true)?"":" · Muted"))}];}
    for(const auto& group:_map["project"].value("groups",Json::array())){NSMutableArray* children=[NSMutableArray array];for(const auto& id:group["rectIds"])for(const auto& r:_map["project"]["rects"])if(r["id"]==id){owned.insert(id);[children addObject:rectNode(r)];}[nodes addObject:@{@"id":ms(group["id"]),@"name":ms(group["name"]),@"kind":@"group",@"ids":idsFor(group["rectIds"]),@"children":children}];}
    for(auto it=_map["project"]["rects"].rbegin();it!=_map["project"]["rects"].rend();++it)if(!owned.contains((*it)["id"]))[nodes addObject:rectNode(*it)];for(const auto& trace:_map["project"].value("traces",Json::array()))[nodes addObject:@{@"id":ms(trace["id"]),@"name":ms(trace["name"]),@"kind":@"trace",@"ids":@[],@"canMute":@YES,@"muted":@(!trace.value("enabled",true)),@"detail":ms("Trace · "+std::to_string(trace.value("pixels",60))+" px"+(trace.value("enabled",true)?"":" · Muted"))}];NSMutableArray* decorated=[NSMutableArray array];for(NSDictionary* node in nodes)[decorated addObject:decorateMapperNode(node,_map)];nodes=decorated;[self updateMapperVisibilityControls];if(![_nodes isEqualToArray:nodes]){_nodes=nodes;[_outline reloadData];[self restoreExpansion:_nodes];}NSMutableIndexSet* indexes=[NSMutableIndexSet indexSet];if(preserveRows){for(NSInteger i=0;i<_outline.numberOfRows;i++){NSDictionary* node=[_outline itemAtRow:i];if([selectedKeys containsObject:[NSString stringWithFormat:@"%@:%@",node[@"kind"],node[@"id"]]])[indexes addIndex:i];}Json restored=Json::array();for(NSInteger i=0;i<_outline.numberOfRows;i++)if([indexes containsIndex:i])for(NSString* id in ((NSDictionary*)[_outline itemAtRow:i])[@"ids"])if(!has(restored,std::string(id.UTF8String)))restored.push_back(id.UTF8String);if(restored.size()!=_selection.size())[indexes removeAllIndexes];}if(indexes.count){[_outline selectRowIndexes:indexes byExtendingSelection:NO];return;}std::set<std::string> covered;for(NSInteger i=0;i<_outline.numberOfRows;i++){NSDictionary* node=[_outline itemAtRow:i];if([node[@"kind"] isEqualToString:@"trace"]&&_trace==[node[@"id"] UTF8String]){[indexes addIndex:i];continue;}bool all=[node[@"ids"] count]>0,uncovered=false;for(NSString* id in node[@"ids"]){all&=has(_selection,std::string(id.UTF8String));uncovered|=!covered.contains(id.UTF8String);}if(all&&uncovered){[indexes addIndex:i];for(NSString* id in node[@"ids"])covered.insert(id.UTF8String);}}[_outline selectRowIndexes:indexes byExtendingSelection:NO];
}
- (void)resolveOwner {_collection.clear();_box.clear();_point.clear();if(_selection.empty())return;for(const auto& c:_map["project"].value("collections",Json::array())){Json ids=Json::array();for(const auto& f:c["faces"])ids.push_back(f["rectId"]);bool all=true;for(const auto& id:_selection)all&=has(ids,id);if(!all)continue;_collection=c["id"];if(c["kind"]=="boxes"){std::set<std::string> boxes;for(const auto& f:c["faces"])if(has(_selection,f["rectId"]))boxes.insert(f["boxId"]);if(boxes.size()==1)_box=*boxes.begin();}if(c["kind"]=="points"&&_selection.size()==1)for(const auto& p:c["points"])if(_selection[0]==_collection+":"+p["id"].get<std::string>())_point=p["id"];return;}}
- (void)field:(NSString*)title value:(const Json&)value binding:(Json)binding {
    auto field=[[NSTextField alloc] initWithFrame:NSMakeRect(0,0,175,24)];field.stringValue=ms(value.is_string()?value.get<std::string>():value.dump());field.identifier=ms(binding.dump());field.target=self;field.action=@selector(boundProperty:);field.enabled=!binding.value("disabled",false);[self propertyRow:title control:field];
}
- (void)choice:(NSString*)title value:(const Json&)value options:(NSArray*)options binding:(Json)binding {auto popup=[[VJPopup alloc] initWithFrame:NSZeroRect pullsDown:NO];for(NSString* option in options){[popup addItemWithTitle:option];popup.lastItem.representedObject=option;if(value==std::string(option.UTF8String))[popup selectItem:popup.lastItem];}popup.identifier=ms(binding.dump());popup.target=self;popup.action=@selector(boundProperty:);[self propertyRow:title control:popup];}
- (void)toggle:(NSString*)title value:(BOOL)value binding:(Json)binding {auto button=[NSButton checkboxWithTitle:title target:self action:@selector(boundProperty:)];button.state=value?NSControlStateValueOn:NSControlStateValueOff;button.identifier=ms(binding.dump());[_inspector addArrangedSubview:button];[button.widthAnchor constraintEqualToAnchor:_inspector.widthAnchor constant:-20].active=YES;[button.heightAnchor constraintEqualToConstant:vj::style::controlHeight].active=YES;}
- (void)operation:(NSString*)title method:(NSString*)method action:(NSString*)action body:(Json)body {auto button=[self button:title action:@selector(boundCommand:)];button.identifier=ms(Json{{"method",method.UTF8String},{"action",action.UTF8String},{"body",body}}.dump());[_inspector addArrangedSubview:button];}
- (void)boundCommand:(NSButton*)sender {auto spec=Json::parse(sender.identifier.UTF8String);[self send:ms(spec["method"]) action:ms(spec["action"]) body:spec["body"]];}
- (void)boundProperty:(NSControl*)sender {
    try{auto binding=Json::parse(sender.identifier.UTF8String);std::string scope=binding["scope"],path=binding["path"];Json value;if([sender isKindOfClass:[NSPopUpButton class]])value=[((NSPopUpButton*)sender).selectedItem.representedObject UTF8String];else if([sender isKindOfClass:[NSButton class]])value=((NSButton*)sender).state==NSControlStateValueOn;else if(binding.value("text",false))value=sender.stringValue.UTF8String;else{const char* raw=sender.stringValue.UTF8String;char* end=nullptr;double n=std::strtod(raw,&end);if(end==raw||*end||!std::isfinite(n))throw std::runtime_error("Enter a finite number");value=n;}
        if(scope=="collection"&&path=="/graphic"){[self applySelectionProperty:"graphic" value:value];return;}
        if(scope=="trace"){for(const auto& trace:_map["project"]["traces"])if(trace["id"]==_trace){auto copy=trace;copy[Json::json_pointer(path)]=value;auto key=path.substr(1,path.find('/',1)-1);[self send:@"PATCH" action:ms("traces/"+_trace) body:{{key,copy[key]}}];return;}}
        else if(scope=="fixture"){for(const auto& fixture:_snapshot["state"].value("fixtures",Json::array()))if(fixture["id"]==vj::mappingTraceFixtureId(_mid,_trace)){auto copy=fixture;copy[Json::json_pointer(path)]=value;auto key=path.substr(1,path.find('/',1)-1);auto result=_model->request("PATCH","/api/v1/leds/"+fixture["id"].get<std::string>(),{{key,copy[key]}});if(result.status>=300){_status.stringValue=ms(result.body.value("error",std::string("Route failed")));return;}_revision=UINT64_MAX;[self refresh];return;}}
        else if(scope=="collection"||scope=="box"||scope=="point"){for(const auto& c:_map["project"]["collections"])if(c["id"]==_collection){if(scope=="collection"){auto copy=c;copy[Json::json_pointer(path)]=value;auto key=path.substr(1,path.find('/',1)-1);[self send:@"PATCH" action:ms("collections/"+_collection) body:{{key,copy[key]}}];}else{std::string key=scope=="box"?"boxes":"points",id=scope=="box"?_box:_point;auto values=c[key];for(auto& item:values)if(item["id"]==id)item[Json::json_pointer(path)]=value;[self send:@"PATCH" action:ms("collections/"+_collection) body:{{key,values}}];}return;}}
        else if(_selection.size()==1){for(const auto& r:_map["project"]["rects"])if(r["id"]==_selection[0]){auto copy=r;if(!copy.contains("curvature"))copy["curvature"]=Json::object();copy[Json::json_pointer(path)]=value;auto key=path.substr(1,path.find('/',1)-1);[self send:@"PATCH" action:ms("rects/"+r["id"].get<std::string>()) body:{{key,copy[key]}}];return;}}
    }catch(const std::exception& e){_status.stringValue=ms(e.what());}
}
- (Json)patternValue:(const std::string&)key {
    Json value;bool first=true;for(const auto& r:_map["project"]["rects"])if(has(_selection,r["id"])){auto graphic=r.value("graphic",std::string("grid"));Json fallback=key=="color"?Json(graphic=="wireframe"?"#00ff66":graphic=="alignment"?"#ffffff":"#00ff00"):key=="thickness"?Json(graphic=="wireframe"?4:3):Json(16);auto config=r.value("config",Json::object());auto next=config.value(key,fallback);if(first){value=next;first=false;}else if(next!=value)return nullptr;}return value;
}
- (void)inspectPattern {
    if(![self section:@"Pattern"])return;
    for(const auto& collection:_map["project"].value("collections",Json::array()))if(collection["id"]==_collection&&collection["kind"]=="boxes"&&(!collection.value("patternStyleExplicit",false)||collection.value("graphic",std::string{})=="faces")){
        [self propertyRow:@"Faces" control:label(@"Solid CMY")];return;
    }
    auto value=[self patternValue:"color"];auto color=[[VJFlatColorWell alloc] initWithFrame:NSMakeRect(0,0,175,26)];_patternColor=color;color.toolTip=@"Pattern color";std::string hex=value.is_string()?value.get<std::string>():"#00ff00";unsigned int rgb=0;std::istringstream stream(hex.substr(1));stream>>std::hex>>rgb;color.color=mc((rgb>>16&255)/255.,(rgb>>8&255)/255.,(rgb&255)/255.);color.target=self;color.action=@selector(patternColor:);[self propertyRow:value.is_null()?@"Color · Mixed":@"Color" control:color];
    for(auto key:{"thickness","markerSize"}){if([self mixed:"graphic"]=="solid")continue;if(std::string(key)=="markerSize"&&[self mixed:"graphic"]!="alignment")continue;auto field=[[NSTextField alloc] initWithFrame:NSMakeRect(0,0,175,24)];auto current=[self patternValue:key];field.stringValue=current.is_number()?ms(current.dump()):@"";field.placeholderString=@"Mixed";field.identifier=ms(key);field.target=self;field.action=@selector(patternNumber:);[self propertyRow:std::string(key)=="thickness"?@"Line width":@"Marker size (%)" control:field];}
}
- (void)patternColor:(NSColorWell*)sender {auto color=[sender.color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];if(!color)return;char value[8];snprintf(value,sizeof(value),"#%02x%02x%02x",int(std::round(color.redComponent*255)),int(std::round(color.greenComponent*255)),int(std::round(color.blueComponent*255)));[self applyPatternConfig:"color" value:Json(value)];}
- (void)patternNumber:(NSTextField*)sender {const char* raw=sender.stringValue.UTF8String;char* end=nullptr;double value=std::strtod(raw,&end);if(end==raw||*end||!std::isfinite(value)){_status.stringValue=@"Enter a finite number";return;}[self applyPatternConfig:sender.identifier.UTF8String value:value];}
- (void)applyPatternConfig:(const std::string&)key value:(const Json&)value {
    // Config belongs to each face, including generated collection faces. Merge
    // individually so editing color does not erase mixed line/marker settings.
    std::map<std::string,Json> groups;for(const auto& rect:_map["project"]["rects"])if(has(_selection,rect["id"])){auto config=rect.value("config",Json::object());config[key]=value;auto encoded=config.dump();if(!groups.contains(encoded))groups[encoded]=Json::array();groups[encoded].push_back(rect["id"]);}
    Json operations=Json::array();for(const auto& [config,ids]:groups)operations.push_back({{"method","PATCH"},{"action","rects"},{"body",{{"rectIds",ids},{"config",Json::parse(config)}}}});if(!operations.empty())[self send:@"POST" action:@"batch" body:{{"operations",operations}}];
}
- (void)contentPositionControls {
    if(_selection.size()!=1)return;
    auto position=[self button:@"Position content" action:@selector(positionContent:)];
    position.buttonType=NSButtonTypePushOnPushOff;
    position.state=_canvas->positioningContent==_selection[0].get<std::string>()?NSControlStateValueOn:NSControlStateValueOff;
    position.toolTip=[self mixed:"kind"]=="overlay"?@"Drag the image inside the overlay. Uses Fill fit. Shift-drag for fine positioning.":@"Drag the image inside the selected surface. Uses Cover fit. Shift-drag for fine positioning.";
    [_inspector addArrangedSubview:position];[_inspector addArrangedSubview:[self button:@"Center crop" action:@selector(centerContent:)]];
}
- (void)positionContent:(NSButton*)sender {
    if(_selection.size()!=1)return;
    const auto id=_selection[0].get<std::string>();
    if(_canvas->positioningContent==id){_canvas->positioningContent.clear();sender.state=NSControlStateValueOff;_status.stringValue=@"Geometry preview";[self inspect];return;}
    const bool overlay=[self mixed:"kind"]=="overlay";
    const std::string fitKey=overlay?"fit":"contentFit",fitValue=overlay?"fill":"cover";
    if([self mixed:fitKey]!=fitValue&&![self send:@"PATCH" action:ms("rects/"+id) body:{{fitKey,fitValue}}])return;
    [_canvas cancelPlacement];_canvas->addingPin.clear();_canvas->positioningContent=id;
    sender.state=NSControlStateValueOn;_status.stringValue=@"Position content";[self inspect];
}
- (void)centerContent:(id)sender {(void)sender;if(_selection.size()==1)[self send:@"PATCH" action:ms("rects/"+_selection[0].get<std::string>()) body:{{"contentPosition",{.5,.5}}}];}
- (void)inspectCollection {
    for(const auto& c:_map["project"]["collections"])if(c["id"]==_collection){NSString* action=ms("collections/"+_collection);[self modeChoices];[_inspector addArrangedSubview:label(ms(c["name"]))];NSMutableArray* sources=[NSMutableArray array];for(size_t i=1;i<=_snapshot["state"]["grid"]["running"].size();i++)[sources addObject:ms("out"+std::to_string(i))];[self choice:@"Source" value:c["content"]["source"] options:sources binding:{{"scope","collection"},{"path","/content/source"}}];if(c["kind"]=="planar"||(c["kind"]=="boxes"&&![self boxSubdivisionTarget].is_null()))[self subdivisionButton];[self inspectPattern];[self toggle:@"Enabled" value:c.value("enabled",true) binding:{{"scope","collection"},{"path","/enabled"}}];[self traceControls:c["content"].value("trace",Json::object()) scope:"collection" prefix:"/content/trace"];
        if(!_selection.empty()){[_inspector addArrangedSubview:label(_selection.size()==1?@"Selected surface":@"Selected surfaces")];[self popup:@"Content fit" key:@"contentFit" values:@[@"inherit",@"contain",@"cover",@"stretch"]];[self contentPositionControls];}
        if(c["kind"]!="boxes"){auto content=c["content"];int rotation=content.value("rotation",0);[_inspector addArrangedSubview:label(ms("Direction · "+std::to_string(rotation)+"°"))];content["rotation"]=(rotation+90)%360;[self operation:@"Rotate direction 90°" method:@"PATCH" action:action body:{{"content",content}}];}
        if(c["kind"]=="planar"){[self choice:@"Layout" value:c["content"]["layout"] options:@[@"follow",@"repeat",@"span"] binding:{{"scope","collection"},{"path","/content/layout"}}];if(_selection.size()==1)for(const auto& f:c["faces"])if(f["rectId"]==_selection[0])[self operation:@"Use as reference" method:@"PATCH" action:action body:{{"referenceFaceId",f["id"]}}];}
        if(c["kind"]=="boxes"&&[self section:@"Box geometry"]){for(auto key:{"scale","perspective","aspect"})[self field:ms(key) value:c["projection"][key] binding:{{"scope","collection"},{"path","/projection/"+std::string(key)}}];for(int i=0;i<2;i++)[self field:i?@"Projector Y":@"Projector X" value:c["projection"]["offset"][i] binding:{{"scope","collection"},{"path","/projection/offset/"+std::to_string(i)}}];if(!_box.empty())for(const auto& box:c["boxes"])if(box["id"]==_box){[_inspector addArrangedSubview:label(ms(box["name"]))];for(auto key:{"center","size","rotation"})for(int i=0;i<3;i++)[self field:ms(std::string(key)+" "+"XYZ"[i]) value:box[key][i] binding:{{"scope","box"},{"path","/"+std::string(key)+"/"+std::to_string(i)},{"disabled",box.contains("alignment")}}];[self operation:@"Duplicate box" method:@"PATCH" action:action body:{{"copyBox",{{"boxId",_box}}}}];if(box.contains("alignment")){auto boxes=c["boxes"];for(auto& item:boxes)if(item["id"]==_box)item.erase("alignment");[self operation:@"Reset alignment" method:@"PATCH" action:action body:{{"boxes",boxes}}];}if(c["boxes"].size()>1){auto boxes=c["boxes"];boxes.erase(std::remove_if(boxes.begin(),boxes.end(),[&](const Json& box){return box["id"]==_box;}),boxes.end());[self operation:@"Delete box" method:@"PATCH" action:action body:{{"boxes",boxes}}];}}}
        if(c["kind"]=="points"&&[self section:@"Point geometry"]){[self choice:@"Shape" value:c["shape"] options:@[@"circle",@"square",@"rectangle"] binding:{{"scope","collection"},{"path","/shape"}}];[self field:@"Radius" value:c["radius"] binding:{{"scope","collection"},{"path","/radius"}}];[self field:@"Aspect" value:c["aspect"] binding:{{"scope","collection"},{"path","/aspect"}}];auto points=c["points"];std::string id="p"+std::to_string((uint64_t)([NSDate timeIntervalSinceReferenceDate]*1000000));points.push_back({{"id",id},{"name","Point"},{"position",{.5,.5}}});[self operation:@"Add point" method:@"PATCH" action:action body:{{"points",points}}];if(!_point.empty())for(const auto& p:c["points"])if(p["id"]==_point){[_inspector addArrangedSubview:label(ms(p["name"]))];for(int i=0;i<2;i++)[self field:i?@"Position Y":@"Position X" value:p["position"][i] binding:{{"scope","point"},{"path","/position/"+std::to_string(i)}}];[self field:@"Rotation" value:p["rotation"] binding:{{"scope","point"},{"path","/rotation"}}];[self field:@"Radius" value:p.value("radius",c["radius"]) binding:{{"scope","point"},{"path","/radius"}}];for(int i=0;i<2;i++)[self field:i?@"Coverage height":@"Coverage width" value:p["coverage"][i] binding:{{"scope","point"},{"path","/coverage/"+std::to_string(i)}}];[self field:@"Margin" value:p["margin"] binding:{{"scope","point"},{"path","/margin"}}];for(int corner=0;corner<4;corner++)for(int axis=0;axis<2;axis++)[self field:ms("Plane "+std::to_string(corner+1)+(axis?" Y":" X")) value:p["alignment"][corner][axis] binding:{{"scope","point"},{"path","/alignment/"+std::to_string(corner)+"/"+std::to_string(axis)}}];if(c["points"].size()>1){auto points=c["points"];points.erase(std::remove_if(points.begin(),points.end(),[&](const Json& point){return point["id"]==_point;}),points.end());[self operation:@"Delete point" method:@"PATCH" action:action body:{{"points",points}}];}}}
        if(c["kind"]=="planar"&&_selection.size()==1)[self inspectGeometry];
        if([self section:@"Collection actions"]){[self operation:@"Remove collection" method:@"DELETE" action:action body:Json::object()];[self operation:@"Delete with surfaces" method:@"DELETE" action:action body:{{"removeFaces",true}}];}return;
    }
}
- (Json)boxSubdivisionTarget {
    if(_box.empty()||_collection.empty()||!_trace.empty())return nullptr;
    for(const auto& c:_map["project"]["collections"])if(c["id"]==_collection&&c["kind"]=="boxes"){
        Json ids=Json::array();for(const auto& f:c["faces"])if(f["boxId"]==_box)ids.push_back(f["rectId"]);
        if(ids.empty()||ids.size()!=_selection.size())return nullptr;for(const auto& id:ids)if(!has(_selection,id))return nullptr;
        return {{"collectionId",_collection},{"boxId",_box}};
    }
    return nullptr;
}
- (void)openBoxSubdivision:(NSMenuItem*)sender {
    Json ids=Json::array();for(NSString* id in sender.representedObject[@"ids"])ids.push_back(id.UTF8String);[self select:ids];[self openSubdivision:sender];
}
- (NSString*)subdivisionError {
    if(_selection.size()!=1||!_trace.empty())return @"Select one surface";
    try{
        for(const auto& c:_map["project"]["collections"])for(const auto& f:c["faces"])if(f["rectId"]==_selection[0]&&c["kind"]!="planar")return @"Box and point faces are not supported yet";
        for(const auto& rect:_map["project"]["rects"])if(rect["id"]==_selection[0]){vj::mappingSubdivisionCells(rect,2,3);return @"";}
    }catch(const std::exception& e){return ms(e.what());}
    return @"Surface unavailable";
}
- (void)subdivisionButton {
    if(_selection.size()!=1&&[self boxSubdivisionTarget].is_null())return;
    auto button=[self button:@"Subdivide…" action:@selector(openSubdivision:)];auto target=[self boxSubdivisionTarget];auto error=target.is_null()?[self subdivisionError]:@"";button.enabled=error.length==0;button.toolTip=error.length?error:target.is_null()?@"Preview rows and columns":@"Preview columns, rows and depth";
    [_inspector addArrangedSubview:button];[button.widthAnchor constraintEqualToAnchor:_inspector.widthAnchor constant:-20].active=YES;
}
- (void)openSubdivision:(id)sender {
    auto target=[self boxSubdivisionTarget];bool box=!target.is_null();auto error=box?@"":[self subdivisionError];if(error.length){_status.stringValue=error;return;}
    [_subdividePopover close];_subdivideBoxTarget=target;_subdivideDepth=nil;if(!box)for(const auto& rect:_map["project"]["rects"])if(rect["id"]==_selection[0])_subdivideSurface=rect;
    _subdivideMid=_mid;_subdivideRevision=_map["revision"];_subdivideOrientation=0;
    auto content=stack(NSUserInterfaceLayoutOrientationVertical);content.spacing=10;content.edgeInsets=NSEdgeInsetsMake(12,12,12,12);
    auto title=label(box?@"Subdivide box":@"Subdivide surface");title.font=vj::style::font(12);[content addArrangedSubview:title];
    _subdivideDiagram=[[VJSubdivisionDiagram alloc]initWithFrame:NSMakeRect(0,0,288,170)];_subdivideDiagram->aspect=vj::mappingCanvasAspect(_map["project"]);_subdivideDiagram.translatesAutoresizingMaskIntoConstraints=NO;[content addArrangedSubview:_subdivideDiagram];
    [_subdivideDiagram.widthAnchor constraintEqualToConstant:288].active=YES;[_subdivideDiagram.heightAnchor constraintEqualToConstant:170].active=YES;
    for(NSString* key in (box?@[@"Columns",@"Rows",@"Depth"]:@[@"Columns",@"Rows"])){
        auto row=stack(NSUserInterfaceLayoutOrientationHorizontal);row.spacing=8;auto title=label(box?[key stringByAppendingString:[key isEqual:@"Columns"]?@" (X)":[key isEqual:@"Rows"]?@" (Y)":@" (Z)"]:key);title.textColor=[key isEqual:@"Columns"]?mc(.25,.8,1):[key isEqual:@"Rows"]?mc(1,.68,.28):mc(.3,.9,.5);[title.widthAnchor constraintEqualToConstant:100].active=YES;[row addArrangedSubview:title];
        auto field=[[NSTextField alloc]initWithFrame:NSZeroRect];field.stringValue=box||[key isEqual:@"Columns"]?@"2":@"3";field.alignment=NSTextAlignmentRight;field.identifier=key;field.delegate=self;field.target=self;field.action=@selector(subdivisionChange:);field.accessibilityLabel=key;
        [field.widthAnchor constraintEqualToConstant:80].active=YES;[field.heightAnchor constraintEqualToConstant:26].active=YES;[row addArrangedSubview:field];
        auto stepper=[[NSStepper alloc]initWithFrame:NSZeroRect];stepper.minValue=1;stepper.maxValue=128;stepper.increment=1;stepper.integerValue=field.integerValue;stepper.identifier=key;stepper.target=self;stepper.action=@selector(subdivisionStep:);[row addArrangedSubview:stepper];[content addArrangedSubview:row];
        if([key isEqual:@"Columns"])_subdivideColumns=field;else if([key isEqual:@"Rows"])_subdivideRows=field;else _subdivideDepth=field;
    }
    if(!box){auto rotate=[self button:@"Rotate grid ↻" action:@selector(rotateSubdivision:)];[content addArrangedSubview:rotate];}
    _subdivideCount=label(@"");_subdivideCount.lineBreakMode=NSLineBreakByWordWrapping;_subdivideCount.maximumNumberOfLines=2;[_subdivideCount.widthAnchor constraintEqualToConstant:288].active=YES;[content addArrangedSubview:_subdivideCount];
    auto actions=stack(NSUserInterfaceLayoutOrientationHorizontal);actions.spacing=8;[actions addArrangedSubview:[self button:@"Cancel" action:@selector(cancelSubdivision:)]];_subdivideApply=[self button:@"Subdivide" action:@selector(applySubdivision:)];[actions addArrangedSubview:_subdivideApply];[content addArrangedSubview:actions];
    _subdividePopover=vj::style::popover(content,NSMakeSize(312,420));_subdividePopover.delegate=self;[self updateSubdivision];
    NSView* anchor=[sender isKindOfClass:NSView.class]?sender:_canvas;NSRect at=anchor==_canvas?NSMakeRect(NSMidX(anchor.bounds),NSMidY(anchor.bounds),1,1):anchor.bounds;
    [_subdividePopover showRelativeToRect:at ofView:anchor preferredEdge:NSRectEdgeMaxX];
}
- (void)subdivisionChange:(id)sender {(void)sender;[self updateSubdivision];}
- (void)controlTextDidChange:(NSNotification*)note {if(note.object==_subdivideColumns||note.object==_subdivideRows||note.object==_subdivideDepth){NSTextField* field=note.object;for(NSView* control in field.superview.subviews)if([control isKindOfClass:NSStepper.class])((NSStepper*)control).integerValue=std::clamp(field.integerValue,NSInteger(1),NSInteger(((NSStepper*)control).maxValue));[self updateSubdivision];}}
- (void)subdivisionStep:(NSStepper*)sender {NSTextField* field=[sender.identifier isEqual:@"Columns"]?_subdivideColumns:[sender.identifier isEqual:@"Rows"]?_subdivideRows:_subdivideDepth;field.integerValue=sender.integerValue;[self updateSubdivision];}
- (void)rotateSubdivision:(id)sender {(void)sender;_subdivideOrientation=(_subdivideOrientation+1)%4;[self updateSubdivision];}
- (void)updateSubdivision {
    _subdivideApply.enabled=NO;_subdivideDiagram->cells=Json::array();_canvas->subdivisionCells=Json::array();
    try{
        auto parse=[](NSTextField* field){const char* raw=field.stringValue.UTF8String;char* end=nullptr;long n=strtol(raw,&end,10);if(end==raw||*end||n<1||n>128)throw std::runtime_error("Counts must be 1–128");return int(n);};
        int columns=parse(_subdivideColumns),rows=parse(_subdivideRows);if(!_subdivideBoxTarget.is_null()){
            int depth=parse(_subdivideDepth);auto plan=vj::mappingBoxSubdivision(_map["project"],_subdivideBoxTarget["collectionId"],_subdivideBoxTarget["boxId"],columns,rows,depth);
            _subdivideDiagram->cells=plan["cells"];_canvas->subdivisionCells=plan["cells"];
            _subdivideCount.stringValue=[NSString stringWithFormat:@"%d × %d × %d · %lu boxes · %lu faces",columns,rows,depth,(unsigned long)plan["boxIds"].size(),(unsigned long)plan["rectIds"].size()];_subdivideCount.textColor=vj::style::secondary();_subdivideApply.enabled=YES;
            [_subdivideDiagram setNeedsDisplay:YES];[_canvas setNeedsDisplay:YES];return;
        }int available=129-int(_map["project"]["rects"].size());
        if(columns*rows<2)throw std::runtime_error("Choose at least two faces");if(columns*rows>available)throw std::runtime_error("Surface limit: "+std::to_string(available)+" new faces available");
        auto cells=vj::mappingSubdivisionCells(_subdivideSurface,columns,rows,_subdivideOrientation);_subdivideDiagram->cells=cells;_canvas->subdivisionCells=cells;
        _subdivideCount.stringValue=[NSString stringWithFormat:@"%d columns × %d rows · %d faces",columns,rows,columns*rows];_subdivideCount.textColor=vj::style::secondary();_subdivideApply.enabled=YES;
    }catch(const std::exception& e){_subdivideCount.stringValue=ms(e.what());_subdivideCount.textColor=mc(1,.65,.3);}
    [_subdivideDiagram setNeedsDisplay:YES];[_canvas setNeedsDisplay:YES];
}
- (void)cancelSubdivision:(id)sender {(void)sender;[_subdividePopover close];}
- (void)popoverDidClose:(NSNotification*)note {if(note.object==_subdividePopover){_canvas->subdivisionCells=Json::array();[_canvas setNeedsDisplay:YES];}}
- (void)applySubdivision:(id)sender {
    (void)sender;[self.window makeFirstResponder:_subdivideApply];if(!_subdivideApply.enabled)return;
    if(_mid!=_subdivideMid||_map["revision"]!=_subdivideRevision){_subdivideCount.stringValue=@"Surface changed · Reopen Subdivide";_subdivideApply.enabled=NO;return;}
    if(!_subdivideBoxTarget.is_null()){
        auto body=_subdivideBoxTarget;body.update({{"columns",_subdivideColumns.integerValue},{"rows",_subdivideRows.integerValue},{"depth",_subdivideDepth.integerValue}});
        if([self send:@"POST" action:@"subdivide-box" body:body])[_subdividePopover close];return;
    }
    if([self send:@"POST" action:@"subdivide" body:{{"rectId",_subdivideSurface["id"]},{"columns",_subdivideColumns.integerValue},{"rows",_subdivideRows.integerValue},{"orientation",_subdivideOrientation}}])[_subdividePopover close];
}
- (void)curveEdge:(NSPopUpButton*)sender {_curveSide=[sender.selectedItem.representedObject UTF8String];[self inspect];}
- (void)beginCurve:(const std::string&)key {if(key=="top"||key=="right"||key=="bottom"||key=="left")_curveSide=key;_curveTracking=YES;_curveBefore=_map;_curvePatch=nullptr;_curveKey=key;}
- (BOOL)previewCurve:(double)value {
    try{auto candidate=_canvas->mapping;for(auto& rect:candidate["project"]["rects"])if(rect["id"]==_selection.at(0)){
        Json patch={{"curvature",{{_curveKey,value}}}};vj::editMappingGeometry(rect,patch);_curvePatch=patch;_canvas->mapping=candidate;[_canvas setNeedsDisplay:YES];
        [self previewProject:candidate["project"] revision:_curveBefore["revision"]];
        _status.stringValue=@"Curvature";return YES;
    }}catch(const std::exception& error){_status.stringValue=ms(error.what());}return NO;
}
- (void)finishCurve:(BOOL)cancelled {
    auto patch=_curvePatch;_curveTracking=NO;_canvas->mapping=_curveBefore;
    if(!cancelled&&!patch.is_null()&&_selection.size()==1)[self send:@"PATCH" action:ms("rects/"+_selection[0].get<std::string>()) body:patch];
    [self clearProjectedPreview];
    _revision=UINT64_MAX;[self refresh];
}
- (void)curveNumber:(NSTextField*)sender {
    try{auto settings=Json::parse(sender.identifier.UTF8String);const char* raw=sender.stringValue.UTF8String;char* end=nullptr;double value=std::strtod(raw,&end);if(end==raw||*end||!std::isfinite(value))throw std::runtime_error("Enter a finite number");
        value=std::clamp(value,settings["minimum"].get<double>(),settings["maximum"].get<double>());[self beginCurve:settings["key"]];BOOL valid=[self previewCurve:value/settings["scale"].get<double>()];[self finishCurve:!valid];
    }catch(const std::exception& error){_status.stringValue=ms(error.what());}
}
- (void)curveControl:(NSString*)title key:(const std::string&)key value:(double)value scale:(double)scale minimum:(double)minimum maximum:(double)maximum step:(double)step {
    [_inspector addArrangedSubview:label(title)];auto row=stack(NSUserInterfaceLayoutOrientationHorizontal);
    auto slider=[[VJMapCurveSlider alloc] initWithFrame:NSMakeRect(0,0,96,22)];slider.minValue=minimum;slider.maxValue=maximum;slider.doubleValue=value*scale;slider.valueStep=step;slider.toolTip=@"Shift-drag: fine · Esc: cancel";[slider.widthAnchor constraintGreaterThanOrEqualToConstant:96].active=YES;
    auto number=[[NSTextField alloc] initWithFrame:NSMakeRect(0,0,48,22)];number.stringValue=[NSString stringWithFormat:@"%.2f",value*scale];number.identifier=ms(Json{{"key",key},{"scale",scale},{"minimum",minimum},{"maximum",maximum}}.dump());number.target=self;number.action=@selector(curveNumber:);[number.widthAnchor constraintEqualToConstant:vj::style::valueWidth].active=YES;
    slider.numberField=number;number.alignment=NSTextAlignmentRight;[number.heightAnchor constraintEqualToConstant:vj::style::controlHeight].active=YES;[slider.heightAnchor constraintEqualToConstant:vj::style::controlHeight].active=YES;
    __weak VJMapper* weak=self;const std::string curveKey=key;
    slider.beginEdit=^{[weak beginCurve:curveKey];};slider.changeValue=^BOOL(double next){return [weak previewCurve:next/scale];};slider.endEdit=^(BOOL cancel){[weak finishCurve:cancel];};
    [row addArrangedSubview:slider];[row addArrangedSubview:number];auto reset=[self button:@"0" action:@selector(boundCommand:)];reset.identifier=ms(Json{{"method","PATCH"},{"action","rects/"+_selection.at(0).get<std::string>()},{"body",{{"curvature",{{key,0.}}}}}}.dump());reset.toolTip=[NSString stringWithFormat:@"Reset %@",title];[reset.widthAnchor constraintEqualToConstant:24].active=YES;[row addArrangedSubview:reset];row.spacing=vj::style::gap;[_inspector addArrangedSubview:row];[row.widthAnchor constraintEqualToAnchor:_inspector.widthAnchor constant:-20].active=YES;[slider setContentHuggingPriority:200 forOrientation:NSLayoutConstraintOrientationHorizontal];
}
- (void)inspectGeometry {if(_selection.size()!=1)return;for(const auto& r:_map["project"]["rects"])if(r["id"]==_selection[0]){NSString* action=ms("rects/"+r["id"].get<std::string>());if(!ownedSurface(_map,r["id"])&&[self section:@"Geometry"]){[self toggle:@"Fold" value:r.value("fold",false) binding:{{"scope","rect"},{"path","/fold"}}];if(!r.value("fold",false)&&r["corners"].size()>4)for(size_t i=0;i<r["corners"].size();i++)[self operation:ms("Remove point "+std::to_string(i+1)) method:@"PATCH" action:action body:{{"removePoint",i}}];}if(r["corners"].size()!=4||r.value("fold",false))return;auto curve=r.value("curvature",Json::object());if(curve.is_null())curve=Json::object();if(![self section:@"Curvature"])return;
        for(auto side:{"top","right","bottom","left"})[self curveControl:ms(side).capitalizedString key:side value:curve.value(side,0.) scale:100 minimum:-200 maximum:200 step:.1];
        if(_curveSide.empty())_curveSide="top";
        [_inspector addArrangedSubview:label(@"Edge shape")];auto edges=[[VJPopup alloc] initWithFrame:NSZeroRect pullsDown:NO];for(auto side:{"top","right","bottom","left"}){[edges addItemWithTitle:ms(side).capitalizedString];edges.lastItem.representedObject=ms(side);if(_curveSide==side)[edges selectItem:edges.lastItem];}edges.target=self;edges.action=@selector(curveEdge:);[_inspector addArrangedSubview:edges];
        [self curveControl:@"Skew (%)" key:_curveSide+"Skew" value:curve.value(_curveSide+"Skew",0.) scale:100 minimum:-100 maximum:100 step:.1];
        [self curveControl:@"Shoulders (%)" key:_curveSide+"Shape" value:curve.value(_curveSide+"Shape",0.) scale:100 minimum:-100 maximum:100 step:.1];
        for(auto key:{"wrapX","wrapY"})[self curveControl:std::string(key)=="wrapX"?@"Wrap X (°)":@"Wrap Y (°)" key:key value:curve.value(key,0.) scale:1 minimum:0 maximum:170 step:1];
        for(auto key:{"spacingX","spacingY"})[self curveControl:std::string(key)=="spacingX"?@"Spacing X (%)":@"Spacing Y (%)" key:key value:curve.value(key,0.) scale:100./3 minimum:-100 maximum:100 step:.1];
        Json reset=Json::object();for(auto side:{"top","right","bottom","left"})for(auto suffix:{"","Skew","Shape"})reset[std::string(side)+suffix]=0.;for(auto key:{"wrapX","wrapY","spacingX","spacingY"})reset[key]=0.;if(curve.contains("pins"))reset["pins"]=curve["pins"];
        [self operation:@"Reset curvature" method:@"PATCH" action:action body:{{"curvature",reset}}];
        if(![self section:@"Edge pins"])return;[_inspector addArrangedSubview:[self button:_canvas->addingPin==r["id"].get<std::string>()?@"Done adding pins":@"Add pins on canvas" action:@selector(toggleAddPins:)]];auto pins=curve.value("pins",Json{{"enabled",true},{"method","fit"},{"points",Json::array()}});[self toggle:@"Pins enabled" value:pins.value("enabled",true) binding:{{"scope","rect"},{"path","/curvature/pins/enabled"}}];[self choice:@"Method" value:pins.value("method",Json("fit")) options:@[@"fit",@"local"] binding:{{"scope","rect"},{"path","/curvature/pins/method"}}];const auto& points=pins["points"];for(size_t i=0;i<points.size();i++){const auto& pin=points[i];std::string path="/curvature/pins/points/"+std::to_string(i);[_inspector addArrangedSubview:label(ms("Pin "+std::to_string(i+1)))];[self choice:@"Edge" value:pin["side"] options:@[@"top",@"right",@"bottom",@"left"] binding:{{"scope","rect"},{"path",path+"/side"}}];[self field:@"Position" value:pin["t"] binding:{{"scope","rect"},{"path",path+"/t"}}];for(int a=0;a<2;a++)[self field:a?@"Target Y":@"Target X" value:pin["target"][a] binding:{{"scope","rect"},{"path",path+"/target/"+std::to_string(a)}}];[self toggle:@"Enabled" value:pin.value("enabled",true) binding:{{"scope","rect"},{"path",path+"/enabled"}}];auto next=pins;next["points"].erase(next["points"].begin()+i);[self operation:@"Remove pin" method:@"PATCH" action:action body:{{"curvature",{{"pins",next}}}}];}
        if(points.size()<32){bool added=false;for(auto side:{"top","right","bottom","left"}){if(added)break;int count=0;for(const auto& p:points)if(p["side"]==side)count++;if(count>=8)continue;for(int i=1;i<=8;i++){double t=i/9.;bool free=true;for(const auto& p:points)if(p["side"]==side&&std::abs(p["t"].get<double>()-t)<.005)free=false;if(!free)continue;auto next=pins;Json target=std::string(side)=="top"?Json::array({t,0}):std::string(side)=="bottom"?Json::array({t,1}):std::string(side)=="left"?Json::array({0,t}):Json::array({1,t});next["points"].push_back({{"id","pin-"+std::to_string((uint64_t)([NSDate timeIntervalSinceReferenceDate]*1000000))},{"side",side},{"t",t},{"target",target},{"enabled",true}});[self operation:@"Add pin" method:@"PATCH" action:action body:{{"curvature",{{"pins",next}}}}];added=true;break;}}}return;
    }}
- (void)createCollection:(NSMenuItem*)sender {NSString* kind=sender.representedObject;Json body={{"kind",[kind isEqualToString:@"stack"]?"boxes":kind.UTF8String}};if([kind isEqualToString:@"planar"])body["rectIds"]=_selection;if([kind isEqualToString:@"stack"])body["preset"]="stack";[self send:@"POST" action:@"collections" body:body];}
- (void)applyGeometry:(const Json&)updates {
    try{auto operations=geometryOperations(_map,updates);if(!operations.empty())[self send:@"POST" action:@"batch" body:{{"operations",operations}}];
    }catch(const std::exception& e){_status.stringValue=ms(e.what());_canvas->mapping=_map;[_canvas setNeedsDisplay:YES];}
}

- (void)applySelectionProperty:(const std::string&)key value:(const Json&)value {
    Json operations=Json::array(),independent=Json::array(),muted=Json::array();std::set<std::string> owned;bool shared=key=="source"||key=="mode"||key=="graphic";
    for(const auto& c:_map["project"].value("collections",Json::array())){bool selected=false;for(const auto& f:c["faces"]){owned.insert(f["rectId"]);selected|=has(_selection,f["rectId"]);}if(!selected)continue;if(key=="fit"||key=="kind"){_status.stringValue=@"Collection faces use fixed geometry and fit";return;}if(shared){Json body;if(key=="source"){if(value=="none")body={{"enabled",false}};else{auto content=c["content"];content["source"]=value;body={{"content",content}};}}else body={{key,value}};operations.push_back({{"method","PATCH"},{"action","collections/"+c["id"].get<std::string>()},{"body",body}});}}
    for(const auto& r:_map["project"]["rects"])if(has(_selection,r["id"])&&(!shared||!owned.contains(r["id"]))){if(key=="source"&&value!="none"&&r.value("source",std::string{})=="none")muted.push_back(r["id"]);else independent.push_back(r["id"]);}if(!independent.empty())operations.push_back({{"method","PATCH"},{"action","rects"},{"body",{{"rectIds",independent},{key,value}}}});if(!muted.empty())operations.push_back({{"method","PATCH"},{"action","rects"},{"body",{{"rectIds",muted},{"mutedSource",value}}}});if(key=="graphic"){Json patternIDs=independent;if(value=="solid")for(const auto& c:_map["project"].value("collections",Json::array())){bool touched=false;for(const auto& f:c["faces"])touched|=has(_selection,f["rectId"]);if(touched)for(const auto& f:c["faces"])if(!has(patternIDs,f["rectId"]))patternIDs.push_back(f["rectId"]);}Json config={{"color",value=="solid"?"#ff69b4":value=="wireframe"?"#00ff66":value=="alignment"?"#ffffff":"#00ff00"},{"thickness",value=="wireframe"?4:3}};if(value=="alignment")config["markerSize"]=16;if(!patternIDs.empty())operations.push_back({{"method","PATCH"},{"action","rects"},{"body",{{"rectIds",patternIDs},{"config",config}}}});}if(!operations.empty())[self send:@"POST" action:@"batch" body:{{"operations",operations}}];
}

- (void)traceControls:(Json)settings scope:(const std::string&)scope prefix:(const std::string&)prefix {if(![self section:@"Trace"])return;if(!settings.is_object())settings=Json::object();[self choice:@"Path" value:settings.value("mode",Json("perimeter")) options:@[@"perimeter",@"horizontal",@"vertical"] binding:{{"scope",scope},{"path",prefix+"/mode"}}];[self choice:@"Scope" value:settings.value("scope",Json("face")) options:@[@"face",@"collection"] binding:{{"scope",scope},{"path",prefix+"/scope"}}];[self field:@"Width" value:settings.value("width",Json(.04)) binding:{{"scope",scope},{"path",prefix+"/width"}}];[self field:@"Offset" value:settings.value("offset",Json(0.)) binding:{{"scope",scope},{"path",prefix+"/offset"}}];[self toggle:@"Reverse" value:settings.value("reverse",false) binding:{{"scope",scope},{"path",prefix+"/reverse"}}];}
- (void)inspectTrace {
    for(const auto& trace:_map["project"].value("traces",Json::array()))if(trace["id"]==_trace){
        [_inspector addArrangedSubview:label(@"LED trace")];[self field:@"Name" value:trace["name"] binding:{{"scope","trace"},{"path","/name"},{"text",true}}];[self toggle:@"Visible" value:trace.value("enabled",true) binding:{{"scope","trace"},{"path","/enabled"}}];
        if([self section:@"Appearance"]){for(const auto* key:{"width","feather","glow","pixels"})[self field:ms(key) value:trace[key] binding:{{"scope","trace"},{"path","/"+std::string(key)}}];[self choice:@"Blend" value:trace["blend"] options:@[@"normal",@"add",@"screen"] binding:{{"scope","trace"},{"path","/blend"}}];}
        for(const auto& fixture:_snapshot["state"].value("fixtures",Json::array()))if(fixture["id"]==vj::mappingTraceFixtureId(_mid,_trace)){
            if(![self section:@"Output routing"])continue;NSMutableArray* sources=[NSMutableArray arrayWithObject:@"none"];for(size_t i=1;i<=_snapshot["state"]["grid"]["running"].size();i++)[sources addObject:ms("out"+std::to_string(i))];auto route=fixture.value("route",Json{{"out","none"},{"start",0.},{"end",1.},{"offset",0.},{"reverse",false}});[self choice:@"Out" value:route.value("out",Json("none")) options:sources binding:{{"scope","fixture"},{"path","/route/out"}}];[self toggle:@"Fixture enabled" value:fixture.value("enabled",true) binding:{{"scope","fixture"},{"path","/enabled"}}];[self field:@"Brightness" value:fixture.value("brightness",Json(1.)) binding:{{"scope","fixture"},{"path","/brightness"}}];for(const auto* key:{"start","end","offset"})[self field:ms(key) value:route.value(key,Json(0.)) binding:{{"scope","fixture"},{"path","/route/"+std::string(key)}}];[self toggle:@"Reverse" value:route.value("reverse",false) binding:{{"scope","fixture"},{"path","/route/reverse"}}];
        }
        _target=[[VJPopup alloc] initWithFrame:NSZeroRect pullsDown:NO];_target.identifier=@"send-projector";for(auto it=_snapshot["mappings"].begin();it!=_snapshot["mappings"].end();++it)if(it.key()!=_mid){[_target addItemWithTitle:ms("Projector "+it.key())];_target.lastItem.representedObject=ms(it.key());}[_inspector addArrangedSubview:_target];[_inspector addArrangedSubview:[self button:@"Send to projector" action:@selector(sendSelected:)]];
        NSString* action=ms("traces/"+_trace);if(![self section:@"Points"])return;auto points=trace["points"];if(points.size()<256){auto last=points.back(),previous=points[points.size()-2];double dx=last[0].get<double>()-previous[0].get<double>(),dy=last[1].get<double>()-previous[1].get<double>(),length=std::hypot(dx,dy);if(length<1e-6){dx=1;dy=0;length=1;}[self operation:@"Add point" method:@"PATCH" action:action body:{{"addPoint",{std::clamp(last[0].get<double>()+.15*dx/length,0.,1.),std::clamp(last[1].get<double>()+.15*dy/length,0.,1.)}}}];}
        for(size_t i=0;i<points.size();i++){for(int a=0;a<2;a++)[self field:ms("Point "+std::to_string(i+1)+(a?" Y":" X")) value:points[i][a] binding:{{"scope","trace"},{"path","/points/"+std::to_string(i)+"/"+std::to_string(a)}}];if(points.size()>2)[self operation:ms("Remove point "+std::to_string(i+1)) method:@"PATCH" action:action body:{{"removePoint",i}}];}[self operation:@"Delete trace" method:@"DELETE" action:action body:Json::object()];return;
    }
}
- (NSString*)expansionKey:(NSDictionary*)node {return [NSString stringWithFormat:@"%s:%@:%@",_mid.c_str(),node[@"kind"],node[@"id"]];}
- (void)restoreExpansion:(NSArray*)nodes {for(NSDictionary* node in nodes)if([node[@"children"] count]&&![_collapsed containsObject:[self expansionKey:node]]){[_outline expandItem:node];[self restoreExpansion:node[@"children"]];}}
- (void)outlineViewItemDidExpand:(NSNotification*)note {if(_refreshing)return;NSDictionary* node=note.userInfo[@"NSObject"];if(!node)return;[_collapsed removeObject:[self expansionKey:node]];[[NSUserDefaults standardUserDefaults] setObject:_collapsed.allObjects forKey:@"VJMapperCollapsed"];}
- (void)outlineViewItemDidCollapse:(NSNotification*)note {if(_refreshing)return;NSDictionary* node=note.userInfo[@"NSObject"];if(!node)return;[_collapsed addObject:[self expansionKey:node]];[[NSUserDefaults standardUserDefaults] setObject:_collapsed.allObjects forKey:@"VJMapperCollapsed"];}
- (void)renameSelection:(id)sender {(void)sender;NSInteger row=_outline.selectedRow;if(row>=0){NSView* view=((VJMapObjectCell*)[_outline viewAtColumn:0 row:row makeIfNecessary:YES]).name;if([view isKindOfClass:[NSTextField class]]){((NSTextField*)view).editable=YES;[self.window makeFirstResponder:view];[(NSTextField*)view selectText:nil];}}}
- (NSMenu*)sidebarMenu:(NSEvent*)event {
    NSInteger row=[_outline rowAtPoint:[_outline convertPoint:event.locationInWindow fromView:nil]];if(row<0)return nil;NSDictionary* node=[_outline itemAtRow:row];return [self objectMenu:node];
}
- (NSMenu*)objectMenu:(NSDictionary*)node {bool selected=[node[@"kind"] isEqualToString:@"trace"]?_trace==[node[@"id"] UTF8String]:[node[@"ids"] count]>0;for(NSString* id in node[@"ids"])selected&=has(_selection,std::string(id.UTF8String));if(!selected){if([node[@"kind"] isEqualToString:@"trace"])[self selectTrace:Json([node[@"id"] UTF8String])];else {Json ids=Json::array();for(NSString* id in node[@"ids"])ids.push_back(id.UTF8String);[self select:ids];}}
    for(NSInteger row=0;row<_outline.numberOfRows;row++){NSDictionary* current=[_outline itemAtRow:row];if([current[@"id"] isEqual:node[@"id"]]&&[current[@"kind"] isEqual:node[@"kind"]]){node=current;break;}}
    auto menu=[[NSMenu alloc] initWithTitle:@"Mapping"];auto add=[&](NSString* title,SEL action){auto item=[[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];item.target=self;[menu addItem:item];return item;};
    if(![node[@"kind"] isEqualToString:@"trace"]&&!_selection.empty()){auto transform=add(@"Scale & rotate",@selector(quickTransform:));transform.keyEquivalent=@"r";transform.keyEquivalentModifierMask=0;}
    add([node[@"mapperHidden"] boolValue]?@"Show in Mapper":@"Hide in Mapper",@selector(contextVisibility:)).representedObject=node;add(@"Solo in Mapper",@selector(contextSolo:)).representedObject=node;[menu addItem:[NSMenuItem separatorItem]];add(@"Rename",@selector(contextRename:)).representedObject=node;if([node[@"kind"] isEqualToString:@"box"]){add(@"Subdivide…",@selector(openBoxSubdivision:)).representedObject=node;}if([node[@"kind"] isEqualToString:@"rect"]){auto item=add(@"Subdivide…",@selector(openSubdivision:));item.enabled=[self subdivisionError].length==0;item.toolTip=[self subdivisionError];}add(@"Mute / Unmute",@selector(mute:));add(@"Duplicate",@selector(contextDuplicate:)).representedObject=node;if(_selection.size()>1)add(@"Create group",@selector(group:));if([node[@"kind"] isEqualToString:@"group"])add(@"Ungroup",@selector(ungroup:));
    if([node[@"children"] count]){auto item=add([_outline isItemExpanded:node]?@"Collapse":@"Expand",@selector(contextExpansion:));item.representedObject=node;}
    auto destinations=[[NSMenu alloc] initWithTitle:@"Send to projector"];for(auto it=_snapshot["mappings"].begin();it!=_snapshot["mappings"].end();++it)if(it.key()!=_mid){auto item=[[NSMenuItem alloc] initWithTitle:ms("Projector "+it.key()) action:@selector(contextSend:) keyEquivalent:@""];item.target=self;Json body;if([node[@"kind"] isEqualToString:@"trace"])body={{"kind","trace"},{"id",[node[@"id"] UTF8String]}};else body={{"rectIds",_selection}};body["target"]=it.key();item.representedObject=ms(body.dump());[destinations addItem:item];}auto send=add(@"Send to projector",nil);send.submenu=destinations;send.enabled=destinations.numberOfItems>0;
    if(!_selection.empty()&&![node[@"kind"] isEqualToString:@"trace"]){[menu addItem:[NSMenuItem separatorItem]];[self addArrangeItems:menu];}
    [menu addItem:[NSMenuItem separatorItem]];add(@"Delete",@selector(remove:));return menu;
}
- (void)contextExpansion:(NSMenuItem*)sender {NSDictionary* node=sender.representedObject;if([_outline isItemExpanded:node])[_outline collapseItem:node];else [_outline expandItem:node];}
- (void)contextDuplicate:(NSMenuItem*)sender {NSDictionary* node=sender.representedObject;if([node[@"kind"] isEqualToString:@"trace"]){[self send:@"POST" action:@"copy-object" body:{{"kind","trace"},{"id",[node[@"id"] UTF8String]},{"target",_mid},{"offset",.02}}];}else if([node[@"kind"] isEqualToString:@"collection"]){[self send:@"POST" action:@"copy-object" body:{{"kind","collection"},{"id",[node[@"id"] UTF8String]},{"target",_mid},{"offset",.02}}];}else if([node[@"kind"] isEqualToString:@"box"]){[self send:@"PATCH" action:[@"collections/" stringByAppendingString:node[@"collection"]] body:{{"copyBox",{{"boxId",[node[@"id"] UTF8String]}}}}];}else [self duplicate:nil];}
- (void)contextSend:(NSMenuItem*)sender {auto body=Json::parse([sender.representedObject UTF8String]);if(body.contains("kind"))[self send:@"POST" action:@"copy-object" body:body];else [self copySelectionTo:body["target"].get<std::string>()];}
- (void)updateLayoutActions {BOOL saved=[(NSString*)_layout.selectedItem.representedObject length]>0;_loadLayoutButton.enabled=saved;_updateLayoutButton.enabled=saved;for(NSMenuItem* item in _layoutActions.itemArray)item.enabled=saved||[item.representedObject isEqual:@"import"]||!item.representedObject;}
- (void)chosenLayout:(id)sender {(void)sender;[self updateLayoutActions];NSString* id=_layout.selectedItem.representedObject;for(const auto& item:_layouts.value("layouts",Json::array()))if(id&&item["id"]==std::string(id.UTF8String)){_layoutName.stringValue=ms(item["name"]);break;}}
- (BOOL)libraryCommand:(const std::string&)method path:(const std::string&)path body:(Json)body {body["libraryRevision"]=_layouts["revision"];auto result=_model->request(method,path,body);if(result.status>=300){_status.stringValue=ms(result.body.value("error",std::string("Layout command failed")));return NO;}_layouts=result.body;_revision=UINT64_MAX;[self refresh];return YES;}
- (void)layoutAction:(NSMenuItem*)sender {
    NSString* action=sender.representedObject;NSString* id=_layout.selectedItem.representedObject;
    if([action isEqualToString:@"import"]){auto panel=[NSOpenPanel openPanel];panel.allowedFileTypes=@[@"json"];panel.allowsMultipleSelection=NO;panel.canChooseDirectories=NO;if([panel runModal]!=NSModalResponseOK)return;NSError* error=nil;auto data=[NSData dataWithContentsOfURL:panel.URL options:0 error:&error];if(!data){_status.stringValue=error.localizedDescription;return;}if(data.length>16*1024*1024){_status.stringValue=@"Layout file exceeds 16 MB";return;}try{auto value=Json::parse((const char*)data.bytes,(const char*)data.bytes+data.length);auto objects=value.contains("objects")?value["objects"]:value;std::string name=value.value("name",std::string(panel.URL.URLByDeletingPathExtension.lastPathComponent.UTF8String));[self libraryCommand:"POST" path:"/api/v1/mapping-layouts/import" body:{{"name",name},{"objects",objects}}];}catch(const std::exception& e){_status.stringValue=ms(e.what());}return;}
    if(!id.length){_status.stringValue=@"Choose a layout";return;}std::string path="/api/v1/mapping-layouts/"+std::string(id.UTF8String);
    if([action isEqualToString:@"rename"]){[self libraryCommand:"PATCH" path:path body:{{"name",_layoutName.stringValue.UTF8String}}];return;}
    if([action isEqualToString:@"delete"]){[self libraryCommand:"DELETE" path:path body:Json::object()];return;}
    if([action isEqualToString:@"export"]){auto result=_model->request("GET",path);if(result.status>=300){_status.stringValue=ms(result.body.value("error",std::string("Export failed")));return;}auto panel=[NSSavePanel savePanel];panel.allowedFileTypes=@[@"json"];panel.nameFieldStringValue=[ms(result.body.value("name",std::string("Mapping"))) stringByAppendingString:@".json"];if([panel runModal]!=NSModalResponseOK)return;Json file={{"format","vj-mapping-layout"},{"version",1},{"name",result.body["name"]},{"objects",result.body["objects"]}};NSError* error=nil;if(![ms(file.dump(2)) writeToURL:panel.URL atomically:YES encoding:NSUTF8StringEncoding error:&error])_status.stringValue=error.localizedDescription;}
}
- (void)toggleAddPins:(id)sender {(void)sender;if(_selection.size()!=1)return;_canvas->addingPin=_canvas->addingPin==_selection[0].get<std::string>()?"":_selection[0].get<std::string>();[self.window makeFirstResponder:_canvas];[self inspect];[_canvas setNeedsDisplay:YES];}
- (void)contextRename:(NSMenuItem*)sender {NSDictionary* node=sender.representedObject;for(NSInteger row=0;row<_outline.numberOfRows;row++){NSDictionary* item=[_outline itemAtRow:row];if([item[@"id"] isEqual:node[@"id"]]&&[item[@"kind"] isEqual:node[@"kind"]]){NSView* field=((VJMapObjectCell*)[_outline viewAtColumn:0 row:row makeIfNecessary:YES]).name;if([field isKindOfClass:[NSTextField class]]){((NSTextField*)field).editable=YES;[self.window makeFirstResponder:field];[(NSTextField*)field selectText:nil];}return;}}}
- (void)copySelectionTo:(const std::string&)target {Json collections=Json::array(),rects=Json::array();std::set<std::string> owned;for(const auto& c:_map["project"].value("collections",Json::array())){bool all=!c["faces"].empty();for(const auto& f:c["faces"])all&=has(_selection,f["rectId"]);if(all){collections.push_back(c["id"]);for(const auto& f:c["faces"])owned.insert(f["rectId"]);}}for(const auto& id:_selection)if(!owned.contains(id))rects.push_back(id);for(const auto& id:collections)if(![self send:@"POST" action:@"copy-object" body:{{"kind","collection"},{"id",id},{"target",target}}])return;if(!rects.empty())[self send:@"POST" action:@"copy-surfaces" body:{{"rectIds",rects},{"target",target}}];}
- (NSMenu*)canvasMenu:(NSEvent*)event {
    NSPoint point=[_canvas convertPoint:event.locationInWindow fromView:nil];auto b=[_canvas mapBounds];auto traces=_map["project"].value("traces",Json::array());for(auto it=traces.rbegin();it!=traces.rend();++it){const auto& t=*it;if(!vj::mappingEditorVisible(_map,t["id"],true)||!t.value("enabled",true))continue;for(size_t i=1;i<t["points"].size();i++)if(edgeDistance(Json::array({t["points"][i-1],t["points"][i]}),b,point)<=std::max(10.,t.value("width",.015)*b.size.height*1.5))return [self objectMenu:@{@"id":ms(t["id"]),@"kind":@"trace",@"ids":@[],@"canMute":@YES,@"muted":@(!t.value("enabled",true)),@"detail":ms("Trace · "+std::to_string(t.value("pixels",60))+" px"+(t.value("enabled",true)?"":" · Muted"))}];}
    const Json* hit=nullptr;double best=INFINITY;bool overlay=true;for(auto it=_map["project"]["rects"].rbegin();it!=_map["project"]["rects"].rend();++it){if(!vj::mappingEditorVisible(_map,(*it)["id"]))continue;auto outline=surfaceOutline(*it,b);auto path=polygon(outline,b);if(![path containsPoint:point]&&edgeDistance(outline,b,point)>5)continue;bool over=it->value("kind",std::string{})=="overlay";double x=0,y=0;for(const auto& p:(*it)["corners"]){x+=p[0].get<double>()/(*it)["corners"].size();y+=p[1].get<double>()/(*it)["corners"].size();}double distance=std::hypot(point.x-b.origin.x-x*b.size.width,point.y-b.origin.y-y*b.size.height);if(!hit||(!over&&overlay)||(over==overlay&&distance<best)){hit=&*it;best=distance;overlay=over;}}if(!hit)return nil;auto id=(*hit)["id"];return [self objectMenu:@{@"id":ms(id),@"kind":@"rect",@"ids":@[ms(id)]}];
}
@end
BOOL VJCheckMapperSelection(){
    auto canvas=[[VJMapCanvas alloc]initWithFrame:NSMakeRect(0,0,800,500)];
    canvas->mapping=vj::Model::initial()["mappings"]["1"];
    Json a=canvas->mapping["project"]["rects"][0],b=a;a["id"]="a";b["id"]="b";a["corners"]={{.1,.1},{.4,.1},{.4,.4},{.1,.4}};b["corners"]={{.6,.6},{.9,.6},{.9,.9},{.6,.9}};canvas->mapping["project"]["rects"]=Json::array({a,b});
    auto event=[&](NSEventType type,double x,double y,NSEventModifierFlags flags){auto bounds=[canvas mapBounds];auto point=[canvas convertPoint:NSMakePoint(bounds.origin.x+x*bounds.size.width,bounds.origin.y+y*bounds.size.height) toView:nil];return [NSEvent mouseEventWithType:type location:point modifierFlags:flags timestamp:1 windowNumber:0 context:nil eventNumber:0 clickCount:1 pressure:1];};
    for(auto flags:{NSEventModifierFlagShift,NSEventModifierFlagCommand,NSEventModifierFlagControl}){
        canvas->selected=Json::array({"a"});[canvas mouseDown:event(NSEventTypeLeftMouseDown,.75,.75,flags)];[canvas mouseUp:event(NSEventTypeLeftMouseUp,.75,.75,flags)];if(canvas->selected!=Json::array({"a","b"}))return NO;
        [canvas mouseDown:event(NSEventTypeLeftMouseDown,.75,.75,flags)];[canvas mouseUp:event(NSEventTypeLeftMouseUp,.75,.75,flags)];if(canvas->selected!=Json::array({"a"}))return NO;
    }
    canvas->selected=Json::array({"b"});[canvas mouseDown:event(NSEventTypeLeftMouseDown,.01,.01,NSEventModifierFlagShift)];[canvas mouseDragged:event(NSEventTypeLeftMouseDragged,.48,.48,NSEventModifierFlagShift)];[canvas mouseUp:event(NSEventTypeLeftMouseUp,.48,.48,NSEventModifierFlagShift)];if(!has(canvas->selected,"a")||!has(canvas->selected,"b"))return NO;
    canvas->selected=Json::array({"a"});auto before=canvas->mapping;[canvas mouseDown:event(NSEventTypeLeftMouseDown,.32,.30,NSEventModifierFlagShift)];[canvas mouseDragged:event(NSEventTypeLeftMouseDragged,.37,.32,NSEventModifierFlagShift)];[canvas mouseUp:event(NSEventTypeLeftMouseUp,.37,.32,NSEventModifierFlagShift)];return canvas->selected==Json::array({"a"})&&canvas->mapping!=before;
}
