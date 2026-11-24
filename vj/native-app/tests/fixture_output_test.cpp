#include "fixture_output.hpp"
#include "control_model.hpp"
#include "api_error.hpp"
#include <cassert>
#include <mutex>
#include <condition_variable>
#include <chrono>
#include <iostream>
using namespace vj;
struct FakeDmx:DmxTransport {
 std::mutex mutex;int scans=0,connects=0;std::vector<std::array<uint8_t,512>> frames;
 Json scan()override{std::lock_guard lock(mutex);scans++;return Json::array();}
 Json connect(const std::string&)override{std::lock_guard lock(mutex);connects++;return {{"serial","FAKE"}};}
 void write(const std::array<uint8_t,512>& frame)override{std::lock_guard lock(mutex);frames.push_back(frame);}
 void close()override{}
};
struct FakeLed:LedTransport {
 std::mutex mutex;int configurations=0;std::vector<std::vector<uint8_t>> packets;
 void configure(const std::string& host,int port)override{std::lock_guard lock(mutex);assert(host=="test.invalid"&&port==21324);configurations++;}
 bool send(int start,const std::vector<uint8_t>& frame)override{std::lock_guard lock(mutex);packets.push_back(wledPacket(start,frame));return true;}
 Json status()const override{return {{"host",""},{"port",0}};}
 void close()override{}
};
int main(){
 auto packet=wledPacket(300,{255,128,0,10,20,30});assert(packet==std::vector<uint8_t>({4,2,1,44,255,128,0,10,20,30}));try{wledPacket(65535,{0,0,0,0,0,0});assert(false);}catch(const ApiError&){}
 Json doc=Json::object();resetControlRuntime(doc);initializeFixtureOutput(doc);doc["controls"]["fixtures"]=Json::array({{{"id","strip"},{"kind","wled"},{"count",2},{"start",300},{"enabled",true}}});
 fixtureOutputRequest(doc,"POST","/api/v1/fixture-output",{{"action","start"},{"host","test.invalid"}});fixtureOutputRequest(doc,"POST","/api/v1/dmx",{{"action","connect"}});
 std::mutex mutex;std::condition_variable changed;Json runtime=Json::object();auto dmx=std::make_unique<FakeDmx>();auto led=std::make_unique<FakeLed>();auto* usb=dmx.get();auto* udp=led.get();
 FixtureOutputRuntime output({[&]{std::lock_guard lock(mutex);auto state=controlSnapshot(doc);state.update(fixtureOutputSnapshot(doc));for(auto i=runtime.begin();i!=runtime.end();++i)state[i.key()].update(i.value());return Json{{"state",state}};},[&](const std::string& key,const Json& value){std::lock_guard lock(mutex);runtime[key]=value;changed.notify_all();}},std::move(dmx),std::move(led));
 output.start();auto wait=[&](auto predicate){std::unique_lock lock(mutex);assert(changed.wait_for(lock,std::chrono::seconds(4),predicate));};wait([&]{return runtime.contains("fixtureOutput");});{std::lock_guard lock(usb->mutex);assert(usb->scans==0&&usb->connects==0);}{std::lock_guard lock(udp->mutex);assert(udp->configurations==0&&udp->packets.empty());}
 auto command=[&](const std::string& path,const Json& body){std::lock_guard lock(mutex);auto next=doc;fixtureOutputRequest(next,"POST",path,body,runtime);doc=next;};
 command("/api/v1/dmx",{{"action","connect"},{"controls",{{"dimmer",1.},{"red",1.}}}});command("/api/v1/fixture-output",{{"action","start"}});output.submitFrames({{"strip",{255,128,0,10,20,30}}});wait([&]{return runtime["dmx"].value("status",std::string{})=="connecting";});{std::lock_guard lock(usb->mutex);assert(!usb->frames.empty()&&usb->frames.front()[0]==0&&usb->frames.front()[1]==0);}
 wait([&]{return runtime["dmx"].value("connected",false);});command("/api/v1/dmx",{{"action","identify"}});wait([&]{return runtime["dmx"].value("identify",false);});{std::lock_guard lock(usb->mutex);assert(usb->frames.back()[0]==41&&usb->frames.back()[11]==255);}
 command("/api/v1/dmx",{{"action","reset"},{"motor","zoom"},{"controls",{{"blackout",true}}}});wait([&]{return runtime["dmx"].contains("channels")&&runtime["dmx"]["channels"][14]==97;});command("/api/v1/dmx",{{"action","disconnect"}});wait([&]{return runtime["dmx"].value("status",std::string{})=="disconnected";});output.stop();
 {std::lock_guard lock(usb->mutex);assert(usb->connects==1&&usb->frames.size()>3);for(size_t i=usb->frames.size()-3;i<usb->frames.size();i++)assert(usb->frames[i][0]==0&&usb->frames[i][1]==0);}{std::lock_guard lock(udp->mutex);assert(udp->configurations==1&&!udp->packets.empty()&&udp->packets.front()==packet);assert(udp->packets.back()[4]==0);}
 std::cout<<"Fixture packet, explicit activation, warmup, identify, reset and blackout checks passed\n";
}
