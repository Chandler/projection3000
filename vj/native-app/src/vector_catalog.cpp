#include "vector_catalog.hpp"
#include "vector_catalog_data.hpp"
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <mutex>
#include <stdexcept>
#include <unistd.h>
#ifdef __APPLE__
#include <mach-o/dyld.h>
#endif
namespace vj {
namespace {
using Json=nlohmann::json;
std::mutex outlineMutex;VectorTextOutliner outliner;
void color(std::vector<float>& values,const Json& p,const char* name){const auto s=p.at(name).get<std::string>();for(int i:{1,3,5})values.push_back(std::stoi(s.substr(i,2),nullptr,16)/255.f);}
}
void installVectorTextOutliner(VectorTextOutliner value){std::lock_guard lock(outlineMutex);outliner=std::move(value);}
bool vectorTextOutlinerAvailable(){std::lock_guard lock(outlineMutex);return static_cast<bool>(outliner);}
Json vectorEffectCatalog(){return Json::parse(vector_catalog_json);}
Json normalizeVectorParams(const std::string& effect,const Json& params){
    if(!params.is_object())throw std::invalid_argument("Vector params must be an object");
    Json result=Json::object(),spec;for(const auto& item:vectorEffectCatalog())if(item["name"]==effect)spec=item;
    if(spec.is_null())throw std::invalid_argument("Unknown built-in vector effect");
    for(const auto& parameter:spec["parameters"])result[parameter["name"].get<std::string>()]=parameter["default"];
    for(auto it=params.begin();it!=params.end();++it){if(!result.contains(it.key()))throw std::invalid_argument("Unknown vector parameter: "+it.key());result[it.key()]=it.value();}
    if(effect=="electric_strips"){if(result["origin"]=="top")result["origin"]="start";else if(result["origin"]=="bottom")result["origin"]="end";}
    if(effect=="lorenz_attractor"&&result["rotation"].is_number()&&result["rotation"].get<double>()<0){result["rotation"]=-result["rotation"].get<double>();result["rotation_direction"]="reverse";}
    for(const auto& parameter:spec["parameters"]){const std::string name=parameter["name"],kind=parameter["kind"];const auto& value=result[name];bool valid=false;
        if(kind=="text")valid=value.is_string()&&value.get_ref<const std::string&>().size()<=16384;
        else if(kind=="bool")valid=value.is_boolean();
        else if(kind=="float")valid=value.is_number()&&std::isfinite(value.get<double>())&&value.get<double>()>=parameter["min"].get<double>()&&value.get<double>()<=parameter["max"].get<double>();
        else if(kind=="choice")valid=std::find(parameter["choices"].begin(),parameter["choices"].end(),value)!=parameter["choices"].end();
        else if(kind=="color"&&value.is_string()){const auto s=value.get<std::string>();valid=s.size()==7&&s[0]=='#'&&s.find_first_not_of("0123456789abcdefABCDEF",1)==std::string::npos;}
        if(!valid)throw std::invalid_argument("Invalid vector parameter: "+name);
    }return result;
}
Json vectorRecipe(const std::string& effect,const Json& raw,int width,int height){
    if(width<1||height<1)throw std::invalid_argument("Vector canvas dimensions must be positive");
    const auto p=normalizeVectorParams(effect,raw);std::vector<float> values;std::string module,cap="round";int abi=1;
    auto add=[&](std::initializer_list<const char*> keys){for(const auto* key:keys)values.push_back(p.at(key).get<float>());};
    auto scaled=[&](const char* key){values.push_back(p.at(key).get<float>()/height);};
    constexpr float radians=3.14159265358979323846f/180;
    if(effect=="vector_cube"){
        module="vector-cube";add({"speed","rotate_x","rotate_y","rotate_z"});values.push_back(p["projection"]=="perspective"?1:0);add({"size"});color(values,p,"glow");scaled("line_width");scaled("glow_width");values.push_back(float(height)/width);for(const auto* key:{"pose_x","pose_y","pose_z"})values.push_back(p.at(key).get<float>()*radians);
    }else if(effect=="laser_text"){
        module="laser-text";color(values,p,"color");scaled("line_width");scaled("glow_width");add({"brightness","size","x","y","pulse","speed"});values.push_back(float(height)/width);
        VectorTextOutliner callback;{std::lock_guard lock(outlineMutex);callback=outliner;}if(!callback)throw std::runtime_error("Native laser text outlines are unavailable on this build");auto geometry=callback(p.at("content"),p.at("font"));if(geometry.size()%3||geometry.size()>30000)throw std::runtime_error("Invalid laser text outline stream");values.push_back(geometry.size()/3);values.insert(values.end(),geometry.begin(),geometry.end());
    }else if(effect=="electric_strips"){
        module="electric-strips";cap="butt";add({"rate","burst","speed","jitter","length","tail","crackle","forks","top_spray","brightness"});color(values,p,"core");color(values,p,"glow");add({"rainbow"});values.push_back(p["origin"]=="end"?1:0);
    }else if(effect=="vector_scan_lines"){
        module="vector-scan-lines";cap="butt";values.push_back(p.at("angle").get<float>()*radians);for(const auto* key:{"rate","spacing","width","blur"})scaled(key);add({"amount"});scaled("wave");add({"wave_frequency","pulse"});color(values,p,"tint");color(values,p,"glow");values.push_back(float(height)/width);
    }else if(effect=="lorenz_attractor"){
        module="lorenz-attractor";abi=2;add({"speed","length","zoom"});values.push_back(p.at("rotation").get<float>()*(p["rotation_direction"]=="reverse"?-1:1));values.push_back(p.at("tilt").get<float>()*radians);scaled("line_width");add({"brightness"});color(values,p,"color");add({"seed"});values.push_back(float(height)/width);
    }else if(effect=="slime_mold"){
        module="slime-mold";abi=2;add({"seed","density","branching","x","y"});scaled("line_width");add({"pulse","speed","pulse_length"});color(values,p,"color");values.push_back(float(height)/width);
    }
    return {{"format",abi==1?"vibe-vector/1":"vibe-graphics/2"},{"abi",abi},{"module","/vector/modules/"+module+".wasm"},{"effect",effect},{"lineCap",cap},{"canvas",{width,height}},{"paramValues",values}};
}
std::filesystem::path defaultVectorModuleRoot(){
    namespace fs=std::filesystem;if(const auto configured=std::getenv("VJ_VECTOR_MODULE_ROOT"))return configured;
    fs::path executable;
#ifdef __APPLE__
    uint32_t length=0;_NSGetExecutablePath(nullptr,&length);std::vector<char> buffer(length);if(_NSGetExecutablePath(buffer.data(),&length)==0)executable=buffer.data();
#else
    char buffer[4096];auto length=readlink("/proc/self/exe",buffer,sizeof(buffer));if(length>0&&length<static_cast<ssize_t>(sizeof(buffer)))executable=std::string(buffer,length);
#endif
    if(!executable.empty())for(const auto& candidate:{executable.parent_path()/"../Resources/vector/modules",executable.parent_path()/"../share/vj-native/vector/modules"}){std::error_code error;if(fs::is_directory(candidate,error))return fs::weakly_canonical(candidate);}
#ifdef VJ_VECTOR_MODULE_ROOT
    return VJ_VECTOR_MODULE_ROOT;
#else
    return {};
#endif
}
}
