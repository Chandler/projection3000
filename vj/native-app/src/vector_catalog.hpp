#pragma once
#include <nlohmann/json.hpp>
#include <filesystem>
#include <functional>
#include <vector>
namespace vj {
using VectorTextOutliner=std::function<std::vector<float>(const std::string&,const std::string&)>;
void installVectorTextOutliner(VectorTextOutliner outliner);
void installMacVectorTextOutliner();
bool vectorTextOutlinerAvailable();
nlohmann::json vectorEffectCatalog();
nlohmann::json normalizeVectorParams(const std::string& effect,const nlohmann::json& params);
nlohmann::json vectorRecipe(const std::string& effect,const nlohmann::json& params,int width,int height);
std::filesystem::path defaultVectorModuleRoot();
}
