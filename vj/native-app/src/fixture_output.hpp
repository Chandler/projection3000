#pragma once
#include <nlohmann/json.hpp>
#include <memory>
#include <functional>
#include <map>
#include <string>
#include <vector>
#include <optional>
#include <array>
namespace vj {
using Json=nlohmann::json;
using FixtureFrames=std::map<std::string,std::vector<std::uint8_t>>;
class DmxTransport {
public:
 virtual ~DmxTransport()=default;
 virtual Json scan()=0;
 virtual Json connect(const std::string& serial)=0;
 virtual void write(const std::array<std::uint8_t,512>& universe)=0;
 virtual void close()=0;
};
class LedTransport {
public:
 virtual ~LedTransport()=default;
 virtual void configure(const std::string& host,int port)=0;
 // False means resolving/retrying; it does not claim receipt by the fixture.
 virtual bool send(int start,const std::vector<std::uint8_t>& rgb)=0;
 virtual Json status()const=0;
 virtual void close()=0;
};
std::unique_ptr<DmxTransport> makeSoundSwitchTransport();
std::unique_ptr<LedTransport> makeWledTransport();
std::vector<std::uint8_t> wledPacket(int start,const std::vector<std::uint8_t>& rgb);
// Pure command/configuration helpers. Call on a transaction copy. Does not
// scan, load USB libraries, resolve hosts, open sockets, or send any packets.
void initializeFixtureOutput(Json& document);
Json fixtureOutputSnapshot(const Json& document);
std::optional<Json> fixtureOutputRequest(Json& document,const std::string& method,const std::string& path,const Json& body,const Json& runtime=Json::object());
struct FixtureOutputCallbacks {
 std::function<Json()> snapshot;
 std::function<void(const std::string&,const Json&)> status;
};
class FixtureOutputRuntime {
public:
 explicit FixtureOutputRuntime(FixtureOutputCallbacks callbacks,
  std::unique_ptr<DmxTransport> dmx=makeSoundSwitchTransport(),
  std::unique_ptr<LedTransport> led=makeWledTransport());
 ~FixtureOutputRuntime();
 void start(); // Saves token baseline; previously saved hardware never starts.
 void stop();  // Blackout before releasing any active output.
 // Bytes are already mixed and power-limited by LedSampler. No GPU types.
 void submitFrames(FixtureFrames frames);
private:
 struct Impl;std::unique_ptr<Impl> impl_;
};
}
