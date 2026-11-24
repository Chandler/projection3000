#include "removable_media.hpp"
#include "media_library.hpp"
#include "api_error.hpp"
#include <algorithm>
#include <array>
#include <chrono>
#include <fstream>
#include <iomanip>
#include <map>
#include <mutex>
#include <sstream>
#ifdef __APPLE__
#include <sys/mount.h>
#include <sys/attr.h>
#include <unistd.h>
#include <uuid/uuid.h>
#else
#include <mntent.h>
#endif
namespace vj {
namespace fs=std::filesystem;using Json=nlohmann::json;
namespace {
std::string sha256(const std::vector<uint8_t>& bytes){
    constexpr uint32_t constants[]={0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2};
    std::array<uint32_t,8> state={0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19};auto data=bytes;const uint64_t bits=static_cast<uint64_t>(data.size())*8;data.push_back(0x80);while(data.size()%64!=56)data.push_back(0);for(int i=7;i>=0;--i)data.push_back(static_cast<uint8_t>(bits>>(i*8)));auto rotate=[](uint32_t x,int n){return (x>>n)|(x<<(32-n));};
    for(size_t offset=0;offset<data.size();offset+=64){uint32_t words[64];for(int i=0;i<16;++i)words[i]=(uint32_t(data[offset+i*4])<<24)|(uint32_t(data[offset+i*4+1])<<16)|(uint32_t(data[offset+i*4+2])<<8)|data[offset+i*4+3];for(int i=16;i<64;++i){auto a=words[i-15],b=words[i-2];words[i]=words[i-16]+(rotate(a,7)^rotate(a,18)^(a>>3))+words[i-7]+(rotate(b,17)^rotate(b,19)^(b>>10));}auto a=state[0],b=state[1],c=state[2],d=state[3],e=state[4],f=state[5],g=state[6],h=state[7];for(int i=0;i<64;++i){const auto first=h+(rotate(e,6)^rotate(e,11)^rotate(e,25))+((e&f)^(~e&g))+constants[i]+words[i];const auto second=(rotate(a,2)^rotate(a,13)^rotate(a,22))+((a&b)^(a&c)^(b&c));h=g;g=f;f=e;e=d+first;d=c;c=b;b=a;a=first+second;}state[0]+=a;state[1]+=b;state[2]+=c;state[3]+=d;state[4]+=e;state[5]+=f;state[6]+=g;state[7]+=h;}
    std::ostringstream result;for(auto value:state)result<<std::hex<<std::setfill('0')<<std::setw(8)<<value;return result.str();
}

std::string lower(std::string value){for(auto& c:value)c=std::tolower((unsigned char)c);return value;}
std::string encode(const std::string& value){const char* digits="0123456789ABCDEF";std::string out;for(unsigned char c:value){if(std::isalnum(c)||c=='/'||c=='-'||c=='_'||c=='.'||c=='~')out+=c;else{out+='%';out+=digits[c>>4];out+=digits[c&15];}}return out;}
std::string decode(const std::string& text){std::string out;auto digit=[](char c){return c>='0'&&c<='9'?c-'0':c>='A'&&c<='F'?c-'A'+10:c>='a'&&c<='f'?c-'a'+10:-1;};for(size_t i=0;i<text.size();++i){unsigned char c=text[i];if(c=='%'){if(i+2>=text.size()||digit(text[i+1])<0||digit(text[i+2])<0)throw ApiError(400,"Invalid media reference");c=digit(text[i+1])*16+digit(text[i+2]);i+=2;}if(!c)throw ApiError(400,"Invalid media reference");out+=char(c);}return out;}
fs::path contained(const fs::path& root,std::string relative){if(relative.size()>16384||relative.find(char(0))!=std::string::npos)throw ApiError(400,"Invalid media path");std::replace(relative.begin(),relative.end(),'\\','/');while(relative.starts_with('/'))relative.erase(0,1);auto canonicalRoot=fs::weakly_canonical(root),path=fs::weakly_canonical(canonicalRoot/relative);auto a=canonicalRoot.begin(),b=path.begin();for(;a!=canonicalRoot.end();++a,++b)if(b==path.end()||*a!=*b)throw ApiError(403,"Path leaves the media drive");return path;}
std::vector<MediaDrive> discover(){std::vector<MediaDrive> result;
#ifdef __APPLE__
    struct statfs* mounts=nullptr;int count=getmntinfo(&mounts,MNT_NOWAIT);
    for(int i=0;i<count;++i){fs::path mount=mounts[i].f_mntonname;if(!mount.string().starts_with("/Volumes/")||std::string(mounts[i].f_fstypename)=="autofs")continue;
        std::string identity=mount.string();struct attrlist attributes{};attributes.bitmapcount=ATTR_BIT_MAP_COUNT;attributes.volattr=ATTR_VOL_INFO|ATTR_VOL_UUID;struct {uint32_t length;uuid_t uuid;} data{};
        if(getattrlist(mount.c_str(),&attributes,&data,sizeof(data),0)==0&&!uuid_is_null(data.uuid)){char uuid[37];uuid_unparse_upper(data.uuid,uuid);identity=uuid;}
        result.push_back({mount.filename().string(),"mac:"+identity,mount});}
#else
    FILE* table=setmntent("/proc/mounts","r");if(table){while(auto* entry=getmntent(table)){fs::path mount=entry->mnt_dir;auto text=mount.string();if(std::string(entry->mnt_type)=="autofs"||!(text.starts_with("/media/")||text.starts_with("/run/media/")||text.starts_with("/mnt/")))continue;std::string identity="linux-mount:"+text;
        std::error_code error;auto device=fs::weakly_canonical(entry->mnt_fsname,error);if(!error)for(fs::directory_iterator it("/dev/disk/by-uuid",error),end;it!=end&&!error;it.increment(error))if(fs::weakly_canonical(it->path(),error)==device){identity="linux:"+it->path().filename().string();break;}
        result.push_back({mount.filename().string(),identity,mount});}endmntent(table);}
#endif
    return result;
}
}
struct RemovableMedia::Impl {Discovery discovery;std::mutex mutex;std::map<std::string,MediaDrive> drives;std::chrono::steady_clock::time_point scanned{};explicit Impl(Discovery d):discovery(d?std::move(d):discover){}void scan(bool force){auto now=std::chrono::steady_clock::now();if(!force&&now-scanned<std::chrono::seconds(2))return;std::map<std::string,MediaDrive> next;for(auto drive:discovery())next[RemovableMedia::driveId(drive.identity)]=std::move(drive);drives=std::move(next);scanned=now;}MediaDrive drive(const std::string& id){std::lock_guard lock(mutex);scan(false);if(!drives.contains(id))scan(true);if(!drives.contains(id))throw ApiError(404,"The removable drive is no longer mounted");return drives.at(id);}};
RemovableMedia::RemovableMedia(Discovery discovery):impl_(std::make_unique<Impl>(std::move(discovery))){}
RemovableMedia::~RemovableMedia()=default;
std::string RemovableMedia::driveId(const std::string& identity){return sha256(std::vector<uint8_t>(identity.begin(),identity.end())).substr(0,20);}
Json RemovableMedia::drives(bool force){std::lock_guard lock(impl_->mutex);impl_->scan(force);Json list=Json::array();for(auto& [id,drive]:impl_->drives)list.push_back({{"id",id},{"name",drive.name}});std::sort(list.begin(),list.end(),[](auto& a,auto& b){return lower(a.at("name"))<lower(b.at("name"));});return list;}
Json RemovableMedia::browseDirectory(const fs::path& root,const std::string& id,const std::string& name,const std::string& relative,const std::string& scheme){auto directory=contained(root,relative);if(!fs::is_directory(directory))throw ApiError(404,"Media folder unavailable");auto rel=directory.lexically_relative(fs::weakly_canonical(root)).generic_string();if(rel==".")rel="";Json entries=Json::array();std::error_code error;
    for(fs::directory_iterator it(directory,error),end;it!=end&&!error;it.increment(error)){auto filename=it->path().filename().string();if(filename.empty()||filename[0]=='.')continue;auto child=rel.empty()?filename:rel+"/"+filename;fs::path path;try{path=contained(root,child);}catch(...){continue;}if(fs::is_directory(path,error)){entries.push_back({{"name",filename},{"type","directory"},{"path",child}});continue;}auto type=MediaLibrary::kind(path);if(type.empty()||!fs::is_regular_file(path,error))continue;auto reference=scheme+encode(child);auto size=fs::file_size(path,error);entries.push_back({{"name",filename},{"type",type},{"path",child},{"size",error?0:size},{"ref",reference},{"file",reference},{"origin",name},{"available",true}});}
    if(error)throw ApiError(403,"Media folder is unreadable");std::sort(entries.begin(),entries.end(),[](auto& a,auto& b){return lower(a.at("name"))<lower(b.at("name"));});return {{"drive",{{"id",id},{"name",name}}},{"path",rel},{"parent",fs::path(rel).parent_path().generic_string()},{"entries",entries}};
}
Json RemovableMedia::browse(const std::string& id,const std::string& relative){auto drive=impl_->drive(id);return browseDirectory(drive.mount,id,drive.name,relative,"removable://"+id+"/");}
fs::path RemovableMedia::resolve(const std::string& reference){if(!reference.starts_with("removable://"))throw ApiError(400,"Invalid removable reference");auto tail=reference.substr(12);auto slash=tail.find('/');if(slash==std::string::npos)throw ApiError(400,"Invalid removable reference");auto drive=impl_->drive(tail.substr(0,slash));return contained(drive.mount,decode(tail.substr(slash+1)));}
RemovableMedia& removableMedia(){static RemovableMedia media;return media;}
}
