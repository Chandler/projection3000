#pragma once
#include <nlohmann/json.hpp>
#include <functional>
#include <memory>
#include <optional>
#include <string>
namespace vj {
using Json=nlohmann::json;
class LinkBackend {
public:
 virtual ~LinkBackend()=default;
 virtual bool available()const=0;
 virtual void enable(bool enabled,double initialTempo)=0;
 virtual void startStopSync(bool enabled)=0;
 virtual void tempo(double bpm)=0;
 virtual void playing(bool playing)=0;
 // tempo, beat, phase, playing, peers, capturedAt (steady-clock seconds).
 virtual Json session(double quantum)=0;
};
bool linkBackendAvailable(); // Compile-time backend availability; no I/O.
std::unique_ptr<LinkBackend> makeLinkBackend();
void initializeLink(Json& document);
Json linkSnapshot(const Json& document);
// /api/v1/link GET/POST. Clock link_sync is delegated here by the Model.
std::optional<Json> linkRequest(Json& document,const std::string& method,const std::string& path,const Json& body,const Json& runtime=Json::object());
struct LinkRuntimeCallbacks {
 std::function<Json()> snapshot;
 std::function<void(const Json&)> status;
 // Null clears transient Link clock. Objects contain bpm, beat, capturedAt.
 // Host must not persist incoming session samples.
 std::function<void(const Json&)> clock;
};
class LinkRuntime {
public:
 explicit LinkRuntime(LinkRuntimeCallbacks callbacks,std::unique_ptr<LinkBackend> backend=makeLinkBackend());
 ~LinkRuntime();
 void start(); // Synchronously saves config tokens, without SDK/session I/O.
 void stop();
private:
 struct Impl;std::unique_ptr<Impl> impl_;
};
}
