#include "fixture_output.hpp"
#include "control_model.hpp"
#include "api_error.hpp"
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstring>
#include <cstdlib>
#include <deque>
#include <dlfcn.h>
#include <fcntl.h>
#include <mutex>
#include <set>
#include <thread>
#include <stdexcept>
#include <sys/socket.h>
#include <netdb.h>
#include <arpa/inet.h>
#include <unistd.h>
#ifdef __APPLE__
#include <mach-o/dyld.h>
#include <filesystem>
#endif
namespace vj {
namespace {
double now(){return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();}
double wall(){return std::chrono::duration<double>(std::chrono::system_clock::now().time_since_epoch()).count();}
void check(bool value,const std::string& reason){if(!value)throw ApiError(400,reason);}
std::string token(){static std::atomic<unsigned long> sequence=0;return std::to_string(getpid())+":"+std::to_string(now())+":"+std::to_string(++sequence);}
Json transportDefaults(){return {{"requested",false},{"activationToken",""},{"scanToken",""},{"commandToken",""},{"action","set"},{"motor","all"}};}
Json wledDefaults(){return {{"host","127.0.0.1"},{"port",21324},{"requested",false},{"activationToken",""}};}
Json withDefaults(Json value,const Json& defaults){if(!value.is_object())value=Json::object();for(auto i=defaults.begin();i!=defaults.end();++i)if(!value.contains(i.key()))value[i.key()]=i.value();return value;}
struct UsbDescriptor {uint8_t length,type;uint16_t usb;uint8_t cls,sub,protocol,packet;uint16_t vendor,product,version;uint8_t manufacturer,name,serial,configs;};
static_assert(sizeof(UsbDescriptor)==18);
class SoundSwitch final:public DmxTransport {
 void* library_=nullptr;void* context_=nullptr;void* handle_=nullptr;
 int(*init_)(void**)=nullptr;ssize_t(*getList_)(void*,void***)=nullptr;int(*descriptor_)(void*,UsbDescriptor*)=nullptr;int(*open_)(void*,void**)=nullptr;int(*string_)(void*,uint8_t,unsigned char*,int)=nullptr;int(*configuration_)(void*,int*)=nullptr;int(*claim_)(void*,int)=nullptr;int(*release_)(void*,int)=nullptr;int(*bulk_)(void*,unsigned char,unsigned char*,int,int*,unsigned int)=nullptr;void(*close_)(void*)=nullptr;void(*freeList_)(void**,int)=nullptr;void(*exit_)(void*)=nullptr;const char*(*error_)(int)=nullptr;
 template<class T> void loadSymbol(T& target,const char* name){target=reinterpret_cast<T>(dlsym(library_,name));if(!target)throw std::runtime_error(std::string("Missing libusb symbol ")+name);}
 void checked(int result){if(result<0)throw std::runtime_error(error_?error_(result):"USB error");}
 void initialize(){if(context_)return;try{if(!library_){std::vector<std::string> candidates;if(const char* path=getenv("VJ_LIBUSB_PATH"))candidates.emplace_back(path);
#if defined(__APPLE__)
 char executablePath[4096]{};uint32_t size=sizeof(executablePath);if(_NSGetExecutablePath(executablePath,&size)==0){auto frameworks=std::filesystem::path(executablePath).parent_path().parent_path()/"Frameworks";for(const auto* library:{"libusb-1.0.0.dylib","libusb-1.0.dylib"})candidates.push_back((frameworks/library).string());}
 candidates.insert(candidates.end(),{"libusb-1.0.dylib","/opt/homebrew/lib/libusb-1.0.dylib","/usr/local/lib/libusb-1.0.dylib","/Applications/TouchDesigner.app/Contents/Frameworks/libusb-1.0.0.dylib"});
#else
 candidates.insert(candidates.end(),{"libusb-1.0.so.0","libusb-1.0.so"});
#endif
 for(auto& path:candidates){library_=dlopen(path.c_str(),RTLD_NOW|RTLD_LOCAL);if(library_)break;}if(!library_)throw std::runtime_error("libusb unavailable; install libusb or set VJ_LIBUSB_PATH");
 loadSymbol(init_,"libusb_init");loadSymbol(getList_,"libusb_get_device_list");loadSymbol(descriptor_,"libusb_get_device_descriptor");loadSymbol(open_,"libusb_open");loadSymbol(string_,"libusb_get_string_descriptor_ascii");loadSymbol(configuration_,"libusb_get_configuration");loadSymbol(claim_,"libusb_claim_interface");loadSymbol(release_,"libusb_release_interface");loadSymbol(bulk_,"libusb_bulk_transfer");loadSymbol(close_,"libusb_close");loadSymbol(freeList_,"libusb_free_device_list");loadSymbol(exit_,"libusb_exit");loadSymbol(error_,"libusb_error_name");}checked(init_(&context_));}catch(...){close();throw;}}
 void packet(std::vector<uint8_t> data){if(!handle_)throw std::runtime_error("USB adapter disconnected");int sent=0;checked(bulk_(handle_,1,data.data(),int(data.size()),&sent,250));if(sent!=int(data.size()))throw std::runtime_error("Incomplete DMX USB transfer");}
 Json devices(const std::string& serial,bool connect){initialize();void** devices=nullptr;ssize_t count=getList_(context_,&devices);if(count<0)checked(int(count));Json found=Json::array();try{for(ssize_t i=0;i<count;i++){UsbDescriptor desc{};if(descriptor_(devices[i],&desc)<0||desc.vendor!=0x15e4||desc.product!=0x0053)continue;void* handle=nullptr;int result=open_(devices[i],&handle);Json item={{"name","SoundSwitch DMX Micro Interface"},{"vid","15e4"},{"pid","0053"},{"serial",""},{"available",result==0}};if(result==0){try{unsigned char buffer[256]{};int size=string_(handle,desc.serial,buffer,255);if(size>=0)item["serial"]=std::string(reinterpret_cast<char*>(buffer),size);if(connect&&(serial.empty()||item["serial"]==serial)){int config=0;checked(configuration_(handle,&config));if(config!=1)throw std::runtime_error("Unexpected USB configuration");checked(claim_(handle,0));handle_=handle;handle=nullptr;packet({0x73,0x54,0x52,0x74,0x02,0x00,0x04,0x00,0x00,0x00,0x01,0x00});packet({0x73,0x54,0x52,0x74,0x02,0x00,0x04,0x00,0x01,0x00,0xff,0xff});freeList_(devices,1);return item;}}catch(...){if(handle)close_(handle);throw;}if(handle)close_(handle);}found.push_back(item);}}catch(...){freeList_(devices,1);throw;}freeList_(devices,1);if(connect)throw std::runtime_error("SoundSwitch adapter unavailable; scan and reconnect");return found;}
public:
 ~SoundSwitch()override{close();}
 Json scan()override{try{auto result=devices("",false);close();return result;}catch(...){close();throw;}}
 Json connect(const std::string& serial)override{close();try{return devices(serial,true);}catch(...){close();throw;}}
 void write(const std::array<uint8_t,512>& universe)override{std::vector<uint8_t> data={0x73,0x54,0x52,0x74,0x01,0x00,0x02,0x02,0x00,0x00};data.insert(data.end(),universe.begin(),universe.end());packet(std::move(data));}
 void close()override{if(handle_){if(release_)release_(handle_,0);if(close_)close_(handle_);handle_=nullptr;}if(context_){if(exit_)exit_(context_);context_=nullptr;}if(library_){dlclose(library_);library_=nullptr;}}
};
class Wled final:public LedTransport {
 struct Resolver {std::mutex mutex;bool resolving=false,valid=false;double next=0;sockaddr_in address{};std::string error;};
 std::shared_ptr<Resolver> resolver_=std::make_shared<Resolver>();std::string host_;int port_=0,socket_=-1;double socketRetry_=0;std::string socketError_;
 void resolve(){auto state=resolver_;std::string host=host_;int port=port_;{std::lock_guard lock(state->mutex);if(state->resolving||now()<state->next)return;state->resolving=true;}
  std::thread([state,host,port]{addrinfo hints{};hints.ai_family=AF_INET;hints.ai_socktype=SOCK_DGRAM;addrinfo* info=nullptr;int result=getaddrinfo(host.c_str(),std::to_string(port).c_str(),&hints,&info);{std::lock_guard lock(state->mutex);if(result==0&&info){state->address=*reinterpret_cast<sockaddr_in*>(info->ai_addr);state->valid=true;state->error.clear();state->next=now()+60;}else {state->error=gai_strerror(result);state->next=now()+5;}state->resolving=false;}if(info)freeaddrinfo(info);}).detach();
 }
public:
 ~Wled()override{close();}
 void configure(const std::string& host,int port)override{close();host_=host;port_=port;resolver_=std::make_shared<Resolver>();resolver_->address.sin_family=AF_INET;resolver_->address.sin_port=htons(port);if(inet_pton(AF_INET,host.c_str(),&resolver_->address.sin_addr)==1){resolver_->valid=true;resolver_->next=INFINITY;}socketRetry_=0;socketError_.clear();}
 bool send(int start,const std::vector<uint8_t>& rgb)override{auto data=wledPacket(start,rgb);if(host_.empty())throw std::runtime_error("WLED host not configured");resolve();sockaddr_in address{};{std::lock_guard lock(resolver_->mutex);if(!resolver_->valid)return false;address=resolver_->address;}
  if(socket_<0){if(now()<socketRetry_)return false;socket_=::socket(AF_INET,SOCK_DGRAM,0);if(socket_<0){socketError_=strerror(errno);socketRetry_=now()+5;return false;}if(fcntl(socket_,F_SETFL,fcntl(socket_,F_GETFL)|O_NONBLOCK)<0){socketError_=strerror(errno);::close(socket_);socket_=-1;socketRetry_=now()+5;return false;}}
  auto size=sendto(socket_,data.data(),data.size(),0,reinterpret_cast<const sockaddr*>(&address),sizeof(address));if(size!=ssize_t(data.size())){socketError_=size<0?strerror(errno):"Incomplete WLED UDP packet";::close(socket_);socket_=-1;socketRetry_=now()+5;return false;}socketError_.clear();return true;
 }
 Json status()const override{std::lock_guard lock(resolver_->mutex);return {{"host",host_},{"port",port_},{"resolved",resolver_->valid},{"resolving",resolver_->resolving},{"error",socketError_.empty()?resolver_->error:socketError_}};}
 void close()override{if(socket_>=0){::close(socket_);socket_=-1;}host_.clear();port_=0;resolver_=std::make_shared<Resolver>();}
};
// Smooth host trajectories follow dmx_motion.Motion, independent from UI polls.
class Motion {
 double last_=0,phase_=0,changed_=0;std::string pattern_;double size_=-1;std::array<double,2> offset_{},origin_{};
public:
 Json sample(const Json& controls,double time){auto c=controls;if(last_!=0)phase_=std::fmod(phase_+std::max(0.,time-last_)*2*M_PI*(.05+.95*c.value("motion_speed",.15)),2*M_PI);last_=time;auto pattern=c.value("motion",std::string("off"));double size=c.value("motion_size",.2);if(pattern!=pattern_||size!=size_){origin_=offset_;changed_=time;pattern_=pattern;size_=size;}double radius=size*.25,pan=c.value("pan",.5),tilt=c.value("tilt",.5),w=std::min({radius,pan,1-pan}),h=std::min({radius,tilt,1-tilt}),x=0,y=0;if(pattern=="circle"){x=w*std::cos(phase_);y=h*std::sin(phase_);}if(pattern=="pan"||pattern=="figure_eight")x=w*std::sin(phase_);if(pattern=="tilt")y=h*std::sin(phase_);if(pattern=="figure_eight")y=h*std::sin(phase_*2);double t=std::clamp((time-changed_)/.6,0.,1.),blend=t*t*(3-2*t);offset_={origin_[0]+(x-origin_[0])*blend,origin_[1]+(y-origin_[1])*blend};c["pan"]=std::clamp(pan+offset_[0],0.,1.);c["tilt"]=std::clamp(tilt+offset_[1],0.,1.);if(pattern!="off"||(t<1&&(origin_[0]||origin_[1])))c["movement_speed"]=1.;return c;}
};
}
std::unique_ptr<DmxTransport> makeSoundSwitchTransport(){return std::make_unique<SoundSwitch>();}
std::unique_ptr<LedTransport> makeWledTransport(){return std::make_unique<Wled>();}
std::vector<uint8_t> wledPacket(int start,const std::vector<uint8_t>& rgb){check(start>=0&&start<=65535,"WLED start must be 0..65535");check(rgb.size()%3==0,"WLED RGB frame must have three bytes per pixel");check(start+rgb.size()/3<=65536,"WLED range exceeds 65536 pixels");check(rgb.size()+4<=65507,"WLED fixture exceeds UDP payload limit");std::vector<uint8_t> packet={4,2,uint8_t(start>>8),uint8_t(start&255)};packet.insert(packet.end(),rgb.begin(),rgb.end());return packet;}
void initializeFixtureOutput(Json& d){if(!d.contains("controls"))resetControlRuntime(d);auto& c=d["controls"];c["fixtureOutput"]=withDefaults(c.value("fixtureOutput",Json::object()),wledDefaults());c["dmx"]["transport"]=withDefaults(c["dmx"].value("transport",Json::object()),transportDefaults());}
Json fixtureOutputSnapshot(const Json& d){auto c=d.value("controls",Json::object());auto config=withDefaults(c.value("fixtureOutput",Json::object()),wledDefaults());auto transport=withDefaults(c.value("dmx",Json::object()).value("transport",Json::object()),transportDefaults());return {{"fixtureOutput",config},{"dmxTransport",transport}};}
std::optional<Json> fixtureOutputRequest(Json& d,const std::string& method,const std::string& path,const Json& incoming,const Json& runtime){
 if(path!="/api/v1/fixture-output"&&path!="/api/v1/dmx")return std::nullopt;initializeFixtureOutput(d);auto body=incoming;if(body.is_object())body.erase("revision");auto& config=d["controls"]["fixtureOutput"];auto& transport=d["controls"]["dmx"]["transport"];auto dmxRuntime=runtime.value("dmx",Json::object());
 if(path=="/api/v1/fixture-output"){
  if(method=="GET"){auto result=config;result.update(runtime.value("fixtureOutput",Json::object()));return result;}
  check(method=="POST"||method=="PUT"||method=="PATCH","Use POST, PUT or PATCH");check(body.is_object(),"Expected an object");for(auto i=body.begin();i!=body.end();++i)check(std::set<std::string>{"action","host","port"}.contains(i.key()),"Unknown fixture output field");auto action=body.value("action",std::string("set"));check(action=="set"||action=="start"||action=="stop","Unknown fixture output action");auto host=body.value("host",config["host"]),port=body.value("port",config["port"]);check(host.is_string()&&!host.get<std::string>().empty()&&host.get<std::string>().size()<=253&&host.get<std::string>().find_first_of(" \t\r\n") == std::string::npos,"Invalid WLED host");check(port.is_number_integer()&&port.get<int>()>=1&&port.get<int>()<=65535,"port must be 1..65535");auto ledRuntime=runtime.value("fixtureOutput",Json::object());bool pending=config.value("activationToken",std::string{})!=ledRuntime.value("acknowledgedToken",std::string{});if((ledRuntime.value("active",false)||(config.value("requested",false)&&pending))&&action!="stop")check(config["host"]==host&&config["port"]==port,"Stop WLED before changing destination");config["host"]=host;config["port"]=port;if(action=="start"||action=="stop"){config["requested"]=action=="start";config["activationToken"]=token();}return config;
 }
 if(method=="GET"){auto result=controlSnapshot(d)["dmx"];result.update(dmxRuntime);return result;}
 check(method=="POST"||method=="PATCH","Use POST or PATCH");check(body.is_object(),"Expected an object");auto action=body.value("action",std::string("set"));if(action=="scan"){check(body.size()==1,"scan only accepts action");check(!dmxRuntime.value("connected",false)&&dmxRuntime.value("status",std::string{})!="connecting","Disconnect before scanning adapters");transport["scanToken"]=token();return controlSnapshot(d)["dmx"];}
 auto status=dmxRuntime.value("status",std::string("disconnected"));bool pending=transport.value("activationToken",std::string{})!=dmxRuntime.value("acknowledgedToken",std::string{});bool active=(transport.value("requested",false)&&pending)||status=="connected"||status=="connecting"||status=="disconnecting";if(active)for(auto field:{"address","mode","serial"})if(body.contains(field))check(body[field]==d["controls"]["dmx"][field],"Disconnect before changing adapter, address, or mode");
 check(std::set<std::string>{"set","connect","disconnect","identify","flash","blackout","reset"}.contains(action),"Unknown DMX action");if(action=="identify"||action=="flash"||action=="reset")check(dmxRuntime.value("connected",false),"Connect the adapter first");if(action=="reset"){auto motor=body.value("motor",std::string("all"));check(motor=="all"||motor=="pan_tilt"||motor=="zoom","Unknown motor");check(body.value("controls",Json::object()).value("blackout",d["controls"]["dmx"]["controls"]["blackout"])==true,"Blackout before resetting motors");}
 auto validated=body;validated["action"]=action=="reset"?"disconnect":(action=="disconnect"||action=="blackout")?action:"set";bool program=body.value("controls",Json::object()).value("program",std::string("off"))!="off";if((action=="disconnect"||action=="reset"||program)&&dmxRuntime.contains("target")){if(!validated.contains("controls"))validated["controls"]=Json::object();validated["controls"]["pan"]=dmxRuntime["target"]["pan"];validated["controls"]["tilt"]=dmxRuntime["target"]["tilt"];}requestControl(d,method,path,validated);
 auto& changedTransport=d["controls"]["dmx"]["transport"];
 if(action=="connect"||action=="disconnect"){changedTransport["requested"]=action=="connect";changedTransport["activationToken"]=token();}
 if(action!="set"||(body.contains("controls")&&body["controls"].value("blackout",false))){bool forceBlackout=body.value("controls",Json::object()).value("blackout",false);changedTransport["action"]=forceBlackout&&action!="reset"?"blackout":action=="set"?"blackout":action;changedTransport["motor"]=body.value("motor",std::string("all"));changedTransport["commandToken"]=token();}auto result=controlSnapshot(d)["dmx"];result.update(dmxRuntime);return result;
}
struct FixtureOutputRuntime::Impl {
 FixtureOutputCallbacks cb;std::unique_ptr<DmxTransport> dmx;std::unique_ptr<LedTransport> led;std::jthread worker;std::mutex mutex;std::condition_variable wake;FixtureFrames frames;std::atomic<double> framesAt{0};uint64_t frameSequence=0,consumed=0;
 std::string dmxToken,scanToken,commandToken,wledToken;bool dmxActive=false,wledActive=false;double warmup=0,identifyUntil=0,flashUntil=0,resetUntil=0,lastReport=0;int resetValue=0;uint64_t dmxFrames=0,wledPackets=0;double lastDmxSent=0,lastLedSent=0;Json device,devices=Json::array(),dmxSettings,dmxEffective,dmxStatus=Json::object(),ledStatus=Json::object(),sentStatus;std::string dmxError,ledError;Motion motion;
 struct Segment {int start=0;size_t size=0;};std::map<std::string,Segment> lastSegments;
 Impl(FixtureOutputCallbacks c,std::unique_ptr<DmxTransport> d,std::unique_ptr<LedTransport> l):cb(std::move(c)),dmx(std::move(d)),led(std::move(l)){}
 void blackoutDmx(){if(!dmxActive)return;try{auto controls=dmxEffective.empty()?dmxSettings["controls"]:dmxEffective;controls["blackout"]=true;controls["motion"]="off";auto frame=dmxUniverse(controls,dmxSettings.value("address",1),dmxSettings.value("mode",15));for(int i=0;i<3;i++){try{dmx->write(frame);}catch(...){break;}std::this_thread::sleep_for(std::chrono::milliseconds(25));}}catch(...){};}
 void closeDmx(bool blackout=true){if(blackout)blackoutDmx();dmx->close();dmxActive=false;device=Json();identifyUntil=flashUntil=resetUntil=0;motion=Motion();}
 void blackoutLed(){if(!wledActive)return;for(auto& [id,segment]:lastSegments)try{led->send(segment.start,std::vector<uint8_t>(segment.size,0));}catch(...){}lastSegments.clear();}
 void closeLed(){blackoutLed();led->close();wledActive=false;}
 void report(bool force=false){if(!force&&now()-lastReport<.25)return;lastReport=now();Json d={{"transportAvailable",true},{"connected",dmxActive&&now()>=warmup},{"status",!dmxError.empty()?"error":dmxActive?(now()<warmup?"connecting":"connected"):"disconnected"},{"error",dmxError},{"device",device},{"devices",devices},{"frames",dmxFrames},{"last_sent",lastDmxSent?Json(lastDmxSent):Json()},{"identify",dmxActive&&now()<identifyUntil},{"flash",dmxActive&&now()<flashUntil},{"requested",dmxActive},{"acknowledgedToken",dmxToken}};if(!dmxEffective.empty()){d["target"]={{"pan",dmxEffective["pan"]},{"tilt",dmxEffective["tilt"]}};auto frame=dmxUniverse(dmxEffective,dmxSettings.value("address",1),dmxSettings.value("mode",15),now()>=warmup&&now()<identifyUntil,now()>=warmup&&now()<flashUntil,now()<resetUntil?resetValue:0);Json channels=Json::array();for(int i=dmxSettings.value("address",1)-1;i<dmxSettings.value("address",1)-1+dmxSettings.value("mode",15);i++)channels.push_back(frame[i]);d["channels"]=channels;}Json l=led->status();l["activeHost"]=l.value("host",Json());l["activePort"]=l.value("port",Json());l.erase("host");l.erase("port");l.update({{"available",true},{"active",wledActive},{"acknowledgedToken",wledToken},{"status",(!ledError.empty()||!l.value("error",std::string{}).empty())?"error":wledActive?"active":"off"},{"packets",wledPackets},{"last_sent",lastLedSent?Json(lastLedSent):Json()},{"stale",wledActive&&now()-framesAt>.5}});if(!ledError.empty())l["error"]=ledError;if(d!=dmxStatus){dmxStatus=d;cb.status("dmx",d);}if(l!=ledStatus){ledStatus=l;cb.status("fixtureOutput",l);}}
 void tickDmx(const Json& state,double time){
  auto settings=state.at("dmx");auto t=state.at("dmxTransport");auto activation=t.value("activationToken",std::string{});if(activation!=dmxToken){dmxToken=activation;if(t.value("requested",false)){if(dmxActive)closeDmx();dmxError.clear();dmxSettings=settings;device=dmx->connect(settings.value("serial",std::string{}));dmxActive=true;dmxFrames=0;lastDmxSent=0;warmup=time+1.5;motion=Motion();}else {closeDmx();dmxError.clear();}}
  auto scan=t.value("scanToken",std::string{});if(scan!=scanToken){scanToken=scan;if(!dmxActive){devices=dmx->scan();dmxError.clear();}}
  auto command=t.value("commandToken",std::string{});if(command!=commandToken){commandToken=command;auto action=t.value("action",std::string("set"));if(action=="identify"&&dmxActive&&time>=warmup){identifyUntil=time+3;flashUntil=resetUntil=0;}if(action=="flash"&&dmxActive&&time>=warmup){flashUntil=time+.25;identifyUntil=resetUntil=0;}if(action=="blackout"||action=="disconnect"){identifyUntil=flashUntil=resetUntil=0;}if(action=="reset"&&dmxActive&&time>=warmup){auto motor=t.value("motor",std::string("all"));resetValue=motor=="pan_tilt"?85:motor=="zoom"?97:80;resetUntil=time+3;identifyUntil=flashUntil=0;motion=Motion();}}
  if(!dmxSettings.empty()&&settings["controls"].value("program",std::string("off"))!="off"&&settings["controls"].value("program",std::string("off"))!=dmxSettings["controls"].value("program",std::string("off")))motion=Motion();dmxSettings=settings;if(!dmxActive)return;dmxEffective=motion.sample(settings.at("controls"),time);if(time<warmup)dmxEffective["blackout"]=true;
  if(!settings["controls"].value("blackout",false))resetUntil=0;
  auto frame=dmxUniverse(dmxEffective,settings.value("address",1),settings.value("mode",15),time>=warmup&&time<identifyUntil,time>=warmup&&time<flashUntil,time<resetUntil?resetValue:0);dmx->write(frame);dmxFrames++;lastDmxSent=wall();
 }
 void tickLed(const Json& state,double time){
  const auto config=state.at("fixtureOutput");auto activation=config.value("activationToken",std::string{});if(activation!=wledToken){wledToken=activation;closeLed();ledError.clear();if(config.value("requested",false)){led->configure(config.value("host",std::string("127.0.0.1")),config.value("port",21324));wledActive=true;consumed=0;wledPackets=0;lastLedSent=0;}}
  if(!wledActive)return;FixtureFrames latest;uint64_t sequence;double received;{std::lock_guard lock(mutex);sequence=frameSequence;received=framesAt;if(sequence!=consumed)latest=frames;}
  bool stale=time-received>.5;std::map<std::string,Json> wanted;for(auto& f:state.value("fixtures",Json::array()))if(f.value("kind",std::string("wled"))!="virtual"&&f.value("enabled",false))wanted[f.value("id",std::string{})]=f;
  for(auto i=lastSegments.begin();i!=lastSegments.end();){auto f=wanted.find(i->first);if(stale||f==wanted.end()||f->second.value("start",0)!=i->second.start||size_t(f->second.value("count",0))*3!=i->second.size){if(led->send(i->second.start,std::vector<uint8_t>(i->second.size,0))){wledPackets++;lastLedSent=wall();i=lastSegments.erase(i);}else ++i;}else ++i;}
  if(stale||sequence==consumed)return;consumed=sequence;for(auto& [id,f]:wanted){int count=f.value("count",0),start=f.value("start",0);auto frame=latest.find(id);if(frame==latest.end())continue;if(count<=0||frame->second.size()!=size_t(count)*3){ledError="Fixture frame size mismatch: "+id;continue;}if(led->send(start,frame->second)){wledPackets++;lastLedSent=wall();lastSegments[id]={start,frame->second.size()};ledError.clear();}}
 }
 void loop(std::stop_token stop){bool initialized=true;while(!stop.stop_requested()){double tick=now();try{auto state=cb.snapshot().at("state");if(!initialized){auto transport=state.value("dmxTransport",transportDefaults()),config=state.value("fixtureOutput",wledDefaults());dmxToken=transport.value("activationToken",std::string{});scanToken=transport.value("scanToken",std::string{});commandToken=transport.value("commandToken",std::string{});wledToken=config.value("activationToken",std::string{});initialized=true;report(true);}else {try{tickDmx(state,tick);}catch(const std::exception& e){dmxError=e.what();closeDmx(false);}try{tickLed(state,tick);}catch(const std::exception& e){ledError=e.what();closeLed();}report();}}catch(const std::exception& e){dmxError=e.what();try{report();}catch(...){}}
  std::unique_lock lock(mutex);wake.wait_for(lock,std::chrono::duration<double>(std::max(.001,.025-(now()-tick))),[&]{return stop.stop_requested();});
 }closeDmx();closeLed();try{report(true);}catch(...){}
 }
};
FixtureOutputRuntime::FixtureOutputRuntime(FixtureOutputCallbacks cb,std::unique_ptr<DmxTransport> dmx,std::unique_ptr<LedTransport> led):impl_(std::make_unique<Impl>(std::move(cb),std::move(dmx),std::move(led))){}
FixtureOutputRuntime::~FixtureOutputRuntime(){stop();}
void FixtureOutputRuntime::start(){if(impl_->worker.joinable())return;auto state=impl_->cb.snapshot().at("state");auto transport=state.value("dmxTransport",transportDefaults()),config=state.value("fixtureOutput",wledDefaults());impl_->dmxToken=transport.value("activationToken",std::string{});impl_->scanToken=transport.value("scanToken",std::string{});impl_->commandToken=transport.value("commandToken",std::string{});impl_->wledToken=config.value("activationToken",std::string{});if(state.value("startupPolicy",std::string("isolated"))=="restore"){impl_->dmxToken="restore-on-start";impl_->wledToken="restore-on-start";}impl_->worker=std::jthread([this](std::stop_token stop){impl_->loop(stop);});}
void FixtureOutputRuntime::stop(){if(impl_->worker.joinable()){impl_->worker.request_stop();impl_->wake.notify_all();impl_->worker.join();}}
void FixtureOutputRuntime::submitFrames(FixtureFrames frames){std::lock_guard lock(impl_->mutex);impl_->frames=std::move(frames);impl_->framesAt=now();impl_->frameSequence++;}
}
