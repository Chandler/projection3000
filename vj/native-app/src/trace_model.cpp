#include "trace_model.hpp"
#include "api_error.hpp"
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <set>
namespace vj {
using Json=nlohmann::json;
namespace {
void require(bool ok,const std::string& message){if(!ok)throw ApiError(400,message);}
double number(const Json& value,double fallback,double low,double high){double n=fallback;if(value.is_number())n=value.get<double>();else if(value.is_string()){try{size_t used=0;n=std::stod(value.get<std::string>(),&used);if(used!=value.get<std::string>().size())n=fallback;}catch(...){}}return std::clamp(std::isfinite(n)?n:fallback,low,high);}
std::string unique(){static std::atomic<unsigned long> sequence;return "trace-"+std::to_string(std::chrono::system_clock::now().time_since_epoch().count())+"-"+std::to_string(++sequence);}
Json defaults(){return {{"points",{{.35,.25},{.35,.75}}},{"width",.015},{"feather",.5},{"glow",.35},{"pixels",60},{"blend","add"},{"enabled",true}};}
void normalize(Json& trace,size_t index){
    require(trace.is_object(),"Trace must be an object");auto id=trace.value("id",Json());if(!id.is_string()||id.get<std::string>().empty())id="trace-"+std::to_string(index+1);trace["id"]=id.get<std::string>().substr(0,100);
    auto name=trace.value("name",Json());if(!name.is_string()||name.get<std::string>().empty())name=trace["id"];trace["name"]=name.get<std::string>().substr(0,200);
    auto points=trace.value("points",Json());require(points.is_array()&&points.size()>=2&&points.size()<=256,"A trace needs 2 to 256 points");
    for(auto& p:points){if(!p.is_array()||p.size()!=2)p=Json::array({.5,.5});else for(auto& v:p)v=number(v,.5,0,1);}trace["points"]=points;
    trace["width"]=number(trace.value("width",Json()),.015,.001,.2);trace["feather"]=number(trace.value("feather",Json()),.5,0,1);trace["glow"]=number(trace.value("glow",Json()),.35,0,1);trace["pixels"]=int(number(trace.value("pixels",Json()),60,2,2000));
    const auto blend=trace.value("blend",Json());trace["blend"]=(blend=="normal"||blend=="add"||blend=="screen")?blend:Json("add");trace["enabled"]=trace.value("enabled",Json())!=Json(false);
}
}
void normalizeMappingTraces(Json& project){
    auto traces=project.value("traces",Json::array());require(traces.is_array()&&traces.size()<=128,"Mapping supports up to 128 traces");std::set<std::string> ids;size_t i=0;for(auto& trace:traces){normalize(trace,i++);require(ids.insert(trace["id"]).second,"Duplicate trace ID");}project["traces"]=traces;
    auto selected=project.value("selectedTraceId",Json());if(!selected.is_string()||!ids.contains(selected.get<std::string>()))project["selectedTraceId"]=nullptr;
}
Json requestMappingTrace(Json& project,const std::string& method,const std::string& id,const Json& body){
    Json next=project;normalizeMappingTraces(next);auto& traces=next["traces"];auto found=std::find_if(traces.begin(),traces.end(),[&](const Json& t){return t["id"]==id;});
    if(method=="GET"){if(id.empty())return {{"traces",traces}};if(found==traces.end())throw ApiError(404,"Trace not found");return *found;}
    require(body.is_object(),"Trace body must be an object");Json result;std::string resultId=id;
    if(method=="POST"&&id.empty()){
        require(traces.size()<128,"Mapping supports up to 128 traces");Json trace=defaults();trace.update(body);trace.erase("revision");trace["id"]=unique();if(!trace.contains("name"))trace["name"]="Trace "+std::to_string(traces.size()+1);if(!body.contains("points"))for(auto& p:trace["points"])p[0]=std::min(.95,p[0].get<double>()+(traces.size()%5)*.08);normalize(trace,traces.size());resultId=trace["id"];traces.push_back(trace);next["selectedTraceId"]=resultId;next["selectedRectId"]=nullptr;
    }else{
        if(found==traces.end())throw ApiError(404,"Trace not found");
        if(method=="DELETE"){traces.erase(found);if(next.value("selectedTraceId",Json())==id)next["selectedTraceId"]=nullptr;}
        else if(method=="PATCH"){
            auto patch=body;patch.erase("revision");patch.erase("id");
            // Accept complete point lists as the canonical API. Convenience point
            // operations use an index and are applied atomically with style edits.
            Json edited=*found;auto remove=patch.value("removePoint",Json());auto add=patch.value("addPoint",Json());patch.erase("removePoint");patch.erase("addPoint");edited.update(patch);
            if(!remove.is_null()){require(remove.is_number_integer(),"removePoint must be an index");int n=remove;require(n>=0&&n<int(edited["points"].size())&&edited["points"].size()>2,"A trace needs at least two points");edited["points"].erase(edited["points"].begin()+n);}
            if(!add.is_null()){require(add.is_array()&&add.size()==2,"addPoint must be an XY pair");edited["points"].push_back(add);}
            normalize(edited,size_t(found-traces.begin()));*found=edited;
        }else throw ApiError(405,"Unsupported trace operation");
    }
    normalizeMappingTraces(next);project=std::move(next);return {{"traceId",resultId}};
}
std::string mappingTraceFixtureId(const std::string& mid,const std::string& id){return (mid=="1"?"map-":"map"+mid+"-")+id;}
Json mappingTraceTopology(const Json& document){
    Json topology=Json::array();if(!document.contains("mappings"))return topology;
    for(auto m=document["mappings"].begin();m!=document["mappings"].end();++m)for(const auto& t:m.value().value("project",Json::object()).value("traces",Json::array())){std::string id=t["id"],name=t.value("name",id);topology.push_back({{"id",mappingTraceFixtureId(m.key(),id)},{"mappingId",m.key()},{"traceId",id},{"label",m.key()=="1"?name:"Mapping "+m.key()+" · "+name},{"count",t.value("pixels",60)},{"path",t["points"]}});}return topology;
}
void reconcileMappingTraceFixtures(Json& document){
    if(!document.contains("controls"))document["controls"]=Json::object();auto& controls=document["controls"];auto existing=controls.value("fixtures",Json::array());auto archive=controls.value("traceFixtureArchive",Json::object());if(!archive.is_object())archive=Json::object();for(const auto& f:existing)if(f.value("kind",std::string{})=="virtual"&&f.contains("id"))archive[f["id"].get<std::string>()]=f;Json fixtures=Json::array();for(const auto& f:existing)if(f.value("kind",std::string{})!="virtual")fixtures.push_back(f);
    for(const auto& target:mappingTraceTopology(document)){
        Json f={{"id",target["id"]},{"kind","virtual"},{"start",0},{"enabled",true},{"brightness",1.},{"power_limit",1.},{"route",{{"out","none"},{"start",0.},{"end",1.},{"offset",0.},{"reverse",false}}}};
        if(archive.contains(target["id"].get<std::string>()))f.update(archive[target["id"].get<std::string>()]);
        for(const auto* key:{"id","label","count","path"})f[key]=target[key];fixtures.push_back(f);
    }controls["fixtures"]=fixtures;controls["traceFixtureArchive"]=archive;
}
}
