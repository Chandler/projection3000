#include "module_registry.hpp"
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <map>
#include <random>
#include <set>
#include <sstream>
#include <stdexcept>
#include <unistd.h>
#include <fcntl.h>
namespace vj {
namespace {
using Json=nlohmann::json;namespace fs=std::filesystem;
constexpr size_t maxModule=2*1024*1024;
std::mutex validatorMutex;VectorModuleValidator validator;
struct RegistryError:std::runtime_error {int status;Json detail;RegistryError(int code,const std::string& message,Json extra=Json::object()):std::runtime_error(message),status(code),detail(std::move(extra)){};};
void require(bool value,const char* message){if(!value)throw RegistryError(400,message);}
bool idValid(const std::string& value){return value.size()==64&&value.find_first_not_of("0123456789abcdef")==std::string::npos;}
bool parameterName(const std::string& value){return !value.empty()&&value.size()<=40&&value[0]>='a'&&value[0]<='z'&&value.find_first_not_of("abcdefghijklmnopqrstuvwxyz0123456789_")==std::string::npos;}
double number(const Json& value){require(value.is_number(),"Expected a finite number");const auto n=value.get<double>();require(std::isfinite(n)&&std::abs(n)<=1e30,"Expected a finite number");return n;}
std::string truncate(std::string value,size_t limit){size_t count=0,i=0;while(i<value.size()&&count<limit){unsigned char c=value[i];size_t bytes=c<128?1:(c&0xe0)==0xc0?2:(c&0xf0)==0xe0?3:4;i=std::min(value.size(),i+bytes);++count;}value.resize(i);return value;}
std::string string(const Json& value){if(value.is_string())return value.get<std::string>();if(value.is_null())return "None";if(value==true)return "True";if(value==false)return "False";return value.dump();}
// SHA-256 for immutable content identities; avoids platform-specific crypto dependencies.
std::string sha256(const std::vector<uint8_t>& bytes){
    constexpr uint32_t constants[]={0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2};
    std::array<uint32_t,8> state={0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19};auto data=bytes;const uint64_t bits=static_cast<uint64_t>(data.size())*8;data.push_back(0x80);while(data.size()%64!=56)data.push_back(0);for(int i=7;i>=0;--i)data.push_back(static_cast<uint8_t>(bits>>(i*8)));auto rotate=[](uint32_t x,int n){return (x>>n)|(x<<(32-n));};
    for(size_t offset=0;offset<data.size();offset+=64){uint32_t words[64];for(int i=0;i<16;++i)words[i]=(uint32_t(data[offset+i*4])<<24)|(uint32_t(data[offset+i*4+1])<<16)|(uint32_t(data[offset+i*4+2])<<8)|data[offset+i*4+3];for(int i=16;i<64;++i){auto a=words[i-15],b=words[i-2];words[i]=words[i-16]+(rotate(a,7)^rotate(a,18)^(a>>3))+words[i-7]+(rotate(b,17)^rotate(b,19)^(b>>10));}auto a=state[0],b=state[1],c=state[2],d=state[3],e=state[4],f=state[5],g=state[6],h=state[7];for(int i=0;i<64;++i){const auto first=h+(rotate(e,6)^rotate(e,11)^rotate(e,25))+((e&f)^(~e&g))+constants[i]+words[i];const auto second=(rotate(a,2)^rotate(a,13)^rotate(a,22))+((a&b)^(a&c)^(b&c));h=g;g=f;f=e;e=d+first;d=c;c=b;b=a;a=first+second;}state[0]+=a;state[1]+=b;state[2]+=c;state[3]+=d;state[4]+=e;state[5]+=f;state[6]+=g;state[7]+=h;}
    std::ostringstream result;for(auto value:state)result<<std::hex<<std::setfill('0')<<std::setw(8)<<value;return result.str();
}
// Python json.dumps(sort_keys=True) uses spaces and fixed notation through 1e15.
// Preserve that canonical byte form so imported original modules keep their identity.
std::string manifestBytes(const Json& value){
    if(value.is_object()){
        std::string result="{";bool first=true;
        for(auto it=value.begin();it!=value.end();++it){if(!first)result+=", ";first=false;result+=Json(it.key()).dump(-1,' ',true)+": "+manifestBytes(it.value());}
        return result+"}";
    }
    if(value.is_array()){
        std::string result="[";bool first=true;
        for(const auto& item:value){if(!first)result+=", ";first=false;result+=manifestBytes(item);}
        return result+"]";
    }
    auto result=value.dump(-1,' ',true);
    if(value.is_number_float()){
        const auto marker=result.find('e');
        if(marker!=std::string::npos){
            const int exponent=std::stoi(result.substr(marker+1));
            if(exponent>=0&&exponent<16){
                auto digits=result.substr(0,marker);const bool negative=digits.starts_with('-');
                if(negative)digits.erase(0,1);const auto point=digits.find('.');
                if(point!=std::string::npos)digits.erase(point,1);
                const auto decimal=static_cast<size_t>(exponent+1);
                if(digits.size()<=decimal){digits.append(decimal-digits.size(),'0');digits+=".0";}
                else digits.insert(decimal,".");
                result=(negative?"-":"")+digits;
            }
        }
    }
    return result;
}
std::vector<uint8_t> decodeBase64(const std::string& value){require(value.size()<=maxModule*2,"Upload too large");require(value.size()%4==0,"Invalid base64 module");std::vector<uint8_t> result;result.reserve(value.size()/4*3);auto digit=[](char c){if(c>='A'&&c<='Z')return c-'A';if(c>='a'&&c<='z')return c-'a'+26;if(c>='0'&&c<='9')return c-'0'+52;if(c=='+')return 62;if(c=='/')return 63;return -1;};for(size_t i=0;i<value.size();i+=4){const int a=digit(value[i]),b=digit(value[i+1]),c=value[i+2]=='='?0:digit(value[i+2]),d=value[i+3]=='='?0:digit(value[i+3]);require(a>=0&&b>=0&&c>=0&&d>=0,"Invalid base64 module");const bool last=i+4==value.size();require((value[i+2]!='='&&value[i+3]!='=')||last,"Invalid base64 padding");require(value[i+2]!='='||value[i+3]=='=',"Invalid base64 padding");result.push_back((a<<2)|(b>>4));if(value[i+2]!='=')result.push_back((b<<4)|(c>>2));if(value[i+3]!='=')result.push_back((c<<6)|d);}return result;}
void publish(const fs::path& path,const std::vector<uint8_t>& bytes){fs::create_directories(path.parent_path());auto pattern=(path.parent_path()/".module-XXXXXX").string();std::vector<char> name(pattern.begin(),pattern.end());name.push_back('\0');int fd=mkstemp(name.data());if(fd<0)throw std::runtime_error("Cannot create animation file");try{size_t offset=0;while(offset<bytes.size()){const auto written=write(fd,bytes.data()+offset,bytes.size()-offset);if(written<0&&errno==EINTR)continue;if(written<=0)throw std::runtime_error("Cannot write animation file");offset+=written;}if(fsync(fd)!=0)throw std::runtime_error("Cannot sync animation file");close(fd);fd=-1;fs::rename(name.data(),path);
        // The rename commits the entry. Do not throw after that point: callers
        // must advance their in-memory pointer even if a filesystem cannot sync directories.
        const int directory=open(path.parent_path().c_str(),O_RDONLY|O_DIRECTORY);
        if(directory>=0){while(fsync(directory)<0&&errno==EINTR){}close(directory);}}catch(...){if(fd>=0)close(fd);unlink(name.data());throw;}}
std::vector<uint8_t> readModule(const fs::path& path){require(fs::is_regular_file(path),"Module file is unavailable");require(fs::file_size(path)<=maxModule,"Module exceeds 2 MiB");std::ifstream input(path,std::ios::binary);require(static_cast<bool>(input),"Cannot read module file");return std::vector<uint8_t>(std::istreambuf_iterator<char>(input),{});}
}
void installVectorModuleValidator(VectorModuleValidator value){std::lock_guard lock(validatorMutex);validator=std::move(value);}
bool vectorModuleValidatorAvailable(){std::lock_guard lock(validatorMutex);return static_cast<bool>(validator);}
Json ModuleRegistry::checkedManifest(const Json& raw){
    require(raw.is_object(),"manifest must be an object");const auto name=raw.value("name",Json());require(name.is_string(),"name must have 1–100 characters");const auto label=name.get<std::string>();require(!label.empty()&&truncate(label,100)==label,"name must have 1–100 characters");const auto abi=raw.value("abi",Json(1));require(abi.is_number_integer()&&(abi==1||abi==2),"abi must be 1 or 2");require(raw.contains("parameters"),"manifest.parameters is required; use [] for an effect with no controls");const auto& parameters=raw["parameters"];require(parameters.is_array()&&parameters.size()<=64,"parameters must be a list of at most 64 numeric controls");Json clean=Json::array();std::set<std::string> names;
    for(const auto& p:parameters){require(p.is_object()&&p.contains("name")&&p["name"].is_string(),"Invalid parameter name");const auto key=p["name"].get<std::string>();require(parameterName(key),"parameter names must match [a-z][a-z0-9_]{0,39}");const double lo=number(p.at("min")),hi=number(p.at("max")),value=number(p.at("default")),step=number(p.value("step",Json(.01)));require(lo<=value&&value<=hi&&step>0&&names.insert(key).second,"Invalid parameter range, step, or duplicate name");clean.push_back({{"name",key},{"label",truncate(string(p.value("label",Json(key))),100)},{"min",lo},{"max",hi},{"default",value},{"step",step}});}
    const auto cap=raw.value("lineCap",Json("round"));require(cap=="round"||cap=="butt","lineCap must be round or butt");return {{"name",label},{"abi",abi},{"description",truncate(string(raw.value("description",Json("External animation"))),2000)},{"parameters",clean},{"lineCap",cap}};
}
Json ModuleRegistry::normalizeParameters(const Json& manifest,const Json& values){Json result=Json::object();for(const auto& p:manifest.at("parameters")){const auto key=p["name"].get<std::string>();double value=p["default"];if(values.is_object()&&values.contains(key)){try{value=number(values[key]);}catch(...){}}result[key]=std::clamp(value,p["min"].get<double>(),p["max"].get<double>());}return result;}
ModuleRegistry::ModuleRegistry(fs::path root){
    require(!root.empty(),"Native registry root must not be empty");root_=fs::absolute(std::move(root));
    fs::create_directories(root_);reloadFromDisk();
}
void ModuleRegistry::reloadFromDisk(){
    std::lock_guard lock(mutex_);entries_=Json::object();warnings_=Json::array();for(const auto& file:fs::directory_iterator(root_)){if(file.path().extension()!=".json")continue;try{Json entry;std::ifstream input(file.path());input>>entry;const auto id=entry.at("id").get<std::string>();require(idValid(id),"Invalid animation id");entry["manifest"]=checkedManifest(entry.at("manifest"));if(!entry.contains("revision"))entry["revision"]=1;const auto path=modulePathUnlocked(entry);require(fs::is_regular_file(path),"Animation module is missing");if(!entry.contains("contentHash")){auto bytes=readModule(path);const auto manifest=manifestBytes(entry["manifest"]);bytes.insert(bytes.end(),manifest.begin(),manifest.end());entry["contentHash"]=sha256(bytes);}entries_[id]=entry;}catch(const std::exception& error){warnings_.push_back({{"file",file.path().filename().string()},{"error",error.what()}});}}
}
fs::path ModuleRegistry::modulePathUnlocked(const Json& entry,const std::string& requested)const{const auto id=entry.at("id").get<std::string>();require(idValid(id),"Invalid animation id");const auto version=requested.empty()?(entry.value("moduleVersion",Json()).is_null()?std::string{}:entry.at("moduleVersion").get<std::string>()):requested;require(version.empty()||idValid(version),"Invalid module version");const auto path=version.empty()?root_/(id+".wasm"):root_/id/(version+".wasm");const auto root=fs::weakly_canonical(root_),candidate=fs::weakly_canonical(path);auto a=root.begin(),b=candidate.begin();for(;a!=root.end();++a,++b)require(b!=candidate.end()&&*a==*b,"Module path escapes native registry");return candidate;}
fs::path ModuleRegistry::modulePath(const std::string& id,const std::string& version)const{std::lock_guard lock(mutex_);if(!entries_.contains(id))throw RegistryError(404,"Unknown uploaded animation");const auto path=modulePathUnlocked(entries_[id],version);if(!fs::is_regular_file(path))throw RegistryError(404,"Animation module is missing");return path;}
Json ModuleRegistry::history()const{std::lock_guard lock(mutex_);Json result=Json::array();for(const auto& entry:entries_)result.push_back(entry);return {{"animations",result}};}
Json ModuleRegistry::diagnostics()const{std::lock_guard lock(mutex_);return {{"validationAvailable",vectorModuleValidatorAvailable()},{"warnings",warnings_},{"count",entries_.size()}};}
Json ModuleRegistry::catalog()const{std::lock_guard lock(mutex_);Json result=Json::array();for(auto it=entries_.begin();it!=entries_.end();++it){const auto& entry=it.value();const auto& manifest=entry["manifest"];Json parameters=Json::array(),performance=Json::array();for(auto parameter:manifest["parameters"]){parameter["kind"]="float";parameters.push_back(parameter);if(performance.size()<8)performance.push_back(parameter["name"]);}result.push_back({{"name","external_"+it.key()},{"label",manifest["name"]},{"description",manifest["description"]},{"kind","vector"},{"collectionGeometry",nullptr},{"adjustment",false},{"vector",true},{"liveSource",false},{"exclusive",false},{"rasterizedWhenStacked",true},{"defaultBlend","normal"},{"parameters",parameters},{"performanceParameters",performance},{"animationId",it.key()},{"animation","/api/v1/animations/"+it.key()},{"wasm","/api/v1/animations/"+it.key()+"/wasm"}});}return result;}
Json ModuleRegistry::normalize(const std::string& effect,const Json& params)const{std::lock_guard lock(mutex_);const auto id=effect.starts_with("external_")?effect.substr(9):effect;if(!entries_.contains(id))throw RegistryError(404,"Unknown uploaded animation");return normalizeParameters(entries_[id]["manifest"],params);}
Json ModuleRegistry::recipe(const std::string& effect,const Json& params,int width,int height)const{std::lock_guard lock(mutex_);const auto id=effect.starts_with("external_")?effect.substr(9):effect;if(!entries_.contains(id))throw RegistryError(404,"Unknown uploaded animation");const auto& entry=entries_[id];const auto& m=entry["manifest"];const auto normalized=normalizeParameters(m,params);Json values=Json::array();for(const auto& p:m["parameters"])values.push_back(normalized[p["name"].get<std::string>()]);return {{"format",m["abi"]==1?"vibe-vector/1":"vibe-graphics/2"},{"abi",m["abi"]},{"module",entry["module"]},{"effect","external_"+id},{"lineCap",m["lineCap"]},{"canvas",{width,height}},{"paramValues",values}};}
RegistryReply ModuleRegistry::upload(std::vector<uint8_t> bytes,const Json& raw,const std::string& requested,std::optional<uint64_t> revision){
    require(bytes.size()>=8&&bytes.size()<=maxModule&&std::memcmp(bytes.data(),"\0asm\1\0\0\0",8)==0,"Expected a WebAssembly module, at most 2 MiB");const auto manifest=checkedManifest(raw);
    VectorModuleValidator callback;{std::lock_guard lock(validatorMutex);callback=validator;}if(!callback)throw RegistryError(501,"WASM validation is unavailable on this build");
    {std::lock_guard lock(mutex_);if(!requested.empty()){if(!entries_.contains(requested))throw RegistryError(404,"Unknown uploaded animation");if(!revision||*revision!=entries_[requested]["revision"].get<uint64_t>())throw RegistryError(409,"Fetch the animation and supply its current revision",{{"revision",entries_[requested]["revision"]}});}}
    callback(bytes,manifest);auto hashed=bytes;const auto serialized=manifestBytes(manifest);hashed.insert(hashed.end(),serialized.begin(),serialized.end());const auto hash=sha256(hashed);
    std::lock_guard lock(mutex_);Json previous=Json::object();std::string id=requested;
    if(!id.empty()){if(!entries_.contains(id))throw RegistryError(404,"Unknown uploaded animation");previous=entries_[id];if(!revision||*revision!=previous["revision"].get<uint64_t>())throw RegistryError(409,"Fetch the animation and supply its current revision",{{"revision",previous["revision"]}});if(previous["contentHash"]==hash)return {200,previous,{}};}
    else{for(const auto& entry:entries_)if(entry["contentHash"]==hash)return {201,entry,{}};id=hash;if(entries_.contains(id)){std::random_device random;std::vector<uint8_t> salt(32);for(auto& byte:salt)byte=random();id=sha256(salt);}}
    const double now=std::chrono::duration<double>(std::chrono::system_clock::now().time_since_epoch()).count();auto entry=previous;entry.update({{"id",id},{"effect","external_"+id},{"manifest",manifest},{"createdAt",previous.value("createdAt",now)},{"updatedAt",now},{"revision",previous.value("revision",uint64_t(0))+1},{"contentHash",hash},{"moduleVersion",hash},{"module","/vector/modules/external/"+id+"/"+hash+".wasm"}});if(entry.contains("lastParams"))entry["lastParams"]=normalizeParameters(manifest,entry["lastParams"]);
    const auto module=modulePathUnlocked(entry);if(!fs::is_regular_file(module))publish(module,bytes);const auto metadata=entry.dump();publish(root_/(id+".json"),std::vector<uint8_t>(metadata.begin(),metadata.end()));entries_[id]=entry;return {requested.empty()?201:200,entry,entry["effect"]};
}
RegistryReply ModuleRegistry::importLocal(const fs::path& file,const Json& manifest,const std::string& id,std::optional<uint64_t> revision){return upload(readModule(file),manifest,id,revision);}
std::optional<RegistryReply> ModuleRegistry::request(const std::string& method,const std::string& path,const Json& body){
    if(!path.starts_with("/api/v1/animations"))return std::nullopt;
    try{
        const std::string prefix="/api/v1/animations";const auto suffix=path.substr(prefix.size());
        if(suffix.empty()&&method=="GET")return RegistryReply{200,history(),{}};
        const auto id=suffix.empty()?std::string{}:suffix.substr(1);
        if(!suffix.empty()&&(!suffix.starts_with("/")||id.find('/')!=std::string::npos))return std::nullopt;
        if(method=="GET"){std::lock_guard lock(mutex_);if(!entries_.contains(id))throw RegistryError(404,"Unknown uploaded animation");return RegistryReply{200,entries_[id],{}};}
        if((method=="POST"&&id.empty())||(method=="PUT"&&!id.empty())){std::optional<uint64_t> revision;if(body.contains("revision")&&body["revision"].is_number_integer()&&body["revision"].get<int64_t>()>=0)revision=body["revision"].get<uint64_t>();require(body.is_object(),"Expected a JSON object");return upload(decodeBase64(body.at("wasmBase64").get<std::string>()),body.at("manifest"),id,revision);}
        return std::nullopt;
    }catch(const RegistryError& error){auto body=error.detail;body["error"]=error.what();return RegistryReply{error.status,body,{}};}
    catch(const std::exception& error){return RegistryReply{400,{{"error",error.what()}},{}};}
}
}
