#include "ndi_clients.hpp"
#include <boost/asio.hpp>
#include <boost/beast.hpp>
#include <boost/uuid/random_generator.hpp>
#include <boost/uuid/uuid_io.hpp>
#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <fstream>
#include <map>
#include <mutex>
#include <thread>
#include <set>
#include <sstream>
#include <stdexcept>
#include <cstring>
#include <cstdlib>
#include <cmath>
#include <cctype>
#include <dlfcn.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <poll.h>
#include <sys/resource.h>
#include <sys/statvfs.h>
#include <unistd.h>
#ifdef __APPLE__
#include <mach/mach.h>
#include <sys/sysctl.h>
#else
#include <sys/sysinfo.h>
#endif
namespace vj {
namespace {
using J=nlohmann::json;using Clock=std::chrono::steady_clock;
double epoch(){return std::chrono::duration<double>(std::chrono::system_clock::now().time_since_epoch()).count();}
bool uuid(const std::string& s){if(s.size()!=36)return false;for(size_t i=0;i<s.size();++i)if(i==8||i==13||i==18||i==23){if(s[i]!='-')return false;}else if(!std::isxdigit(static_cast<unsigned char>(s[i])))return false;return true;}
void require(bool condition,const char* message){if(!condition)throw std::invalid_argument(message);}
struct Endpoint {std::string host,port;};
Endpoint endpoint(const std::string& value){require(value.starts_with("http://")&&value.size()<2048,"Expected an HTTP receiver endpoint");auto authority=value.substr(7);if(authority.ends_with('/'))authority.pop_back();require(authority.find_first_of("/@?# \r\n\t") == std::string::npos&&!authority.empty(),"Invalid receiver endpoint");Endpoint out;if(authority.front()=='['){auto end=authority.find(']');require(end!=std::string::npos,"Invalid IPv6 endpoint");out.host=authority.substr(1,end-1);out.port=end+1==authority.size()?"80":authority.substr(end+2);require(end+1==authority.size()||authority[end+1]==':',"Invalid endpoint port");}else{auto colon=authority.rfind(':');out.host=authority.substr(0,colon);out.port=colon==std::string::npos?"80":authority.substr(colon+1);}require(!out.host.empty()&&!out.port.empty()&&out.port.size()<=5&&std::all_of(out.port.begin(),out.port.end(),[](unsigned char c){return std::isdigit(c);}),"Invalid endpoint");int port=std::stoi(out.port);require(port>0&&port<=65535,"Invalid endpoint port");return out;}
std::string boundedHost(const std::string& host,int seconds,const std::atomic<bool>& cancel);
std::string urlHost(std::string host){require(!host.empty()&&host.size()<253&&host.find_first_of("/@?# \r\n\t")==std::string::npos,"Invalid WLED host");if(host.find(':')!=std::string::npos&&!host.starts_with('['))host="["+host+"]";return "http://"+host;}
}
NdiClients::Json NdiClients::httpRequest(const std::string& base,const std::string& method,const std::string& path,const Json& body,int seconds,const std::atomic<bool>& cancel){
    require(path.starts_with('/')&&path.find_first_of("\r\n")==std::string::npos,"Invalid receiver path");auto target=endpoint(base);auto began=Clock::now();boost::system::error_code addressError;auto address=boost::asio::ip::make_address(target.host,addressError);if(addressError)address=boost::asio::ip::make_address(boundedHost(target.host,std::min(seconds,2),cancel));namespace asio=boost::asio;namespace beast=boost::beast;namespace http=beast::http;using tcp=asio::ip::tcp;
    asio::io_context io;beast::tcp_stream stream(io);std::array<tcp::endpoint,1> addresses={tcp::endpoint(address,static_cast<unsigned short>(std::stoi(target.port)))};asio::steady_timer timer(io);beast::flat_buffer buffer;http::request<http::string_body> request;http::response_parser<http::string_body> parser;parser.body_limit(262144);request.version(11);request.method_string(method);request.target(path);request.set(http::field::host,target.host+":"+target.port);request.set(http::field::user_agent,"VJNative/1");if(!body.is_null()&&!body.empty()){request.set(http::field::content_type,"application/json");request.body()=body.dump();request.prepare_payload();}
    bool done=false;std::string error;auto deadline=began+std::chrono::seconds(std::clamp(seconds,1,15));auto finish=[&](std::string message){if(done)return;done=true;error=std::move(message);timer.cancel();boost::system::error_code ignored;stream.socket().close(ignored);};
    std::function<void()> watchdog;watchdog=[&]{if(done)return;if(cancel||Clock::now()>=deadline){finish(cancel?"Cancelled":"Receiver HTTP timed out");return;}timer.expires_after(std::chrono::milliseconds(50));timer.async_wait([&](auto ec){if(!ec)watchdog();});};watchdog();
    if(!done)stream.async_connect(addresses,[&](auto ec,auto){if(done)return;if(ec){finish(ec.message());return;}http::async_write(stream,request,[&](auto ec,auto){if(done)return;if(ec){finish(ec.message());return;}http::async_read(stream,buffer,parser,[&](auto ec,auto){if(done)return;if(ec){finish(ec.message());return;}finish("");});});});
    io.run();if(!error.empty())throw std::runtime_error(error);auto response=parser.release();Json result=Json::parse(response.body());require(result.is_object(),"Invalid receiver response");if(response.result_int()>=300)throw std::runtime_error(result.value("error","Client HTTP "+std::to_string(response.result_int())));return result;
}
namespace {
// DNS-SD ABI is shared by Bonjour and Avahi's compatibility library. Keeping it
// dynamically loaded lets headless Linux builds work without desktop packages.
using Ref=void*;using Flags=uint32_t;using Err=int32_t;
using BrowseCB=void(*)(Ref,Flags,uint32_t,Err,const char*,const char*,const char*,void*);
using ResolveCB=void(*)(Ref,Flags,uint32_t,Err,const char*,const char*,uint16_t,uint16_t,const unsigned char*,void*);
using AddrCB=void(*)(Ref,Flags,uint32_t,Err,const char*,const sockaddr*,uint32_t,void*);
struct Bonjour {
 void* lib=nullptr;Err(*browse)(Ref*,Flags,uint32_t,const char*,const char*,BrowseCB,void*)=nullptr;Err(*resolve)(Ref*,Flags,uint32_t,const char*,const char*,const char*,ResolveCB,void*)=nullptr;Err(*address)(Ref*,Flags,uint32_t,uint32_t,const char*,AddrCB,void*)=nullptr;Err(*process)(Ref)=nullptr;int(*socket)(Ref)=nullptr;void(*release)(Ref)=nullptr;
 template<class T>void load(T& fn,const char* name){fn=reinterpret_cast<T>(dlsym(lib,name));if(!fn)throw std::runtime_error("Bonjour API unavailable");}
 Bonjour(){for(auto name:{"/usr/lib/libdns_sd.dylib","/usr/lib/system/libsystem_dnssd.dylib","libdns_sd.so.1","libdns_sd.so"}){lib=dlopen(name,RTLD_NOW|RTLD_LOCAL);if(lib)break;}if(!lib)throw std::runtime_error("Bonjour unavailable (DNS-SD library missing)");try{load(browse,"DNSServiceBrowse");load(resolve,"DNSServiceResolve");load(address,"DNSServiceGetAddrInfo");load(process,"DNSServiceProcessResult");load(socket,"DNSServiceRefSockFD");load(release,"DNSServiceRefDeallocate");}catch(...){dlclose(lib);lib=nullptr;throw;}}
 ~Bonjour(){if(lib)dlclose(lib);}
};
struct DiscoveryState {
 struct Node {DiscoveryState* owner;Ref ref=nullptr;std::string id;uint16_t port=0;};Bonjour api;bool wled=false;std::vector<std::unique_ptr<Node>> nodes;J found=J::array();std::set<std::string> seen;
 ~DiscoveryState(){for(auto& n:nodes)if(n->ref)api.release(n->ref);}
 Node* node(){if(nodes.size()>=128)return nullptr;nodes.push_back(std::make_unique<Node>());nodes.back()->owner=this;return nodes.back().get();}
 static void addressed(Ref,Flags flags,uint32_t,Err error,const char*,const sockaddr* address,uint32_t,void* context){if(error||!(flags&2)||!address||address->sa_family!=AF_INET)return;auto n=static_cast<Node*>(context);auto ipv4=reinterpret_cast<const sockaddr_in*>(address)->sin_addr;auto value=ntohl(ipv4.s_addr);if(value==0||(value&0xf0000000)==0xe0000000)return;char text[INET_ADDRSTRLEN];if(!inet_ntop(AF_INET,&ipv4,text,sizeof(text)))return;std::string url="http://"+std::string(text)+":"+std::to_string(n->port);if(n->owner->seen.insert(n->id+url).second)n->owner->found.push_back({{"id",n->id},{"url",url}});}
 static void resolved(Ref,Flags,uint32_t interface,Err error,const char*,const char* host,uint16_t port,uint16_t length,const unsigned char* data,void* context){if(error||!port)return;auto original=static_cast<Node*>(context);std::map<std::string,std::string> props;size_t at=0;while(at<length){size_t size=data[at++];if(size>length-at)return;std::string field(reinterpret_cast<const char*>(data+at),size);at+=size;auto eq=field.find('=');if(eq!=std::string::npos)props[field.substr(0,eq)]=field.substr(eq+1);}if(!original->owner->wled&&(props["version"]!="1"||!uuid(props["id"])))return;auto n=original->owner->node();if(!n)return;n->id=original->owner->wled?props["mac"]:props["id"];n->port=ntohs(port);if(n->owner->api.address(&n->ref,0,interface,1,host,addressed,n))n->ref=nullptr;}
 static void browsed(Ref,Flags flags,uint32_t interface,Err error,const char* name,const char* type,const char* domain,void* context){if(error||!(flags&2))return;auto owner=static_cast<DiscoveryState*>(context);auto n=owner->node();if(n&&owner->api.resolve(&n->ref,0,interface,name,type,domain,resolved,n))n->ref=nullptr;}
};
std::string boundedHost(const std::string& host,int seconds,const std::atomic<bool>& cancel){DiscoveryState state;auto n=state.node();n->port=80;if(state.api.address(&n->ref,0,0,1,host.c_str(),DiscoveryState::addressed,n))throw std::runtime_error("Hostname resolution unavailable");auto deadline=Clock::now()+std::chrono::seconds(std::clamp(seconds,1,3));while(!cancel&&Clock::now()<deadline){pollfd descriptor{state.api.socket(n->ref),POLLIN,0};if(::poll(&descriptor,1,50)>0&&(descriptor.revents&POLLIN)){if(state.api.process(n->ref))break;if(!state.found.empty())return endpoint(state.found[0].at("url")).host;}}throw std::runtime_error(cancel?"Cancelled":"Hostname resolution timed out");}
}
NdiClients::Json NdiClients::discover(int seconds,const std::atomic<bool>& cancel){DiscoveryState state;auto n=state.node();if(state.api.browse(&n->ref,0,0,"_vibe-ndi._tcp",nullptr,DiscoveryState::browsed,&state))throw std::runtime_error("Bonjour discovery could not start");auto deadline=Clock::now()+std::chrono::seconds(std::clamp(seconds,1,5));while(!cancel&&Clock::now()<deadline){std::vector<pollfd> sockets;std::vector<DiscoveryState::Node*> refs;for(auto& node:state.nodes)if(node->ref){int fd=state.api.socket(node->ref);if(fd>=0){sockets.push_back({fd,POLLIN,0});refs.push_back(node.get());}}if(::poll(sockets.data(),sockets.size(),50)>0)for(size_t i=0;i<sockets.size();++i)if(sockets[i].revents&POLLIN)if(state.api.process(refs[i]->ref)){state.api.release(refs[i]->ref);refs[i]->ref=nullptr;}}return state.found;}
struct NdiClients::Impl {
 std::filesystem::path file;Http http;Discovery discovery;Source source;mutable std::mutex mutex;std::mutex operations,lifecycle;std::condition_variable wake;std::thread worker;std::atomic<bool> cancel{false};J clients=J::object();std::map<std::string,std::vector<std::string>> endpoints;std::string master,error;bool running=false;
 Impl(std::filesystem::path path,Http h,Discovery d):file(std::move(path)),http(h?std::move(h):httpRequest),discovery(d?std::move(d):discover){J saved;try{std::ifstream stream(file);stream>>saved;}catch(...){}master=saved.is_object()?saved.value("master_id",std::string{}):"";if(!uuid(master))master=boost::uuids::to_string(boost::uuids::random_generator()());if(saved.is_object()&&saved.contains("clients")&&saved["clients"].is_object())for(auto it=saved["clients"].begin();it!=saved["clients"].end();++it)if(uuid(it.key())&&it.value().is_object()){clients[it.key()]=it.value();clients[it.key()]["online"]=false;}}
 void save(){J value;{std::lock_guard lock(mutex);value={{"master_id",master},{"clients",clients}};}try{std::filesystem::create_directories(file.parent_path());auto temp=file;temp+=".tmp";{std::ofstream stream(temp);stream<<value.dump(2);stream.flush();if(!stream)throw std::runtime_error("Unable to save receiver cache");}std::filesystem::rename(temp,file);}catch(const std::exception& e){std::lock_guard lock(mutex);error=std::string("Receiver cache unavailable: ")+e.what();}}
 void accept(const std::string& id,const J& data,const std::string& url){require(data.is_object()&&data.value("id",std::string{})==id&&data.value("version",0)==1,"Receiver identity mismatch");require(data.contains("inputs")&&data["inputs"].is_array()&&data["inputs"].size()<=4,"Invalid receiver inputs");std::set<std::string> inputs;for(auto& input:data["inputs"]){require(input.is_object(),"Invalid receiver input");auto key=input.value("id",std::string{});require((key=="display-1"||key=="display-2"||key=="display-3"||key=="display-4")&&inputs.insert(key).second,"Invalid receiver display");require(!input.contains("managed")||input["managed"].is_null()||input["managed"].is_object(),"Invalid receiver binding");}std::lock_guard lock(mutex);clients[id]=data;clients[id].update({{"online",true},{"url",url},{"settings_url",url+"/"},{"last_seen",epoch()}});}
 void discovered(const J& data){require(data.is_array()&&data.size()<=128,"Invalid receiver discovery");std::lock_guard lock(mutex);for(auto& item:data){auto id=item.at("id").get<std::string>(),url=item.at("url").get<std::string>();require(uuid(id),"Invalid receiver identity");endpoint(url);if(endpoints.size()>=256&&!endpoints.contains(id))continue;auto& list=endpoints[id];if(list.size()<8&&std::find(list.begin(),list.end(),url)==list.end())list.push_back(url);}}
 std::optional<std::string> feed(const std::string& projector,bool enable){Source callback;{std::lock_guard lock(mutex);callback=source;}if(!callback){if(enable)throw std::runtime_error("Projector publication service unavailable");return std::nullopt;}return callback(projector,enable);}
 void poll(){std::lock_guard serial(operations);std::map<std::string,std::vector<std::string>> addresses;{std::lock_guard lock(mutex);addresses=endpoints;for(auto it=clients.begin();it!=clients.end();++it)if(!addresses.contains(it.key())&&it->contains("url"))addresses[it.key()]={(*it)["url"]};}for(auto& [id,urls]:addresses){if(cancel)return;for(auto& url:urls){try{auto data=http(url,"GET","/api/v1/receiver",nullptr,3,cancel);accept(id,data,url);for(auto& input:data["inputs"]){auto binding=input.value("managed",J());if(!binding.is_object()||binding.value("master_id",std::string{})!=master)continue;auto source=feed(binding.value("projector",std::string{}),false);if(!source||*source==input.value("source",std::string{}))continue;try{auto result=http(url,"PUT","/api/v1/receiver/inputs/"+input.at("id").get<std::string>(),{{"source",*source},{"managed",binding},{"expected",binding}},3,cancel);accept(id,result,url);}catch(const std::exception& e){std::lock_guard lock(mutex);clients[id]["routing_error"]=e.what();}}break;}catch(const std::exception& e){std::lock_guard lock(mutex);if(clients.contains(id)){clients[id]["online"]=false;clients[id]["error"]=e.what();}else error=e.what();}}}save();}
 J assign(const std::string& id,const std::string& input,const J& raw){require(raw.is_object()&&(raw.contains("projector")||raw.contains("rotate_180")||raw.contains("buffer_ms")),"Expected projector, rotate_180, or buffer_ms");if(raw.contains("rotate_180"))require(raw["rotate_180"].is_boolean(),"rotate_180 must be boolean");if(raw.contains("buffer_ms"))require(raw["buffer_ms"].is_number_integer()&&raw["buffer_ms"]>=0&&raw["buffer_ms"]<=500,"buffer_ms must be an integer from 0 to 500");std::string projector;if(raw.contains("projector")&&!raw["projector"].is_null()){require(raw["projector"].is_string(),"Unknown projector");projector=raw["projector"];require(projector=="1"||projector=="2"||projector=="3"||projector=="4","Unknown projector");}
  std::lock_guard serial(operations);J client;{std::lock_guard lock(mutex);require(clients.contains(id)&&clients[id].value("online",false),"Client offline");client=clients[id];}bool exists=false;for(auto& item:client["inputs"])exists|=item["id"]==input;require(exists,"Unknown display input");J update=J::object();if(raw.contains("projector")){std::string selected;J binding=nullptr;if(!projector.empty()){auto source=feed(projector,true);auto deadline=Clock::now()+std::chrono::seconds(8);while((!source||source->empty())&&!cancel&&Clock::now()<deadline){std::this_thread::sleep_for(std::chrono::milliseconds(100));source=feed(projector,false);}if(cancel)throw std::runtime_error("Cancelled");if(!source||source->empty())throw std::runtime_error("Projector feed is not ready; check Published feeds");selected=*source;binding={{"master_id",master},{"projector",projector}};}update={{"source",selected},{"managed",binding}};}for(auto key:{"rotate_180","buffer_ms"})if(raw.contains(key))update[key]=raw[key];auto url=client.at("url").get<std::string>();auto data=http(url,"PUT","/api/v1/receiver/inputs/"+input,update,3,cancel);accept(id,data,url);save();std::lock_guard lock(mutex);return clients[id];
 }
};
NdiClients::NdiClients(std::filesystem::path path,Http http,Discovery discovery):impl_(std::make_unique<Impl>(std::move(path),std::move(http),std::move(discovery))){impl_->save();}
NdiClients::~NdiClients(){stop();}
void NdiClients::setSourceProvider(Source source){std::lock_guard lock(impl_->mutex);impl_->source=std::move(source);}
void NdiClients::start(){std::lock_guard lifecycle(impl_->lifecycle);std::lock_guard lock(impl_->mutex);if(impl_->running)return;impl_->cancel=false;impl_->running=true;impl_->worker=std::thread([this]{while(!impl_->cancel){try{impl_->discovered(impl_->discovery(2,impl_->cancel));}catch(const std::exception& e){std::lock_guard lock(impl_->mutex);impl_->error=e.what();}if(impl_->cancel)break;impl_->poll();std::unique_lock lock(impl_->mutex);impl_->wake.wait_for(lock,std::chrono::seconds(3),[&]{return impl_->cancel.load();});}});}
void NdiClients::stop(){std::lock_guard lifecycle(impl_->lifecycle);impl_->cancel=true;impl_->wake.notify_all();if(impl_->worker.joinable())impl_->worker.join();{std::lock_guard lock(impl_->mutex);impl_->running=false;}/* Local explicit commands may be used without continuous discovery. */impl_->cancel=false;}
void NdiClients::discovered(const Json& data){impl_->discovered(data);}
void NdiClients::poll(){impl_->poll();}
NdiClients::Json NdiClients::snapshot()const{std::lock_guard lock(impl_->mutex);J list=J::array();for(auto& client:impl_->clients)list.push_back(client);return {{"master_id",impl_->master},{"clients",list},{"error",impl_->error},{"discovering",impl_->running}};}
std::optional<NdiClients::Json> NdiClients::request(const std::string& method,const std::string& path,const Json& body){const std::string prefix="/api/v1/ndi/clients";if(path==prefix&&method=="GET")return snapshot();if(path==prefix+"/discover"&&method=="POST"){if(body.value("enabled",true))start();else stop();return snapshot();}if(!path.starts_with(prefix+"/"))return std::nullopt;auto tail=path.substr(prefix.size()+1);auto slash=tail.find('/');if(slash==std::string::npos)return std::nullopt;auto id=tail.substr(0,slash),action=tail.substr(slash+1);require(uuid(id),"Invalid receiver identity");if(action.starts_with("inputs/")&&method=="PUT")return impl_->assign(id,action.substr(7),body);if(action=="restart"&&method=="POST"){std::lock_guard serial(impl_->operations);std::string url;{std::lock_guard lock(impl_->mutex);require(impl_->clients.contains(id)&&impl_->clients[id].value("online",false),"Client offline");url=impl_->clients[id].at("url");}return impl_->http(url,"POST","/api/player/restart",nullptr,3,impl_->cancel);}return std::nullopt;}
struct NetworkDiagnostics::Impl {
 std::filesystem::path root;NdiClients::Http http;std::mutex mutex,scanMutex;std::atomic<bool> cancel{false};J sample;std::string sampledHost;Clock::time_point sampledAt{},cpuAt{};double previousTotal=0,previousIdle=0,previousProcess=0;J cachedStats,rendererKey;Clock::time_point statsAt{},rendererAt{};
 Impl(std::filesystem::path r,NdiClients::Http h):root(std::move(r)),http(h?std::move(h):NdiClients::httpRequest){}
};
NetworkDiagnostics::NetworkDiagnostics(std::filesystem::path root,NdiClients::Http http):impl_(std::make_unique<Impl>(std::move(root),std::move(http))){}
NetworkDiagnostics::~NetworkDiagnostics()=default;
NetworkDiagnostics::Json NetworkDiagnostics::discoverWled(const Json& configured){
 std::unique_lock scan(impl_->scanMutex,std::try_to_lock);
 if(!scan.owns_lock())throw std::runtime_error("WLED scan already running");
 J devices=J::array(),interfaces=J::array(),warnings=J::array();
 std::vector<std::string> candidates;std::set<std::string> seen;
 auto add=[&](const std::string& url){if(candidates.size()<512&&seen.insert(url).second)candidates.push_back(url);};
 auto host=configured.value("host",std::string{});
 if(!host.empty()&&host!="127.0.0.1")try{add(urlHost(host)+":80");}catch(...){}
 // WLED advertises its HTTP endpoint using _wled._tcp, including on USB Ethernet.
 try{
  DiscoveryState state;state.wled=true;auto n=state.node();
  auto error=state.api.browse(&n->ref,0,0,"_wled._tcp",nullptr,DiscoveryState::browsed,&state);
  if(error)throw std::runtime_error("WLED Bonjour discovery could not start ("+std::to_string(error)+"). Check VJ Local Network permission in System Settings.");
  auto deadline=Clock::now()+std::chrono::seconds(3);
  while(!impl_->cancel&&Clock::now()<deadline){
   std::vector<pollfd> sockets;std::vector<DiscoveryState::Node*> refs;
   for(auto& node:state.nodes)if(node->ref){int fd=state.api.socket(node->ref);if(fd>=0){sockets.push_back({fd,POLLIN,0});refs.push_back(node.get());}}
   if(::poll(sockets.data(),sockets.size(),50)>0)for(size_t i=0;i<sockets.size();++i)if(sockets[i].revents&POLLIN)if(state.api.process(refs[i]->ref)){state.api.release(refs[i]->ref);refs[i]->ref=nullptr;}
  }
  for(auto& found:state.found)add(found.at("url"));
 }catch(const std::exception& e){warnings.push_back(e.what());}
 // Probe bounded directly attached private ranges as a fallback for disabled mDNS.
 // Never sweep VPN, loopback, public networks or the entire link-local /16.
 ifaddrs* list=nullptr;
 if(getifaddrs(&list)==0){
  for(auto p=list;p;p=p->ifa_next){
   if(!p->ifa_addr||!p->ifa_netmask||p->ifa_addr->sa_family!=AF_INET||!(p->ifa_flags&IFF_UP)||!(p->ifa_flags&IFF_RUNNING)||(p->ifa_flags&(IFF_LOOPBACK|IFF_POINTOPOINT)))continue;
   uint32_t ip=ntohl(reinterpret_cast<sockaddr_in*>(p->ifa_addr)->sin_addr.s_addr),mask=ntohl(reinterpret_cast<sockaddr_in*>(p->ifa_netmask)->sin_addr.s_addr);
   char address[INET_ADDRSTRLEN];inet_ntop(AF_INET,&reinterpret_cast<sockaddr_in*>(p->ifa_addr)->sin_addr,address,sizeof(address));
   bool linkLocal=(ip&0xffff0000)==0xa9fe0000;
   J entry={{"name",p->ifa_name},{"address",address},{"linkLocal",linkLocal}};
   if(linkLocal){warnings.push_back(std::string(p->ifa_name)+" has a self-assigned address. A directly connected DHCP controller needs an address before it can be found.");interfaces.push_back(entry);continue;}
   bool privateIP=(ip&0xff000000)==0x0a000000||(ip&0xfff00000)==0xac100000||(ip&0xffff0000)==0xc0a80000;
   if(!privateIP)continue;
   uint32_t limitedMask=mask|0xffffff00,first=ip&limitedMask,last=first|~limitedMask;
   in_addr base{htonl(first)};char range[INET_ADDRSTRLEN];inet_ntop(AF_INET,&base,range,sizeof(range));
   entry["scanStart"]=range;entry["limitedToLocal24"]=(mask&0xffffff00)!=0xffffff00;interfaces.push_back(entry);
   for(uint32_t value=first+1;value<last;++value)if(value!=ip){in_addr candidate{htonl(value)};char text[INET_ADDRSTRLEN];inet_ntop(AF_INET,&candidate,text,sizeof(text));add("http://"+std::string(text)+":80");}
  }
  freeifaddrs(list);
 }
 std::atomic<size_t> next{0},probed{0};std::mutex resultMutex;
 auto deadline=Clock::now()+std::chrono::seconds(18);
 {
  std::vector<std::jthread> workers;
  for(size_t i=0;i<std::min<size_t>(32,candidates.size());++i)workers.emplace_back([&]{
   while(!impl_->cancel&&Clock::now()<deadline){
    auto index=next.fetch_add(1);if(index>=candidates.size())break;++probed;
    try{
     auto info=impl_->http(candidates[index],"GET","/json/info",nullptr,1,impl_->cancel);
     if(!info.contains("ver")||!info["ver"].is_string()||!info.value("leds",J()).is_object()||!info["leds"].value("count",J()).is_number_integer()||!info.value("udpport",J()).is_number_integer())continue;
     auto port=info["udpport"].get<int>();if(port<1||port>65535)continue;
     auto target=endpoint(candidates[index]);
     J device={{"host",target.host},{"httpPort",std::stoi(target.port)},{"port",port},{"name",info.value("name",J()).is_string()?info["name"]:J(target.host)},{"version",info["ver"]},{"ledCount",info["leds"]["count"]},{"mac",info.value("mac",J())},{"url",candidates[index]+"/"},{"online",true}};
     std::lock_guard lock(resultMutex);devices.push_back(device);
   }catch(const std::exception& e){
    // Preserve the configured endpoint's error; closed fallback ports are expected.
    if(index==0&&!host.empty()&&host!="127.0.0.1"){std::lock_guard lock(resultMutex);warnings.push_back("Configured WLED "+host+": "+e.what());}
   }
   }
  });
 }
 std::sort(devices.begin(),devices.end(),[](const J& a,const J& b){return a.at("host").get<std::string>()<b.at("host").get<std::string>();});
 if(devices.empty())warnings.push_back("No WLED controller responded. Check power, cable, and IP configuration; a direct cable has no DHCP server unless one is configured.");
 return {{"devices",devices},{"interfaces",interfaces},{"warnings",warnings},{"probed",probed.load()},{"candidates",candidates.size()},{"complete",probed.load()==candidates.size()},{"checkedAt",epoch()}};
}
NetworkDiagnostics::Json NetworkDiagnostics::network(const Json& wled,const Json& fixtures,int serverPort,bool probe){std::lock_guard lock(impl_->mutex);std::string host=wled.value("host",std::string{}),url;try{url=urlHost(host);}catch(...){}auto now=Clock::now();if(impl_->sample.is_null()||impl_->sampledHost!=host||(probe&&now-impl_->sampledAt>=std::chrono::seconds(5))){impl_->sample={{"online",false},{"checkedAt",nullptr},{"latencyMs",nullptr},{"error",probe?J():J("Not probed")},{"name",nullptr},{"version",nullptr},{"ip",nullptr},{"ledCount",nullptr}};impl_->sampledHost=host;if(probe){impl_->sample["checkedAt"]=epoch();try{require(!url.empty(),"WLED host unavailable");auto started=Clock::now();auto info=impl_->http(url,"GET","/json/info",nullptr,2,impl_->cancel);require(info.contains("ver")&&info.contains("leds")&&info["leds"].is_object(),"Response is not WLED device information");impl_->sample.update({{"online",true},{"name",info.value("name",J())},{"version",info["ver"]},{"ip",info.value("ip",J())},{"ledCount",info["leds"].value("count",J())},{"latencyMs",std::round(std::chrono::duration<double,std::milli>(Clock::now()-started).count()*10)/10}});}catch(const std::exception& e){impl_->sample["error"]=e.what();}impl_->sampledAt=Clock::now();}}
 char hostname[256]={};gethostname(hostname,sizeof(hostname)-1);std::map<std::string,J> interfaces;ifaddrs* list=nullptr;if(getifaddrs(&list)==0){for(auto p=list;p;p=p->ifa_next){if(!p->ifa_name)continue;auto& item=interfaces[p->ifa_name];if(item.is_null())item={{"name",p->ifa_name},{"up",bool(p->ifa_flags&IFF_UP)},{"addresses",J::array()}};if(!p->ifa_addr)continue;int family=p->ifa_addr->sa_family;char address[INET6_ADDRSTRLEN];const void* data=family==AF_INET?static_cast<const void*>(&reinterpret_cast<sockaddr_in*>(p->ifa_addr)->sin_addr):family==AF_INET6?static_cast<const void*>(&reinterpret_cast<sockaddr_in6*>(p->ifa_addr)->sin6_addr):nullptr;if(data&&inet_ntop(family,data,address,sizeof(address)))item["addresses"].push_back(address);}freeifaddrs(list);}J interfaceList=J::array();for(auto& [name,value]:interfaces)interfaceList.push_back(value);J fixtureList=J::array();if(fixtures.is_array())for(auto& f:fixtures)if(f.value("kind",std::string{})=="wled")fixtureList.push_back({{"id",f.value("id",J())},{"label",f.value("label",J())},{"enabled",f.value("enabled",false)},{"start",f.value("start",0)},{"count",f.value("count",0)}});J status=impl_->sample;status.update({{"host",host},{"url",url+"/"},{"infoUrl",url+"/json/info"},{"transport","DNRGB/UDP"},{"udpPort",wled.value("port",21324)},{"transportError",wled.value("error",std::string{})},{"sampleAgeSeconds",impl_->sample["checkedAt"].is_null()?J():J(std::chrono::duration<double>(Clock::now()-impl_->sampledAt).count())},{"fixtures",fixtureList}});return {{"apiVersion",1},{"hostname",hostname},{"serverPort",serverPort},{"interfaces",interfaceList},{"wled",status}};
}
NetworkDiagnostics::Json NetworkDiagnostics::stats(int activeOutputs,const Json& renderer){std::lock_guard lock(impl_->mutex);auto now=Clock::now();if(impl_->cachedStats.is_null()||now-impl_->statsAt>=std::chrono::seconds(1)){
 double total=0,idle=0,uptime=0;uint64_t memoryTotal=0,memoryAvailable=0,swapTotal=0,swapUsed=0,rss=0;unsigned threads=0;long cpus=sysconf(_SC_NPROCESSORS_ONLN);
#ifdef __APPLE__
 host_cpu_load_info_data_t cpuTicks{};mach_msg_type_number_t count=HOST_CPU_LOAD_INFO_COUNT;if(host_statistics(mach_host_self(),HOST_CPU_LOAD_INFO,reinterpret_cast<host_info_t>(&cpuTicks),&count)==KERN_SUCCESS){for(auto ticks:cpuTicks.cpu_ticks)total+=ticks;idle=cpuTicks.cpu_ticks[CPU_STATE_IDLE];}
 size_t size=sizeof(memoryTotal);sysctlbyname("hw.memsize",&memoryTotal,&size,nullptr,0);vm_statistics64_data_t vm{};count=HOST_VM_INFO64_COUNT;vm_size_t page=0;host_page_size(mach_host_self(),&page);if(host_statistics64(mach_host_self(),HOST_VM_INFO64,reinterpret_cast<host_info64_t>(&vm),&count)==KERN_SUCCESS)memoryAvailable=uint64_t(vm.free_count+vm.inactive_count+vm.speculative_count)*page;
 xsw_usage swap{};size=sizeof(swap);if(sysctlbyname("vm.swapusage",&swap,&size,nullptr,0)==0){swapTotal=swap.xsu_total;swapUsed=swap.xsu_used;}timeval boot{};size=sizeof(boot);int mib[]={CTL_KERN,KERN_BOOTTIME};if(sysctl(mib,2,&boot,&size,nullptr,0)==0)uptime=epoch()-boot.tv_sec;
 mach_task_basic_info_data_t task{};count=MACH_TASK_BASIC_INFO_COUNT;if(task_info(mach_task_self(),MACH_TASK_BASIC_INFO,reinterpret_cast<task_info_t>(&task),&count)==KERN_SUCCESS)rss=task.resident_size;thread_act_array_t ports=nullptr;mach_msg_type_number_t n=0;if(task_threads(mach_task_self(),&ports,&n)==KERN_SUCCESS){threads=n;for(unsigned i=0;i<n;i++)mach_port_deallocate(mach_task_self(),ports[i]);vm_deallocate(mach_task_self(),reinterpret_cast<vm_address_t>(ports),n*sizeof(thread_t));}
#else
 std::ifstream cpuFile("/proc/stat");std::string line;std::getline(cpuFile,line);std::istringstream fields(line);std::string label;fields>>label;double ticks=0;int i=0;while(fields>>ticks){if(i<8)total+=ticks;if(i==3||i==4)idle+=ticks;++i;}
 struct sysinfo info{};if(sysinfo(&info)==0){memoryTotal=uint64_t(info.totalram)*info.mem_unit;memoryAvailable=uint64_t(info.freeram+info.bufferram)*info.mem_unit;swapTotal=uint64_t(info.totalswap)*info.mem_unit;swapUsed=uint64_t(info.totalswap-info.freeswap)*info.mem_unit;uptime=info.uptime;}std::ifstream mem("/proc/meminfo");while(std::getline(mem,line)){std::istringstream f(line);std::string key;uint64_t value;if(f>>key>>value&&key=="MemAvailable:")memoryAvailable=value*1024;}
 std::ifstream statm("/proc/self/statm");uint64_t virtualPages=0,residentPages=0;if(statm>>virtualPages>>residentPages)rss=residentPages*sysconf(_SC_PAGESIZE);std::ifstream status("/proc/self/status");while(std::getline(status,line))if(line.starts_with("Threads:")){std::istringstream f(line.substr(8));f>>threads;}
#endif
 J cpu=nullptr;if(impl_->previousTotal>0&&total>impl_->previousTotal)cpu=std::clamp(100*(1-(idle-impl_->previousIdle)/(total-impl_->previousTotal)),0.,100.);impl_->previousTotal=total;impl_->previousIdle=idle;
 rusage usage{};getrusage(RUSAGE_SELF,&usage);double process=usage.ru_utime.tv_sec+usage.ru_utime.tv_usec/1e6+usage.ru_stime.tv_sec+usage.ru_stime.tv_usec/1e6;J processCpu=nullptr;if(impl_->cpuAt!=Clock::time_point{})processCpu=std::max(0.,100*(process-impl_->previousProcess)/std::chrono::duration<double>(now-impl_->cpuAt).count());impl_->previousProcess=process;impl_->cpuAt=now;
 double loads[3]={};J loadAverage=nullptr;if(getloadavg(loads,3)==3)loadAverage={loads[0],loads[1],loads[2]};J disk={{"totalBytes",nullptr},{"freeBytes",nullptr},{"usedPercent",nullptr}};struct statvfs filesystem{};if(statvfs(impl_->root.c_str(),&filesystem)==0){uint64_t bytes=uint64_t(filesystem.f_blocks)*filesystem.f_frsize,free=uint64_t(filesystem.f_bavail)*filesystem.f_frsize;disk={{"totalBytes",bytes},{"freeBytes",free},{"usedPercent",bytes?100.*(bytes-free)/bytes:0}};}
 impl_->cachedStats={{"sampledAt",epoch()},{"system",{{"cpuPercent",cpu},{"logicalCpus",cpus},{"loadAverage",loadAverage},{"memory",{{"totalBytes",memoryTotal},{"availableBytes",memoryAvailable},{"usedPercent",memoryTotal?100.*(memoryTotal-std::min(memoryTotal,memoryAvailable))/memoryTotal:0}}},{"swap",{{"totalBytes",swapTotal},{"usedBytes",swapUsed}}},{"disk",disk},{"uptimeSeconds",uptime},{"gpuUtilizationPercent",nullptr}}},{"processes",J::array({{{"pid",getpid()},{"name","VJNative"},{"role","server"},{"cpuPercent",processCpu},{"rssBytes",rss},{"threads",threads}}})}};impl_->statsAt=now;
 }
 auto result=impl_->cachedStats;result["apiVersion"]=1;result["activeOutputs"]=activeOutputs;auto key=renderer.value("sequence",J(renderer));if(!renderer.empty()&&key!=impl_->rendererKey){impl_->rendererKey=key;impl_->rendererAt=now;}J age=impl_->rendererAt==Clock::time_point{}?J():J(std::chrono::duration<double>(now-impl_->rendererAt).count());result["renderer"]={{"connected",!renderer.empty()},{"stale",renderer.empty()||age.is_null()||age.get<double>()>5},{"sampleAgeSeconds",age},{"metrics",renderer.empty()?J():renderer}};return result;
}
}
