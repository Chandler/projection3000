#include "link_runtime.hpp"
#include "api_error.hpp"
#include <atomic>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <mutex>
#include <set>
#include <thread>
#include <unistd.h>
namespace vj {
namespace {
double now(){return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();}
std::string token(){static std::atomic<uint64_t> seq=0;return std::to_string(getpid())+":"+std::to_string(now())+":"+std::to_string(++seq);}
void check(bool valid,const std::string& reason){if(!valid)throw ApiError(400,reason);}
Json defaults(){return {{"enabled",false},{"quantum",4.},{"startStopSync",false},{"tempo",120.},{"playing",false},{"activationToken",""},{"tempoToken",""},{"playingToken",""}};}
Json config(const Json& d){auto value=d.value("controls",Json::object()).value("link",Json::object());auto def=defaults();for(auto i=def.begin();i!=def.end();++i)if(!value.contains(i.key()))value[i.key()]=i.value();value["sync"]=d.value("controls",Json::object()).value("clock",Json::object()).value("link_sync",false);return value;}
}
void initializeLink(Json& d){auto c=config(d);c.erase("sync");d["controls"]["link"]=c;}
Json linkSnapshot(const Json& d){auto c=config(d);return {{"linkConfig",c},{"link",{{"available",linkBackendAvailable()},{"enabled",false},{"sync",c["sync"]},{"error",""},{"peers",0},{"tempo",0.},{"beat",0.},{"phase",0.},{"playing",false}}}};}
std::optional<Json> linkRequest(Json& d,const std::string& method,const std::string& path,const Json& incoming,const Json& runtime){
 if(path!="/api/v1/link")return std::nullopt;initializeLink(d);if(method=="GET"){auto result=linkSnapshot(d)["link"];result.update(runtime);result["config"]=config(d);return result;}
 check(method=="POST"||method=="PATCH","Use POST or PATCH");auto body=incoming;if(body.is_object())body.erase("revision");check(body.is_object(),"Expected an object");for(auto i=body.begin();i!=body.end();++i)check(std::set<std::string>{"action","enabled","bpm","playing","quantum"}.contains(i.key()),"Unknown Link field: "+i.key());auto action=body.value("action",std::string{});auto& c=d["controls"]["link"];auto& clock=d["controls"]["clock"];
 if(action=="set_enabled"||action=="set_sync"||action=="start_stop_sync"){
  check(body.at("enabled").is_boolean(),"enabled must be boolean");bool enabled=body["enabled"];if(enabled&&!linkBackendAvailable())throw ApiError(501,"Ableton Link SDK is not included in this build");
  if(action=="set_sync"){clock["link_sync"]=enabled;if(enabled){clock["midi_clock_sync"]=false;c["enabled"]=true;c["activationToken"]=token();}}
  else if(action=="set_enabled"){c["enabled"]=enabled;c["activationToken"]=token();if(!enabled)clock["link_sync"]=false;}
  else c["startStopSync"]=enabled;
 }else if(action=="set_tempo"){
  check(body.at("bpm").is_number(),"bpm must be numeric");double bpm=body["bpm"];check(std::isfinite(bpm)&&bpm>=20&&bpm<=300,"bpm must be 20..300");c["tempo"]=bpm;c["tempoToken"]=token();
 }else if(action=="set_playing"){check(body.at("playing").is_boolean(),"playing must be boolean");c["playing"]=body["playing"];c["playingToken"]=token();}
 else if(action=="set_quantum"){check(body.at("quantum").is_number(),"quantum must be numeric");double q=body["quantum"];check(std::isfinite(q)&&q>0&&q<=64,"quantum must be greater than 0 and at most 64");c["quantum"]=q;}
 else throw ApiError(400,"Unknown Link action");return config(d);
}
struct LinkRuntime::Impl {
 LinkRuntimeCallbacks cb;std::unique_ptr<LinkBackend> backend;std::jthread worker;std::mutex mutex;std::condition_variable wake;std::string activationToken,tempoToken,playingToken,error;bool active=false,sync=false,startStop=false;Json previousStatus;
 Impl(LinkRuntimeCallbacks c,std::unique_ptr<LinkBackend> b):cb(std::move(c)),backend(std::move(b)){}
 void clear(){if(sync){sync=false;cb.clock(Json());}}
 void report(const Json& session){Json report=session;report.erase("capturedAt");report.update({{"available",backend->available()},{"enabled",active},{"sync",sync},{"error",error},{"acknowledgedToken",activationToken},{"startStopSync",startStop}});for(auto key:{"beat","phase","tempo"})if(report.contains(key)&&report[key].is_number())report[key]=std::round(report[key].get<double>()*1000)/1000.;if(report!=previousStatus){previousStatus=report;cb.status(report);}}
 void loop(std::stop_token stop){
  while(!stop.stop_requested()){
   try{
    auto state=cb.snapshot().at("state");auto c=state.value("linkConfig",defaults());auto clock=state.value("clock",Json::object());auto activation=c.value("activationToken",std::string{});if(activation!=activationToken){activationToken=activation;bool enabled=c.value("enabled",false);backend->enable(enabled,clock.value("bpm",state.value("bpm",120.)));active=enabled;error.clear();if(active){startStop=c.value("startStopSync",false);backend->startStopSync(startStop);}if(!active)clear();}
    bool wanted=active&&c.value("sync",false)&&!clock.value("midi_clock_sync",false);if(!wanted)clear();if(active){bool transportSync=c.value("startStopSync",false);if(transportSync!=startStop){backend->startStopSync(transportSync);startStop=transportSync;}
     auto tempo=c.value("tempoToken",std::string{});if(tempo!=tempoToken){tempoToken=tempo;backend->tempo(c.value("tempo",120.));}
     auto playing=c.value("playingToken",std::string{});if(playing!=playingToken){playingToken=playing;backend->playing(c.value("playing",false));}
    }
    auto session=backend->session(c.value("quantum",4.));if(wanted){double bpm=session.value("tempo",0.),beat=session.value("beat",0.),at=session.value("capturedAt",0.);if(std::isfinite(bpm)&&bpm>=20&&bpm<=300&&std::isfinite(beat)&&std::isfinite(at)){sync=true;cb.clock({{"bpm",bpm},{"beat",beat},{"capturedAt",at}});}else {clear();error="Invalid Link session clock";}}
    report(session);
   }catch(const std::exception& e){error=e.what();try{backend->enable(false,120.);}catch(...){}active=false;try{clear();report({{"tempo",0.},{"beat",0.},{"phase",0.},{"peers",0},{"playing",false}});}catch(...){};}
   std::unique_lock lock(mutex);wake.wait_for(lock,std::chrono::milliseconds(100),[&]{return stop.stop_requested();});
  }
  try{clear();backend->enable(false,120.);active=false;report({{"tempo",0.},{"beat",0.},{"phase",0.},{"peers",0},{"playing",false}});}catch(...){}
 }
};
LinkRuntime::LinkRuntime(LinkRuntimeCallbacks cb,std::unique_ptr<LinkBackend> backend):impl_(std::make_unique<Impl>(std::move(cb),std::move(backend))){}
LinkRuntime::~LinkRuntime(){stop();}
void LinkRuntime::start(){if(impl_->worker.joinable())return;auto c=impl_->cb.snapshot().at("state").value("linkConfig",defaults());impl_->activationToken=impl_->cb.snapshot().at("state").value("startupPolicy",std::string("isolated"))=="restore"?"restore-on-start":c.value("activationToken",std::string{});impl_->tempoToken=c.value("tempoToken",std::string{});impl_->playingToken=c.value("playingToken",std::string{});impl_->worker=std::jthread([this](std::stop_token stop){impl_->loop(stop);});}
void LinkRuntime::stop(){if(impl_->worker.joinable()){impl_->worker.request_stop();impl_->wake.notify_all();impl_->worker.join();}}
}
