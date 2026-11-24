#include "mapping_model.hpp"
#include "api_error.hpp"
#include "mapping_geometry.hpp"
#include "mapping_collections.hpp"
#include "trace_model.hpp"
#include "collection_rendering.hpp"
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <set>
#include <cctype>
#include <cstdio>

namespace vj {
namespace {
void require(bool condition,const std::string& message){if(!condition)throw ApiError(400,message);}
std::string unique(const std::string& prefix){static std::atomic<unsigned long> sequence;return prefix+"-"+std::to_string(std::chrono::system_clock::now().time_since_epoch().count())+"-"+std::to_string(++sequence);}
std::string name(const Json& value){
    require(value.is_string(),"Name must be text");auto result=value.get<std::string>();
    auto first=result.find_first_not_of(" \t\r\n"),last=result.find_last_not_of(" \t\r\n");
    require(first!=std::string::npos,"Name is required");result=result.substr(first,last-first+1);
    require(std::count_if(result.begin(),result.end(),[](unsigned char c){return (c&0xc0)!=0x80;})<=200,"Name is too long");return result;
}
std::string lower(std::string value){for(auto& c:value)c=std::tolower(static_cast<unsigned char>(c));return value;}
double finite(const Json& value,double minimum,double maximum){require(value.is_number(),"Expected number");double result=value;require(std::isfinite(result)&&result>=minimum&&result<=maximum,"Number outside range");return result;}
void points(const Json& value,size_t minimum,size_t maximum){
    require(value.is_array()&&value.size()>=minimum&&value.size()<=maximum,"Invalid point count");
    for(const auto& point:value){require(point.is_array()&&point.size()==2,"Expected XY pair");for(const auto& v:point)finite(v,0,1);}
}
Json& object(Json& items,const std::string& id){for(auto& item:items)if(item.value("id",std::string{})==id)return item;throw ApiError(404,"Object not found");}
Json& mapping(Json& document,const std::string& mid){require(document["mappings"].contains(mid),"Unknown mapping");return document["mappings"][mid];}
void revision(const Json& body,const std::string& key,const Json& current){if(!body.contains(key)||!body[key].is_number_integer()||body[key]!=current)throw ApiError(409,"Supply the current "+key);}
Json objects(const Json& project){Json result;for(const auto* key:{"rects","traces","collections","groups"})result[key]=project.value(key,Json::array());return result;}
void source(const Json& value){require(value.is_string(),"Invalid source");auto s=value.get<std::string>();if(s=="none")return;bool valid=false;for(int i=1;i<=20;++i)valid|=s=="out"+std::to_string(i);require(valid,"Invalid source");}
void choice(const Json& value,const std::vector<Json>& choices){require(std::find(choices.begin(),choices.end(),value)!=choices.end(),"Invalid option");}
bool owned(const Json& project,const std::string& rid){for(const auto& c:project.value("collections",Json::array()))for(const auto& f:c.value("faces",Json::array()))if(f.value("rectId",std::string{})==rid)return true;return false;}
bool generated(const Json& project,const std::string& rid){for(const auto& c:project.value("collections",Json::array()))if(c.value("kind",std::string{})!="planar")for(const auto& f:c.value("faces",Json::array()))if(f.value("rectId",std::string{})==rid)return true;return false;}
void cleanGroups(Json& project){
    Json result=Json::array();std::set<std::string> available,used,groupIds;
    for(const auto& rect:project["rects"])available.insert(rect["id"]);
    for(auto group:project.value("groups",Json::array())){
        require(group.is_object()&&group.contains("id")&&group["id"].is_string(),"Invalid group");
        require(!group["id"].get<std::string>().empty()&&group["id"].get<std::string>().size()<=100,"Invalid group ID");require(groupIds.insert(group["id"]).second,"Duplicate group ID");group["name"]=name(group["name"]);
        require(group["rectIds"].is_array()&&group["rectIds"].size()<=128,"Invalid group members");Json members=Json::array();std::set<std::string> local;
        for(const auto& id:group["rectIds"]){require(id.is_string(),"Invalid group member");auto rid=id.get<std::string>();require(local.insert(rid).second,"Duplicate group member");if(!available.contains(rid))continue;require(used.insert(rid).second,"A surface can belong to only one group");members.push_back(rid);}
        if(!members.empty()){group["rectIds"]=members;result.push_back(group);}
    }
    require(result.size()<=128,"Too many groups");project["groups"]=result;
}
void validateRect(const Json& rect){
    require(rect.contains("id")&&rect["id"].is_string(),"Surface needs an ID");name(rect.at("name"));validateMappingGeometry(rect);
    source(rect.at("source"));choice(rect.at("mode"),{"live","grid"});choice(rect.at("kind"),{"surface","overlay"});choice(rect.at("blend"),{"normal","add","screen","multiply","subtract"});choice(rect.at("fit"),{"stretch","fit","fill"});
    choice(rect.value("contentFit",Json("inherit")),{"inherit","stretch","contain","cover"});
    const auto position=rect.value("contentPosition",Json::array({.5,.5}));
    require(position.is_array()&&position.size()==2,"Content position needs two coordinates");
    for(const auto& axis:position)finite(axis,0,1);
    require(rect.value("occlude",Json(false)).is_boolean(),"occlude must be boolean");
    double radius=finite(rect.value("cornerRadius",Json(0)),0,.5);require(!radius||(rect["corners"].size()==4&&!rect.value("fold",false)),"Rounded corners require a four-corner surface");
    if(const auto h=rect.find("hemisphere");h!=rect.end()){
        require(h->is_object()&&h->value("enabled",Json(true)).is_boolean(),"hemisphere must be an object with boolean enabled");
        finite(h->value("wrap",Json(1)),0,1);finite(h->value("feather",Json(.04)),0,.5);finite(h->value("inset",Json(0)),0,.5);finite(h->value("edgeBoost",Json(0)),0,1);
        if(h->value("enabled",true))require(rect["corners"].size()==4&&!rect.value("fold",false)&&!radius&&rect.value("kind",std::string("surface"))=="surface","Hemisphere requires a four-corner surface without rounded corners");
    }
}
void validateProject(Json& project){
    require(project.is_object()&&project["rects"].is_array()&&project["rects"].size()<=128,"Mapping supports up to 128 surfaces");std::set<std::string> seen;
    for(const auto& rect:project["rects"]){if(!owned(project,rect["id"]))validateRect(rect);require(seen.insert(rect["id"]).second,"Duplicate surface ID");}
    normalizeMappingCollections(project);normalizeMappingTraces(project);cleanGroups(project);
}
void patchRect(Json& rect,const Json& patch){
    // Hemisphere edits merge into the current settings, so one field can change alone.
    Json hemisphere={{"enabled",true},{"wrap",1.},{"feather",.04},{"inset",0.},{"edgeBoost",0.}};
    if(patch.contains("hemisphere")){require(patch["hemisphere"].is_object(),"hemisphere must be an object");if(rect.value("hemisphere",Json()).is_object())hemisphere.update(rect["hemisphere"]);hemisphere.update(patch["hemisphere"]);}
    static const std::set<std::string> geometry={"corners","uvs","cornerRadius","fold","removePoint","curvature"};
    static const std::set<std::string> fields={"name","source","mutedSource","mode","graphic","config","blend","fit","contentFit","contentPosition","kind","trace","occlude","hemisphere"};
    editMappingGeometry(rect,patch);
    for(auto it=patch.begin();it!=patch.end();++it){if(it.key()=="revision"||it.key()=="rectIds"||it.key()=="id"||geometry.contains(it.key()))continue;require(fields.contains(it.key()),"Surface setting not yet ported: "+it.key());rect[it.key()]=it.value();}
    if(patch.contains("fit"))rect.erase("fitBounds");
    if(patch.contains("name"))rect["name"]=name(patch["name"]);
    if(patch.contains("source")&&patch["source"]!="none")rect["mutedSource"]=patch["source"];
    if(rect.contains("mutedSource"))source(rect["mutedSource"]);
    if(patch.contains("hemisphere"))rect["hemisphere"]=hemisphere;
    if(patch.contains("trace")){
        require(patch["trace"].is_object(),"trace must be an object");auto trace=Json{{"mode","perimeter"},{"scope","face"},{"width",.04},{"offset",0.},{"reverse",false}};trace.update(patch["trace"]);
        choice(trace["mode"],{"perimeter","horizontal","vertical"});choice(trace["scope"],{"face","collection"});finite(trace["width"],.001,1);finite(trace["offset"],0,1);require(trace["reverse"].is_boolean(),"reverse must be boolean");rect["trace"]=trace;
    }
    if(rect.contains("graphic"))choice(rect["graphic"],{"grid","alignment","wireframe","solid","faces"});
    if(rect.contains("config")){const auto& c=rect["config"];require(c.is_object(),"Invalid pattern settings");if(c.contains("centerDot"))require(c["centerDot"].is_boolean(),"centerDot must be boolean");if(c.contains("color")){require(c["color"].is_string(),"Invalid color");auto color=c["color"].get<std::string>();require(color.size()==7&&color[0]=='#'&&color.find_first_not_of("0123456789abcdefABCDEF",1)==std::string::npos,"Expected #RRGGBB");}if(c.contains("thickness"))finite(c["thickness"],1,20);if(c.contains("markerSize"))finite(c["markerSize"],5,35);}
    validateRect(rect);
}
Json layoutSummary(const Json& document){
    Json entries=Json::array();for(auto it=document["layouts"].begin();it!=document["layouts"].end();++it){Json item={{"id",it.key()},{"name",it.value()["name"]}};for(const auto* key:{"rects","traces","collections","groups"})item[key]=it.value()["objects"][key].size();entries.push_back(item);}
    std::sort(entries.begin(),entries.end(),[](const Json& a,const Json& b){return lower(a["name"])<lower(b["name"]);});return {{"revision",document["layoutsRevision"]},{"layouts",entries}};
}
}

Json captureMappingClipboard(const Json& mapping,const Json& ids,const std::string& mid,const std::string& trace){
    auto project=mapping.at("project");Json payload={{"format","vj-mapping-clipboard/1"},{"mappingId",mid}};
    if(!trace.empty()){payload["kind"]="trace";payload["trace"]=object(project["traces"],trace);return payload;}
    const auto selected=mappingIds(project,ids);
    for(auto collection:project.value("collections",Json::array()))if(collection["kind"]=="boxes")for(auto box:collection["boxes"]){
        Json faces=Json::array(),rects=Json::array();std::set<std::string> members;
        for(const auto& face:collection["faces"])if(face["boxId"]==box["id"]){faces.push_back(face);members.insert(face["rectId"]);rects.push_back(object(project["rects"],face["rectId"]));}
        if(std::all_of(selected.begin(),selected.end(),[&](const Json& id){return members.contains(id.get<std::string>());})){box["alignment"]=mappingBoxAlignment(collection,box["id"]);collection["boxes"]=Json::array();collection["faces"]=Json::array();payload.update({{"kind","box"},{"collection",collection},{"box",box},{"faces",faces},{"rects",rects}});return payload;}
    }
    payload["kind"]="surfaces";payload["rects"]=Json::array();for(const auto& id:selected)payload["rects"].push_back(object(project["rects"],id));
    payload["collections"]=Json::array();
    for(auto collection:project.value("collections",Json::array()))if(collection["kind"]=="planar"){
        Json faces=Json::array();for(const auto& face:collection["faces"])if(std::find(selected.begin(),selected.end(),face["rectId"])!=selected.end())faces.push_back(face);
        if(!faces.empty()){collection["faces"]=faces;payload["collections"].push_back(collection);}
    }
    return payload;
}
Json mappingLayouts(const Json& document){return layoutSummary(document);}
Json mappingIds(const Json& project,const Json& ids,bool allowEmpty){
    require(ids.is_array()&&ids.size()<=128&&(allowEmpty||!ids.empty()),"Supply surface IDs");std::set<std::string> available,seen;Json result=Json::array();
    for(const auto& rect:project["rects"])available.insert(rect["id"]);
    for(const auto& value:ids){require(value.is_string(),"Invalid surface ID");auto id=value.get<std::string>();require(available.contains(id),"Unknown surface");if(seen.insert(id).second)result.push_back(id);}return result;
}
void validateMappingProject(Json& project){validateProject(project);}
Json mappingSnapshot(const Json& document,const std::string& mid,const Json& selection,bool collectionsNormalized){
    auto result=document.at("mappings").at(mid);result["layout"]=nullptr;const auto lid=result.value("layoutId",std::string{});
    if(document.contains("layouts")&&document["layouts"].contains(lid)){const auto& layout=document["layouts"][lid];result["layout"]={{"id",lid},{"name",layout["name"]},{"modified",objects(result["project"])!=layout["objects"]}};}
    result.erase("layoutId");result["selectedRectIds"]=Json::array();for(const auto& id:selection)for(const auto& rect:result["project"]["rects"])if(rect["id"]==id)result["selectedRectIds"].push_back(id);
    std::set<std::string> effects={"media_collection","patch_collection","patch_trace"},traces={"patch_trace"},activeSources,traceSources;
    if(document.contains("grid")){
        const auto& grid=document["grid"];
        for(auto bus=grid["running"].begin();bus!=grid["running"].end();++bus)for(const auto* bank:{"selections","selections_b"}){
            const auto selected=grid[bank].value(bus.key(),Json::object());
            for(const auto& row:grid["rows"]){const auto id=row["id"].get<std::string>();if(!row.value("enabled",true)||!selected.contains(id))continue;
                const auto cid=selected[id].get<std::string>();if(!row["clips"].contains(cid))continue;const auto& clip=row["clips"][cid];if(clip.value("opacity",1.)<=0)continue;
                const auto gen=clip["gen"].get<std::string>(),source=bus.key()=="program"?"out1":bus.key();if(effects.contains(gen))activeSources.insert(source);if(traces.contains(gen))traceSources.insert(source);
            }
        }
    }
    auto normalized=result["project"];if(!collectionsNormalized)normalizeMappingCollections(normalized);
    const auto derived=collectionRendering(normalized,mid,activeSources,traceSources);result["project"]["renderRects"]=derived.renderRects;
    result["collectionContexts"]=Json::object();for(const auto& [key,context]:derived.contexts)result["collectionContexts"][key]={{"source",context.first},{"geometry",context.second}};
    return result;
}
Json mappingRequest(Json& d,const std::string& method,const std::vector<std::string>& p,const Json& body){
    if(!d.contains("layouts"))d["layouts"]=Json::object();if(!d.contains("layoutsRevision"))d["layoutsRevision"]=0;
    if(p.at(2)=="mapping-layouts"){
        auto& layouts=d["layouts"];std::string lid=p.size()>3?p[3]:"";const bool importing=method=="POST"&&lid=="import";if(importing)lid.clear();
        if(!lid.empty()&&!layouts.contains(lid))throw ApiError(404,"Layout not found");
        if(method=="GET"){if(lid.empty())return layoutSummary(d);Json result=layouts[lid];result.update({{"id",lid},{"revision",d["layoutsRevision"]}});return result;}
        revision(body,"libraryRevision",d["layoutsRevision"]);
        if(method=="DELETE"){require(!lid.empty(),"Layout ID required");layouts.erase(lid);for(auto& m:d["mappings"])if(m.value("layoutId",std::string{})==lid)m.erase("layoutId");}
        else{
            require((method=="POST"&&lid.empty())||((method=="PUT"||method=="PATCH")&&!lid.empty()),"Invalid layout command");auto title=name(body.at("name"));
            for(auto it=layouts.begin();it!=layouts.end();++it)if(it.key()!=lid&&lower(it.value()["name"])==lower(title))throw ApiError(409,"A layout with that name already exists");
            if(method=="PATCH")layouts[lid]["name"]=title;
            else if(importing){
                require(layouts.size()<1024,"Maximum 1024 layouts");auto project=body.at("objects");require(project.is_object(),"Layout objects must be an object");
                for(const auto* key:{"rects","traces","collections","groups"})if(!project.contains(key))project[key]=Json::array();
                validateProject(project);lid=unique("layout");layouts[lid]={{"name",title},{"objects",objects(project)}};
            }else{
                auto& m=mapping(d,body.at("mappingId").get<std::string>());revision(body,"revision",m["revision"]);
                if(lid.empty()){require(layouts.size()<1024,"Maximum 1024 layouts");lid=unique("layout");}layouts[lid]={{"name",title},{"objects",objects(m["project"])}};m["layoutId"]=lid;
            }
        }
        d["layoutsRevision"]=d["layoutsRevision"].get<uint64_t>()+1;auto result=layoutSummary(d);result["id"]=lid;return result;
    }
    require(p.size()>=4,"Mapping ID required");const auto mid=p[3];auto& m=mapping(d,mid);auto& project=m["project"];
    if(method=="GET"){if(p.size()==4)return mappingSnapshot(d,mid);if(p[4]=="traces"){auto result=requestMappingTrace(project,method,p.size()>5?p[5]:"",body);result["revision"]=m["revision"];return result;}if(p[4]=="collections")return {{"revision",m["revision"]},{"collections",project.value("collections",Json::array())}};if(p[4]=="groups")return {{"revision",m["revision"]},{"groups",project.value("groups",Json::array())}};throw ApiError(404,"Mapping route not found");}
    require(p.size()>=5,"Mapping action required");revision(body,"revision",m["revision"]);const auto action=p[4];Json extra=Json::object();
    if(action=="batch"){
        require(method=="POST"&&body.contains("operations")&&body["operations"].is_array()&&!body["operations"].empty()&&body["operations"].size()<=128,"Supply 1–128 operations");
        Json candidate=d;const auto initialRevision=m["revision"].get<uint64_t>();
        for(const auto& operation:body["operations"]){
            const auto route=operation.at("action").get<std::string>(),verb=operation.at("method").get<std::string>();
            require(verb=="PATCH"||verb=="POST","Batch supports PATCH and POST");
            auto slash=route.find('/');const auto category=route.substr(0,slash);
            require(category=="collections"||category=="rects"||category=="transform-surfaces"||category=="move-surfaces","Unsupported batch action");
            std::vector<std::string> path={"api","v1","mappings",mid,category};
            if(slash!=std::string::npos){auto child=route.substr(slash+1);require(!child.empty()&&child.find('/')==std::string::npos,"Invalid batch action");path.push_back(child);}
            Json request=operation.value("body",Json::object());require(request.is_object(),"Invalid batch body");request["revision"]=candidate["mappings"][mid]["revision"];mappingRequest(candidate,verb,path,request);
        }
        candidate["mappings"][mid]["revision"]=initialRevision+1;d=std::move(candidate);return mappingSnapshot(d,mid);
    }
    if(action=="subdivide-box"){
        require(method=="POST","Use POST");
        auto integer=[&](const char* key){const auto v=body.value(key,Json(2));require(v.is_number_integer(),std::string(key)+" must be an integer");return int(finite(v,1,128));};
        auto plan=mappingBoxSubdivision(project,body.at("collectionId"),body.at("boxId"),integer("columns"),integer("rows"),integer("depth"));
        project=plan["project"];validateProject(project);m["revision"]=m["revision"].get<uint64_t>()+1;
        auto result=mappingSnapshot(d,mid,plan["rectIds"]);result["rectIds"]=plan["rectIds"];result["boxIds"]=plan["boxIds"];return result;
    }
    if(action=="subdivide"){
        require(method=="POST","Use POST");const auto rid=body.at("rectId").get<std::string>();
        const auto integer=[&](const char* key,int fallback){auto v=body.value(key,Json(fallback));require(v.is_number_integer(),std::string(key)+" must be an integer");return int(finite(v,0,128));};
        const int columns=integer("columns",2),rows=integer("rows",3),orientation=integer("orientation",0);
        require(columns*rows>1,"Choose at least two faces");
        auto original=object(project["rects"],rid);auto cells=mappingSubdivisionCells(original,columns,rows,orientation);
        require(project["rects"].size()-1+cells.size()<=128,"Mapping supports up to 128 surfaces");
        for(const auto& c:project["collections"])for(const auto& f:c["faces"])if(f["rectId"]==rid)require(c["kind"]=="planar","Box and point faces cannot be subdivided yet");
        Json ids=Json::array(),children=Json::array();
        for(size_t i=0;i<cells.size();i++){
            auto child=original;child["id"]=unique("rect");child["name"]=original["name"].get<std::string>()+" · R"+std::to_string(i/columns+1)+" C"+std::to_string(i%columns+1);
            child["corners"]=cells[i]["corners"];child["uvs"]=cells[i]["uvs"];
            // Spread bright alignment hues around the wheel, rather than giving
            // every new face its parent's indistinguishable pattern color.
            const double hue=std::fmod(.5+i*.6180339887498949,1.)*6;
            const int sector=int(hue);const double t=hue-sector,low=.15;
            const double rising=low+(1-low)*t,falling=1-(1-low)*t;
            const double rgb[6][3]={{1,rising,low},{falling,1,low},{low,1,rising},{low,falling,1},{rising,low,1},{1,low,falling}};
            char color[8];std::snprintf(color,sizeof(color),"#%02x%02x%02x",int(std::round(rgb[sector][0]*255)),int(std::round(rgb[sector][1]*255)),int(std::round(rgb[sector][2]*255)));
            child["mode"]="grid";child["graphic"]="solid";child["patternStyleExplicit"]=true;
            auto config=child.value("config",Json::object());config["color"]=color;child["config"]=config;
            if(original.value("fit",std::string("stretch"))!="stretch"&&!original.contains("fitBounds")){
                double low[2]={INFINITY,INFINITY},high[2]={-INFINITY,-INFINITY};for(const auto& p:original["corners"])for(int a=0;a<2;a++){low[a]=std::min(low[a],p[a].get<double>());high[a]=std::max(high[a],p[a].get<double>());}child["fitBounds"]={high[0]-low[0],high[1]-low[1]};
            }
            ids.push_back(child["id"]);children.push_back(child);
        }
        for(auto& c:project["collections"]){
            Json faces=Json::array();for(auto face:c["faces"]){
                if(face["rectId"]!=rid){faces.push_back(face);continue;}
                // Collection normalization owns its faces' display mode/style.
                // Keep the new solid alignment faces after normalization/reload.
                c["mode"]="grid";c["graphic"]="solid";c["patternStyleExplicit"]=true;
                const auto oldFaceId=face["id"];Json first;
                for(size_t i=0;i<cells.size();i++){
                    auto f=face;f["id"]=unique("face");f["rectId"]=ids[i];f["planeCorners"]=Json::array();
                    for(const auto& uv:cells[i]["localCorners"])f["planeCorners"].push_back(mappingQuadPoint(face["planeCorners"],uv[0],uv[1]));
                    f["uvs"]=cells[i]["uvs"];if(i==0)first=f["id"];faces.push_back(f);
                }
                if(c.contains("plane")&&c["plane"].value("referenceFaceId",Json())==oldFaceId)c["plane"]["referenceFaceId"]=first;
            }c["faces"]=faces;
        }
        for(auto& group:project["groups"]){Json members=Json::array();for(const auto& id:group["rectIds"]){if(id==rid)for(const auto& child:ids)members.push_back(child);else members.push_back(id);}group["rectIds"]=members;}
        Json rects=Json::array();for(const auto& rect:project["rects"]){if(rect["id"]==rid)for(const auto& child:children)rects.push_back(child);else rects.push_back(rect);}project["rects"]=rects;
        project["selectedRectId"]=ids[0];extra["rectIds"]=ids;
        validateProject(project);m["revision"]=m["revision"].get<uint64_t>()+1;auto result=mappingSnapshot(d,mid,ids);result.update(extra);return result;
    }
    if(action=="paste"){
        require(method=="POST","Use POST");const auto& payload=body.at("clipboard");require(payload.is_object()&&payload.value("format",std::string{})=="vj-mapping-clipboard/1","Invalid mapping clipboard");
        const auto kind=payload.value("kind",std::string{});const double offset=finite(body.value("offset",Json(.025)),-100,100);Json ids=Json::array();
        const auto copiedName=[](const Json& items,const Json& original){auto base=name(original)+" copy",result=base;int n=2;while(std::any_of(items.begin(),items.end(),[&](const Json& item){return item.value("name",std::string{})==result;}))result=base+" "+std::to_string(n++);return result;};
        if(kind=="trace"){
            auto trace=payload.at("trace");trace["name"]=copiedName(project["traces"],trace.at("name"));for(auto& p:trace["points"]){p[0]=p[0].get<double>()+offset;p[1]=p[1].get<double>()+offset;}
            auto result=requestMappingTrace(project,"POST","",trace);extra["traceId"]=result.at("traceId");
        }else if(kind=="surfaces"||kind=="box"){
            const auto& rects=payload.at("rects");require(rects.is_array()&&!rects.empty()&&rects.size()<=128,"Supply 1–128 copied surfaces");
            std::map<std::string,std::string> replacements;for(auto rect:rects){auto old=rect.at("id").get<std::string>();require(!replacements.contains(old),"Duplicate copied surface");rect["id"]=unique("rect");replacements[old]=rect["id"];rect["origin"]="manual";rect["name"]=copiedName(project["rects"],rect.at("name"));
                if(kind=="surfaces")for(auto& p:rect["corners"]){p[0]=p[0].get<double>()+offset;p[1]=p[1].get<double>()+offset;}
                validateRect(rect);ids.push_back(rect["id"]);project["rects"].push_back(rect);
            }
            if(kind=="surfaces"){
                const auto collections=payload.value("collections",Json::array());require(collections.is_array()&&collections.size()<=128,"Invalid clipboard collections");
                for(auto source:collections){
                    require(source.at("kind")=="planar","Invalid planar clipboard");auto cid=source.at("id").get<std::string>();Json* destination=nullptr;
                    if(payload.value("mappingId",std::string{})==mid)for(auto& c:project["collections"])if(c["id"]==cid&&c["kind"]=="planar")destination=&c;
                    const bool newCollection=destination==nullptr;auto faces=source.at("faces");require(faces.is_array()&&!faces.empty()&&faces.size()<=128,"Invalid copied planar faces");
                    if(newCollection){source["id"]=unique("collection");source["name"]=copiedName(project["collections"],source.at("name"));source["faces"]=Json::array();project["collections"].push_back(source);destination=&project["collections"].back();}
                    std::map<std::string,std::string> faceIDs;
                    for(auto face:faces){auto old=face.at("rectId").get<std::string>();require(replacements.contains(old),"Missing copied planar surface");auto fid=unique("face");faceIDs[face.at("id")]=fid;face["id"]=fid;face["rectId"]=replacements.at(old);(*destination)["faces"].push_back(face);}
                    if(newCollection&&(*destination).value("plane",Json::object()).value("space",std::string{})=="reference"){
                        auto& plane=(*destination)["plane"];auto ref=plane.at("referenceFaceId").get<std::string>();
                        // A subset copy may omit the old reference face. Its plane coordinates
                        // remain valid; identify one of the copied faces as the new reference.
                        plane["referenceFaceId"]=faceIDs.contains(ref)?faceIDs.at(ref):(*destination)["faces"][0]["id"].get<std::string>();
                    }
                }
            }
            if(kind=="box"){
                auto source=payload.at("collection");require(source.at("kind")=="boxes","Invalid box clipboard");auto cid=source.at("id").get<std::string>();Json* destination=nullptr;
                if(payload.value("mappingId",std::string{})==mid)for(auto& c:project["collections"])if(c["id"]==cid&&c["kind"]=="boxes")destination=&c;
                const bool newCollection=destination==nullptr;
                if(!destination){source["id"]=unique("collection");source["boxes"]=Json::array();source["faces"]=Json::array();project["collections"].push_back(source);destination=&project["collections"].back();}
                auto box=payload.at("box");require((*destination)["boxes"].size()<16,"Maximum 16 boxes per collection");box["name"]=copiedName((*destination)["boxes"],box.at("name"));box["id"]=unique("box");(*destination)["boxes"].push_back(box);
                std::map<std::string,std::string> faceIDs;for(auto face:payload.at("faces")){auto old=face.at("rectId").get<std::string>();require(replacements.contains(old),"Missing copied box face");auto fid=unique("face");faceIDs[face.at("id")]=fid;face["id"]=fid;face["rectId"]=replacements.at(old);face["boxId"]=box["id"];(*destination)["faces"].push_back(face);}
                if(newCollection&&(*destination).contains("plane")&&(*destination)["plane"].contains("referenceFaceId")){auto ref=(*destination)["plane"]["referenceFaceId"].get<std::string>();if(faceIDs.contains(ref))(*destination)["plane"]["referenceFaceId"]=faceIDs.at(ref);}
                validateProject(project);moveMappingCollectionSurfaces(project,ids,Json::array({offset,offset}));
            }
            extra["rectIds"]=ids;project["selectedRectId"]=ids.back();project["selectedTraceId"]=nullptr;
        }else throw ApiError(400,"Unsupported mapping clipboard kind");
        validateProject(project);m["revision"]=m["revision"].get<uint64_t>()+1;auto result=mappingSnapshot(d,mid);result.update(extra);return result;
    }
    if(action=="load-layout"){
        require(method=="POST","Use POST");revision(body,"libraryRevision",d["layoutsRevision"]);auto lid=body.at("layoutId").get<std::string>();if(!d["layouts"].contains(lid))throw ApiError(404,"Layout not found");
        const auto output=project["output"];project=d["layouts"][lid]["objects"];project["output"]=output;m["layoutId"]=lid;
    }else if(action=="traces"){
        extra=requestMappingTrace(project,method,p.size()>5?p[5]:"",body);
    }else if(action=="collections"){
        extra=requestMappingCollection(project,method,p.size()>5?p[5]:"",body);
    }else if(action=="groups"){
        auto& groups=project["groups"];if(groups.is_null())groups=Json::array();std::string gid=p.size()>5?p[5]:"";
        Json previous;if(!gid.empty())previous=object(groups,gid);
        if(method=="DELETE"){require(!gid.empty(),"Group ID required");groups.erase(std::remove_if(groups.begin(),groups.end(),[&](const Json& g){return g["id"]==gid;}),groups.end());}
        else{
            require((method=="POST"&&gid.empty())||(method=="PATCH"&&!gid.empty()),"Invalid group command");
            auto title=name(body.value("name",previous.is_null()?Json():previous["name"]));
            auto members=body.contains("rectIds")?mappingIds(project,body["rectIds"]):previous.at("rectIds");
            if(gid.empty())gid=unique("group");Json group={{"id",gid},{"name",title},{"rectIds",members}},next=Json::array();bool replaced=false;
            for(auto old:groups){if(old["id"]==gid){next.push_back(group);replaced=true;continue;}auto& ids=old["rectIds"];ids.erase(std::remove_if(ids.begin(),ids.end(),[&](const Json& id){return std::find(members.begin(),members.end(),id)!=members.end();}),ids.end());if(!ids.empty())next.push_back(old);}
            if(!replaced)next.push_back(group);groups=next;
        }extra["groupId"]=gid;
    }else if(action=="rects"){
        if(method=="POST"&&p.size()==5){
            if(body.contains("corners")){points(body["corners"],3,64);if(body["corners"].size()!=4)require(body.contains("uvs"),"Non-quad shapes require corresponding UVs");}
            if(body.contains("uvs"))points(body["uvs"],body.value("corners",Json::array({{0,0},{1,0},{1,1},{0,1}})).size(),body.value("corners",Json::array({{0,0},{1,0},{1,1},{0,1}})).size());
            Json rect={{"id",unique("rect")},{"name",body.value("name",std::string("Surface"))},{"kind","surface"},{"origin","manual"},{"source","out1"},{"mutedSource","out1"},{"mode","live"},{"graphic","grid"},{"config",{{"color","#00ff00"},{"thickness",3}}},{"corners",{{0,0},{1,0},{1,1},{0,1}}},{"uvs",{{0,1},{1,1},{1,0},{0,0}}},{"blend","normal"},{"fit","stretch"},{"cornerRadius",0.0}};
            patchRect(rect,body);project["rects"].push_back(rect);project["selectedRectId"]=rect["id"];extra["rectId"]=rect["id"];
        }else{
            Json ids=p.size()>5?mappingIds(project,Json::array({p[5]})):mappingIds(project,body.at("rectIds"));
            if(method=="DELETE"){
                removeMappingCollectionSurfaces(project,ids);
            }else{require(method=="PATCH","Invalid surface command");for(const auto& id:ids){if(owned(project,id))for(const auto* field:{"source","mutedSource","mode","graphic","fit"})require(!body.contains(field),"Edit collection-owned properties through its collection");if(body.contains("corners")||body.contains("uvs")||body.contains("fold")||body.contains("removePoint"))require(!owned(project,id),"Edit collection geometry through its collection");require(!body.contains("occlude")||!owned(project,id),"Occlusion requires an independent surface");require(!body.contains("hemisphere")||!owned(project,id),"Hemisphere requires an independent surface");if(body.contains("curvature"))require(!generated(project,id),"Curvature requires a planar collection or an independent surface");patchRect(object(project["rects"],id),body);}}
        }
    }else if(action=="arrange-surfaces"){
        // Rect order is stacking order: later surfaces draw in front of earlier ones.
        require(method=="POST","Use POST");const auto to=body.value("to",std::string{});choice(Json(to),{"front","forward","backward","back"});
        Json ids=mappingIds(project,body.at("rectIds"));for(const auto& id:ids)require(!owned(project,id),"Arrange collection faces through their collection");
        auto& rects=project["rects"];std::vector<Json> list(rects.begin(),rects.end());auto selected=[&](const Json& r){return std::find(ids.begin(),ids.end(),r["id"])!=ids.end();};
        if(to=="front"||to=="back"){std::vector<Json> chosen,rest;for(auto& r:list)(selected(r)?chosen:rest).push_back(r);list=to=="front"?rest:chosen;auto& tail=to=="front"?chosen:rest;list.insert(list.end(),tail.begin(),tail.end());}
        else if(to=="forward"){for(size_t i=list.size();i-->1;)if(selected(list[i-1])&&!selected(list[i]))std::swap(list[i-1],list[i]);}
        else{for(size_t i=1;i<list.size();i++)if(selected(list[i])&&!selected(list[i-1]))std::swap(list[i-1],list[i]);}
        rects=Json(list);extra["rectIds"]=ids;
    }else if(action=="move-surfaces"){
        require(method=="POST","Use POST");extra["rectIds"]=moveMappingCollectionSurfaces(project,mappingIds(project,body.at("rectIds")),body.at("offset"));
    }else if(action=="transform-surfaces"){
        require(method=="POST"&&body.at("rects").is_array(),"Supply surface geometry");for(const auto& patch:body["rects"]){auto id=patch.at("id").get<std::string>();if(owned(project,id))for(const auto* field:{"source","mutedSource","mode","graphic","fit"})require(!patch.contains(field),"Edit collection-owned properties through its collection");require(!patch.contains("occlude")||!owned(project,id),"Occlusion requires an independent surface");require(!patch.contains("hemisphere")||!owned(project,id),"Hemisphere requires an independent surface");require(!generated(project,id),"Edit generated geometry through its collection");patchRect(object(project["rects"],id),patch);}
    }else if(action=="output"){
        require(method=="PATCH","Use PATCH");for(auto it=body.begin();it!=body.end();++it){if(it.key()=="revision")continue;if(it.key()=="rotation")choice(it.value(),{0,90,180,270});else{require(it.key()=="enabled"||it.key()=="boundsGrid","Unknown output setting");require(it.value().is_boolean(),"Expected boolean");}project["output"][it.key()]=it.value();}
    }else if(action=="copy-object"||action=="copy-surfaces"){
        require(method=="POST","Use POST");
        if(action=="copy-object"&&body.at("kind")=="trace"){
            const auto target=body.at("target").get<std::string>();auto& dest=mapping(d,target);auto copy=object(project["traces"],body.at("id"));const auto oldFixture=mappingTraceFixtureId(mid,copy["id"]);copy["id"]=unique("trace");if(target==mid)copy["name"]=copy["name"].get<std::string>()+" copy";
            const auto offset=finite(body.value("offset",Json(0)),-1,1);for(auto& p:copy["points"]){p[0]=std::clamp(p[0].get<double>()+offset,0.,1.);p[1]=std::clamp(p[1].get<double>()+offset,0.,1.);}
            dest["project"]["traces"].push_back(copy);dest["project"]["selectedTraceId"]=copy["id"];validateProject(dest["project"]);dest["revision"]=dest["revision"].get<uint64_t>()+1;
            auto fixtures=d["controls"].value("fixtures",Json::array());for(auto fixture:fixtures)if(fixture.value("id",std::string{})==oldFixture){fixture["id"]=mappingTraceFixtureId(target,copy["id"]);d["controls"]["fixtures"].push_back(fixture);break;}
            return {{"id",copy["id"]},{"target",target},{"revision",dest["revision"]}};
        }
        if(action=="copy-object"&&body.at("kind")=="collection"){
            // The same projector duplicates in place: a named copy whose faces are offset.
            auto target=body.at("target").get<std::string>();auto& dest=mapping(d,target);auto copy=object(project["collections"],body.at("id"));copy["id"]=unique("collection");std::map<std::string,std::string> faces;
            const double offset=target==mid&&copy["kind"]=="planar"?finite(body.value("offset",Json(0)),-1,1):0;if(target==mid)copy["name"]=name(copy.value("name",Json("Collection")))+" copy";
            if(copy["kind"]=="points")copy["faces"]=Json::array();else for(auto& face:copy["faces"]){auto rect=object(project["rects"],face["rectId"]);rect["id"]=unique("rect");for(auto& pt:rect["corners"]){pt[0]=pt[0].get<double>()+offset;pt[1]=pt[1].get<double>()+offset;}faces[face["id"]]=unique("face");face["id"]=faces[face["id"]];face["rectId"]=rect["id"];dest["project"]["rects"].push_back(rect);}
            if(copy.contains("plane")&&copy["plane"].contains("referenceFaceId")){const auto ref=copy["plane"]["referenceFaceId"].get<std::string>();if(faces.contains(ref))copy["plane"]["referenceFaceId"]=faces[ref];}
            dest["project"]["collections"].push_back(copy);validateProject(dest["project"]);dest["revision"]=dest["revision"].get<uint64_t>()+1;return {{"id",copy["id"]},{"target",target},{"revision",dest["revision"]}};
        }
        if(action=="copy-object")require(body.at("kind")=="rect","Unknown object kind");auto ids=mappingIds(project,action=="copy-object"?Json::array({body.at("id")}):body.at("rectIds"));
        auto target=body.at("target").get<std::string>();auto& dest=mapping(d,target);Json copies=Json::array();double offset=finite(body.value("offset",Json(0)),-1,1);
        for(const auto& id:ids){auto copy=object(project["rects"],id);copy["id"]=unique("rect");copy["origin"]="manual";if(target==mid)copy["name"]=copy["name"].get<std::string>()+" copy";for(auto& pt:copy["corners"]){pt[0]=pt[0].get<double>()+offset;pt[1]=pt[1].get<double>()+offset;}validateMappingGeometry(copy);copies.push_back(copy);}
        for(const auto& copy:copies)dest["project"]["rects"].push_back(copy);validateProject(dest["project"]);dest["revision"]=dest["revision"].get<uint64_t>()+1;
        if(action=="copy-object")return {{"id",copies[0]["id"]},{"target",target},{"revision",dest["revision"]}};
        return {{"mapping",mappingSnapshot(d,target)},{"rectIds",[&]{Json result=Json::array();for(const auto& copy:copies)result.push_back(copy["id"]);return result;}()}};
    }else throw ApiError(501,"Mapping action not yet ported: "+action);
    validateProject(project);m["revision"]=m["revision"].get<uint64_t>()+1;
    auto result=mappingSnapshot(d,mid);result.update(extra);if(extra.contains("rectId"))return {{"rectId",extra["rectId"]},{"mapping",result}};return result;
}
}
