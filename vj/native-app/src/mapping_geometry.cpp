#include "mapping_geometry.hpp"
#include "api_error.hpp"
#include "../../native-renderer/src/surface_curvature.hpp"
#include <algorithm>
#include <array>
#include <cmath>
#include <cctype>
#include <cstdlib>
#include <set>
#include <string>
namespace vj {
nlohmann::json mappingEditorVisibility(const nlohmann::json& project,const nlohmann::json& input){
    const auto stored=input.is_object()?input:nlohmann::json::object();
    using J=nlohmann::json;J state={{"hiddenRectIds",J::array()},{"hiddenTraceIds",J::array()},{"soloRectIds",J::array()},{"soloTraceIds",J::array()},{"solo",stored.value("solo",false)}};
    for(const char* key:{"hiddenRectIds","hiddenTraceIds","soloRectIds","soloTraceIds"}){
        auto ids=stored.value(key,J::array());if(!ids.is_array())continue;bool trace=std::string(key).find("Trace")!=std::string::npos;
        for(const auto& id:ids)if(id.is_string())for(const auto& object:project.value(trace?"traces":"rects",J::array()))if(object["id"]==id&&std::find(state[key].begin(),state[key].end(),id)==state[key].end())state[key].push_back(id);
    }
    // Deleting/replacing every solo target should not leave an empty editor.
    if(state["solo"]==true&&state["soloRectIds"].empty()&&state["soloTraceIds"].empty()&&(!stored.value("soloRectIds",J::array()).empty()||!stored.value("soloTraceIds",J::array()).empty()))state["solo"]=false;
    return state;
}
bool mappingEditorVisible(const nlohmann::json& mapping,const nlohmann::json& id,bool trace){
    const auto state=mapping.value("editorVisibility",nlohmann::json::object());const auto hidden=state.value(trace?"hiddenTraceIds":"hiddenRectIds",nlohmann::json::array());
    if(std::find(hidden.begin(),hidden.end(),id)!=hidden.end())return false;
    if(!state.value("solo",false))return true;const auto solo=state.value(trace?"soloTraceIds":"soloRectIds",nlohmann::json::array());return std::find(solo.begin(),solo.end(),id)!=solo.end();
}
nlohmann::json mappingEditorView(const nlohmann::json& mapping,const std::string& mid){
    using J=nlohmann::json;
    // The editor draws already-rendered buses. Tessellated collection contexts
    // belong to the render graph, not the per-frame view-demand descriptor.
    J view=J::object();for(auto it=mapping.begin();it!=mapping.end();++it)if(it.key()!="collectionContexts")view[it.key()]=it.value();
    const auto state=mapping.value("editorVisibility",J::object());if(!state.value("solo",false)&&state.value("hiddenRectIds",J::array()).empty()&&state.value("hiddenTraceIds",J::array()).empty())return view;auto& project=view["project"];const auto& source=mapping["project"];J visible=J::array();
    for(const auto& rect:source["rects"])if(mappingEditorVisible(mapping,rect["id"]))visible.push_back(rect);
    project["rects"]=visible;J rendered=J::array();
    for(auto rect:source.value("renderRects",source["rects"])){
        bool direct=false;for(const auto& original:source["rects"])if(original["id"]==rect["id"]){direct=true;break;}
        if(direct&&!mappingEditorVisible(mapping,rect["id"]))continue;
        if(rect.contains("nativeBus")){
            const J emptyContexts=J::object();const auto& contexts=mapping.contains("collectionContexts")?mapping.at("collectionContexts"):emptyContexts;const auto key=rect["nativeBus"].get<std::string>();
            if(contexts.contains(key)){
                const auto faces=contexts[key]["geometry"].value("faceIds",J::array());J masks=J::array();bool known=false;
                for(const auto& original:source["rects"]){bool member=original["id"]==rect["id"]||std::find(faces.begin(),faces.end(),J(mid+":"+original["id"].get<std::string>()))!=faces.end()||std::find(faces.begin(),faces.end(),original["id"])!=faces.end();
                    for(const auto& collection:source.value("collections",J::array()))for(const auto& face:collection["faces"])if(face["rectId"]==original["id"]&&std::find(faces.begin(),faces.end(),face["id"])!=faces.end())member=true;
                    if(member){known=true;if(mappingEditorVisible(mapping,original["id"]))masks.push_back({{"corners",original["corners"]},{"cornerRadius",original.value("cornerRadius",0.)},{"curvature",original.value("curvature",J())}});}
                }
                if(known){if(masks.empty())continue;rect["maskSurfaces"]=masks;if(rect.contains("overlaySurfaces"))rect["overlaySurfaces"]=masks;}
            }
        }
        rendered.push_back(rect);
    }project["renderRects"]=rendered;J traces=J::array();for(const auto& trace:source.value("traces",J::array()))if(mappingEditorVisible(mapping,trace["id"],true))traces.push_back(trace);project["traces"]=traces;
    return view;
}

namespace {
using Json=nlohmann::json;
constexpr std::array<const char*,4> sides={"top","right","bottom","left"};
void require(bool condition,const std::string& message){if(!condition)throw ApiError(400,message);}
double number(const Json& value,double low,double high,const std::string& message){require(value.is_number(),message);double n=value.get<double>();require(std::isfinite(n)&&n>=low&&n<=high,message);return n;}
bool boolean(const Json& value,const std::string& message){require(value.is_boolean(),message);return value.get<bool>();}
size_t characters(const std::string& text){size_t count=0;for(unsigned char c:text)if((c&0xc0)!=0x80)count++;return count;}
std::vector<std::string> curveKeys(){std::vector<std::string> result;for(auto side:sides)result.push_back(side);for(auto side:sides)for(auto suffix:{"Skew","Shape"})result.push_back(std::string(side)+suffix);for(auto key:{"wrapX","wrapY","spacingX","spacingY"})result.push_back(key);return result;}
bool numericCoercion(const Json& value,double& result){
    if(value.is_number()){result=value.get<double>();return std::isfinite(result);}if(value.is_boolean()){result=value.get<bool>()?1:0;return true;}
    if(!value.is_string())return false;auto text=value.get<std::string>();const char* begin=text.c_str();char* end=nullptr;result=std::strtod(begin,&end);if(end==begin)return false;while(*end&&std::isspace(static_cast<unsigned char>(*end)))++end;return !*end&&std::isfinite(result);
}
Json point(const Json& raw){if(!raw.is_array()||raw.size()!=2)return Json::array({.5,.5});double x,y;if(!numericCoercion(raw[0],x)||!numericCoercion(raw[1],y))return Json::array({.5,.5});return Json::array({std::clamp(x,0.,1.),std::clamp(y,0.,1.)});}
Json pins(const Json& raw){
    if(raw.is_null())return nullptr;require(raw.is_object(),"Invalid edge pin settings");for(auto it=raw.begin();it!=raw.end();++it)require(it.key()=="enabled"||it.key()=="method"||it.key()=="points","Invalid edge pin settings");
    bool enabled=boolean(raw.value("enabled",Json(true)),"Pin method must be fit or local; enabled must be boolean");auto method=raw.value("method",Json("fit"));require(method=="fit"||method=="local","Pin method must be fit or local; enabled must be boolean");auto points=raw.value("points",Json::array());require(points.is_array()&&points.size()<=32,"At most 32 edge pins");Json clean=Json::array();std::set<std::string> ids;std::array<std::vector<double>,4> positions;
    for(const auto& p:points){require(p.is_object(),"Invalid edge pin");for(auto it=p.begin();it!=p.end();++it)require(it.key()=="id"||it.key()=="side"||it.key()=="t"||it.key()=="target"||it.key()=="enabled","Invalid edge pin");auto id=p.value("id",Json());require(id.is_string(),"Pins need unique IDs");auto name=id.get<std::string>();require(characters(name)>=1&&characters(name)<=64&&ids.insert(name).second,"Pins need unique IDs");auto side=p.value("side",Json());int index=-1;for(int i=0;i<4;i++)if(side==sides[i])index=i;require(index>=0,"Pin needs an edge and t in 0.01..0.99");double t=number(p.value("t",Json()),.01,.99,"Pin needs an edge and t in 0.01..0.99");bool on=boolean(p.value("enabled",Json(true)),"Pin enabled must be boolean");auto target=p.value("target",Json());require(target.is_array()&&target.size()==2,"Pin target must be two finite perspective coordinates in -4..5");for(auto& v:target)v=number(v,-4,5,"Pin target must be two finite perspective coordinates in -4..5");require(positions[index].size()<8,"At most eight pins per edge, separated by 0.005");for(double previous:positions[index])require(std::abs(t-previous)>=.005,"At most eight pins per edge, separated by 0.005");positions[index].push_back(t);clean.push_back({{"id",id},{"side",side},{"t",t},{"target",target},{"enabled",on}});}
    return {{"enabled",enabled},{"method",method},{"points",clean}};
}
surface_curvature::Settings settings(const Json& clean){surface_curvature::Settings result;result.top=clean["top"];result.right=clean["right"];result.bottom=clean["bottom"];result.left=clean["left"];result.wrap_x=clean["wrapX"];result.wrap_y=clean["wrapY"];result.spacing_x=clean["spacingX"];result.spacing_y=clean["spacingY"];for(int i=0;i<4;i++){result.skew[i]=clean[std::string(sides[i])+"Skew"];result.shape[i]=clean[std::string(sides[i])+"Shape"];}
    if(clean.contains("pins")){const auto& p=clean["pins"];result.pins_enabled=p["enabled"];result.local_pins=p["method"]=="local";for(const auto& pin:p["points"]){int side=0;for(int i=0;i<4;i++)if(pin["side"]==sides[i])side=i;result.pins.push_back({side,pin["t"],{pin["target"][0],pin["target"][1]},pin["enabled"]});}}
    return result;
}
void mesh(const Json& corners,const Json& uvs,surface_curvature::Settings curve){
    std::vector<surface_curvature::Point> points,texture;for(const auto& p:corners)points.push_back({p[0].get<float>(),p[1].get<float>()});for(const auto& p:uvs)texture.push_back({p[0].get<float>(),p[1].get<float>()});
    require(surface_curvature::quad_matrix(points).has_value()&&surface_curvature::quad_matrix(texture).has_value(),"Curvature needs a convex quad");surface_curvature::prepare_pins(curve);require(surface_curvature::build(points,texture,curve).has_value(),"Curvature would cross or collapse the surface or cross the perspective horizon");
}
Json curvature(const Json& raw,const Json& corners,const Json& uvs,bool fold){
    if(raw.is_null())return nullptr;require(raw.is_object(),"Invalid curvature settings");const auto keys=curveKeys();for(auto it=raw.begin();it!=raw.end();++it)require(it.key()=="pins"||std::find(keys.begin(),keys.end(),it.key())!=keys.end(),"Invalid curvature settings");Json clean=Json::object();bool active=false;
    for(const auto& key:keys){double low=-1,high=1;if(key.starts_with("wrap")){low=0;high=170;}else if(key.starts_with("spacing")){low=-3;high=3;}else if(std::find(sides.begin(),sides.end(),key)!=sides.end()){low=-2;high=2;}double value=number(raw.value(key,Json(0)),low,high,"curvature."+key+" is outside range");clean[key]=value;active|=value!=0;}
    auto normalizedPins=pins(raw.value("pins",Json()));if(!normalizedPins.is_null()){clean["pins"]=normalizedPins;active=true;}if(!active)return clean;
    require(!fold&&corners.size()==4,"Curvature requires four corners without a fold");auto curve=settings(clean);bool activePins=curve.pins_enabled&&std::any_of(curve.pins.begin(),curve.pins.end(),[](const auto& p){return p.enabled;});if(activePins){auto base=curve;base.pins.clear();mesh(corners,uvs,base);}mesh(corners,uvs,curve);return clean;
}
void validate(Json& rect){
    require(rect.is_object(),"Invalid mapping surface");auto corners=rect.value("corners",Json());require(corners.is_array()&&corners.size()>=3&&corners.size()<=64,"Invalid rect corners");for(auto& p:corners)p=point(p);
    const auto rawUVs=rect.value("uvs",Json());Json uvs=rawUVs;if(!uvs.is_array()||uvs.size()!=corners.size()){uvs=Json::array();const Json defaults={{0,1},{1,1},{1,0},{0,0}};for(size_t i=0;i<corners.size();i++)uvs.push_back(i<4?defaults[i]:Json::array({.5,.5}));}else for(auto& p:uvs)p=point(p);
    bool fold=boolean(rect.value("fold",Json(false)),"A fold needs six perimeter points");if(fold){require(corners.size()==6,"A fold needs six perimeter points");require(rawUVs.is_array()&&rawUVs.size()==6,"A fold needs six UV coordinates");int sign=0;for(const auto& panel:std::array<std::array<size_t,4>,2>{{{{0,1,4,5}},{{1,2,3,4}}}})for(int i=0;i<4;i++){const auto& a=corners[panel[i]];const auto& b=corners[panel[(i+1)%4]];const auto& c=corners[panel[(i+2)%4]];double cross=(b[0].get<double>()-a[0].get<double>())*(c[1].get<double>()-b[1].get<double>())-(b[1].get<double>()-a[1].get<double>())*(c[0].get<double>()-b[0].get<double>());require(std::abs(cross)>=1e-8,"Fold panels must not cross or collapse");int next=cross>0?1:-1;require(!sign||sign==next,"Fold panels must not cross or collapse");sign=next;}}
    auto curve=curvature(rect.value("curvature",Json()),corners,uvs,fold);double radius=number(rect.value("cornerRadius",Json(0)),0,.5,"Corner radius must be between 0 and 0.5");require(!radius||(!fold&&corners.size()==4),"Rounded corners require a four-corner surface");rect["corners"]=corners;rect["uvs"]=uvs;rect["fold"]=fold;if(!curve.is_null())rect["curvature"]=curve;else rect.erase("curvature");if(rect.contains("cornerRadius"))rect["cornerRadius"]=radius;
}
}
double mappingCanvasAspect(const Json& project){
    const int rotation=project.value("output",Json::object()).value("rotation",0);
    return ((rotation%180+180)%180)==90?9./16.:16./9.;
}
Json defaultMappingSurfaceCorners(const Json& project){
    const double width=.6,height=width*mappingCanvasAspect(project)/(16./9.);
    return Json::array({{.5-width/2,.5-height/2},{.5+width/2,.5-height/2},{.5+width/2,.5+height/2},{.5-width/2,.5+height/2}});
}
Json mappingQuadPoint(const Json& p,double u,double v){
    require(p.is_array()&&p.size()==4,"Subdivision needs four corners");
    const double ax=p[0][0],ay=p[0][1],bx=p[1][0],by=p[1][1],cx=p[2][0],cy=p[2][1],dx=p[3][0],dy=p[3][1];
    const double x1=bx-cx,y1=by-cy,x2=dx-cx,y2=dy-cy,x3=ax-bx+cx-dx,y3=ay-by+cy-dy;
    double g=0,h=0;
    if(std::abs(x3)+std::abs(y3)>1e-12){const double det=x1*y2-x2*y1;require(std::abs(det)>1e-12,"Surface perspective is degenerate");g=(x3*y2-x2*y3)/det;h=(x1*y3-x3*y1)/det;}
    const double q=1+g*u+h*v;require(std::isfinite(q)&&q>1e-9,"Subdivision crosses the perspective horizon");
    return Json::array({((bx-ax+g*bx)*u+(dx-ax+h*dx)*v+ax)/q,((by-ay+g*by)*u+(dy-ay+h*dy)*v+ay)/q});
}
Json mappingSubdivisionCells(const Json& surface,int columns,int rows,int orientation){
    require(columns>=1&&rows>=1&&columns<=128&&rows<=128&&columns*rows<=128,"Subdivision supports up to 128 faces");
    require(orientation>=0&&orientation<=3,"Grid orientation must be 0–3");
    auto rect=surface;validate(rect);
    require(rect.value("kind",std::string("surface"))=="surface","Choose a surface");
    require(rect["corners"].size()==4&&!rect.value("fold",false),"Subdivision needs an unfolded four-corner surface");
    require(rect.value("cornerRadius",0.)==0,"Remove rounded corners before subdividing");
    if(rect.contains("curvature"))require(!settings(rect["curvature"]).active(),"Remove curvature and edge pins before subdividing");
    Json cells=Json::array();
    for(int row=0;row<rows;row++)for(int column=0;column<columns;column++){
        Json corners=Json::array(),uvs=Json::array(),local=Json::array();
        for(auto xy:std::array<std::array<int,2>,4>{{{0,0},{1,0},{1,1},{0,1}}}){
            double u=double(column+xy[0])/columns,v=double(row+xy[1])/rows;
            if(orientation==1){double old=u;u=1-v;v=old;}else if(orientation==2){u=1-u;v=1-v;}else if(orientation==3){double old=u;u=v;v=1-old;}
            local.push_back({u,v});corners.push_back(mappingQuadPoint(rect["corners"],u,v));uvs.push_back(mappingQuadPoint(rect["uvs"],u,v));
        }
        cells.push_back({{"corners",corners},{"uvs",uvs},{"localCorners",local}});
    }
    cells[0]["axes"]=Json::array();for(auto xy:std::array<std::array<double,2>,3>{{{0,0},{1,0},{0,1}}}){
        double u=xy[0],v=xy[1];if(orientation==1){double old=u;u=1-v;v=old;}else if(orientation==2){u=1-u;v=1-v;}else if(orientation==3){double old=u;u=v;v=1-old;}
        cells[0]["axes"].push_back(mappingQuadPoint(rect["corners"],u,v));
    }
    return cells;
}
void validateMappingGeometry(Json& rect){auto candidate=rect;validate(candidate);rect=std::move(candidate);}
void validateMappingGeometry(const Json& rect){auto candidate=rect;validate(candidate);}
void editMappingGeometry(Json& rect,const Json& patch){
    require(patch.is_object(),"Invalid geometry patch");auto candidate=rect;
    if(patch.contains("fold")){bool on=boolean(patch["fold"],"fold must be a boolean"),was=boolean(candidate.value("fold",Json(false)),"fold must be a boolean");if(on&&!was){require(candidate.contains("corners")&&candidate["corners"].is_array()&&candidate["corners"].size()==4,"Add fold requires four corners");for(const auto* key:{"corners","uvs"}){require(candidate.contains(key)&&candidate[key].is_array()&&candidate[key].size()==4,"Add fold requires four UV coordinates");auto points=candidate[key];auto mid=[](const Json& a,const Json& b){require(a.is_array()&&a.size()==2&&b.is_array()&&b.size()==2,"Invalid fold coordinate");return Json::array({(a[0].get<double>()+b[0].get<double>())/2,(a[1].get<double>()+b[1].get<double>())/2});};candidate[key]=Json::array({points[0],mid(points[0],points[1]),points[1],points[2],mid(points[3],points[2]),points[3]});}candidate["fold"]=true;}else if(!on&&was){for(auto key:{"corners","uvs"}){require(candidate.contains(key)&&candidate[key].is_array()&&candidate[key].size()==6,"A fold needs six perimeter and UV coordinates");auto points=candidate[key];candidate[key]=Json::array({points[0],points[2],points[3],points[5]});}candidate["fold"]=false;}}
    if(patch.contains("removePoint")){auto index=patch["removePoint"];require(!candidate.value("fold",false)&&candidate["corners"].size()>4&&index.is_number_integer(),"Cannot remove this point; remove the fold as a whole");int64_t i=index.get<int64_t>();require(i>=0&&static_cast<uint64_t>(i)<candidate["corners"].size(),"Cannot remove this point; remove the fold as a whole");for(auto key:{"corners","uvs"}){require(candidate[key].is_array()&&static_cast<size_t>(i)<candidate[key].size(),"Cannot remove this point");candidate[key].erase(candidate[key].begin()+i);}}
    for(auto key:{"corners","uvs","cornerRadius"})if(patch.contains(key))candidate[key]=patch[key];
    if(patch.contains("curvature")){auto update=patch["curvature"];require(update.is_null()||update.is_object(),"curvature must be an object or null");if(update.is_null())candidate.erase("curvature");else{Json existing=candidate.value("curvature",Json::object());if(existing.is_null())existing=Json::object();require(existing.is_object(),"Invalid existing curvature settings");if(update.contains("pins")&&update["pins"].is_object()){auto current=existing.value("pins",Json::object());if(current.is_null())current=Json::object();require(current.is_object(),"Invalid edge pin settings");current.update(update["pins"]);update["pins"]=current;}existing.update(update);candidate["curvature"]=existing;}}
    validate(candidate);rect=std::move(candidate);
}
}
