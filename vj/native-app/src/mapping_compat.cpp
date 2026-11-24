#include "mapping_compat.hpp"
#include "meta_mapping.hpp"
#include "mapping_model.hpp"
#include "api_error.hpp"
#include <algorithm>
#include <cmath>
namespace vj { namespace {
void require(bool condition,const std::string& error){if(!condition)throw ApiError(400,error);}
std::string textId(const Json& value){if(value.is_null())return {};auto text=value.is_string()?value.get<std::string>():value.dump();return text.substr(0,100);}
long long integer(const Json& value){if(value.is_number()){const auto number=value.get<double>();require(std::isfinite(number)&&number>-9e18&&number<9e18,"Invalid mapping counter");return static_cast<long long>(number);}if(value.is_string()){auto text=value.get<std::string>();size_t used=0;auto result=std::stoll(text,&used);require(used==text.size(),"Invalid mapping counter");return result;}throw ApiError(400,"Invalid mapping counter");}
Json checked(const Json& raw){auto project=raw;require(project.is_object(),"mapping project must be an object");require(project.dump().size()<=32u*1024*1024,"mapping project is too large");require(project.contains("rects")&&project["rects"].is_array(),"Mapping supports up to 128 surfaces");for(auto& rect:project["rects"]){require(rect.is_object(),"Invalid surface");if(!rect.contains("kind"))rect["kind"]="surface";if(!rect.contains("mode"))rect["mode"]="live";if(!rect.contains("source"))rect["source"]="none";if(!rect.contains("blend"))rect["blend"]="normal";if(!rect.contains("fit"))rect["fit"]="stretch";}validateMappingProject(project);project.erase("renderRects");return project;}
Json defaults(const std::string& mid){return {{"rects",Json::array({{{"id","rect-1"},{"name","Rect 1"},{"kind","surface"},{"graphic","grid"},{"config",{{"color","#00ff00"},{"thickness",3}}},{"corners",{{0,0},{1,0},{1,1},{0,1}}},{"uvs",{{0,1},{1,1},{1,0},{0,0}}},{"source","out"+mid},{"mode","live"},{"blend","normal"},{"fit","stretch"}}})},{"selectedRectId","rect-1"},{"selectedTraceId",nullptr},{"traces",Json::array()},{"collections",Json::array()},{"groups",Json::array()},{"output",{{"rotation",0},{"boundsGrid",false}}}};}
}
bool mappingCompatibilityRoute(const std::string& path){return path=="/api/v1/mappings/reset"||(path.starts_with("/api/v1/mappings/")&&path.ends_with("/commit"));}
Json mappingCompatibilityCommand(Json& document,const std::string& path,const Json& body){
    require(body.is_object(),"Expected an object");auto& mappings=document.at("mappings");
    if(path=="/api/v1/mappings/reset"){
        const auto revisions=body.value("revisions",Json());require(revisions.is_object()&&revisions.size()==mappings.size(),"Supply current revisions for all four mappings");
        for(auto it=mappings.begin();it!=mappings.end();++it)if(!revisions.contains(it.key())||!revisions[it.key()].is_number_integer()||revisions[it.key()]!=it.value()["revision"])throw ApiError(409,"Mappings changed; reload and try again");
        Json result=Json::object();for(auto it=mappings.begin();it!=mappings.end();++it){it.value()["project"]=checked(defaults(it.key()));it.value().erase("layoutId");it.value()["nextRectId"]=2;it.value()["nextTraceId"]=1;it.value()["revision"]=it.value()["revision"].get<uint64_t>()+1;}
        document["outputCount"]=std::max(4,document.value("outputCount",1));auto& grid=document["grid"];for(int i=1;i<=document["outputCount"].get<int>();++i){auto bus=i==1?"program":"out"+std::to_string(i);if(!grid["running"].contains(bus))grid["running"][bus]=true;for(const auto* bank:{"selections","selections_b"})if(!grid[bank].contains(bus))grid[bank][bus]=Json::object();if(!grid["crossfade"].contains(bus))grid["crossfade"][bus]=0.;}
        for(auto it=mappings.begin();it!=mappings.end();++it)result[it.key()]=mappingSnapshot(document,it.key());return {{"mappings",result}};
    }
    const std::string prefix="/api/v1/mappings/";const auto mid=path.substr(prefix.size(),path.size()-prefix.size()-7);require(mappings.contains(mid),"Unknown mapping");auto& mapping=mappings[mid];
    long long base=-1;try{base=integer(body.value("baseRevision",Json(-1)));}catch(...){}if(base<0||Json(base)!=mapping["revision"])throw ApiError(409,"stale mapping revision");
    require(!body.contains("presets")||body["presets"].empty()||body["presets"]==false,"Use the mapping layouts API; reload the mapper");auto project=checked(body.at("project"));const auto rect=std::clamp(integer(body.value("nextRectId",Json(2))),1LL,1000000LL),trace=std::clamp(integer(body.value("nextTraceId",Json(1))),1LL,1000000LL);
    mapping["project"]=std::move(project);if(body.value("clearLayout",Json())==true)mapping.erase("layoutId");mapping["nextRectId"]=rect;mapping["nextTraceId"]=trace;mapping["revision"]=mapping["revision"].get<uint64_t>()+1;
    auto result=mappingSnapshot(document,mid);result["clientId"]=textId(body.value("clientId",Json()));result["commitId"]=textId(body.value("commitId",Json()));return result;
}
Json prepareMappingPreview(const std::string& mid,const Json& body){
    long long base=-1;try{base=integer(body.value("baseRevision",Json(-1)));}catch(...){}if(base<0)throw ApiError(409,"stale mapping revision");
    if(body.contains("markers")){
        require(!body.contains("project"),"Supply markers or project, not both");
        const auto& markers=body.at("markers");require(markers.is_array()&&markers.size()<=4,"Supply up to four placement markers");
        auto markerProject=checked({{"rects",markers},{"collections",Json::array()},{"traces",Json::array()},{"groups",Json::array()}});
        for(const auto& marker:markerProject["rects"]){
            require(marker.at("mode")=="grid"&&marker.value("graphic",std::string{})=="wireframe"&&marker.value("config",Json::object()).value("centerOnly",Json())==true,"Markers must be dot-only patterns");
            const auto color=marker["config"].value("color",std::string{});require(color.size()==7&&color[0]=='#'&&color.find_first_not_of("0123456789abcdefABCDEF",1)==std::string::npos,"Expected marker #RRGGBB");
        }
        return {{"type","mapping_markers"},{"mappingId",mid},{"clientId",textId(body.value("clientId",Json()))},{"baseRevision",base},{"markers",markerProject["rects"]}};
    }
    return {{"type","mapping_preview"},{"mappingId",mid},{"clientId",textId(body.value("clientId",Json()))},{"baseRevision",base},{"project",checked(body.at("project"))}};
}
Json mappingCompatibilityPreview(const Json& document,const std::string& mid,const Json& body){
    auto preview=prepareMappingPreview(mid,body);require(document.at("mappings").contains(mid),"Unknown mapping");
    if(preview["baseRevision"]!=document["mappings"][mid]["revision"])throw ApiError(409,"stale mapping revision");return preview;
}
void applyMappingPreviews(Json& snapshot){
    const auto previews=snapshot.value("mappingPreviews",Json::object());if(previews.empty())return;
    Json document={{"mappings",snapshot.at("mappings")},{"grid",snapshot.at("state").at("grid")}};
    for(auto it=previews.begin();it!=previews.end();++it){if(it.value().contains("markers"))continue;if(!document["mappings"].contains(it.key())||it.value().value("baseRevision",Json())!=document["mappings"][it.key()]["revision"])continue;document["mappings"][it.key()]["project"]=it.value().at("project");auto derived=mappingSnapshot(document,it.key(),Json::array(),true);snapshot["mappings"][it.key()]["project"]=derived["project"];snapshot["mappings"][it.key()]["collectionContexts"]=derived["collectionContexts"];}
}
void MappingPreviewCache::apply(Json& snapshot){
    Json previews=Json::object();for(auto it=snapshot.at("mappingPreviews").begin();it!=snapshot.at("mappingPreviews").end();++it)if(!it.value().contains("markers"))previews[it.key()]=it.value();
    if(previews.empty()){derived_=Json::object();previews_=Json();}
    const auto revision=snapshot.value("revision",uint64_t(0)),media=snapshot.value("mediaRevision",uint64_t(0));
    if(!previews.empty()&&(revision!=revision_||media!=media_||previews!=previews_)){
        // The model already validated and generated collection meshes when it
        // accepted this preview. Derive draw geometry once per changed preview,
        // not once per video frame while the pointer is stationary.
        auto rendered=snapshot;rendered["mappingPreviews"]=previews;applyMappingPreviews(rendered);appendMetaMappingRendering(rendered);derived_=Json::object();
        for(auto it=previews.begin();it!=previews.end();++it)if(rendered["mappings"].contains(it.key())){
            const auto& mapping=rendered["mappings"][it.key()];
            derived_[it.key()]={{"project",mapping["project"]},{"collectionContexts",mapping["collectionContexts"]}};
        }
        revision_=revision;media_=media;previews_=previews;
    }
    for(auto it=derived_.begin();it!=derived_.end();++it)snapshot["mappings"][it.key()].update(it.value());
    for(auto it=snapshot["mappingPreviews"].begin();it!=snapshot["mappingPreviews"].end();++it){
        if(!it.value().contains("markers")||!snapshot["mappings"].contains(it.key())||it.value()["baseRevision"]!=snapshot["mappings"][it.key()]["revision"])continue;
        auto& project=snapshot["mappings"][it.key()]["project"];auto& rects=project["renderRects"];if(!rects.is_array())rects=project["rects"];
        for(const auto& marker:it.value()["markers"])rects.push_back(marker);
    }
}

}
