#include "midi_runtime.hpp"
#include "api_error.hpp"
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <deque>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <map>
#include <mutex>
#include <regex>
#include <set>
#include <sstream>
#include <thread>
#include <fcntl.h>
#include <sys/file.h>
#include <unistd.h>
#include <cstdlib>
namespace vj {
namespace {
double now(){return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();}
void check(bool ok,const std::string& reason){if(!ok)throw ApiError(400,reason);}
void fields(const Json& body,const std::set<std::string>& allowed){check(body.is_object(),"Expected an object");for(auto i=body.begin();i!=body.end();++i)check(allowed.contains(i.key()),"Unknown MIDI field: "+i.key());}
std::string token(){static std::atomic<uint64_t> sequence=0;return std::to_string(getpid())+":"+std::to_string(now())+":"+std::to_string(++sequence);}
std::string busName(const std::string& b){return b=="out1"?"program":b;}
void validateLearn(const Json& target){
 if(target.is_null())return;check(target.is_object(),"target must be an object or null");auto kind=target.value("kind",std::string{});
 if(kind=="mix_master")check(target.value("which",std::string{})=="video"||target.value("which",std::string{})=="led","Unknown mix master");
 else if(kind=="mix_effect")check(std::set<std::string>{"pulse","strobe","invert","blackout","flash"}.contains(target.value("effect",std::string{})),"Unknown or unsupported mix effect");
 else if(kind=="cast")check(target.contains("cast")&&target["cast"].is_string()&&std::regex_match(target["cast"].get<std::string>(),std::regex("#[0-9a-fA-F]{6}")),"Invalid cast");
 else if(kind=="grid_clip"||kind=="grid_column"){check(target.contains("column")&&target["column"].is_string(),"column required");if(kind=="grid_clip")check(target.contains("row")&&target["row"].is_string(),"row required");if(target.contains("bank"))check(target["bank"]=="A"||target["bank"]=="B","Invalid bank");}
 else if(kind=="param")check(target.contains("bus")&&target["bus"].is_string()&&target.contains("slot")&&target["slot"].is_number_integer()&&target["slot"].get<int>()>=0&&target.contains("param")&&target["param"].is_string(),"Parameter target needs bus, slot, param");
 else throw ApiError(400,"Unknown MIDI learning target");
}
std::array<double,3> rgb(const Json& color){if(!color.is_string()||!std::regex_match(color.get<std::string>(),std::regex("#[0-9a-fA-F]{6}")))return {1,0,0};auto s=color.get<std::string>();return {std::stoi(s.substr(1,2),nullptr,16)/255.,std::stoi(s.substr(3,2),nullptr,16)/255.,std::stoi(s.substr(5,2),nullptr,16)/255.};}
std::array<double,3> hsv(std::array<double,3> c){double max=*std::max_element(c.begin(),c.end()),min=*std::min_element(c.begin(),c.end()),delta=max-min,h=0;if(delta){if(max==c[0])h=(c[1]-c[2])/delta;else if(max==c[1])h=2+(c[2]-c[0])/delta;else h=4+(c[0]-c[1])/delta;h=std::fmod(h/6+1,1.);}return {h,max?delta/max:0,max};}
std::string hueColor(double h,double s,double v){double i=std::floor(h*6),f=h*6-i,p=v*(1-s),q=v*(1-s*f),t=v*(1-s*(1-f));std::array<double,3> result;switch(int(i)%6){case 0:result={v,t,p};break;case 1:result={q,v,p};break;case 2:result={p,v,t};break;case 3:result={p,q,v};break;case 4:result={t,p,v};break;default:result={v,p,q};}std::ostringstream out;out<<'#'<<std::hex<<std::setfill('0');for(double channel:result)out<<std::setw(2)<<int(std::nearbyint(channel*255));return out.str();}
// Same cooperative lease files as Patch/original VJ. The distinct owner name
// allows the development app to yield to either application. No file access
// occurs until the user explicitly selects an APC controller.
class Lease {
 std::filesystem::path folder_;int fd_=-1;std::string seen_;
 std::string read()const{std::ifstream in(folder_/"APC40-mkII.request");return std::string(std::istreambuf_iterator<char>(in),{});}
 void prepare(){if(folder_.empty()){const char* home=getenv("HOME");if(!home)throw std::runtime_error("HOME unavailable for MIDI ownership");folder_=std::filesystem::path(home)/"Library/Application Support/Vibe MIDI";}std::filesystem::create_directories(folder_);}
public:
 ~Lease(){release();}
 void request(){prepare();seen_="VJ Native:"+token();auto temporary=folder_/("request-"+token());{std::ofstream out(temporary);if(!(out<<seen_))throw std::runtime_error("Cannot request MIDI ownership");}std::filesystem::rename(temporary,folder_/"APC40-mkII.request");}
 bool yielded(){if(folder_.empty())return false;auto value=read();bool change=value!=seen_;seen_=value;return change&&!value.empty()&&!value.starts_with("VJ Native:");}
 bool acquire(){if(fd_>=0)return true;prepare();fd_=::open((folder_/"APC40-mkII.lock").c_str(),O_CREAT|O_RDWR,0600);if(fd_<0)throw std::runtime_error("Cannot open MIDI ownership lock");if(flock(fd_,LOCK_EX|LOCK_NB)<0){::close(fd_);fd_=-1;return false;}std::ofstream(folder_/"APC40-mkII.owner")<<"VJ Native";return true;}
 void release(){if(fd_>=0){flock(fd_,LOCK_UN);::close(fd_);fd_=-1;}}
};
const Json* rowFor(const Json& g,const std::string& id){for(auto& row:g.at("rows"))if(row.value("id",std::string{})==id)return &row;return nullptr;}
Json selectedClip(const Json& g){auto focus=g.value("control_focus",Json::object());auto rowId=focus.value("row",Json());auto row=rowId.is_string()?rowFor(g,rowId.get<std::string>()):nullptr;auto column=focus.value("column",Json());if(row&&column.is_string()&&(*row)["clips"].contains(column.get<std::string>()))return {{"row",(*row)["id"]},{"column",column},{"bus",focus.value("bus",std::string("program"))},{"clip",(*row)["clips"][column.get<std::string>()]}};return Json();}
Json parameterSpecs(const Json& catalog,const std::string& gen,bool performance){for(auto& effect:catalog)if(effect.value("name",std::string{})==gen){auto parameters=effect.value("parameters",Json::array());if(!performance)return parameters;Json result=Json::array();for(auto& name:effect.value("performanceParameters",Json::array())){for(auto& p:parameters)if(p["name"]==name){result.push_back(p);break;}if(result.size()==8)break;}return result;}return Json::array();}
}
bool isApc40(const std::string& name){return std::regex_search(name,std::regex("\\bAPC40[ _-]*MK(II|2)\\b",std::regex::icase));}
void MidiByteParser::reset(){status_=0;data_.clear();sysex_=false;}
void MidiByteParser::feed(const uint8_t* bytes,size_t count,double seconds,const MidiBackend::Receive& receive){for(size_t i=0;i<count;i++){uint8_t b=bytes[i];if(b>=0xf8){receive({b,0,0,seconds});continue;}if(b==0xf0){sysex_=true;status_=0;data_.clear();continue;}if(b==0xf7){sysex_=false;status_=0;data_.clear();continue;}if(sysex_)continue;if(b&0x80){status_=b<0xf0?b:0;data_.clear();continue;}if(!status_)continue;data_.push_back(b);size_t needed=(status_&0xf0)==0xc0||(status_&0xf0)==0xd0?1:2;if(data_.size()==needed){receive({status_,data_[0],needed==2?data_[1]:uint8_t(0),seconds});data_.clear();}}}
Json midiParameterValue(const Json& spec,int value,const Json& current,bool quantize){double f=std::clamp(value,0,127)/127.;auto kind=spec.value("kind",std::string{});if(kind=="float"||kind=="int"){double lo=spec.value("min",0.),hi=spec.value("max",1.);double n=spec.value("scale",std::string{})=="log"&&lo>0?lo*std::pow(hi/lo,f):lo+f*(hi-lo);double step=spec.value("step",0.);if(quantize&&step>0)n=lo+std::nearbyint((n-lo)/step)*step;n=std::clamp(n,lo,hi);return kind=="int"?Json(int(std::nearbyint(n))):Json(n);}if(kind=="bool")return value>=64;if(kind=="choice"){auto values=spec.value("choices",Json::array());return values.empty()?current:values[std::min(size_t(f*values.size()),values.size()-1)];}if(kind=="color"){auto c=hsv(rgb(current));return hueColor(f,c[1]>0?c[1]:1,c[2]>0?c[2]:1);}return current;}
int midiParameterPosition(const Json& spec,const Json& value){auto kind=spec.value("kind",std::string{});double f=0;if((kind=="float"||kind=="int")&&value.is_number()){double lo=spec.value("min",0.),hi=spec.value("max",1.),n=std::clamp(value.get<double>(),lo,hi);f=spec.value("scale",std::string{})=="log"&&lo>0&&hi!=lo?std::log(n/lo)/std::log(hi/lo):(n-lo)/(hi!=lo?hi-lo:1);}else if(kind=="bool")f=value==true?1:0;else if(kind=="color")f=hsv(rgb(value))[0];else if(kind=="choice"){auto values=spec.value("choices",Json::array());for(size_t i=0;i<values.size();i++)if(values[i]==value){f=double(i)/std::max(size_t(1),values.size()-1);break;}}return int(std::nearbyint(std::clamp(f,0.,1.)*127));}
Json midiModelCommand(Json& d,const Json& incoming){Json body=incoming;body.erase("revision");fields(body,{"action","name","target","index","enabled","channel","cc","note","expectedTarget","value","hook"});auto& midi=d["controls"]["midi"];auto action=body.value("action",std::string{});
 if(action=="midi_set_hook"){
  auto id=body.value("hook",std::string{});check(std::set<std::string>{"clip_launch","column_launch","output_select","clip_parameters","dmx_parameters","fader_attach_button","controller_lights"}.contains(id),"Unknown editable MIDI hook");check(body.at("enabled").is_boolean(),"enabled must be boolean");midi["hooks"][id]=body["enabled"];
 }
 else if(action=="midi_bind"){
  auto target=body.at("target");validateLearn(target);check(!target.is_null(),"target required");check(body.contains("cc")!=body.contains("note"),"Supply exactly one of cc or note");
  const bool cc=body.contains("cc");auto kind=target.value("kind",std::string{});check(cc==(kind=="param"||kind=="mix_master"),"MIDI message type does not match target");
  auto saved=midi["learning"];midi["learning"]=target;Json capture={{"action","midi_capture"},{"channel",body.at("channel")},{cc?"cc":"note",body.at(cc?"cc":"note")},{"expectedTarget",target}};midiModelCommand(d,capture);midi["learning"]=saved;
 }
 else if(action=="midi_update"){
  check(body.at("index").is_number_integer(),"index must be integer");int index=body["index"];auto& list=midi["mappings"];check(index>=0&&index<int(list.size()),"Unknown MIDI mapping");auto entry=list[index];
  if(body.contains("enabled")){check(body["enabled"].is_boolean(),"enabled must be boolean");entry["enabled"]=body["enabled"];}
  for(auto key:{"channel","cc","note"})if(body.contains(key)){check(body[key].is_number_integer(),"MIDI number must be integer");int n=body[key];check(n>=0&&n<=(std::string(key)=="channel"?15:127),"MIDI number out of range");check(std::string(key)=="channel"||entry.value("type",std::string{})==key,"MIDI message type cannot change");entry[key]=n;}
  if(body.contains("target")){
   auto candidate=d;candidate["controls"]["midi"]["mappings"]=Json::array();auto field=entry.value("type",std::string{})=="cc"?"cc":"note";
   midiModelCommand(candidate,{{"action","midi_bind"},{"target",body["target"]},{"channel",entry["channel"]},{field,entry[field]}});
   auto updated=candidate["controls"]["midi"]["mappings"].back();updated["enabled"]=entry.value("enabled",true);entry=updated;
  }
  auto number=entry.value("type",std::string{})=="cc"?"cc":"note";for(int i=0;i<int(list.size());i++)if(i!=index)check(list[i].value("type",std::string{})!=entry["type"].get<std::string>()||list[i].value("channel",-1)!=entry["channel"]||list[i].value(number,-1)!=entry[number],"MIDI input already bound");list[index]=entry;
 }
 else if(action=="midi_scan")midi["scanToken"]=token();
 else if(action=="midi_select"){auto name=body.value("name",Json());check(name.is_null()||(name.is_string()&&name.get<std::string>().size()<=512),"name must be text or null");midi["selected"]=name==""?Json():name;midi["requested"]=midi["selected"];midi["selectionToken"]=token();}
 else if(action=="midi_learn"){auto target=body.value("target",Json());validateLearn(target);midi["learning"]=target;}
 else if(action=="midi_unmap"){check(body.at("index").is_number_integer(),"index must be integer");int index=body["index"];auto& list=midi["mappings"];check(index>=0&&index<int(list.size()),"Unknown MIDI mapping");list.erase(index);}
 else if(action=="midi_clock_sync"){check(body.at("enabled").is_boolean(),"enabled must be boolean");d["controls"]["clock"]["midi_clock_sync"]=body["enabled"];if(body["enabled"]==true)d["controls"]["clock"]["link_sync"]=false;}
 else if(action=="midi_controller_disconnected"){if(d.contains("grid")){d["grid"]["fader_sync"]=false;d["grid"]["fader_position"]=nullptr;}}
 else if(action=="midi_fader_position"){check(body.at("value").is_number(),"value must be numeric");double value=body["value"];check(std::isfinite(value)&&value>=0&&value<=1,"value must be 0..1");d["grid"]["fader_position"]=value;}
 else if(action=="midi_capture"){
  auto target=midi.value("learning",Json());if(target.is_null()||body.value("expectedTarget",Json())!=target)return midi;check(body.at("channel").is_number_integer(),"channel must be integer");int channel=body["channel"];check(channel>=0&&channel<=15,"channel must be 0..15");bool cc=body.contains("cc");auto field=cc?"cc":"note";check(body.at(field).is_number_integer(),"MIDI number must be integer");int number=body[field];check(number>=0&&number<=127,"MIDI number must be 0..127");auto kind=target.value("kind",std::string{});if(cc&&kind!="param"&&kind!="mix_master")return midi;if(!cc&&kind!="grid_clip"&&kind!="grid_column"&&kind!="mix_effect"&&kind!="cast")return midi;Json entry={{"type",cc?"cc":"note"},{"channel",channel},{field,number}};if(kind=="param")for(auto key:{"bus","slot","param"})entry[key]=target[key];if(kind=="mix_master")entry["mix"]=target["which"];if(kind=="mix_effect")entry["mix_effect"]=target["effect"];if(kind=="cast")entry["cast"]=target["cast"];if(kind=="grid_clip"||kind=="grid_column"){entry["grid"]=target;entry["grid"].erase("kind");entry["grid"]["action"]=kind=="grid_clip"?"launch_clip":"launch_column";}auto& mappings=midi["mappings"];mappings.erase(std::remove_if(mappings.begin(),mappings.end(),[&](const Json& m){return m.value("type",std::string{})==(cc?"cc":"note")&&m.value("channel",-1)==channel&&m.value(field,-1)==number;}),mappings.end());mappings.push_back(entry);midi["learning"]=nullptr;
 }else throw ApiError(400,"Unknown MIDI action");return midi;
}
Json midiControlHooks(const Json& d,const Json& catalog,bool connected,bool patchOwnsTracks,bool patchOwnsCrossfader){
 const auto& g=d.at("grid");const auto& midi=d.at("controls").at("midi");auto flags=midi.value("hooks",Json::object());auto focus=g.value("control_focus",Json::object());auto bus=focus.value("bus",std::string("program"));Json result=Json::array();
 auto edit=[&](const std::string& id){return Json{{"method","POST"},{"path","/api/v1/midi"},{"body",{{"action","midi_set_hook"},{"hook",id},{"enabled",false}}}};};
 auto add=[&](std::string id,std::string label,Json input,Json target,bool active=true){bool enabled=flags.value(id,true);result.push_back({{"id",id},{"kind","builtin"},{"label",label},{"device","apc40mkII"},{"input",input},{"target",target},{"enabled",enabled},{"active",connected&&enabled&&active},{"disable",edit(id)},{"editScope",id}});};
 Json channels=Json::array(),notes=Json::array();for(int i=0;i<8;i++)channels.push_back(i);for(int i=0;i<40;i++)notes.push_back(i);
 add("clip_launch","Clip pads",{{"type","note"},{"notes",notes},{"channels","any"}},{{"kind","grid"},{"bus",bus},{"rows",g["rows"].size()},{"columns",g["columns"]},{"noteLayout","(4 - floor(note/8)) rows from bottom; note % 8 column"}});
 add("column_launch","Launch column",{{"type","note"},{"note",52},{"channels",channels}},{{"kind","grid_column"},{"bus",bus},{"columns",g["columns"]}});
 add("output_select","Select Out",{{"type","note"},{"note",51},{"channels",channels}},{{"kind","control_focus"},{"bus",bus},{"channelToOut","channel + 1"}});
 add("fader_attach_button","Attach A/B fader",{{"type","note"},{"note",103},{"channel",0}},{{"kind","fader_sync"},{"value",g.value("fader_sync",false)}});
 add("controller_lights","Controller lights",{{"type","note"},{"note",98},{"channel",0}},{{"kind","controller_lights"},{"value",g.value("controller_lights",std::string("full"))}});
 const bool dmx=d["controls"]["dmx"].value("_apc_until",0.)>now();
 Json encoders=Json::array();auto clip=selectedClip(g);auto params=clip.is_null()?Json::array():parameterSpecs(catalog,clip["clip"]["gen"],true);
 for(int i=0;i<8;i++){Json target=nullptr;if(i<int(params.size()))target={{"bus",bus},{"row",clip["row"]},{"column",clip["column"]},{"clip",clip["clip"]["id"]},{"name",clip["clip"].value("name",std::string{})},{"parameter",params[i]["name"]}};encoders.push_back({{"channel",0},{"cc",16+i},{"target",target}});}
 add("clip_parameters","Selected clip parameters",{{"type","cc"},{"channel",0},{"ccRange",{16,23}}},{{"kind","parameters"},{"routes",encoders}},!dmx&&!clip.is_null());
 Json dmxRoutes=Json::array();dmxRoutes.push_back({{"cc",13},{"parameter","brightness"}});for(int i=0;i<6;i++)dmxRoutes.push_back({{"cc",16+i},{"parameter",std::array<const char*,6>{"pan","tilt","speed","beam","strobe","color"}[i]}});
 add("dmx_parameters","DMX controls",{{"type","cc"},{"channel",0},{"cc",{13,16,17,18,19,20,21,22,23}}},{{"kind","dmx"},{"routes",dmxRoutes}},dmx);
 result.push_back({{"id","crossfader"},{"kind","builtin"},{"device","apc40mkII"},{"label","A/B crossfader"},{"input",{{"type","cc"},{"channel",0},{"cc",15}}},{"target",{{"kind","crossfade"},{"bus",bus}}},{"enabled",g.value("fader_sync",false)},{"active",connected&&g.value("fader_sync",false)},{"disable",{{"method","POST"},{"path","/api/v1/grid"},{"body",{{"action","set_fader_sync"},{"enabled",false},{"bus",bus}}}}}});
 if(patchOwnsCrossfader){auto& hook=result.back();hook["active"]=connected;hook["enabled"]=true;hook["kind"]="forward";hook["target"]={{"application","Patch"},{"hooks","/v1/midi/hooks"}};hook["editScope"]="Patch A/B Follow APC";hook.erase("disable");}
 for(int i=0;i<8;i++)result.push_back({{"id","track_fader_"+std::to_string(i+1)},{"kind","forward"},{"device","apc40mkII"},{"label","Track fader "+std::to_string(i+1)},{"input",{{"type","cc"},{"channel",i},{"cc",7}}},{"enabled",patchOwnsTracks},{"active",connected&&patchOwnsTracks},{"target",patchOwnsTracks?Json{{"application","Patch"},{"hooks","/v1/midi/hooks"}}:Json()},{"automaticClipOpacity",false}});
 result.push_back({{"id","clock"},{"kind","builtin"},{"label","MIDI clock"},{"input",{{"type","realtime"},{"status",248}}},{"target",{{"kind","bpm"}}},{"enabled",d["controls"]["clock"].value("midi_clock_sync",false)},{"disable",{{"method","POST"},{"path","/api/v1/midi"},{"body",{{"action","midi_clock_sync"},{"enabled",false}}}}}});
 const auto mappings=midi.value("mappings",Json::array());for(size_t i=0;i<mappings.size();i++)result.push_back({{"id","mapping_"+std::to_string(i)},{"kind","learned"},{"index",i},{"enabled",mappings[i].value("enabled",true)},{"binding",mappings[i]},{"edit",{{"method","POST"},{"path","/api/v1/midi"},{"body",{{"action","midi_update"},{"index",i}}}}},{"disable",{{"method","POST"},{"path","/api/v1/midi"},{"body",{{"action","midi_update"},{"index",i},{"enabled",false}}}}},{"remove",{{"method","POST"},{"path","/api/v1/midi"},{"body",{{"action","midi_unmap"},{"index",i}}}}}});
 return result;
}

struct MidiRuntime::Impl {
 MidiRuntimeCallbacks cb;std::unique_ptr<MidiBackend> backend;std::jthread worker;std::mutex mutex;std::condition_variable wake;std::deque<std::pair<uint64_t,MidiMessage>> queue;std::atomic<uint64_t> generation{0};
 std::string desired,connected,status="Off",error,selectionToken,scanToken,lightMode;MidiPorts ports;Lease lease;bool apc=false;double scanned=0;Json lastStatus;std::deque<double> ticks;std::map<int,Json> held;std::map<std::array<int,3>,int> sent;Json layout;
 Impl(MidiRuntimeCallbacks c,std::unique_ptr<MidiBackend> b):cb(std::move(c)),backend(std::move(b)){}
 void command(const std::string& path,const Json& body){cb.command(path,body);}
 void grid(Json body){command("/api/v1/grid",body);}
 void report(){Json next={{"available",backend->available()},{"inputs",ports.inputs},{"outputs",ports.outputs},{"selected",desired.empty()?Json():Json(desired)},{"connected",connected.empty()?Json():Json(connected)},{"status",status},{"error",error},{"cooperative",true},{"patchAPCOwned",cb.controllerOwned&&cb.controllerOwned()},{"controller",apc?Json("APC40 mkII"):Json()}};if(next!=lastStatus){lastStatus=next;cb.status(next);}}
 void close(){patchFeedback=false;bool wasApc=apc;generation++;backend->close();lease.release();connected.clear();apc=false;ticks.clear();held.clear();sent.clear();layout=Json();lightMode.clear();if(wasApc)try{command("/api/v1/midi",{{"action","midi_controller_disconnected"}});}catch(...){};}
 void scan(){ports=backend->ports();scanned=now();}
 void connect(){if(desired.empty())return;if(!backend->available()){status="Unavailable";return;}if(std::find(ports.inputs.begin(),ports.inputs.end(),desired)==ports.inputs.end()){status="Disconnected";return;}if(isApc40(desired)&&!lease.acquire()){status="Waiting for controller";return;}auto epoch=++generation;backend->open(desired,isApc40(desired),[this,epoch,controller=isApc40(desired)](MidiMessage message){std::lock_guard lock(mutex);if(controller&&((message.status==0xb0&&message.data1==15)||((message.status&0xf0)==0xb0&&(message.status&15)<8&&message.data1==7))&&!queue.empty()&&queue.back().first==epoch&&queue.back().second.status==message.status&&queue.back().second.data1==message.data1)queue.back().second=message;else if(queue.size()<4096)queue.emplace_back(epoch,message);wake.notify_one();});connected=desired;apc=isApc40(desired);status="Connected";error.clear();sent.clear();layout=Json();lightMode.clear();}
 Json context(const Json& state){auto g=state.at("grid");auto focus=g.value("control_focus",Json::object());std::string bus=focus.value("bus",std::string("program"));Json next={{"show",g.value("active_show",Json())},{"bus",bus},{"rows",Json::array()},{"columns",g["columns"]}};for(auto& row:g["rows"]){Json clips=Json::object();for(auto i=row["clips"].begin();i!=row["clips"].end();++i)clips[i.key()]=i.value().value("id",Json());next["rows"].push_back({{"id",row["id"]},{"clips",clips}});}if(layout!=next){sent.clear();layout=next;for(auto i=held.begin();i!=held.end();){auto target=i->second;int ri=4-i->first/8,ci=i->first%8;int rowIndex=int(g["rows"].size())-1-ri;bool valid=ri>=0&&rowIndex>=0&&ci<int(g["columns"].size());if(valid){auto& row=g["rows"][rowIndex];auto cid=g["columns"][ci]["id"].get<std::string>();valid=row["id"]==target["row"]&&target["column"].get<std::string>()==cid&&row["clips"].contains(cid)&&row["clips"][cid]["id"]==target["clip"]&&target["bus"]==bus;}if(!valid)i=held.erase(i);else ++i;}}return g;}
 void edited(const Json& target){for(auto& [note,h]:held)if(h["row"]==target["row"]&&h["column"]==target["column"])h["edited"]=true;}
 bool apcMessage(const MidiMessage& msg,const Json& state){
  int kind=msg.status&0xf0,ch=msg.status&15,n=msg.data1,v=msg.data2;bool pressed=kind==0x90&&v>0;
  const auto hooks=state["midi"].value("hooks",Json::object());
  std::string hook;
  if(kind==0xb0&&ch==0&&(n==13||(n>=16&&n<=23)))hook=state.value("dmx",Json::object()).value("apc_active",false)?"dmx_parameters":"clip_parameters";
  if(kind==0x90||kind==0x80){if(ch==0&&n==98)hook="controller_lights";else if(ch==0&&n==103)hook="fader_attach_button";else if(n<40)hook="clip_launch";else if(ch<8&&n==51)hook="output_select";else if(ch<8&&n==52)hook="column_launch";}
  if(!hook.empty()&&!hooks.value(hook,true)){if(hook=="clip_launch")held.erase(n);return false;}
  if(kind==0xb0&&ch==0&&state.value("dmx",Json::object()).value("apc_active",false)&&(n==13||(n>=16&&n<=23))){auto values=state["dmx"]["apc"];Json changes=Json::object();if(n==13){int delta=v<64?v:v-128;changes["brightness"]=std::clamp(values.value("brightness",0.)+delta/127.,0.,1.);}else if(n<22){auto key=std::array<const char*,6>{"pan","tilt","speed","beam","strobe","color"}[n-16];changes[key]=n==21?Json(std::min(7,v*8/128)):Json(v/127.);}if(!changes.empty())command("/api/v1/dmx",{{"apc",changes}});return true;}
  auto g=context(state);std::string bus=g["control_focus"].value("bus",std::string("program"));
  if(kind==0x90||kind==0x80){
   if(ch==0&&n==98){if(pressed){std::vector<std::string> modes={"full","dim","off"};auto i=std::find(modes.begin(),modes.end(),g.value("controller_lights",std::string("full")));grid({{"action","set_controller_lights"},{"mode",modes[(std::distance(modes.begin(),i)+1)%3]}});}return true;}
   if(ch==0&&n==0x67){if(pressed){bool enabled=!g.value("fader_sync",false);grid({{"action","set_fader_sync"},{"bus",bus},{"enabled",enabled}});if(enabled&&g.contains("fader_position")&&g["fader_position"].is_number())grid({{"action","set_crossfade"},{"bus",bus},{"value",g["fader_position"]}});}return true;}
   if(n<40){if(!pressed){auto i=held.find(n);if(i!=held.end()){auto target=i->second;held.erase(i);auto selections=g["selections"].value(target["bus"].get<std::string>(),Json::object());if(target.value("deselect_on_release",false)&&!target.value("edited",false)&&selections.value(target["row"].get<std::string>(),Json())==target["column"])grid({{"action","stop_row"},{"bus",target["bus"]},{"row",target["row"]}});}return true;}
    int ri=4-n/8,ci=n%8,index=int(g["rows"].size())-1-ri;if(index<0||ci>=int(g["columns"].size()))return true;auto row=g["rows"][index];auto column=g["columns"][ci]["id"].get<std::string>();if(!row["clips"].contains(column))return true;bool selected=g["selections"].value(bus,Json::object()).value(row["id"].get<std::string>(),Json())==column;held[n]={{"row",row["id"]},{"column",column},{"clip",row["clips"][column]["id"]},{"bus",bus},{"edited",false},{"deselect_on_release",selected}};grid({{"action","select_cell"},{"bus",bus},{"row",row["id"]},{"column",column}});if(!selected)grid({{"action","launch_clip"},{"bus",bus},{"row",row["id"]},{"column",column}});return true;
   }
   if((n==51||n==52)&&ch<8){if(pressed){auto out=ch==0?"program":"out"+std::to_string(ch+1);if(n==51&&g["running"].contains(out)){held.clear();grid({{"action","select_out"},{"bus",out}});}else if(n==52&&ch<int(g["columns"].size())){auto column=g["columns"][ch]["id"].get<std::string>();bool populated=false;for(auto& row:g["rows"])populated|=row["clips"].contains(column);if(populated)grid({{"action","launch_column"},{"bus",bus},{"column",column}});}}return true;}
  }
  if(kind==0xb0&&n>=16&&n<=23){auto target=selectedClip(g);if(ch!=0)return false;if(target.is_null())return true;auto clip=target["clip"];auto params=parameterSpecs(cb.catalog(),clip["gen"],true);int index=n-16;if(index<int(params.size())){edited(target);auto spec=params[index];auto key=spec["name"].get<std::string>();Json changes={{key,midiParameterValue(spec,v,clip["params"].value(key,spec.value("default",Json())))}};if(clip["gen"]=="video"&&key=="position")changes["seek_nonce"]=clip["params"].value("seek_nonce",0)+1;grid({{"action","set_clip"},{"bus",bus},{"row",target["row"]},{"column",target["column"]},{"params",changes}});}return true;}
  return false;
 }
 void dispatch(const MidiMessage& msg){
  if(apc&&cb.controllerMessage&&cb.controllerMessage(msg.status,msg.data1,msg.data2)){
   if((msg.status&0xf0)==0xb0&&((msg.data1>=16&&msg.data1<=23)||(msg.data1>=48&&msg.data1<=55)))send(0xb0,msg.status&15,msg.data1,msg.data2);
   return;
  }
  if(apc&&(msg.status&0xf0)==0xb0&&(msg.status&15)<8&&msg.data1==7&&cb.channelFader&&cb.channelFader(msg.status&15,msg.data2/127.))return;
  if(apc&&msg.status==0xb0&&msg.data1==15){command("/api/v1/midi",{{"action","midi_fader_position"},{"value",msg.data2/127.}});return;}
  auto state=cb.snapshot().at("state");int kind=msg.status&0xf0,ch=msg.status&15,n=msg.data1,v=msg.data2;
  if(apc&&apcMessage(msg,state))return;
  if(msg.status==0xf8){ticks.push_back(msg.seconds);while(ticks.size()>49)ticks.pop_front();if(ticks.size()>=25){double span=ticks.back()-ticks[ticks.size()-25];if(span>0){double bpm=60/span;if(bpm>20&&bpm<300&&state["midi"].value("clock_sync",false)&&std::abs(bpm-state.value("bpm",120.))>.5)command("/api/v1/clock",{{"action","set_bpm"},{"bpm",bpm}});}}return;}
  if(msg.status==0xfa||msg.status==0xfc){ticks.clear();return;}
  bool cc=kind==0xb0,note=kind==0x90&&v>0;if(!cc&&!note)return;
  auto learning=state["midi"].value("learning",Json());auto learnKind=learning.is_object()?learning.value("kind",std::string{}):std::string{};
  if((cc&&(learnKind=="param"||learnKind=="mix_master"))||(note&&(learnKind=="grid_clip"||learnKind=="grid_column"||learnKind=="mix_effect"||learnKind=="cast"))){command("/api/v1/midi",{{"action","midi_capture"},{"channel",ch},{cc?"cc":"note",n},{"expectedTarget",learning}});return;}
  for(auto& mapping:state["midi"].value("mappings",Json::array())){
   if(!mapping.value("enabled",true))continue;
   if(mapping.value("type",std::string{})!=(cc?"cc":"note")||mapping.value("channel",-1)!=ch||mapping.value(cc?"cc":"note",-1)!=n)continue;
   try {
    if(cc&&mapping.contains("mix")){command("/api/v1/mix",{{mapping["mix"]=="video"?"video_master":"led_master",v/127.}});}
    else if(cc&&mapping.contains("param")){
     const auto& g=state["grid"];auto bus=busName(mapping.value("bus",std::string("program")));auto selections=g["selections"].value(bus,Json::object());int wanted=mapping.value("slot",-1),slot=0;for(auto& row:g["rows"]){auto rid=row["id"].get<std::string>();if(!selections.contains(rid))continue;auto cid=selections[rid].get<std::string>();if(!row["clips"].contains(cid))continue;if(slot++!=wanted)continue;auto clip=row["clips"][cid];std::string param=mapping["param"];Json command={{"action","set_clip"},{"bus",bus},{"row",rid},{"column",cid}};if(param=="_opacity")command["opacity"]=v/127.;else {for(auto& spec:parameterSpecs(cb.catalog(),clip["gen"],false))if(spec["name"]==param){command["params"]={{param,midiParameterValue(spec,v,clip["params"].value(param,spec.value("default",Json())),false)}};break;}}if(command.contains("opacity")||command.contains("params"))grid(command);break;}
    }else if(note&&mapping.contains("grid"))grid(mapping["grid"]);
    else if(note&&mapping.contains("mix_effect")){auto effect=mapping["mix_effect"].get<std::string>();if(std::set<std::string>{"pulse","strobe","invert","blackout"}.contains(effect))command("/api/v1/mix",{{effect,!state["mix"].value(effect,false)}});else if(effect=="flash")command("/api/v1/flash",Json::object());}
    else if(note&&mapping.contains("cast"))command("/api/v1/mix",{{"cast",state["mix"].value("cast",Json())==mapping["cast"]?Json():mapping["cast"]}});
   }catch(const std::exception& e){error=e.what();}
  }
 }
 void send(int kind,int channel,int number,int value){
  value=std::clamp(value,0,127);if(kind==0x90){if(lightMode=="off")value=0;else if(lightMode=="dim"&&(number<40||(number>=82&&number<=86))){if(value==9)value=10;if(value==21)value=22;if(value==45)value=46;}}
  std::array<int,3> key={kind,channel,number};auto i=sent.find(key);if(i!=sent.end()&&i->second==value)return;backend->send({uint8_t(kind|channel),uint8_t(number),uint8_t(value)});sent[key]=value;
 }
 bool patchFeedback=false;
 void feedback(){
  bool owned=apc&&cb.controllerOwned&&cb.controllerOwned();
  if(owned!=patchFeedback){
   patchFeedback=owned;held.clear();sent.clear();layout=Json();
   if(owned){for(int channel=0;channel<8;++channel)for(int note=0;note<104;++note)send(0x90,channel,note,0);for(int cc=24;cc<32;++cc)send(0xb0,0,cc,1);for(int cc=56;cc<64;++cc)send(0xb0,0,cc,1);}
   else lightMode="";
  }
  if(owned)return;
  if(!apc||connected.empty())return;auto state=cb.snapshot().at("state"),g=context(state);auto mode=g.value("controller_lights",std::string("full"));
  if(lightMode!=mode){lightMode=mode;sent.clear();for(int channel=0;channel<8;channel++)for(int note:{48,49,50,51,52,66})send(0x90,channel,note,0);for(int note=58;note<=65;note++)send(0x90,0,note,0);for(int note:{80,82,83,84,85,86,87,88,89,90,91,92,93,102,103})send(0x90,0,note,0);for(int cc=24;cc<32;cc++)send(0xb0,0,cc,mode=="off"?0:1);for(int cc=56;cc<64;cc++)send(0xb0,0,cc,mode=="off"?0:1);}
  auto bus=g["control_focus"].value("bus",std::string("program"));auto a=g["selections"].value(bus,Json::object()),b=g["selections_b"].value(bus,Json::object());int pulse=int(now()*2)%2;send(0x90,0,0x67,g.value("fader_sync",false)?1:0);
  for(int i=0;i<8;i++){std::string out=i==0?"program":"out"+std::to_string(i+1);send(0x90,i,51,g["running"].contains(out)?(out==bus?pulse:1):0);bool populated=false,active=!a.empty();if(i<int(g["columns"].size())){auto cid=g["columns"][i]["id"].get<std::string>();for(auto& row:g["rows"]){bool filled=row["clips"].contains(cid);populated|=filled;active&=a.value(row["id"].get<std::string>(),Json())==(filled?Json(cid):Json());}}else active=false;send(0x90,i,52,populated?(active?pulse:1):0);}
  for(int ri=0;ri<5;ri++)for(int ci=0;ci<8;ci++){int index=int(g["rows"].size())-1-ri,value=0;if(index>=0&&ci<int(g["columns"].size())){auto& row=g["rows"][index];auto cid=g["columns"][ci]["id"].get<std::string>();if(row["clips"].contains(cid)){bool active=a.value(row["id"].get<std::string>(),Json())==cid,activeB=b.value(row["id"].get<std::string>(),Json())==cid;value=active&&activeB?(pulse?21:45):active?21:activeB?45:9;}}send(0x90,0,(4-ri)*8+ci,value);}
  auto target=selectedClip(g);Json params=target.is_null()?Json::array():parameterSpecs(cb.catalog(),target["clip"]["gen"],true);auto dmx=state.value("dmx",Json::object());bool dmxActive=dmx.value("apc_active",false);for(int i=0;i<8;i++){int value=0;if(i<int(params.size())){auto key=params[i]["name"].get<std::string>();value=midiParameterPosition(params[i],target["clip"]["params"].value(key,params[i].value("default",Json())));}if(dmxActive){value=0;if(i==5)value=std::min(127,dmx["apc"].value("color",0)*16+8);else if(i<6){auto key=std::array<const char*,6>{"pan","tilt","speed","beam","strobe","color"}[i];value=std::nearbyint(dmx["apc"].value(key,0.)*127);}}send(0xb0,0,16+i,value);}
 }
 void loop(std::stop_token stop){
  bool initialized=true;double maintenance=0,feedbackAt=0;
  try{command("/api/v1/midi",{{"action","midi_controller_disconnected"}});scan();report();}catch(const std::exception& e){error=e.what();status="Error";}
  while(!stop.stop_requested()){
   try{
    if(now()-maintenance>=.1){maintenance=now();
    auto midi=cb.snapshot().at("state").at("midi");auto selection=midi.value("selectionToken",std::string{}),scanRequest=midi.value("scanToken",std::string{});
    if(!initialized){selectionToken=selection;scanToken=scanRequest;initialized=true;error.clear();status="Off";command("/api/v1/midi",{{"action","midi_controller_disconnected"}});report();}
    if(selection!=selectionToken){selectionToken=selection;close();error.clear();auto name=midi.value("requested",midi.value("selected",Json()));desired=name.is_string()?name.get<std::string>():std::string{};status="Off";if(!desired.empty()){if(isApc40(desired))lease.request();scan();connect();}}
    if(scanRequest!=scanToken){scanToken=scanRequest;scan();}
    // Discovery must also run while Off so newly attached inputs can be selected.
    if(now()-scanned>=1){scan();if(!desired.empty()){if(isApc40(desired)&&lease.yielded()){close();desired.clear();status="In use by another app";}else {if(!connected.empty()&&std::find(ports.inputs.begin(),ports.inputs.end(),connected)==ports.inputs.end()){close();status="Disconnected";}if(connected.empty())connect();}}}
    }
    std::deque<std::pair<uint64_t,MidiMessage>> messages;{std::unique_lock lock(mutex);wake.wait_for(lock,std::chrono::milliseconds(100),[&]{return stop.stop_requested()||!queue.empty();});messages.swap(queue);}for(auto& [epoch,message]:messages)if(epoch==generation.load()&&!connected.empty())dispatch(message);if(now()-feedbackAt>=1./30){feedbackAt=now();feedback();report();}
   }catch(const std::exception& e){error=e.what();status="Error";close();try{report();}catch(...){};std::unique_lock lock(mutex);wake.wait_for(lock,std::chrono::milliseconds(250),[&]{return stop.stop_requested();});}
  }
  close();desired.clear();status="Off";try{report();}catch(...){}
 }
};
MidiRuntime::MidiRuntime(MidiRuntimeCallbacks callbacks,std::unique_ptr<MidiBackend> backend):impl_(std::make_unique<Impl>(std::move(callbacks),std::move(backend))){}
MidiRuntime::~MidiRuntime(){stop();}
void MidiRuntime::start(){if(impl_->worker.joinable())return;auto initial=impl_->cb.snapshot().at("state").at("midi");impl_->selectionToken=impl_->cb.snapshot().at("state").value("startupPolicy",std::string("isolated"))=="restore"?"restore-on-start":initial.value("selectionToken",std::string{});impl_->scanToken=initial.value("scanToken",std::string{});impl_->worker=std::jthread([this](std::stop_token stop){impl_->loop(stop);});}
void MidiRuntime::stop(){if(impl_->worker.joinable()){impl_->worker.request_stop();impl_->wake.notify_all();impl_->worker.join();}}
}
