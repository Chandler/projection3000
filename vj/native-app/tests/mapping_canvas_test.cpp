#include "mapping_canvas.hpp"
#include "model.hpp"
#include <cassert>
#include <cmath>
#include <iostream>
using vj::Json;
int main(){
    const vj::CanvasRect bounds{0,0,1600,900},viewport{0,0,1600,900};
    Json mapping=vj::Model::initial()["mappings"]["1"],selected=Json::array(),trace=nullptr;std::string pin,content;
    auto& rect=mapping["project"]["rects"][0];rect["corners"]=Json::array({{.2,.2},{.6,.2},{.6,.7},{.2,.7}});rect["uvs"]=Json::array({{0,1},{1,1},{1,0},{0,0}});
    vj::MappingCanvasDoc doc{mapping,selected,trace,pin,content};
    Json picked,moved,geometry,property;
    vj::MappingCanvasGesture gesture;gesture.actions.selection=[&](const Json& ids){picked=ids;};gesture.actions.translation=[&](const Json&,const Json& delta){moved=delta;};
    gesture.actions.geometry=[&](const Json& updates){geometry=updates;};gesture.actions.surfaceProperty=[&](const Json&,const Json& patch){property=patch;};
    auto at=[&](double x,double y){return vj::CanvasPoint{x*bounds.w,y*bounds.h};};
    // Tap selects the surface under the pointer.
    gesture.down(doc,at(.4,.45),bounds,viewport,1,{});gesture.up(doc,at(.4,.45),bounds,false);assert(picked==Json::array({"rect-1"})&&selected==picked);
    // Body drag previews, then commits one translation.
    gesture.down(doc,at(.4,.45),bounds,viewport,1,{});gesture.drag(doc,at(.45,.45),bounds,false);assert(gesture.preview(doc).has_value());
    gesture.up(doc,at(.45,.45),bounds,false);assert(moved.is_array()&&std::abs(moved[0].get<double>()-.05)<1e-9&&std::abs(moved[1].get<double>())<1e-9);
    mapping["project"]["rects"][0]["corners"]=Json::array({{.2,.2},{.6,.2},{.6,.7},{.2,.7}});
    // Corner handles move one corner only.
    gesture.down(doc,at(.2,.2),bounds,viewport,1,{});assert(gesture.corner()==0);gesture.up(doc,at(.25,.22),bounds,false);
    assert(geometry.size()==1&&std::abs(geometry[0]["corners"][0][0].get<double>()-.25)<1e-9&&geometry[0]["corners"][1]==Json::array({.6,.2}));
    // Edge handles bend the selected surface; the outline then follows the curve.
    auto scene=vj::mappingCanvasScene(mapping,selected,trace,bounds,viewport);auto edges=scene["rects"][0]["edges"];assert(edges.size()==4&&edges[0]["side"]=="top");
    auto top=bounds.screen(edges[0]["point"]);gesture.down(doc,top,bounds,viewport,1,{});gesture.up(doc,{top.x,top.y-90},bounds,false);
    assert(property.contains("curvature")&&property["curvature"]["top"].get<double>()>0);
    auto curved=mapping;curved["project"]["rects"][0]["curvature"]={{"top",.3}};assert(vj::mappingCanvasScene(curved,selected,trace,bounds,viewport)["rects"][0]["outline"].size()>4);
    // Double-clicking a straight edge inserts a corner.
    mapping["project"]["rects"][0]["curvature"]=Json::object();property=nullptr;gesture.down(doc,at(.3,.7),bounds,viewport,2,{});assert(property["corners"].size()==5&&property["uvs"].size()==5);
    // Empty-space drag is a marquee selection.
    picked=nullptr;gesture.down(doc,at(.8,.1),bounds,viewport,1,{});assert(gesture.marquee()&&selected.empty());gesture.drag(doc,at(.3,.3),bounds,false);gesture.up(doc,at(.3,.3),bounds,false);assert(picked==Json::array({"rect-1"}));
    // Touch clients widen hit targets without changing geometry.
    gesture.hitScale=3;gesture.down(doc,at(.25+20/1600.,.22),bounds,viewport,1,{});assert(gesture.corner()==0);gesture.cancel(doc);
    std::cout<<"Mapping canvas gestures and scene passed\n";
}
