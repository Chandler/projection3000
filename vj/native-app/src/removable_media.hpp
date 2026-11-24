#pragma once
#include <nlohmann/json.hpp>
#include <filesystem>
#include <functional>
#include <memory>
#include <vector>
namespace vj {
struct MediaDrive {std::string name,identity;std::filesystem::path mount;};
class RemovableMedia {
public:
    using Json=nlohmann::json;
    using Discovery=std::function<std::vector<MediaDrive>()>;
    explicit RemovableMedia(Discovery discovery={});
    ~RemovableMedia();
    Json drives(bool force=false);
    Json browse(const std::string& id,const std::string& relative="");
    std::filesystem::path resolve(const std::string& reference);
    static std::string driveId(const std::string& identity);
    static Json browseDirectory(const std::filesystem::path& root,const std::string& id,const std::string& name,const std::string& relative,const std::string& scheme);
private:
    struct Impl;std::unique_ptr<Impl> impl_;
};
RemovableMedia& removableMedia();
}
