#include "control_model.hpp"
#include "api_error.hpp"
#include <cassert>
#include <iostream>
using namespace vj;
int main(){
    Json d;resetControlRuntime(d);
    auto command=[&](const std::string& path,const Json& body,const std::string& method="POST"){
        auto next=d;auto result=requestControl(next,method,path,body);d=next;assert(result);return *result;
    };
    command("/api/v1/mix",{{"video_master",.4},{"sync",{{"video",75}}},{"revision",9}});
    auto state=controlSnapshot(d);assert(state["mix"]["video_master"]==.4);assert(state["mix"]["sync"]["clock"]==0);
    auto saved=d;try{command("/api/v1/mix",{{"video_master",.8},{"pulse",1}});assert(false);}catch(const ApiError& e){assert(e.status==400);}assert(d==saved);
    auto before=controlClock(d,controlNow())["beat"].get<double>();command("/api/v1/clock",{{"action","set_bpm"},{"bpm",90}});auto after=controlClock(d,controlNow())["beat"].get<double>();assert(after>=before&&after-before<.01);
    auto fixture=[](const char* id,const char* kind){return Json{{"id",id},{"kind",kind},{"extension",42},{"route",{{"out","none"},{"start",0.},{"end",1.},{"offset",0.},{"reverse",false}}}};};
    d["controls"]["fixtures"]=Json::array({fixture("a","wled"),fixture("b","wled"),fixture("trace","virtual")});resetControlRuntime(d);
    command("/api/v1/leds/a",{{"route",{{"out","out3"},{"start",.2}}},{"brightness",.6}},"PATCH");
    auto fixtures=controlSnapshot(d)["fixtures"];assert(fixtures[1]["route"]["out"]=="out3");assert(fixtures[1]["route"]["start"]==0);assert(fixtures[2]["route"]["out"]=="none");assert(fixtures[0]["extension"]==42);
    command("/api/v1/dmx",{{"controls",{{"dimmer",.5},{"pan",.25},{"tilt",.75}}},{"address",498},{"mode",15}});
    auto c=controlSnapshot(d)["dmx"];assert(c["channels"].size()==15&&c["channels"][0]==128);assert(c["channels"][2]==64&&c["channels"][3]==0);assert(c["connected"]==false);
    saved=d;try{command("/api/v1/dmx",{{"action","connect"}});assert(false);}catch(const ApiError& e){assert(e.status==501);}assert(d==saved);
    command("/api/v1/dmx",{{"apc",{{"color",5},{"strobe",0.},{"brightness",1.}}},{"controls",{{"motion","circle"}}}});c=controlSnapshot(d)["dmx"];assert(c["controls"]["blue"]==1&&c["controls"]["red"]==0);assert(c["controls"]["program"]=="off");
    auto u=dmxUniverse({{"blackout",true},{"dimmer",1.}},1,13);assert(u[0]==0&&u[1]==0&&u[6]==0);
    std::vector<std::array<float,3>> pixels={{{1,1,1}},{{1,1,1}}};applyLedMix(pixels,controlSnapshot(d)["mix"],0,0,1,.5);assert(std::abs(pixels[0][0]-.5)<.0001);
    std::cout<<"Control model checks passed\n";
}
