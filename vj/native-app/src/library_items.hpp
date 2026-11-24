#pragma once
#include <nlohmann/json.hpp>
namespace vj::library {
using Json=nlohmann::json;
inline bool live(const std::string& effect){return effect=="usb_webcam"||effect=="ndi"||effect=="syphon";}
inline Json favorite(const std::string& kind,const std::string& id,const std::string& name){
    return {{"kind",kind},{"id",id},{"name",name}};
}
inline Json sourceRow(const std::string& effect,const Json& source,const Json& inventory){
    auto selection=source.value("selection",source.value("device",std::string{}));
    auto name=source.value("label",source.value("name",std::string("Camera")));
    std::string locator;
    if(effect=="usb_webcam")locator=source.value("uniqueId",selection);
    else{
        auto parsed=Json::parse(selection,nullptr,false);
        if(parsed.is_object()){
            auto stream=parsed.value("name",std::string{});
            if(effect=="ndi")locator=stream;
            else{
                auto app=parsed.value("app",std::string{});
                Json key={{"app",app},{"name",stream}};
                size_t matches=0;
                for(const auto& entry:inventory){
                    auto other=Json::parse(entry.value("selection",std::string{}),nullptr,false);
                    if(other.is_object()&&other.value("app",std::string{})==app&&other.value("name",std::string{})==stream)++matches;
                }
                if((matches>1||(app.empty()&&stream.empty()))&&parsed.contains("uuid"))key["uuid"]=parsed["uuid"];
                locator=key.dump();
            }
        }
    }
    Json row={{"effect",effect},{"name",name},{"params",{{effect=="usb_webcam"?"device":"source",selection}}},{"available",true}};
    if(!locator.empty())row["favorite"]=favorite("source",effect+":"+locator,name);
    return row;
}
inline Json unavailable(const Json& pin){
    auto id=pin.value("id",std::string{}),name=pin.value("name",id);
    Json row={{"name",name},{"kind","unavailable"},{"available",false},{"favorite",pin}};
    if(pin.value("kind",std::string{})!="source")return row;
    auto colon=id.find(':');if(colon==std::string::npos)return row;
    auto effect=id.substr(0,colon),binding=id.substr(colon+1);
    if(effect=="ndi")binding=Json({{"name",binding}}).dump();
    else if(effect!="syphon")return row; // Camera selectors require live device resolution.
    row.update({{"effect",effect},{"params",{{"source",binding}}}});
    return row;
}
inline bool sameFavorite(const Json& a,const Json& b){return a.at("kind")==b.at("kind")&&a.at("id")==b.at("id");}
inline Json placement(const Json& item){
    if(item.contains("subpatchID"))return {{"subpatchID",item.at("subpatchID")},{"outputID",item.at("outputID")},{"name",item.at("name")}};
    return {{"effect",item.at("effect")},{"name",item.at("name")},{"params",item.at("params")}};
}
}
