#pragma once
#include <nlohmann/json.hpp>
namespace vj {
nlohmann::json metaMappingSnapshot(const nlohmann::json& document);
void appendMetaMappingRendering(nlohmann::json& snapshot);
void reconcileMetaMapping(nlohmann::json& document);
nlohmann::json metaMappingCommand(nlohmann::json& document,const nlohmann::json& command);
}
