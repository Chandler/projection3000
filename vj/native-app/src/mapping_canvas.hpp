#pragma once
#include "../../native-renderer/src/surface_curvature.hpp"
#include <nlohmann/json.hpp>
#include <functional>
#include <optional>
#include <string>
// Mapper canvas geometry and pointer editing, shared by the AppKit Mapper and
// the phone remote so both draw and edit surfaces identically.
namespace vj {
using Json=nlohmann::json;
struct CanvasPoint {double x=0,y=0;};
struct CanvasRect {double x=0,y=0,w=0,h=0;
    bool contains(CanvasPoint p)const{return p.x>=x&&p.x<x+w&&p.y>=y&&p.y<y+h;}
    CanvasRect inset(double d)const{return {x+d,y+d,w-2*d,h-2*d};}
    CanvasPoint screen(const Json& p)const{return {x+p[0].get<double>()*w,y+p[1].get<double>()*h};}};
surface_curvature::Settings mappingCurveSettings(const Json& rect);
// Outline in normalized coordinates; aspect is the canvas width/height.
Json mappingSurfaceOutline(const Json& rect,double aspect);
std::pair<const Json*,const Json*> mappingPointOwner(const Json& mapping,const Json& rectID);
Json mappingEditCorners(const Json& rect,const Json& mapping);
Json mappingScreenMatrix(const Json& corners);
Json mappingProjectPoint(const Json& matrix,double x,double y);
Json mappingInversePoint(const Json& matrix,double x,double y);
void mappingSetPointReference(Json& point,const Json& collection,const Json& corners);
bool mappingOwnedSurface(const Json& mapping,const Json& id);
bool mappingGeneratedSurface(const Json& mapping,const Json& id);
Json mappingRotationTarget(const Json& mapping,const Json& selected);
struct MappingRotationHandle {CanvasPoint point,anchor;};
std::optional<MappingRotationHandle> mappingRotationHandle(const Json& mapping,const Json& selected,const Json& target,CanvasRect bounds,CanvasRect viewport);
Json mappingRotateAlignment(Json result,const Json& center,double angle,double aspect);
Json mappingGeometryOperations(const Json& source,const Json& updates);
double mappingEdgeDistance(const Json& points,CanvasRect b,CanvasPoint cursor);
bool mappingPolygonContains(const Json& points,CanvasRect b,CanvasPoint cursor);
// Edge bend handles (T/R/B/L) for a single selected planar quad, or empty.
Json mappingEdgeHandles(const Json& mapping,const Json& rect);
// Everything the Mapper canvas draws for a mapping, in normalized coordinates.
// curveHandles=false omits edge bend and pin handles (touch clients opt in).
Json mappingCanvasScene(const Json& mapping,const Json& selected,const Json& selectedTrace,CanvasRect bounds,CanvasRect viewport,bool curveHandles=true);

struct MappingCanvasDoc {Json& mapping;Json& selected;Json& selectedTrace;const std::string& addingPin;const std::string& positioningContent;};
struct MappingCanvasActions {
    std::function<void(const Json&)> selection,traceSelection,geometry;
    std::function<void(const Json&,const Json&)> traceGeometry,surfaceProperty,collectionProperty,translation;
    std::function<void(const std::string&)> curveEdgeSelection;
};
struct MappingPointerModifiers {bool shift=false,command=false,additive=false;};
// Pointer gesture state for one canvas. Hit radii are in view points; touch
// clients pass a larger hitScale. Commits are delivered through actions.
class MappingCanvasGesture {
public:
    // curveHandles=false disables edge bends, pins and double-click point insert/remove.
    MappingCanvasActions actions;double hitScale=1;bool curveHandles=true;
    // Returns false when the press is not a geometry gesture (content mode miss).
    void down(MappingCanvasDoc doc,CanvasPoint at,CanvasRect bounds,CanvasRect viewport,int clickCount,MappingPointerModifiers modifiers);
    void drag(MappingCanvasDoc doc,CanvasPoint at,CanvasRect bounds,bool shift);
    void up(MappingCanvasDoc doc,CanvasPoint at,CanvasRect bounds,bool shift);
    void cancel(MappingCanvasDoc doc);
    // Touch scale/rotate of the selection about its centre (the Mapper's quick
    // transform as a drag). Commits through actions.geometry.
    void transformDown(MappingCanvasDoc doc,CanvasPoint at,CanvasRect bounds,bool scale,bool rotate);
    // Move one corner handle by a normalized offset and commit it.
    bool nudgeCorner(MappingCanvasDoc doc,const Json& rectId,size_t index,double dx,double dy);
    const Json& clickID()const{return clickID_;}
    bool dragging()const{return dragging_;}bool moved()const{return moved_;}bool marquee()const{return marquee_;}bool scaling()const{return scale_;}
    long corner()const{return corner_;}bool rotating()const{return !rotationTarget_.is_null();}bool rotationUpdated()const{return !rotationUpdate_.is_null();}bool contentDrag()const{return !contentDrag_.empty();}
    CanvasRect marqueeRect()const{return marqueeRect_;}
    // The project to preview while a geometry drag is in progress.
    std::optional<std::pair<Json,uint64_t>> preview(const MappingCanvasDoc& doc)const;
    // Test fixture: begin a surface translation drag from start.
    void beginTranslation(MappingCanvasDoc doc,CanvasPoint start,const Json& ids){start_=start;original_=doc.mapping;dragIDs_=ids;dragging_=true;corner_=-1;}
private:
    bool dragging_=false,marquee_=false,scale_=false,moved_=false,aspectResize_=false,additive_=false,toggleClick_=false;
    Json selectionBefore_,original_,dragIDs_,clickID_,offset_,geometryUpdates_;CanvasPoint start_;long corner_=-1;CanvasRect marqueeRect_;
    std::string traceDrag_,pinSurface_,contentDrag_,bendSurface_,bendSide_;Json contentStart_,contentPosition_;size_t pinIndex_=0;
    Json pinMatrix_,pinStart_,pinTarget_,pinUpdate_,pinCurve_,rotationTarget_,rotationUpdate_;double bendValue_=0,rotateAngle_=0;
    bool transform_=false,transformScale_=false,transformRotate_=false;CanvasPoint transformCenter_,transformVector_;
    void update(MappingCanvasDoc& doc,CanvasPoint at,CanvasRect b,bool shift);
    void reset(){dragging_=marquee_=transform_=false;original_=nullptr;}
};
}
