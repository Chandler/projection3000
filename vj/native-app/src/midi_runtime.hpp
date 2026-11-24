#pragma once
#include <nlohmann/json.hpp>
#include <functional>
#include <memory>
#include <string>
#include <vector>
#include <cstdint>
namespace vj {
using Json=nlohmann::json;
struct MidiMessage {uint8_t status=0,data1=0,data2=0;double seconds=0;};
struct MidiPorts {std::vector<std::string> inputs,outputs;};
class MidiBackend {
public:
    using Receive=std::function<void(MidiMessage)>;
    virtual ~MidiBackend()=default;
    virtual bool available()const=0;
    virtual MidiPorts ports()=0;
    virtual void open(const std::string& input,bool controller,Receive receive)=0;
    virtual void send(const std::vector<uint8_t>& bytes)=0;
    virtual void close()=0;
};
std::unique_ptr<MidiBackend> makeMidiBackend();
// Defined only by midi_mac.mm; pass explicitly in the Mac application host.
std::unique_ptr<MidiBackend> makeMacMidiBackend();
bool isApc40(const std::string& name);
// Portable byte parser, including running status and interleaved realtime.
class MidiByteParser {
    uint8_t status_=0;std::vector<uint8_t> data_;bool sysex_=false;
public:
    void feed(const uint8_t* bytes,size_t count,double seconds,const MidiBackend::Receive& receive);
    void reset();
};
// Pure configuration mutation; root supplies atomic document transaction.
// /api/v1/midi POST: midi_scan, midi_select, midi_learn, midi_unmap,
// midi_capture (inject/learn CC or note), midi_fader_position (APC feedback).
Json midiModelCommand(Json& document,const Json& body);
Json midiControlHooks(const Json& document,const Json& catalog,bool connected,bool patchOwnsTracks,bool patchOwnsCrossfader=false);
struct MidiRuntimeCallbacks {
    std::function<Json()> snapshot;
    std::function<Json()> catalog;
    std::function<void(const std::string&,const Json&)> command;
    std::function<void(const Json&)> status;
    // Return true when embedded Patch owns APC track faders; no document transaction.
    std::function<bool(int,double)> channelFader;
    std::function<bool(int,int,int)> controllerMessage;
    std::function<bool()> controllerOwned;
};
// Construction/start never discover or connect. Only a new explicit scan or
// selection token during this runtime's lifetime authorizes device access.
class MidiRuntime {
public:
    explicit MidiRuntime(MidiRuntimeCallbacks callbacks,std::unique_ptr<MidiBackend> backend=makeMidiBackend());
    ~MidiRuntime();
    MidiRuntime(const MidiRuntime&)=delete;
    void start();
    void stop();
private:
    struct Impl;std::unique_ptr<Impl> impl_;
};
// Shared with native inspector and controller feedback, independent of devices.
Json midiParameterValue(const Json& spec,int value,const Json& current,bool quantize=true);
int midiParameterPosition(const Json& spec,const Json& value);
}
