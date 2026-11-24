#pragma once
#include <filesystem>
#include <functional>
#include <nlohmann/json.hpp>
namespace vj {
// Software frame at the clip's seek position within its loop interval. Local
// files only; no playback/audio/live capture. Cached by source identity + seek.
std::filesystem::path mediaClipThumbnail(const std::filesystem::path& file,
    const std::filesystem::path& cacheRoot,const nlohmann::json& params,
    const std::function<bool()>& cancelled={});
}
