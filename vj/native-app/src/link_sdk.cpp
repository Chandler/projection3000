#include "link_runtime.hpp"
#include <ableton/Link.hpp>
#include <chrono>
namespace vj {
namespace {
class SdkLink final:public LinkBackend {
 std::unique_ptr<ableton::Link> link_;
public:
 ~SdkLink()override{if(link_)link_->enable(false);}
 bool available()const override{return true;}
 void enable(bool enabled,double initialTempo)override{if(enabled&&!link_)link_=std::make_unique<ableton::Link>(initialTempo);if(link_)link_->enable(enabled);}
 void startStopSync(bool enabled)override{if(link_)link_->enableStartStopSync(enabled);}
 void tempo(double bpm)override{if(!link_)return;auto state=link_->captureAppSessionState();state.setTempo(bpm,link_->clock().micros());link_->commitAppSessionState(state);}
 void playing(bool enabled)override{if(!link_)return;auto state=link_->captureAppSessionState();state.setIsPlaying(enabled,link_->clock().micros());link_->commitAppSessionState(state);}
 Json session(double quantum)override{
  if(!link_)return {{"tempo",0.},{"beat",0.},{"phase",0.},{"playing",false},{"peers",0},{"capturedAt",0.}};
  auto state=link_->captureAppSessionState();auto when=link_->clock().micros();double captured=std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();return {{"tempo",state.tempo()},{"beat",state.beatAtTime(when,quantum)},{"phase",state.phaseAtTime(when,quantum)},{"playing",state.isPlaying()},{"peers",link_->numPeers()},{"capturedAt",captured}};
 }
};
}
bool linkBackendAvailable(){return true;}
std::unique_ptr<LinkBackend> makeLinkBackend(){return std::make_unique<SdkLink>();}
}
