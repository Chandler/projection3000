#include "live_sources.hpp"
#include "ndi_runtime.hpp"
#include "syphon_input.hpp"
#include <chrono>
#include <fstream>
#include <iostream>
#include <thread>
#include <set>
#ifdef __linux__
#include <sys/stat.h>
#include <sys/sysmacros.h>
#endif
using Json=nlohmann::json;
#ifdef __APPLE__
Json nativeCameraSources();
#endif
namespace {
Json ndi(const std::string& extra){
    auto runtime=NdiRuntime::get();
    if(!runtime->api)return {{"available",false},{"sources",Json::array()},{"error",runtime->error}};
    // Include local senders when multicast hostname resolution is unavailable.
    const auto addresses=extra.empty()?std::string("127.0.0.1"):"127.0.0.1,"+extra;
    NDIlib_find_create_t options{};options.show_local_sources=true;options.p_extra_ips=addresses.c_str();
    auto finder=runtime->api->find_create_v2(&options);
    if(!finder)return {{"available",false},{"sources",Json::array()},{"error","NDI discovery unavailable"}};
    struct Guard{const NDIlib_v5* api;NDIlib_find_instance_t finder;~Guard(){api->find_destroy(finder);}} guard{runtime->api,finder};
    const auto until=std::chrono::steady_clock::now()+std::chrono::milliseconds(1600);
    while(std::chrono::steady_clock::now()<until)runtime->api->find_wait_for_sources(finder,100);
    uint32_t count=0;const auto* items=runtime->api->find_get_current_sources(finder,&count);Json result=Json::array();std::set<std::string> seen;
    for(uint32_t i=0;i<count;i++){
        std::string name=items[i].p_ndi_name?items[i].p_ndi_name:"",url=items[i].p_url_address?items[i].p_url_address:"";if(!seen.insert(name).second)continue;
        result.push_back({{"name",name},{"label",name},{"url",url},{"selection",Json({{"name",name},{"url",url},{"extra_ips",extra}}).dump()}});
    }
    return {{"available",true},{"sources",result},{"version",runtime->version}};
}
Json syphon(){
#ifdef __APPLE__
    const auto until=std::chrono::steady_clock::now()+std::chrono::milliseconds(700);
    do{syphon_poll();std::this_thread::sleep_for(std::chrono::milliseconds(10));}while(std::chrono::steady_clock::now()<until);
    return {{"available",true},{"sources",syphon_sources()}};
#else
    return {{"available",false},{"sources",Json::array()},{"error","Syphon requires macOS"}};
#endif
}
Json cameras(){
#ifdef __APPLE__
    return nativeCameraSources();
#elif defined(__linux__)
    namespace fs=std::filesystem;Json result=Json::array();std::error_code error;
    std::map<std::string,std::string> aliases;
    for(const auto* directory:{"/dev/v4l/by-path","/dev/v4l/by-id"}){
        std::vector<fs::path> paths;for(const auto& item:fs::directory_iterator(directory,error))paths.push_back(item.path());
        std::sort(paths.begin(),paths.end());for(const auto& path:paths){auto real=fs::canonical(path,error);if(!error)aliases[real.string()]=path.string();}
    }
    std::vector<fs::path> entries;for(const auto& item:fs::directory_iterator("/sys/class/video4linux",error))entries.push_back(item.path());
    std::sort(entries.begin(),entries.end());
    for(const auto& entry:entries){
        auto node="/dev/"+entry.filename().string();struct stat info{};if(stat(node.c_str(),&info)||!S_ISCHR(info.st_mode))continue;
        std::ifstream props("/run/udev/data/c"+std::to_string(major(info.st_rdev))+":"+std::to_string(minor(info.st_rdev)));
        std::string line;bool capture=false;while(std::getline(props,line))if(line.starts_with("E:ID_V4L_CAPABILITIES=")&&line.find(":capture:")!=std::string::npos)capture=true;
        if(!capture)continue;
        std::ifstream name(entry/"name");std::string label;std::getline(name,label);
        const auto device=aliases.contains(node)?aliases[node]:node;
        result.push_back({{"device",device},{"selection",device},{"label",label.empty()?entry.filename().string():label},{"node",node}});
    }
    return {{"available",true},{"sources",result},{"cameras",result}};
#else
    return {{"available",false},{"sources",Json::array()},{"error","Camera discovery is supported on macOS and Linux"}};
#endif
}
}
int main(int argc,char** argv){
    try{
        if(argc<2)throw std::runtime_error("Source kind required: cameras, syphon or ndi");
        std::string kind=argv[1];Json result;
        if(kind=="--capabilities")result={{"sources",Json::array()},{"capabilities",vj::liveSourceCapabilities()}};
        else if(kind=="ndi")result=ndi(vj::normalizeNdiExtraIPs(argc>2?argv[2]:""));
        else if(kind=="syphon")result=syphon();
        else if(kind=="cameras")result=cameras();
        else throw std::runtime_error("Unknown source kind");
        std::cout<<result.dump()<<std::endl;return 0;
    }catch(const std::exception& error){std::cout<<Json({{"available",false},{"sources",Json::array()},{"error",error.what()}}).dump()<<std::endl;return 1;}
}
