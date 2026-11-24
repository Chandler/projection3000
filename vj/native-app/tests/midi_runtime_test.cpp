#include "midi_runtime.hpp"
#include "control_model.hpp"
#include <cassert>
#include <mutex>
#include <condition_variable>
#include <chrono>
#include <iostream>
using namespace vj;
struct FakeMidi:MidiBackend {
 std::mutex mutex;Receive receive;int scans=0,opens=0,sends=0;
 bool available()const override{return true;}
 MidiPorts ports()override{std::lock_guard lock(mutex);scans++;return {{"Test Input"},{}};}
 void open(const std::string& name,bool controller,Receive r)override{std::lock_guard lock(mutex);assert(name=="Test Input"&&!controller);opens++;receive=r;}
 void send(const std::vector<uint8_t>&)override{std::lock_guard lock(mutex);sends++;}
 void close()override{std::lock_guard lock(mutex);receive={};}
 void emit(MidiMessage msg){Receive callback;{std::lock_guard lock(mutex);callback=receive;}assert(callback);callback(msg);}
};
int main(){
 MidiByteParser parser;std::vector<MidiMessage> parsed;uint8_t bytes[]={0xb2,7,0xf8,99,8,64,0xf0,1,2,0xf8,0xf7,0x92,40,127,41,0};parser.feed(bytes,sizeof(bytes),1,[&](MidiMessage m){parsed.push_back(m);});assert(parsed.size()==6&&parsed[0].status==0xf8&&parsed[1].data2==99&&parsed[2].data1==8&&parsed[4].status==0x92&&parsed[5].data2==0);
 assert(midiParameterValue({{"kind","bool"}},64,false)==true);assert(midiParameterValue({{"kind","float"},{"min",1.},{"max",100.},{"scale","log"}},127,1)==100.);assert(midiParameterValue({{"kind","color"}},0,"#ffffff")=="#ff0000");assert(midiParameterPosition({{"kind","color"}},"#00ff00")==42);
 Json doc=Json::object();resetControlRuntime(doc);doc["grid"]={{"rows",Json::array()},{"columns",Json::array()},{"running",{{"program",true}}},{"control_focus",{{"bus","program"},{"row",nullptr},{"column",nullptr}}}};
 // An old saved selection must not trigger scanning or opening at startup.
 midiModelCommand(doc,{{"action","midi_select"},{"name","Test Input"}});
 std::mutex mutex;std::condition_variable changed;Json status=Json::object();auto fake=std::make_unique<FakeMidi>();auto* backend=fake.get();
 MidiRuntime runtime({[&]{std::lock_guard lock(mutex);auto state=controlSnapshot(doc);state["grid"]=doc["grid"];state["midi"].update(status);return Json{{"state",state}};},[]{return Json::array();},[&](const std::string& path,const Json& body){std::lock_guard lock(mutex);auto copy=doc;requestControl(copy,"POST",path,body);doc=copy;changed.notify_all();},[&](const Json& next){std::lock_guard lock(mutex);status=next;changed.notify_all();}},std::move(fake));
 runtime.start();auto wait=[&](auto pred){std::unique_lock lock(mutex);assert(changed.wait_for(lock,std::chrono::seconds(3),pred));};wait([&]{return !status.empty();});{std::lock_guard lock(backend->mutex);assert(backend->scans==0&&backend->opens==0);}
 {std::lock_guard lock(mutex);midiModelCommand(doc,{{"action","midi_select"},{"name","Test Input"}});}wait([&]{return status.value("status",std::string{})=="Connected";});
 {std::lock_guard lock(mutex);midiModelCommand(doc,{{"action","midi_learn"},{"target",{{"kind","mix_master"},{"which","video"}}}});}
 backend->emit({0xb0,7,100,2});wait([&]{return doc["controls"]["midi"]["learning"].is_null();});backend->emit({0xb0,7,64,3});wait([&]{return doc["controls"]["mix"]["video_master"]==64./127;});
 {std::lock_guard lock(mutex);requestControl(doc,"POST","/api/v1/clock",{{"action","midi_clock_sync"},{"enabled",true}});}for(int i=0;i<25;i++)backend->emit({0xf8,0,0,10+i*.6/24});wait([&]{return std::abs(doc["controls"]["clock"]["bpm"].get<double>()-100)<.01;});runtime.stop();{std::lock_guard lock(backend->mutex);assert(backend->opens==1&&backend->sends==0);}std::cout<<"MIDI parser, learning, clock and explicit activation checks passed\n";
}
