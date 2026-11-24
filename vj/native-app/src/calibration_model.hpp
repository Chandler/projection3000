#pragma once
#include <nlohmann/json.hpp>
#include <filesystem>
#include <mutex>
#include <map>
#include <set>
#include <string>
namespace vj {
// All times are monotonic seconds supplied by the host; no capture or GL ownership.
class CalibrationModel {
public:
    using Json=nlohmann::json;
    explicit CalibrationModel(std::filesystem::path stateRoot);
    Json status(const Json& displays,const Json& vectors=Json::object()) const;
    Json command(double now); // Expires abandoned sessions after eight seconds.
    Json projector(const Json& data,const Json& displays,double now);
    void touch(double now);
    void acknowledge(uint64_t revision); // Only for commands with no required physical targets.
    void acknowledgeTarget(const std::string& id,uint64_t revision);
    bool presented(uint64_t revision) const;
    Json startCamera(const std::string& device,const std::string& instance,double now);
    std::string cameraGeneration() const;
    void reloadFromDisk(); // Reload saved entries only; no pattern/camera mutation.
    Json library() const;
    Json save(const Json& calibration);
    // mappings is {id:{revision,project}}. Returns replacements only; no mutation.
    // Root validates every project then commits all replacements atomically.
    Json prepareLoad(const Json& requestedRevisions,const Json& mappings,const Json& displays,double now) const;
    void loaded(); // Only after the mapping transaction commits.
    Json diagnostics() const;
private:
    std::filesystem::path path_;
    mutable std::mutex mutex_;
    Json state_={{"revision",0},{"outputs",Json::object()},{"camera",""}},saved_=Json::array();
    std::string owner_,cameraInstance_,storageError_;
    double clientAt_=-1e9,leaseAt_=-1e9;
    uint64_t presented_=0;
    std::map<uint64_t,std::set<std::string>> requiredTargets_;
    std::map<std::string,uint64_t> presentedTargets_;
    void advance(Json next); // Caller holds mutex_.
};
}
