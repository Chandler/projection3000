#pragma once
#include <nlohmann/json.hpp>
#include <optional>
#include <string>
#include <array>
#include <vector>
namespace vj {
using Json=nlohmann::json;
// These functions never open a device or send network packets. Call request on
// a transaction copy; persist only after success. Unknown imported keys survive.
Json controlDefaults();
void resetControlRuntime(Json& document);
bool isControlRoute(const std::string& path);
std::optional<Json> requestControl(Json& document,const std::string& method,const std::string& path,const Json& body);
Json controlSnapshot(const Json& document);
Json controlClock(const Json& document,double now);
double controlNow();
std::array<unsigned char,512> dmxUniverse(const Json& controls,int address=1,int mode=15,bool identify=false,bool flash=false,int reset=0);
// Post-composition LED master, color, beat envelope, flash, then power ceiling.
void applyLedMix(std::vector<std::array<float,3>>& pixels,const Json& mix,double beat,double flash,double brightness,double powerLimit);
}
