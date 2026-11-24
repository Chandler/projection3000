#include "text_source.hpp"
#include <boost/uuid/detail/sha1.hpp>
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <fcntl.h>
#include <fstream>
#include <iomanip>
#include <mutex>
#include <sstream>
#include <stdexcept>
#include <unistd.h>
#ifdef __APPLE__
#include <mach-o/dyld.h>
#endif
namespace vj {
namespace fs=std::filesystem;
using Json=nlohmann::json;
namespace {
const std::pair<const char*,const char*> typefaces[]={
    {"Archivo Black","ArchivoBlack"},{"Bebas Neue","BebasNeue"},{"Bungee","Bungee"},
    {"DM Serif Display","DMSerifDisplay"},{"Lobster","Lobster"},{"Pacifico","Pacifico"},
    {"Permanent Marker","PermanentMarker"},{"Special Elite","SpecialElite"},
    {"Monoton","Monoton"},{"Press Start 2P","PressStart2P"}};
std::mutex backendMutex;
TextRasterizer backend;
std::string backendVersion;
Json param(const char* name,const char* label,const char* kind,Json value){return {{"name",name},{"label",label},{"kind",kind},{"default",value}};}
Json number(const char* name,const char* label,double value,double lo,double hi,double step=.01){auto p=param(name,label,"float",value);p.update({{"min",lo},{"max",hi},{"step",step}});return p;}
Json choice(const char* name,const char* label,const char* value,Json choices){auto p=param(name,label,"choice",value);p["choices"]=choices;return p;}
std::string hash(const std::string& value){boost::uuids::detail::sha1 sha;sha.process_bytes(value.data(),value.size());boost::uuids::detail::sha1::digest_type digest;sha.get_digest(digest);std::ostringstream result;for(auto n:digest)result<<std::hex<<std::setfill('0')<<std::setw(2*sizeof(n))<<static_cast<uint32_t>(n);return result.str();}
}
void installTextRasterizer(TextRasterizer rasterizer,const std::string& version){std::lock_guard lock(backendMutex);backend=std::move(rasterizer);backendVersion=version;}
fs::path defaultTextFontRoot(){
    if(const auto configured=std::getenv("VJ_TEXT_FONT_ROOT"))return fs::path(configured);
    fs::path executable;
#ifdef __APPLE__
    uint32_t length=0;_NSGetExecutablePath(nullptr,&length);std::vector<char> buffer(length);if(_NSGetExecutablePath(buffer.data(),&length)==0)executable=buffer.data();
#else
    char buffer[4096];auto length=readlink("/proc/self/exe",buffer,sizeof(buffer));if(length>0&&length<static_cast<ssize_t>(sizeof(buffer)))executable=std::string(buffer,length);
#endif
    if(!executable.empty()){
        std::error_code error;
        for(const auto& candidate:{executable.parent_path()/"../Resources/fonts",executable.parent_path()/"../share/vj-native/fonts"})if(fs::is_directory(candidate,error))return fs::weakly_canonical(candidate);
    }
#ifdef VJ_BUNDLED_FONT_ROOT
    return fs::path(VJ_BUNDLED_FONT_ROOT);
#else
    return {}; // A missing explicit font root is an error, never a system fallback.
#endif
}
Json textSourceCatalog(){
    Json names=Json::array();for(const auto& [name,file]:typefaces){(void)file;names.push_back(name);}
    return {{"name","text"},{"label","Text"},{"description",""},{"kind","source"},{"collectionGeometry",nullptr},{"adjustment",false},{"vector",false},{"liveSource",false},{"exclusive",false},{"rasterizedWhenStacked",false},{"defaultBlend","normal"},
        {"parameters",Json::array({param("content","Text","text","YOUR TEXT"),choice("font","Font","Archivo Black",names),param("italic","Italic","bool",false),param("color","Text color","color","#ffffff"),number("color_opacity","Text opacity",1,0,1),param("background","Background","color","#000000"),number("background_opacity","Background opacity",0,0,1),number("size","Size",.15,.02,.75),number("x","Horizontal position",.5,0,1),number("y","Vertical position",.5,0,1),choice("align","Alignment","center",{"left","center","right"}),number("weight","Weight",2,1,20,1),param("outline","Outline color","color","#000000"),number("outline_opacity","Outline opacity",1,0,1),number("outline_width","Outline width",0,0,12,1)})},
        {"performanceParameters",{"size","x","y","weight","outline_width","color","background","align"}}};
}
Json normalizeTextParams(const Json& params){
    if(!params.is_object())throw std::invalid_argument("Text params must be an object");
    Json result=Json::object();auto schema=textSourceCatalog()["parameters"];
    for(const auto& p:schema)result[p["name"].get<std::string>()]=p["default"];
    for(auto it=params.begin();it!=params.end();++it){if(!result.contains(it.key()))throw std::invalid_argument("Unknown text parameter: "+it.key());result[it.key()]=it.value();}
    if(result["font"].is_string()){
        const std::pair<const char*,const char*> legacy[]={{"Sans","Archivo Black"},{"Sans double","Archivo Black"},{"Serif","DM Serif Display"},{"Serif heavy","DM Serif Display"},{"Compact","Bebas Neue"},{"Compact serif","Special Elite"},{"Script","Pacifico"},{"Script ornate","Lobster"}};
        for(const auto& [oldName,newName]:legacy)if(result["font"]==oldName)result["font"]=newName;
    }
    for(const auto& p:schema){const std::string name=p["name"];const auto& value=result[name];const std::string kind=p["kind"];bool valid=false;
        if(kind=="text")valid=value.is_string()&&value.get_ref<const std::string&>().size()<=65536&&value.get_ref<const std::string&>().find('\0')==std::string::npos;
        else if(kind=="bool")valid=value.is_boolean();
        else if(kind=="choice")valid=std::find(p["choices"].begin(),p["choices"].end(),value)!=p["choices"].end();
        else if(kind=="float")valid=value.is_number()&&std::isfinite(value.get<double>())&&value.get<double>()>=p["min"].get<double>()&&value.get<double>()<=p["max"].get<double>();
        else if(kind=="color"&&value.is_string()){const auto color=value.get<std::string>();valid=color.size()==7&&color[0]=='#'&&color.find_first_not_of("0123456789abcdefABCDEF",1)==std::string::npos;}
        if(!valid)throw std::invalid_argument("Invalid text parameter: "+name);
    }
    return result;
}
TextSource::TextSource(fs::path cacheRoot,fs::path fontRoot):cacheRoot_(std::move(cacheRoot)),fontRoot_(std::move(fontRoot)){if(cacheRoot_.empty())throw std::invalid_argument("Text cache root is required");}
bool TextSource::available(){std::lock_guard lock(backendMutex);return static_cast<bool>(backend);}
Json TextSource::fonts()const{
    Json result=Json::array();for(const auto& [name,file]:typefaces){std::error_code error;const auto path=fontRoot_/(std::string(file)+".ttf");result.push_back({{"name",name},{"available",!fontRoot_.empty()&&fs::is_regular_file(path,error)}});}
    return {{"available",available()},{"fonts",result},{"backend",available()?"coretext":"unavailable"}};
}
std::string TextSource::asset(const Json& raw,int width,int height)const{
    if(width<1||height<1||width>8192||height>8192||static_cast<long long>(width)*height>33554432)throw std::invalid_argument("Text dimensions exceed render limits");
    const auto params=normalizeTextParams(raw);
    std::lock_guard lock(backendMutex);if(!backend)throw std::runtime_error("Native text rasterization backend is unavailable on this build");
    fs::path fontFile;for(const auto& [name,file]:typefaces)if(params["font"]==name)fontFile=fontRoot_/(std::string(file)+".ttf");
    if(fontRoot_.empty()||fontFile.empty()||!fs::is_regular_file(fontFile))throw std::runtime_error("Bundled font is missing: "+params["font"].get<std::string>());
    Json key={{"backend",backendVersion},{"width",width},{"height",height},{"params",params},{"fontSize",fs::file_size(fontFile)},{"fontModified",fs::last_write_time(fontFile).time_since_epoch().count()}};
    const auto destination=cacheRoot_/(hash(key.dump())+".png");if(fs::is_regular_file(destination)&&fs::file_size(destination)>8)return destination.string();
    fs::create_directories(cacheRoot_);auto name=(cacheRoot_/".text-XXXXXX").string();std::vector<char> temporary(name.begin(),name.end());temporary.push_back('\0');int fd=mkstemp(temporary.data());if(fd<0)throw std::runtime_error("Cannot create text cache asset");close(fd);
    const fs::path path(temporary.data());
    try{backend(path,fontFile,width,height,params);fd=open(path.c_str(),O_RDONLY);if(fd<0)throw std::runtime_error("Cannot read generated text asset");const int result=fsync(fd);close(fd);if(result!=0)throw std::runtime_error("Cannot sync generated text asset");fs::rename(path,destination);}catch(...){std::error_code ignored;fs::remove(path,ignored);throw;}
    return destination.string();
}
}
