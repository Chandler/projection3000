#include "ui_commands.hpp"
#include "api_error.hpp"
#include <set>
namespace vj {
UiRequest translateUiCommand(const nlohmann::json& message){
    using J=nlohmann::json;
    if(!message.is_object()||!message.contains("type")||!message["type"].is_string())throw ApiError(400,"Expected an object with a command type");
    const auto type=message["type"].get<std::string>();J body=message;body.erase("type");
    if(type=="send"||type=="grab"||message.value("bus",J())=="preview")throw ApiError(400,"Preview routing was removed; use Out A/B selections and set_crossfade");
    if(type=="grid")return {"POST","/api/v1/grid",body};
    if(type=="set_outs"){if(!body.contains("count"))body["count"]=1;return {"PUT","/api/v1/outputs",body};}
    if(type=="flash")return {"POST","/api/v1/flash",body};
    if(type=="set_stream_hd")return {"PATCH","/api/v1/stream",{{"hd",body.value("enabled",J(false))}}};
    if(type=="set_mix")return {"POST","/api/v1/mix",body};
    if(type=="set_bpm"||type=="tap"||type=="midi_clock_sync"||type=="link_sync"){
        body["action"]=type;if(type=="set_bpm"&&!body.contains("bpm"))body["bpm"]=120;
        return {"POST","/api/v1/clock",body};
    }
    if(type=="midi_select"||type=="midi_learn"||type=="midi_unmap"){body["action"]=type;return {"POST","/api/v1/midi",body};}
    if(type=="set_linked"){body["linked"]=body.value("enabled",J(false));body.erase("enabled");return {"PUT","/api/v1/leds",body};}
    if(type=="set_fixture"){
        if(!body.contains("id")||!body["id"].is_string())throw ApiError(400,"Fixture ID required");
        auto id=body["id"].get<std::string>();if(id.empty()||id.find_first_of("/?#")!=std::string::npos)throw ApiError(400,"Invalid fixture ID");
        body.erase("id");return {"PATCH","/api/v1/leds/"+id,body};
    }
    if(type=="set_ndi_projectors")return {"PUT","/api/v1/ndi/projectors",body.at("projectors")};
    // Original layer IDs identify live layer instances, not clip IDs. Only the
    // output-control API can resolve them; never reinterpret them as grid IDs.
    if(std::set<std::string>{"add_layer","replace_layer","remove_layer","move_layer","set_param","set_layer","clear_bus"}.contains(type)){
        auto bus=body.value("bus",std::string("program"));if(bus=="program")bus="out1";
        if(bus.empty()||bus.find_first_of("/?#")!=std::string::npos)throw ApiError(400,"Invalid output");body.erase("bus");
        if(type=="add_layer"||type=="replace_layer"){body["action"]=type;body["effect"]=body.at("gen");body.erase("gen");}
        else if(type=="set_param"){body["action"]="params";body["layerId"]=body.at("id");body["params"]={{body.at("param").get<std::string>(),body.at("value")}};body.erase("id");body.erase("param");body.erase("value");}
        else if(type=="clear_bus")body["action"]="clear";
        else{body["action"]=type;body["layerId"]=body.at("id");body.erase("id");}
        return {"POST","/api/v1/outputs/"+bus,body};
    }
    if(std::set<std::string>{"save_preset","load_preset","delete_preset","save_scene","update_scene","load_scene","revert_scene","delete_scene","save_clip","load_clip","delete_clip"}.contains(type)||type.find("show")!=std::string::npos)throw ApiError(400,"Removed command; use /api/v1/grid");
    throw ApiError(501,"UI command not yet implemented: "+type);
}
}
