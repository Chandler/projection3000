#include "api_compat.hpp"
#include <algorithm>
#include <cmath>
#include <fstream>
#include <sys/utsname.h>
#include <unistd.h>
#ifdef __APPLE__
#include <mach-o/dyld.h>
#endif
namespace vj { namespace {
Json blends(){return {"normal","add","multiply","screen","subtract"};}
Json actions(){return {"undo","redo","select_out","select_cell","add_column","rename_column","delete_column","launch_column","move_column","add_row","set_row","move_row","stop_row","delete_row","put_clip","set_clip","copy_clip","delete_clip","delete_cell","launch_clip","toggle_clip","start_out","stop_out","toggle_out","set_crossfade","set_fader_sync","set_controller_lights","create_show","duplicate_show","rename_show","select_show","delete_show"};}
Json device(){char host[256]={};struct utsname os{};gethostname(host,sizeof(host)-1);uname(&os);return {{"hostname",host},{"platform",os.sysname},{"architecture",os.machine}};}
std::string markdown(std::string input){std::string result;for(char c:input){if(c=='|'||c=='['||c==']'||c=='\\')result+='\\';result+=c=='\n'||c=='\r'?' ':c;}return result;}
}
void decorateExternalSnapshot(Json& snapshot,double uptimeSeconds,bool wasmAvailable){
    static const auto identity=device();snapshot["device"]=identity;snapshot["device"]["uptimeSeconds"]=std::isfinite(uptimeSeconds)?std::max(0.,uptimeSeconds):0.;
    snapshot["capabilities"]={{"vectorAbis",wasmAvailable?Json::array({1,2}):Json::array()},{"maxModuleBytes",2*1024*1024},{"maxParameters",64},{"maxOutputs",20},{"maxProjectors",4},{"clipGrid",true},{"clipGridVersion",2},{"sharedClipGrid",true},{"outputBanks",{"A","B"}},{"outputCrossfade",true},{"vectorCompositing",wasmAvailable},{"gridActions",actions()},{"maxGridRows",64},{"maxGridColumns",64},{"namedShows",true},{"liveFrameInput",false},{"shaderUpload",false},{"native",{{"fullParity",false},{"moduleValidationAvailable",wasmAvailable}}}};
    auto& state=snapshot["state"];state["type"]="state";state["outputs"]=Json::array();state["buses"]=Json::object();state["vector_recipes"]=Json::object();state["outs"]=0;state["projector_ids"]=Json::array();state["blend_modes"]=blends();state["clients"]=Json::object();
    const auto counts=state.value("frameTransport",Json::object()).value("clientsByBus",Json::object());
    for(int i=1;i<=20;++i){const auto bus=i==1?"program":"out"+std::to_string(i),out="out"+std::to_string(i);state["outputs"].push_back(bus);state["clients"][bus]=counts.value(bus,0);
        const auto info=snapshot.value("outputs",Json::object()).value(out,Json::object());state["vector_recipes"][bus]=info.value("vector",Json());
        if(info.value("active",false)){state["outs"]=state["outs"].get<int>()+1;state["buses"][bus]=info.value("layers",Json::array());}
    }
    for(auto it=snapshot["mappings"].begin();it!=snapshot["mappings"].end();++it)state["projector_ids"].push_back(it.key());
    snapshot["projectors"]=state.value("projectors",Json{{"displays",Json::array()},{"vectors",Json::object()},{"error","Native renderer is not connected."}});
    const auto patterns=snapshot.value("calibration",Json::object()).value("outputs",Json::object());
    for(auto& display:snapshot["projectors"]["displays"]){auto id=display.at("id");display["pattern"]=patterns.value(id.is_string()?id.get<std::string>():id.dump(),Json());}
    snapshot["links"]={{"stats","/api/v1/stats"},{"network","/api/v1/network"},{"ndiClients","/api/v1/ndi/clients"},{"mediaDrives","/api/v1/media/drives"},{"docs","/api/v1/docs"},{"preprocess","/api/v1/media/preprocess"},{"events","/api/v1/events"},{"effects","/api/v1/effects"},{"grid","/api/v1/grid"},{"bankFrames","/ws/outputs/{bus}/banks/{bank}"},{"leds","/api/v1/leds"},{"sdk","/api/v1/sdk/abi.ts"},{"capabilities","/api/v1/capabilities"}};
}
Json externalEffectsResponse(Json catalog,bool wasmAvailable){for(auto& effect:catalog){effect.erase("title");effect.erase("params");}return {{"effects",catalog},{"blendModes",blends()},{"stackOrder","bottom-to-top"},{"vectorLayersExclusive",false},{"vectorRasterizedWhenStacked",wasmAvailable}};}
std::filesystem::path defaultApiAssetRoot(){
    std::vector<std::filesystem::path> candidates;char executable[8192]={};
#ifdef __APPLE__
    uint32_t size=sizeof(executable);if(_NSGetExecutablePath(executable,&size)==0){const auto bin=std::filesystem::path(executable).parent_path();candidates.push_back(bin/"../Resources");candidates.push_back(bin/"resources/vj");}
#else
    const auto count=readlink("/proc/self/exe",executable,sizeof(executable)-1);if(count>0){executable[count]=0;const auto bin=std::filesystem::path(executable).parent_path();candidates.push_back(bin/"resources/vj");candidates.push_back(bin/"../share/vj");}
#endif
#ifdef VJ_API_ASSET_ROOT
    candidates.emplace_back(VJ_API_ASSET_ROOT);
#endif
    for(const auto& path:candidates){std::error_code error;if(std::filesystem::is_regular_file(path/"docs/external-api.md",error)&&std::filesystem::is_regular_file(path/"vector-effects/sdk/abi.ts",error))return path;}
    return {};
}
std::optional<Reply> apiCompatibilityReply(const std::string& method,const std::string& path,const Json& snapshot,const Json& catalog,const std::filesystem::path& assetRoot){
    const bool recognized=path=="/api/v1"||path=="/api/v1/"||path=="/api/v1/capabilities"||path=="/api/v1/docs"||path.starts_with("/api/v1/sdk/");
    if(!recognized)return {};if(method!="GET"&&method!="HEAD")return Reply{405,{{"error","Method not allowed"}}};
    if(path=="/api/v1"||path=="/api/v1/")return Reply{200,{{"apiVersion",1},{"links",snapshot.value("links",Json::object())},{"capabilities",snapshot.value("capabilities",Json::object())},{"device",snapshot.value("device",Json::object())}}};
    if(path=="/api/v1/capabilities")return Reply{200,snapshot.value("capabilities",Json::object())};
    std::filesystem::path relative;std::string contentType;
    if(path=="/api/v1/docs"){relative="docs/external-api.md";contentType="text/markdown; charset=utf-8";}
    else {
        static const std::map<std::string,std::string> files={{"abi.ts","vector-effects/sdk/abi.ts"},{"graphics-v2.ts","vector-effects/sdk/graphics-v2.ts"},{"math.ts","vector-effects/sdk/math.ts"},{"example.ts","vector-effects/effects/external-example.ts"},{"runtime.js","static/vector/runtime.js"}};
        const auto name=path.substr(12);const auto found=files.find(name);if(found==files.end())return Reply{404,{{"error","Unknown SDK asset"}}};relative=found->second;contentType=name.ends_with(".js")?"text/javascript; charset=utf-8":"text/plain; charset=utf-8";
    }
    if(assetRoot.empty())return Reply{404,{{"error","API assets unavailable in this installation"}}};
    const auto file=assetRoot/relative;std::error_code ec;if(!std::filesystem::is_regular_file(file,ec)||std::filesystem::file_size(file,ec)>4u*1024*1024||ec)return Reply{404,{{"error","API asset unavailable in this installation"}}};
    std::ifstream input(file,std::ios::binary);if(!input)return Reply{404,{{"error","API asset unavailable in this installation"}}};std::string text((std::istreambuf_iterator<char>(input)),{});
    if(path=="/api/v1/docs"){
        text="Native migration build: consult /api/v1/capabilities and returned runtime status. This reference describes the original API; parity review remains incomplete.\n\n"+text;
        text+="\n\n## Live effect and filter catalog\n\n| Effect | Type |\n|---|---|\n";
        for(const auto& effect:catalog){const auto name=effect.at("name").get<std::string>();text+="| ["+markdown(effect.value("label",name))+"](/api/v1/effects/"+name+") (`"+name+"`) | "+markdown(effect.value("kind",std::string{}))+" |\n";}
    }
    return Reply{200,Json(),std::move(text),contentType};
}
}
