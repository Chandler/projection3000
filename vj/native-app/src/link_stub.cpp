#include "link_runtime.hpp"
#include <stdexcept>
namespace vj {
namespace {
class NoLink final:public LinkBackend {
public:
 bool available()const override{return false;}
 void enable(bool enabled,double)override{if(enabled)throw std::runtime_error("Ableton Link SDK is not included in this build");}
 void startStopSync(bool)override{}
 void tempo(double)override{throw std::runtime_error("Ableton Link SDK is not included in this build");}
 void playing(bool)override{throw std::runtime_error("Ableton Link SDK is not included in this build");}
 Json session(double)override{return {{"tempo",0.},{"beat",0.},{"phase",0.},{"playing",false},{"peers",0},{"capturedAt",0.}};}
};
}
bool linkBackendAvailable(){return false;}
std::unique_ptr<LinkBackend> makeLinkBackend(){return std::make_unique<NoLink>();}
}
