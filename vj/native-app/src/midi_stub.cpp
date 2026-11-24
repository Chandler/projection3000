#include "midi_runtime.hpp"
#include <stdexcept>
namespace vj {
namespace {
class UnavailableMidi final:public MidiBackend {
public:
 bool available()const override{return false;}
 MidiPorts ports()override{return {};}
 void open(const std::string&,bool,Receive)override{throw std::runtime_error("MIDI backend unavailable on this build");}
 void send(const std::vector<uint8_t>&)override{throw std::runtime_error("MIDI output unavailable on this build");}
 void close()override{}
};
}
std::unique_ptr<MidiBackend> makeMidiBackend(){return std::make_unique<UnavailableMidi>();}
}
