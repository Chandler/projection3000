#pragma once
#include <nlohmann/json.hpp>
#include <chrono>
#include <filesystem>
#include <map>
#include <mutex>

namespace vj {
// Validation/resolution never discovers a source, opens a camera, or loads NDI.
std::string normalizeNdiExtraIPs(const std::string& value); // invalid => exception
std::string normalizeLiveSelection(const std::string& generator,const std::string& value);
nlohmann::json liveSourceCatalog();
nlohmann::json liveSourceCapabilities();
std::filesystem::path liveSourceHelperPath();

// Only explicit discover() calls launch the native helper. Its separate process
// isolates Syphon's thread-affine discovery directory from renderer contexts.
class LiveSourceDiscovery {
public:
    explicit LiveSourceDiscovery(std::filesystem::path helper=liveSourceHelperPath());
    nlohmann::json discover(const std::string& kind,const std::string& extraIPs="");
    nlohmann::json capabilities()const;
private:
    struct Cached {nlohmann::json result;std::chrono::steady_clock::time_point updated;};
    std::filesystem::path helper_;
    std::mutex mutex_;
    std::map<std::string,Cached> cache_;
};
}
