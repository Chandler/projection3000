#pragma once
#include <nlohmann/json.hpp>
#include <filesystem>
#include <optional>
#include <functional>
#include <string>
#include <memory>
#include <cstdint>

namespace vj {
class MediaProcessing;
using MediaInspector=std::function<nlohmann::json(const std::filesystem::path& file,const std::filesystem::path& cacheRoot,bool thumbnail)>;
void installMediaInspector(MediaInspector inspector);
bool mediaInspectorAvailable();
// Optional software FFmpeg backend, linked only by renderer-enabled builds.
void installFFmpegMediaInspector();
// Read the existing library without modifying it. New imports belong exclusively
// to the native application's state directory until migration is approved.
class MediaLibrary {
public:
    using Json=nlohmann::json;
    explicit MediaLibrary(std::filesystem::path importRoot,
                          std::filesystem::path sharedRoot=defaultSharedRoot());
    static std::filesystem::path defaultSharedRoot();
    static std::string kind(const std::filesystem::path& path);
    Json catalog() const;
    Json status(const std::string& reference,const std::string& expectedKind="") const;
    std::string resolve(const std::string& reference,const std::string& expectedKind="") const;
    Json inspect(const std::string& reference,bool thumbnail=false) const;
    // Snapshot decoration never runs a decoder or waits for a worker.
    void decorateVideo(Json& clip) const;
    std::uint64_t processingRevision() const;
    Json importFile(const std::filesystem::path& source) const;
    // Native API extensions use JSON and do not masquerade as multipart upload.
    std::optional<Json> request(const std::string& method,const std::string& path,const Json& body) const;
private:
    std::filesystem::path sharedRoot_,importRoot_;
    std::shared_ptr<MediaProcessing> processing_;
    std::filesystem::path candidate(const std::string& reference) const;
    Json item(const std::filesystem::path& path,const std::filesystem::path& root,const std::string& scheme) const;
};
// Original image/video schemas. File choices are supplied by catalog(), not a
// stale list captured at compile time.
nlohmann::json mediaEffectCatalog();
std::string mediaItemIdentity(const nlohmann::json& items, size_t index);
void identifyMediaItems(nlohmann::json& items);
void validateMediaItems(const nlohmann::json& items);
}
