#include "composition_api.hpp"
#include "api_error.hpp"
#include <algorithm>
#include <cmath>
#include <limits>
#include <set>
namespace vj {
namespace {
void require(bool yes,const std::string& message){if(!yes)throw ApiError(400,message);}
std::string busName(int i){return i==1?"program":"out"+std::to_string(i);}
const Json& emptyObject(){static const Json value=Json::object();return value;}
const Json& objectAt(const Json& j,const std::string& key){return j.is_object()&&j.contains(key)&&j[key].is_object()?j[key]:emptyObject();}
const Json* effectSpec(const Json& catalog,const std::string& effect){for(const auto& item:catalog)if(item.value("name",std::string{})==effect)return &item;return nullptr;}
std::string instanceKey(const Json& grid,const std::string& bus,const std::string& bank,const Json& row,const Json& clip){return Json::array({grid.value("active_show",std::string{}),bus,bank,row.at("id"),clip.at("id")}).dump();}
struct Choice {const Json* row;const Json* clip;std::string column,key;};
std::vector<Choice> choices(const Json& document,const std::string& bus,const std::string& bank){
    std::vector<Choice> result;const auto& g=document.at("grid");const auto& selection=objectAt(objectAt(g,bank=="A"?"selections":"selections_b"),bus);
    for(const auto& row:g.at("rows")){const auto rid=row.at("id").get<std::string>();if(!selection.contains(rid)||!selection[rid].is_string())continue;const auto column=selection[rid].get<std::string>();const auto& clips=objectAt(row,"clips");if(!clips.contains(column)||!clips[column].is_object())continue;const auto& clip=clips[column];result.push_back({&row,&clip,column,instanceKey(g,bus,bank,row,clip)});}return result;
}
void startClock(Json& document,const std::string& bus,double now,double beat){document["compositionApi"]["clocks"][bus]={{"playing",true},{"seconds",0.0},{"beats",0.0},{"startedAt",now},{"startedBeat",beat}};}
Json layers(const Json& d,const Json& catalog,const std::string& bus,const std::string& bank){
    Json result=Json::array();const auto& ids=objectAt(objectAt(d,"compositionApi"),"identities");
    for(const auto& c:choices(d,bus,bank)){
        if(!ids.contains(c.key))throw ApiError(500,"Composition identities require reconciliation");
        const auto& row=*c.row;const auto& clip=*c.clip;const auto gen=clip.value("gen",std::string{});const auto* spec=effectSpec(catalog,gen);
        auto sourceIdentity=ids.at(c.key);if(bank=="B"){const auto& a=objectAt(objectAt(d.at("grid"),"selections"),bus);auto rid=row.at("id").get<std::string>();if(a.contains(rid)&&a[rid]==c.column){auto shared=instanceKey(d.at("grid"),bus,"A",row,clip);if(ids.contains(shared))sourceIdentity=ids.at(shared);}}
        Json layer={{"id",ids[c.key]},{"source_id","native-layer-"+sourceIdentity.dump()},{"gen",gen},{"label",spec?spec->value("label",gen):gen},{"params",clip.value("params",Json::object())},{"opacity",1.0},{"clip_opacity",clip.value("opacity",1.0)},{"blend",clip.value("blend",row.value("blend",std::string("normal")))},{"enabled",row.value("enabled",true)},{"grid_row",row.at("id")},{"grid_column",c.column}};
        layer["collection_layout"]=spec&&spec->value("adjustment",false)?clip.value("collectionLayout",std::string("inherit")):clip.value("collectionLayout",std::string("repeat"));
        if(spec&&spec->contains("collectionGeometry")&&!(*spec)["collectionGeometry"].is_null())layer["collection_effect"]=(*spec)["collectionGeometry"];
        if(clip.contains("nativeImportUnsupported"))layer["nativeImportUnsupported"]=clip["nativeImportUnsupported"];
        result.push_back(std::move(layer));
    }return result;
}
}
void reconcileCompositionApi(Json& document,double now,double globalBeat,bool resetClocks,const Json& command){
    auto& api=document["compositionApi"];if(!api.is_object())api=Json::object();if(!api.contains("nextLayerId"))api["nextLayerId"]=1;
    auto& identities=api["identities"];if(!identities.is_object())identities=Json::object();auto& clocks=api["clocks"];if(!clocks.is_object())clocks=Json::object();
    const auto action=command.value("action",std::string{});auto commandBus=command.value("bus",std::string("out1"));if(commandBus=="out1")commandBus="program";
    Json live=Json::object();auto next=api["nextLayerId"].get<int64_t>();require(next>0,"Invalid composition layer counter");
    for(const auto& value:identities)if(value.is_number_integer())next=std::max(next,value.get<int64_t>()+1);
    for(int i=1;i<=20;++i){const auto bus=busName(i);if(resetClocks||!clocks.contains(bus))startClock(document,bus,now,globalBeat);
        for(const auto* bank:{"A","B"})for(const auto& c:choices(document,bus,bank)){
            const bool relaunch=std::string(bank)=="A"&&command.value("bank",std::string("A"))=="A"&&bus==commandBus&&
              ((action=="launch_column")||((action=="launch_clip"||action=="toggle_clip")&&command.value("row",std::string{})==c.row->at("id").get<std::string>()));
            if(!relaunch&&identities.contains(c.key))live[c.key]=identities[c.key];else{require(next<=std::numeric_limits<int>::max(),"Composition layer ID limit reached");live[c.key]=next++;}
        }
    }identities=std::move(live);api["nextLayerId"]=next;
}
Json compositionClock(const Json& document,const std::string& bus,double now,double globalBeat,double bpm){
    const auto& clock=objectAt(objectAt(objectAt(document,"compositionApi"),"clocks"),bus);const bool playing=clock.value("playing",true);
    const double seconds=clock.value("seconds",0.0)+(playing?now-clock.value("startedAt",now):0.0);
    const double beats=clock.value("beats",0.0)+(playing?globalBeat-clock.value("startedBeat",globalBeat):0.0);
    return {{"seconds",std::max(0.0,seconds)},{"beat",std::max(0.0,beats)},{"bpm",bpm},{"playing",playing},{"serverMonotonicNs",static_cast<int64_t>(now*1e9)}};
}
Json compositionOutputs(const Json& document,const Json& catalog,const Json& routing,double now,double globalBeat,double bpm){
    const auto& g=document.at("grid");Json outputs=Json::object();const int count=document.value("outputCount",1);
    for(int i=1;i<=20;++i){const auto bus=busName(i);const auto a=layers(document,catalog,bus,"A"),b=layers(document,catalog,bus,"B");const auto sa=objectAt(objectAt(g,"selections"),bus),sb=objectAt(objectAt(g,"selections_b"),bus);
        outputs["out"+std::to_string(i)]={{"active",i<=count},{"running",i<=count&&objectAt(g,"running").value(bus,false)},{"internalBus",bus},{"projectors",objectAt(routing,"output_projectors").value(bus,Json::array())},{"destinations",objectAt(routing,"output_destinations").value(bus,Json::array())},{"selections",sa},{"crossfade",objectAt(g,"crossfade").value(bus,0.0)},{"banks",{{"A",{{"selections",sa},{"layers",a},{"frames","/ws/outputs/out"+std::to_string(i)+"/banks/A"}}},{"B",{{"selections",sb},{"layers",b},{"frames","/ws/outputs/out"+std::to_string(i)+"/banks/B"}}}}},{"layers",a},{"clock",compositionClock(document,bus,now,globalBeat,bpm)},{"vector",nullptr},{"vectorRasterized",false}};
        int enabled=0;bool vector=false;for(const auto& layer:a)if(layer.value("enabled",true)){++enabled;const auto* spec=effectSpec(catalog,layer.value("gen",std::string{}));vector=vector||(spec&&spec->value("vector",false));}
        outputs["out"+std::to_string(i)]["vectorRasterized"]=i<=count&&objectAt(g,"running").value(bus,false)&&enabled>1&&vector;
    }return outputs;
}
Json applyCompositionCommand(Json& document,const std::string& out,const Json& body,const Json& catalog,const CompositionGridExecutor& execute,double now,double globalBeat){
    require(body.is_object(),"Expected a JSON object");int index=0;for(int i=1;i<=20;++i)if(out=="out"+std::to_string(i))index=i;require(index!=0,"Unknown output");require(index<=document.value("outputCount",1),"Output inactive; PUT /api/v1/outputs with {\"count\":N} first");
    if(body.contains("revision")&&body["revision"]!=document.at("revision"))throw ApiError(409,"State changed; fetch current state");
    require(body.contains("action")&&body["action"].is_string(),"action must be text");const auto action=body["action"].get<std::string>(),bus=busName(index);reconcileCompositionApi(document,now,globalBeat);
    Json commands=Json::array();auto run=[&](Json command){command["bus"]=bus;command["bank"]="A";Json value=execute(document,command);commands.push_back(command);reconcileCompositionApi(document,now,globalBeat,false,command);return value;};
    auto clear=[&](){auto selected=objectAt(objectAt(document.at("grid"),"selections"),bus);for(auto it=selected.begin();it!=selected.end();++it)run({{"action","stop_row"},{"row",it.key()}});};
    if(action=="load"||action=="add_layer"||action=="replace_layer"){
        std::string effect=body.value("effect",std::string{});if(effect.empty()){const auto animation=body.value("animationId",Json(""));effect="external_"+(animation.is_string()?animation.get<std::string>():animation.dump());}
        const auto* spec=effectSpec(catalog,effect);require(spec,"Unknown effect/animationId");const bool adjustment=spec->value("adjustment",false);require(action!="load"||!adjustment,"Adjustment filters modify layers below them; use action=\"add_layer\"");
        const auto params=body.value("params",Json::object());require(params.is_object(),"params must be an object");const auto selected=choices(document,bus,"A");
        if(action=="replace_layer"&&!adjustment&&!selected.empty()){
            // Keep the shared cell identity and metadata while replacing its
            // generator/defaults. The executor validates media and parameters.
            const auto old=*selected.back().clip;const auto rid=selected.back().row->at("id");const auto column=selected.back().column;
            auto created=run({{"action","put_clip"},{"row",rid},{"column",column},{"effect",effect},{"params",params}});
            for(auto& row:document["grid"]["rows"])if(row["id"]==rid){auto replacement=old;replacement["gen"]=created["gen"];replacement["params"]=created["params"];replacement.erase("nativeImportUnsupported");row["clips"][column]=std::move(replacement);break;}
            if(spec->value("defaultBlend",std::string("normal"))!="normal")run({{"action","set_row"},{"row",rid},{"blend",(*spec)["defaultBlend"]}});
            run({{"action","launch_clip"},{"row",rid},{"column",column}});
        }else{
            if(action=="load")clear();const auto& columns=document.at("grid").at("columns");require(!columns.empty(),"Grid requires a column");const auto column=columns.front().at("id");
            const auto row=run({{"action","add_row"},{"name",spec->value("label",effect)}});const auto rid=row.at("id");
            run({{"action","put_clip"},{"row",rid},{"column",column},{"effect",effect},{"params",params}});
            run({{"action","set_row"},{"row",rid},{"blend",spec->value("defaultBlend",std::string("normal"))}});
            run({{"action","launch_clip"},{"row",rid},{"column",column}});
        }if(action=="load")startClock(document,bus,now,globalBeat);
    }else if(action=="params"||action=="set_layer"||action=="remove_layer"||action=="move_layer"){
        const auto selected=choices(document,bus,"A");const Choice* found=nullptr;const auto layerId=body.value("layerId",Json());const auto& ids=document["compositionApi"]["identities"];
        if(action=="params"&&(layerId.is_null()||layerId==0||layerId==false)){if(!selected.empty())found=&selected.back();}else for(const auto& c:selected)if(layerId.is_number_integer()&&ids.at(c.key)==layerId){found=&c;break;}
        require(found,action=="params"?"No matching layer":"layerId must identify an existing layer");const auto rid=found->row->at("id");const auto column=found->column;
        if(action=="params")run({{"action","set_clip"},{"row",rid},{"column",column},{"params",body.value("params",Json::object())}});
        else if(action=="remove_layer")run({{"action","stop_row"},{"row",rid}});
        else if(action=="move_layer"){const auto dir=body.value("dir",Json());require(dir.is_number_integer()&&(dir==-1||dir==1),"dir must be -1 or 1");run({{"action","move_row"},{"row",rid},{"dir",dir}});}
        else{Json row={{"action","set_row"},{"row",rid}};for(const auto* key:{"enabled","blend"})if(body.contains(key))row[key]=body[key];if(row.size()>2)run(row);if(body.contains("opacity"))run({{"action","set_clip"},{"row",rid},{"column",column},{"opacity",body["opacity"]}});}
    }else if(action=="start"||action=="stop"||action=="toggle")run({{"action",action+"_out"}});
    else if(action=="mute"){require(body.contains("muted")&&body["muted"].is_boolean(),"muted must be boolean");run({{"action",body["muted"].get<bool>()?"stop_out":"start_out"}});}
    else if(action=="clear"){clear();startClock(document,bus,now,globalBeat);}
    else if(action=="play"||action=="pause"||action=="restart"){
        if(action=="restart")startClock(document,bus,now,globalBeat);else{const auto position=compositionClock(document,bus,now,globalBeat,120);document["compositionApi"]["clocks"][bus]={{"playing",action=="play"},{"seconds",position["seconds"]},{"beats",position["beat"]},{"startedAt",now},{"startedBeat",globalBeat}};}
    }else throw ApiError(400,"Unknown action");
    reconcileCompositionApi(document,now,globalBeat);return {{"commands",commands}};
}
}
