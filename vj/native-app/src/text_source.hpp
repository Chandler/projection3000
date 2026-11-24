#pragma once
#include <filesystem>
#include <functional>
#include <nlohmann/json.hpp>
#include <string>

namespace vj {
using TextRasterizer=std::function<void(const std::filesystem::path& destination,
                                      const std::filesystem::path& fontFile,
                                      int width,int height,const nlohmann::json& params)>;
void installTextRasterizer(TextRasterizer rasterizer,const std::string& version);
std::filesystem::path defaultTextFontRoot();
nlohmann::json textSourceCatalog(); // One effect object, same schema as original TextOverlay.
nlohmann::json normalizeTextParams(const nlohmann::json& params);
class TextSource {
public:
    TextSource(std::filesystem::path cacheRoot,std::filesystem::path fontRoot=defaultTextFontRoot());
    static bool available();
    nlohmann::json fonts() const;
    std::string asset(const nlohmann::json& params,int width,int height) const;
private:
    std::filesystem::path cacheRoot_,fontRoot_;
};
// Defined by the optional CoreText backend; portable core never calls this.
void installMacTextRasterizer();
void installPortableTextBackends();
}
