#pragma once
#include <nlohmann/json.hpp>
#include <string>
namespace vj {
nlohmann::json mappingBoxAlignment(const nlohmann::json& collection,const std::string& boxId);
nlohmann::json mappingBoxSubdivision(const nlohmann::json& project,const std::string& collectionId,const std::string& boxId,int columns,int rows,int depth);
void normalizeMappingCollections(nlohmann::json& project);
void removeMappingCollectionSurfaces(nlohmann::json& project,const nlohmann::json& rectIds);
nlohmann::json requestMappingCollection(nlohmann::json& project,const std::string& method,const std::string& id,const nlohmann::json& body);
nlohmann::json moveMappingCollectionSurfaces(nlohmann::json& project,const nlohmann::json& rectIds,const nlohmann::json& offset);
nlohmann::json mappingCollectionRenderRects(const nlohmann::json& project);
}
