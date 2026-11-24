#include "library_placement.hpp"
#include <algorithm>

namespace vj {
Reply placeLibrarySubpatch(Model& model,const Json& body,const StageLibraryOutput& stage,const FinishLibraryOutput& finish){
    auto action=body.value("action",Json());
    bool independent=action=="make_independent";
    if(!independent&&((action!="put_clip"&&action!="set_clip")||!body.value("subpatchID",Json()).is_string()||!body.value("outputID",Json()).is_string()))return {400,{{"error","Specify an action, subpatchID and outputID"}}};
    if(!body.value("row",Json()).is_string()||!body.value("column",Json()).is_string())return {400,{{"error","Specify a row and column"}}};
    auto current=model.snapshot();const auto& grid=current.at("state").at("grid");const auto revision=current.at("revision");
    if(body.contains("revision")&&body.at("revision")!=revision)return {409,{{"error","Revision changed"}}};
    if(body.contains("active_show")&&body.at("active_show")!=grid.at("active_show"))return {409,{{"error","Active show changed"}}};
    auto row=std::find_if(grid["rows"].begin(),grid["rows"].end(),[&](const Json& value){return value["id"]==body["row"];});
    if(row==grid["rows"].end()||std::none_of(grid["columns"].begin(),grid["columns"].end(),[&](const Json& value){return value["id"]==body["column"];}))return {400,{{"error","Unknown clip slot"}}};
    const auto clip=row->at("clips").value(body["column"].get<std::string>(),Json::object());
    if(independent&&!clip.value("gen",std::string{}).starts_with("patch_"))return {400,{{"error","Select a Patch-backed clip"}}};
    auto input=independent?clip.at("params").value("source",std::string{}):std::string{};
    LibraryOutputRequest request{independent,{},{},input};
    if(!independent){request.templateID=body.at("subpatchID");request.outputID=body.at("outputID");}
    auto placed=stage(request);
    if(placed.status>=300)return placed;
    auto type=placed.body.at("type").get<std::string>(),source=placed.body.at("source").get<std::string>();
    vj::Reply reply(400,{{"error","Incompatible output or parameter"}});
    try {
        Json command={{"row",body["row"]},{"column",body["column"]},{"active_show",grid.at("active_show")},{"revision",revision},{"action",action}};
        if(body.contains("bus"))command["bus"]=body["bus"];
        if(independent&&clip["gen"]==("patch_"+type)){
            command["action"]="set_clip";command["params"]={{"source",source}};
            reply=model.request("POST","/api/v1/grid",command);
        }else if(!independent&&action=="put_clip"&&(type=="video"||type=="collection"||type=="trace"||type=="adjustment")){
            command["effect"]="patch_"+type;command["params"]={{"source",source}};
            command["name"]=body.value("name",placed.body.value("name",std::string("Patch")));
            reply=model.request("POST","/api/v1/grid",command);
        }else if(action=="set_clip"&&(type=="palette"||type=="control")&&body.at("parameter").is_string()){
            auto key=body["parameter"].get<std::string>();
            if(!clip.empty()){
                for(const auto& effect:model.effectCatalog())if(effect["name"]==clip["gen"])for(const auto& p:effect["parameters"])if(p["name"]==key){
                    if(type=="palette"&&p.value("paletteSource",false))command["params"]={{key,source}};
                    else if(type=="control"&&p["kind"]=="float"){
                        command["patchControls"]=clip.value("patchControls",Json::object());command["patchControls"][key]={{"source",source},{"min",p.at("min")},{"max",p.at("max")}};
                    }else continue;
                    reply=model.request("POST","/api/v1/grid",command);
                }
            }
        }
    }catch(const std::exception& e){reply={400,{{"error",e.what()}}};}
    auto id=placed.body.at("id").get<std::string>();
    auto finished=finish(id,reply.status<300);
    if(finished.status>=300){
        reply.body["retainedInstance"]=id;reply.body["cleanupError"]=finished.body.at("error");
    }else if(reply.status<300)reply.body["subpatch"]=std::move(placed.body);
    return reply;
}
}
