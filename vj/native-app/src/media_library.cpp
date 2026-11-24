#include "media_library.hpp"
#include "media_processing.hpp"
#include "removable_media.hpp"
#include "api_error.hpp"
#include <algorithm>
#include <boost/uuid/detail/sha1.hpp>
#include <sstream>
#include <iomanip>
#include <set>
#include <cmath>
#include <atomic>
#include <cctype>
#include <cstdlib>
#include <fstream>
#include <mutex>
#include <stdexcept>
#include <system_error>
#include <fcntl.h>
#include <unistd.h>

namespace vj {
namespace fs=std::filesystem;
using Json=nlohmann::json;
namespace {
std::mutex inspectorMutex;
MediaInspector inspector;
std::string lower(std::string value){for(auto& c:value)c=static_cast<char>(std::tolower(static_cast<unsigned char>(c)));return value;}
bool contained(const fs::path& root,const fs::path& path){auto a=root.begin(),b=path.begin();for(;a!=root.end();++a,++b)if(b==path.end()||*a!=*b)return false;return b!=path.end();}
fs::path canonicalPath(const fs::path& path){std::error_code error;auto result=fs::weakly_canonical(path,error);return error?fs::path{}:result;}
std::string encode(const std::string& value){const char* hex="0123456789ABCDEF";std::string result;for(unsigned char c:value){if(std::isalnum(c)||c=='/'||c=='-'||c=='_'||c=='.'||c=='~')result+=c;else{result+='%';result+=hex[c>>4];result+=hex[c&15];}}return result;}
std::string decode(const std::string& value){std::string result;auto digit=[](char c)->int{if(c>='0'&&c<='9')return c-'0';if(c>='A'&&c<='F')return c-'A'+10;if(c>='a'&&c<='f')return c-'a'+10;return -1;};for(size_t i=0;i<value.size();++i){char c=value[i];if(c=='%'){if(i+2>=value.size()||digit(value[i+1])<0||digit(value[i+2])<0)throw std::invalid_argument("Invalid media reference encoding");c=static_cast<char>((digit(value[i+1])<<4)|digit(value[i+2]));i+=2;}if(c=='\0')throw std::invalid_argument("Invalid media reference");result+=c;}return result;}
fs::path expand(fs::path value){auto raw=value.string();if(raw=="~"||raw.starts_with("~/")){const auto home=std::getenv("HOME");if(!home)throw std::invalid_argument("Home directory unavailable");return raw=="~"?fs::path(home):fs::path(home)/raw.substr(2);}return value;}
Json parameter(const char* name,const char* label,const char* kind,Json value){return {{"name",name},{"label",label},{"kind",kind},{"default",value}};}
Json number(const char* name,const char* label,double value,double minimum,double maximum,double step=.01){auto p=parameter(name,label,"float",value);p.update({{"min",minimum},{"max",maximum},{"step",step}});return p;}
Json choice(const char* name,const char* label,const char* value,Json choices){auto p=parameter(name,label,"choice",value);p["choices"]=choices;return p;}
}
void installMediaInspector(MediaInspector value){std::lock_guard lock(inspectorMutex);inspector=std::move(value);}
bool mediaInspectorAvailable(){std::lock_guard lock(inspectorMutex);return static_cast<bool>(inspector);}
MediaLibrary::MediaLibrary(fs::path importRoot,fs::path sharedRoot):sharedRoot_(canonicalPath(expand(sharedRoot))),importRoot_(canonicalPath(expand(importRoot))){if(sharedRoot_.empty()||importRoot_.empty()||!importRoot_.is_absolute())throw std::invalid_argument("Media roots must resolve to absolute paths");if(sharedRoot_==importRoot_)throw std::invalid_argument("Native imports require a separate media directory");processing_=std::make_shared<MediaProcessing>(importRoot_.parent_path()/"media-processing");}
fs::path MediaLibrary::defaultSharedRoot(){if(const auto root=std::getenv("VJ_MEDIA_ROOT");root&&*root)return fs::path(root);const auto home=std::getenv("HOME");return home?fs::path(home)/"av/videos":fs::path("/nonexistent/vj-media");}
std::string MediaLibrary::kind(const fs::path& path){const auto extension=lower(path.extension().string());for(const auto* e:{".png",".jpg",".jpeg",".webp"})if(extension==e)return "image";for(const auto* e:{".mp4",".mov",".webm",".avi",".mkv",".m4v"})if(extension==e)return "video";return {};}
fs::path MediaLibrary::candidate(const std::string& reference) const {
    if(reference.empty())return {};
    if(reference.size()>16384||reference.find('\0')!=std::string::npos)throw std::invalid_argument("Invalid media reference");
    if(reference.starts_with("removable://"))return removableMedia().resolve(reference);
    fs::path root,relative;
    if(reference.starts_with("library://")){root=sharedRoot_;relative=decode(reference.substr(10));}
    else if(reference.starts_with("native-media://")){root=importRoot_;relative=decode(reference.substr(15));}
    else {
        if(reference.find("://")!=std::string::npos)throw std::invalid_argument("Unsupported media reference scheme");
        auto path=expand(reference);if(!path.is_absolute())path=sharedRoot_/path;
        auto result=canonicalPath(path);
        if(contained(sharedRoot_,result)||contained(importRoot_,result))return result;
        throw std::invalid_argument("Media file is outside the library; import it first");
    }
    if(relative.empty()||relative.is_absolute())throw std::invalid_argument("Invalid media reference path");
    auto result=canonicalPath(root/relative);
    if(!contained(root,result))throw std::invalid_argument("Media reference escapes library root");
    return result;
}
Json MediaLibrary::item(const fs::path& path,const fs::path& root,const std::string& scheme) const {
    auto relative=path.lexically_relative(root).generic_string();
    std::error_code error;const auto size=fs::file_size(path,error);
    Json result={{"name",path.filename().string()},{"path",relative},{"type",kind(path)},{"file",scheme+encode(relative)},{"available",!error}};
    if(!error)result["size"]=size;
    result["origin"]=scheme=="library://"?"library":"native";
    return result;
}
Json MediaLibrary::catalog() const {
    Json items=Json::array();
    for(const auto& [root,scheme]:{std::pair{sharedRoot_,std::string("library://")},std::pair{importRoot_,std::string("native-media://")}}){
        std::error_code error;
        fs::recursive_directory_iterator it(root,fs::directory_options::skip_permission_denied,error),end;
        for(;it!=end;it.increment(error)){
            if(error){error.clear();continue;}
            const auto path=it->path();const auto name=path.filename().string();
            if(!name.empty()&&name[0]=='.'){if(it->is_directory(error))it.disable_recursion_pending();continue;}
            if(!it->is_regular_file(error)||kind(path).empty()||!contained(root,canonicalPath(path)))continue;
            items.push_back(item(path,root,scheme));
        }
    }
    std::sort(items.begin(),items.end(),[](const Json& a,const Json& b){return lower(a["path"].get<std::string>())<lower(b["path"].get<std::string>());});
    return {{"items",items}};
}
Json MediaLibrary::status(const std::string& reference,const std::string& expectedKind) const {
    Json result={{"file",reference},{"available",false},{"status","missing"}};
    try {
        const auto path=candidate(reference);if(path.empty()){result["status"]="empty";return result;}
        const auto type=kind(path);result["type"]=type;
        if(type.empty()||(!expectedKind.empty()&&type!=expectedKind)){result["status"]="unsupported";return result;}
        std::error_code error;const bool exists=fs::is_regular_file(path,error);result["available"]=exists;
        if(exists){result["status"]="ready";result["resolved_file"]=path.string();auto size=fs::file_size(path,error);if(!error)result["size"]=size;}
    }catch(const ApiError& e){result["status"]=e.status==404?"missing":"invalid";result["error"]=e.what();}
    catch(const std::invalid_argument& e){result["status"]="invalid";result["error"]=e.what();}
    catch(const std::exception& e){result["status"]="missing";result["error"]=e.what();}
    return result;
}
std::string MediaLibrary::resolve(const std::string& reference,const std::string& expectedKind) const {return status(reference,expectedKind).value("resolved_file",std::string{});}
Json MediaLibrary::inspect(const std::string& reference,bool thumbnail) const {
    auto result=status(reference);result["metadataAvailable"]=mediaInspectorAvailable();
    if(!result.value("available",false))return result;
    MediaInspector callback;{std::lock_guard lock(inspectorMutex);callback=inspector;}
    if(!callback){result["error"]="Media inspection backend is unavailable on this build";return result;}
    try{result["metadata"]=callback(result.at("resolved_file").get<std::string>(),importRoot_.parent_path()/"media-cache",thumbnail);}
    catch(const std::exception& error){result["metadataAvailable"]=false;result["error"]=error.what();}
    return result;
}
void MediaLibrary::decorateVideo(Json& clip) const {
    auto file=clip.value("resolved_file",std::string{});if(file.empty())return;
    clip["renditions"]=processing_->renditions(file);
    auto track=clip.value("params",Json::object()).value("subtitle_track",std::string{});
    if(track.empty())return;
    auto asset=processing_->subtitleAsset(file,track);
    if(!asset.empty()){clip["subtitle_asset"]=asset;clip["subtitleStatus"]={{"state","completed"}};}
    else try{clip["subtitleStatus"]=processing_->prepareSubtitle(file,track);}catch(const std::exception& e){clip["subtitleStatus"]={{"state","failed"},{"error",e.what()}};}
}
std::uint64_t MediaLibrary::processingRevision() const{return processing_->revision();}
Json MediaLibrary::importFile(const fs::path& source) const {
    const auto path=canonicalPath(expand(source));std::error_code error;
    if(path.empty()||!fs::is_regular_file(path,error)||kind(path).empty())throw std::invalid_argument("Choose an existing supported image or video file");
    if(contained(sharedRoot_,path))return item(path,sharedRoot_,"library://");
    if(contained(importRoot_,path))return item(path,importRoot_,"native-media://");
    fs::create_directories(importRoot_);
    // Reserve a hidden temporary file using O_EXCL. Publish through link(), which
    // never overwrites a concurrently imported file with the same name.
    std::string temporary=(importRoot_/".import-XXXXXX").string();std::vector<char> name(temporary.begin(),temporary.end());name.push_back('\0');
    int fd=mkstemp(name.data());if(fd<0)throw std::runtime_error("Unable to create media import file");
    temporary=name.data();
    try {
        std::ifstream input(path,std::ios::binary);if(!input)throw std::runtime_error("Unable to read media file");
        std::vector<char> buffer(1024*1024);while(input){input.read(buffer.data(),buffer.size());auto remaining=input.gcount();const char* next=buffer.data();while(remaining>0){auto count=::write(fd,next,static_cast<size_t>(remaining));if(count<=0){if(count<0&&errno==EINTR)continue;throw std::runtime_error("Unable to write media import");}next+=count;remaining-=count;}}
        if(!input.eof())throw std::runtime_error("Unable to read complete media file");
        if(fsync(fd)!=0)throw std::runtime_error("Unable to sync media import");close(fd);fd=-1;
        auto stem=path.stem().string();while(!stem.empty()&&stem.front()=='.')stem.erase(stem.begin());if(stem.empty())stem="media";const auto extension=lower(path.extension().string());
        for(unsigned suffix=1;;++suffix){auto destination=importRoot_/(stem+(suffix==1?"":"-"+std::to_string(suffix))+extension);if(link(temporary.c_str(),destination.c_str())==0){unlink(temporary.c_str());return item(destination,importRoot_,"native-media://");}if(errno!=EEXIST)throw std::runtime_error("Unable to publish media import");}
    }catch(...){if(fd>=0)close(fd);unlink(temporary.c_str());throw;}
}
std::optional<Json> MediaLibrary::request(const std::string& method,const std::string& path,const Json& body) const {
    if(method=="GET"&&(path=="/api/removable"||path=="/api/v1/media/drives")){auto drives=removableMedia().drives(true);drives.insert(drives.begin(),Json{{"id","native"},{"name","Imported Media"},{"kind","library"}});drives.insert(drives.begin(),Json{{"id","library"},{"name","Built-in Library"},{"kind","library"}});return Json{{"drives",drives}};}
    if(method=="GET"&&path.starts_with("/api/removable/")&&path.ends_with("/browse")){auto id=path.substr(15,path.size()-22);auto relative=body.value("path",std::string{});auto result=(id=="library"||id=="native")?RemovableMedia::browseDirectory(id=="library"?sharedRoot_:importRoot_,id,id=="library"?"Built-in Library":"Imported Media",relative,id=="library"?"library://":"native-media://"):removableMedia().browse(id,relative);for(auto& entry:result["entries"])if(entry.value("type",std::string{})!="directory")entry["url"]=(id=="library"?"/videos/":id=="native"?"/native-media/":"/removable/"+id+"/")+encode(entry.at("path").get<std::string>());return result;}
    if(method=="GET"&&path=="/api/videos"){
        Json names=Json::array();
        const auto listing=catalog();
        for(const auto& entry:listing.at("items"))if(entry.at("type")=="video"){
            const auto relative=entry.at("path").get<std::string>();
            // Original endpoint lists top-level names; native imports need their
            // explicit scheme to avoid ambiguity with the read-only library.
            if(entry.at("origin")=="library"){if(relative.find('/')==std::string::npos)names.push_back(relative);}
            else names.push_back(entry.at("file"));
        }
        return Json{{"videos",names}};
    }
    if(method=="GET"&&path=="/api/images"){
        Json images=Json::array();
        const auto listing=catalog();
        for(const auto& entry:listing.at("items"))if(entry.at("type")=="image"){
            const auto reference=entry.at("file").get<std::string>();
            const auto metadata=inspect(reference,true).value("metadata",Json::object());
            const auto thumbnail=metadata.value("thumbnail",Json::object());
            images.push_back({{"file",reference},{"name",entry.at("name")},{"relative",entry.at("path")},
                {"thumb",thumbnail.value("data",std::string{})},{"origin",entry.at("origin")}});
        }
        return Json{{"images",images}};
    }
    if(method=="GET"&&(path=="/api/media/catalog"||path=="/api/v1/media/catalog"))return catalog();
    if((method=="POST"||method=="GET")&&path=="/api/v1/media/inspect"){auto wanted=body.value("thumbnail",Json(false));bool thumbnail=wanted==true||wanted=="true"||wanted=="1";return inspect(body.at("file").get<std::string>(),thumbnail);}
    if(method=="POST"&&path=="/api/v1/media/import")return Json{{"item",importFile(body.at("path").get<std::string>())}};
    if(method=="POST"&&path=="/api/v1/media/status")return status(body.at("file").get<std::string>(),body.value("type",std::string{}));
    if(method=="GET"&&(path=="/api/videos/subtitles"||path=="/api/v1/media/subtitles")){
        auto file=resolve(body.at("file").get<std::string>(),"video");if(file.empty())throw std::invalid_argument("Video is unavailable");
        return Json{{"tracks",processing_->subtitleTracks(file)}};
    }
    if(method=="POST"&&path=="/api/v1/media/subtitles/prepare"){
        auto file=resolve(body.at("file").get<std::string>(),"video");if(file.empty())throw std::invalid_argument("Video is unavailable");
        return processing_->prepareSubtitle(file,body.at("track").get<std::string>(),body.value("retry",true));
    }
    if(method=="GET"&&path=="/api/v1/media/subtitles/status")return processing_->subtitleStatus();
    if(path=="/api/v1/media/preprocess"){
        if(method=="GET")return processing_->preprocessStatus();
        if(method=="POST"){std::vector<fs::path> files;auto listing=catalog();for(const auto& item:listing.at("items"))if(item.at("type")=="video"){auto file=resolve(item.at("file"),"video");if(!file.empty())files.push_back(file);}return processing_->startPreprocess(files);}
    }
    if(method=="POST"&&path=="/api/v1/media/preprocess/cancel")return processing_->cancelPreprocess();
    return std::nullopt;
}
std::string mediaItemIdentity(const Json& items,size_t index){
    const auto& item=items.at(index);if(item.contains("id"))return item.at("id").get<std::string>();
    auto path=item.at("file").get<std::string>();boost::uuids::detail::sha1 hash;hash.process_bytes(path.data(),path.size());boost::uuids::detail::sha1::digest_type digest;hash.get_digest(digest);std::ostringstream out;for(auto word:digest)out<<std::hex<<std::setfill('0')<<std::setw(2*sizeof(word))<<static_cast<unsigned long>(word);
    size_t occurrence=0;for(size_t i=0;i<index;++i)if(items[i]["file"]==item["file"])++occurrence;
    return out.str().substr(0,16)+(occurrence?":"+std::to_string(occurrence):"");
}
void identifyMediaItems(Json& items){
    std::vector<std::string> identities;for(size_t i=0;i<items.size();++i)identities.push_back(mediaItemIdentity(items,i));
    for(size_t i=0;i<items.size();++i)items[i]["id"]=identities[i];
}
void validateMediaItems(const Json& items){
    if(!items.is_array()||items.size()>256)throw std::invalid_argument("Media must be a list of at most 256 items");
    std::set<std::string> identities;
    for(size_t i=0;i<items.size();++i){const auto& item=items[i];
        if(!item.is_object()||!item.contains("type")||!item.contains("file")||(item["type"]!="image"&&item["type"]!="video")||!item["file"].is_string()||item["file"].get<std::string>().empty())throw std::invalid_argument("Each media item requires type (image/video) and file");
        for(auto it=item.begin();it!=item.end();++it)if(it.key()!="type"&&it.key()!="file"&&it.key()!="id"&&it.key()!="params")throw std::invalid_argument("Unknown media item field: "+it.key());
        if(item.contains("id")&&(!item["id"].is_string()||item["id"].get<std::string>().empty()||item["id"].get<std::string>().size()>128))throw std::invalid_argument("Media item id must be a nonempty string up to 128 characters");
        if(!identities.insert(mediaItemIdentity(items,i)).second)throw std::invalid_argument("Media item ids must be unique");
        if(!item.contains("params"))continue;const auto& p=item["params"];
        if(item["type"]!="video"||!p.is_object())throw std::invalid_argument("Only video items accept playback params");
        for(auto it=p.begin();it!=p.end();++it){auto key=it.key();if(key=="playing"){if(!it.value().is_boolean())throw std::invalid_argument("playing must be boolean");}
            else if(key=="loop_start"||key=="loop_end"||key=="position"||key=="seek_nonce"){
                double maximum=key=="seek_nonce"?999999.:1.;if(!it.value().is_number()||!std::isfinite(it.value().get<double>())||it.value().get<double>()<0||it.value().get<double>()>maximum)throw std::invalid_argument("Invalid video item "+key);
            }else throw std::invalid_argument("Unknown video item param: "+key);
        }
        if(p.value("loop_start",0.)>=p.value("loop_end",1.))throw std::invalid_argument("Video loop start must be before end");
    }
}
Json mediaEffectCatalog(){
    auto file=choice("file","File","",Json::array());file["mediaFile"]=true;
    Json image={{"name","image"},{"label","Image"},{"description","Place a still image, preserving PNG transparency."},{"parameters",Json::array({file,choice("fit","Fit","contain",{"contain","cover","stretch"}),number("scale","Scale",1,.05,3),number("x","Horizontal position",.5,0,1),number("y","Vertical position",.5,0,1),number("gain","Brightness",1,0,2)})}};
    Json video={{"name","video"},{"label","Video"},{"description","Loop a video file."},{"parameters",Json::array({file,choice("loop_mode","Loop mode","forward",{"forward","ping-pong"}),number("speed","Speed",1,.1,3),number("loop_start","Loop start",0,0,1,.001),number("loop_end","Loop end",1,0,1,.001),parameter("playing","Playing","bool",true),number("position","Position",0,0,1,.001),number("seek_nonce","Seek nonce",0,0,999999,1),choice("fit","Fit","stretch",{"stretch","contain","cover"}),parameter("audio_enabled","Audio out","bool",false),number("audio_gain","Audio level",1,0,2),parameter("subtitle_track","Subtitles","text",""),number("gain","Brightness",1,0,2)})}};
    for(auto* effect:{&image,&video})effect->update({{"nativeMedia",true},{"kind","source"},{"collectionGeometry",nullptr},{"adjustment",false},{"vector",false},{"liveSource",false},{"exclusive",false},{"rasterizedWhenStacked",false},{"defaultBlend","normal"}});
    image["performanceParameters"]={"scale","x","y","gain","fit"};
    video["performanceParameters"]={"speed","position","loop_start","loop_end","gain","audio_gain","loop_mode","fit"};
    Json collection={{"name","media_collection"},{"label","Media Collection"},{"kind","source"},{"collectionGeometry","media"},{"adjustment",false},{"vector",false},{"liveSource",false},{"exclusive",false},{"rasterizedWhenStacked",false},{"defaultBlend","normal"},{"parameters",Json::array({parameter("items","Media","media_list",Json::array()),choice("fit","Fit","contain",{"contain","cover","stretch"}),number("speed","Speed",1,.1,3),parameter("playing","Playing","bool",true),number("gain","Brightness",1,0,2)})},{"performanceParameters",{"speed","gain","fit"}}};
    return Json::array({image,video,collection});
}
}
