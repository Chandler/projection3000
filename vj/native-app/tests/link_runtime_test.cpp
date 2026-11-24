#include "link_runtime.hpp"
#include <cassert>
#include <mutex>
#include <condition_variable>
#include <chrono>
#include <iostream>
using namespace vj;
struct FakeLink:LinkBackend {
 std::mutex mutex;int joins=0;bool enabled=false,playing_=false;double bpm=100.;
 bool available()const override{return true;}
 void enable(bool value,double)override{std::lock_guard lock(mutex);enabled=value;if(value)joins++;}
 void startStopSync(bool)override{}
 void tempo(double value)override{std::lock_guard lock(mutex);bpm=value;}
 void playing(bool value)override{std::lock_guard lock(mutex);playing_=value;}
 Json session(double)override{std::lock_guard lock(mutex);return {{"tempo",bpm},{"beat",42.25},{"phase",2.25},{"playing",playing_},{"peers",2},{"capturedAt",std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count()}};}
};
int main(){
 Json doc={{"controls",{{"clock",{{"bpm",120.},{"link_sync",true},{"midi_clock_sync",false}}}}}};initializeLink(doc);doc["controls"]["link"]["enabled"]=true;doc["controls"]["link"]["activationToken"]="saved";
 std::mutex mutex;std::condition_variable changed;Json status=Json::object(),sample;int samples=0,clears=0;auto fake=std::make_unique<FakeLink>();auto* backend=fake.get();
 LinkRuntime runtime({[&]{std::lock_guard lock(mutex);auto state=linkSnapshot(doc);state["clock"]=doc["controls"]["clock"];return Json{{"state",state}};},[&](const Json& next){std::lock_guard lock(mutex);status=next;changed.notify_all();},[&](const Json& next){std::lock_guard lock(mutex);sample=next;if(next.is_null())clears++;else samples++;changed.notify_all();}},std::move(fake));
 runtime.start();{std::lock_guard lock(backend->mutex);assert(backend->joins==0);} // start synchronously captures saved tokens.
 {std::lock_guard lock(mutex);doc["controls"]["link"]["activationToken"]="explicit-immediately-after-start";}
 auto wait=[&](auto pred){std::unique_lock lock(mutex);assert(changed.wait_for(lock,std::chrono::seconds(3),pred));};wait([&]{return samples>0;});{std::lock_guard lock(mutex);assert(sample["bpm"]==100.&&sample["beat"]==42.25&&sample["capturedAt"].get<double>()>0);doc["controls"]["link"]["tempo"]=132.;doc["controls"]["link"]["tempoToken"]="tempo";doc["controls"]["link"]["playing"]=true;doc["controls"]["link"]["playingToken"]="playing";}
 wait([&]{return status.value("playing",false)&&status.value("tempo",0.)==132.;});{std::lock_guard lock(mutex);doc["controls"]["clock"]["midi_clock_sync"]=true;doc["controls"]["clock"]["link_sync"]=false;}wait([&]{return clears>0;});runtime.stop();{std::lock_guard lock(backend->mutex);assert(backend->joins==1&&!backend->enabled);}
 std::cout<<"Link activation baseline, session clock, tempo/play commands and MIDI exclusion checks passed\n";
}
