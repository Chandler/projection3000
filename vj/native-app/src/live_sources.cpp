#include "live_sources.hpp"
#include "live_source_catalog.hpp"
#include <algorithm>
#include <arpa/inet.h>
#include <cerrno>
#include <csignal>
#include <fcntl.h>
#include <poll.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>
#include <regex>
#ifdef __APPLE__
#include <mach-o/dyld.h>
#endif
extern char **environ;

namespace vj {
namespace {
using Json=nlohmann::json;
std::string trim(std::string s){const auto first=s.find_first_not_of(" \t\r\n");if(first==std::string::npos)return {};return s.substr(first,s.find_last_not_of(" \t\r\n")-first+1);}
Json unavailable(const std::string& error){return {{"available",false},{"sources",Json::array()},{"error",error}};}
Json invoke(const std::filesystem::path& helper,const std::string& kind,const std::string& extra){
    if(helper.empty()||access(helper.c_str(),X_OK)!=0)return unavailable("Native source discovery helper is not installed");
    int descriptors[2];if(pipe(descriptors)!=0)return unavailable("Could not create discovery pipe");
    // Prevent inherited pipe ends retaining the child output indefinitely.
    fcntl(descriptors[0],F_SETFD,FD_CLOEXEC);fcntl(descriptors[1],F_SETFD,FD_CLOEXEC);
    posix_spawn_file_actions_t actions;posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions,descriptors[1],STDOUT_FILENO);
    posix_spawn_file_actions_addclose(&actions,descriptors[0]);
    posix_spawn_file_actions_addclose(&actions,descriptors[1]);
    posix_spawn_file_actions_addopen(&actions,STDERR_FILENO,"/dev/null",O_WRONLY,0);
    std::string executable=helper.string();
    char* args[]={executable.data(),const_cast<char*>(kind.c_str()),const_cast<char*>(extra.c_str()),nullptr};
    pid_t process=0;const int launched=posix_spawn(&process,executable.c_str(),&actions,nullptr,args,environ);
    posix_spawn_file_actions_destroy(&actions);close(descriptors[1]);
    if(launched){close(descriptors[0]);return unavailable("Could not start native source discovery helper");}
    fcntl(descriptors[0],F_SETFL,O_NONBLOCK);
    std::string output;int status=0;bool finished=false,failed=false;
    const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(6);
    while(!finished&&std::chrono::steady_clock::now()<deadline){
        pollfd fd{descriptors[0],POLLIN,0};poll(&fd,1,50);
        char buffer[4096];ssize_t n;
        while((n=read(descriptors[0],buffer,sizeof(buffer)))>0){output.append(buffer,n);if(output.size()>1024*1024){failed=true;break;}}
        if(failed)break;
        const auto waited=waitpid(process,&status,WNOHANG);
        if(waited==process)finished=true;
        else if(waited<0&&errno!=EINTR){failed=true;break;}
    }
    if(!finished){kill(process,SIGKILL);while(waitpid(process,&status,0)<0&&errno==EINTR){};}
    if(finished&&!failed){
        char remaining[4096];ssize_t n;
        while((n=read(descriptors[0],remaining,sizeof(remaining)))>0){output.append(remaining,n);if(output.size()>1024*1024){failed=true;break;}}
    }
    close(descriptors[0]);
    if(!finished||failed||!WIFEXITED(status)||WEXITSTATUS(status)!=0)return unavailable("Native source discovery failed or timed out");
    auto result=Json::parse(output,nullptr,false);
    if(!result.is_object()||!result.value("sources",Json()).is_array())return unavailable("Invalid source discovery response");
    return result;
}
}
std::string normalizeNdiExtraIPs(const std::string& value){
    if(value.size()>1024)throw std::invalid_argument("Invalid remote IPs");
    std::string result;std::size_t start=0,count=0;
    do{
        auto comma=value.find(',',start);auto part=trim(value.substr(start,comma==std::string::npos?comma:comma-start));
        if(!part.empty()){
            if(++count>16)throw std::invalid_argument("At most 16 remote IPs");
            unsigned char address[16];char normalized[INET6_ADDRSTRLEN];
            const int family=part.find(':')==std::string::npos?AF_INET:AF_INET6;
            if(inet_pton(family,part.c_str(),address)!=1||!inet_ntop(family,address,normalized,sizeof(normalized)))throw std::invalid_argument("Invalid remote IPs");
            if(!result.empty())result+=',';result+=normalized;
        }
        if(comma==std::string::npos)break;start=comma+1;
    }while(true);return result;
}
std::string normalizeLiveSelection(const std::string& generator,const std::string& raw){
    if(generator=="usb_webcam"){
        auto value=trim(raw);
#ifdef __APPLE__
        if(value.empty()||value=="none"||value.find_first_of(":/\\")!=std::string::npos||value.find('\0')!=std::string::npos)return {};
        return value;
#else
        if(std::regex_match(value,std::regex("[0-9]{1,3}")))value="/dev/video"+std::to_string(std::stoi(value));
        if(!std::regex_match(value,std::regex("/dev/video[0-9]+|/dev/v4l/by-(id|path)/[^/]+")))return {};
        const auto base=std::filesystem::path(value).filename();if(base=="."||base==".."||value.find('\0')!=std::string::npos)return {};
        return value;
#endif
    }
    if(generator!="ndi"&&generator!="syphon")return {};
    if(raw.size()>(generator=="ndi"?8192:4096))return {};
    auto data=Json::parse(raw,nullptr,false);if(!data.is_object())return {};
    const std::vector<std::string> keys=generator=="ndi"?std::vector<std::string>{"name","url","extra_ips"}:std::vector<std::string>{"app","name","uuid"};
    Json selected=Json::object();
    for(const auto& key:keys){
        auto part=data.value(key,Json(""));if(!part.is_string())return {};const auto text=part.get<std::string>();
        if(text.size()>(generator=="ndi"?2048:1024)||std::any_of(text.begin(),text.end(),[&](unsigned char c){return generator=="ndi"?c<32:c==0;}))return {};
        selected[key]=text;
    }
    if(generator=="ndi"){
        if(trim(selected["name"]).empty())return {};
        try{selected["extra_ips"]=normalizeNdiExtraIPs(selected["extra_ips"]);}catch(...){return {};}
    }else if(selected["app"]==""&&selected["name"]==""&&selected["uuid"]=="")return {};
    return selected.dump();
}
Json liveSourceCatalog(){return Json::parse(live_source_catalog_json);}
Json liveSourceCapabilities(){
    return {{"ndi",{{"supported",true},{"runtimeRequired",true}}},{"usb_webcam",{{"supported",true}}},{"syphon",{{"supported",
#ifdef __APPLE__
    true
#else
    false
#endif
    }}}};
}
std::filesystem::path liveSourceHelperPath(){
    char executable[8192]={};
#ifdef __APPLE__
    uint32_t length=sizeof(executable);if(_NSGetExecutablePath(executable,&length)!=0)return {};
#else
    auto count=readlink("/proc/self/exe",executable,sizeof(executable)-1);if(count<=0)return {};
#endif
    return std::filesystem::path(executable).parent_path()/"vj-source-discovery";
}
LiveSourceDiscovery::LiveSourceDiscovery(std::filesystem::path helper):helper_(std::move(helper)){}
Json LiveSourceDiscovery::capabilities()const{auto result=liveSourceCapabilities();for(auto& entry:result)entry["discoveryAvailable"]=entry["supported"].get<bool>()&&!helper_.empty()&&access(helper_.c_str(),X_OK)==0;return result;}
Json LiveSourceDiscovery::discover(const std::string& kind,const std::string& extraIPs){
    if(kind!="ndi"&&kind!="syphon"&&kind!="cameras")throw std::invalid_argument("Unknown source type");
#ifndef __APPLE__
    if(kind=="syphon")return unavailable("Syphon requires macOS");
#endif
    const auto extra=kind=="ndi"?normalizeNdiExtraIPs(extraIPs):std::string{};
    const auto key=kind+"\n"+extra;std::lock_guard lock(mutex_);auto it=cache_.find(key);
    if(it!=cache_.end()&&std::chrono::steady_clock::now()-it->second.updated<std::chrono::seconds(kind=="syphon"?2:3))return it->second.result;
    auto result=invoke(helper_,kind,extra);cache_[key]={result,std::chrono::steady_clock::now()};return result;
}
}
