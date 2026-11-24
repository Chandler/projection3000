#pragma once
#include <nlohmann/json.hpp>
#include <filesystem>
#include <memory>
#include <string>
#include <vector>

namespace vj {
// Optional command-line FFmpeg workers. All files are cached under the native
// data root; source media is read-only. Destruction cancels and joins workers.
class MediaProcessing {
public:
    using Json=nlohmann::json;
    explicit MediaProcessing(std::filesystem::path cacheRoot);
    ~MediaProcessing();
    MediaProcessing(const MediaProcessing&)=delete;
    Json subtitleTracks(const std::filesystem::path& file) const;
    Json prepareSubtitle(const std::filesystem::path& file,const std::string& track,bool retry=false);
    std::string subtitleAsset(const std::filesystem::path& file,const std::string& track) const;
    Json renditions(const std::filesystem::path& file) const;
    Json startPreprocess(const std::vector<std::filesystem::path>& files);
    Json cancelPreprocess();
    Json preprocessStatus() const;
    Json subtitleStatus() const;
    std::uint64_t revision() const;
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
}
