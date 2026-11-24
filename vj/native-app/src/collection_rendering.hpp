#pragma once
#include <nlohmann/json.hpp>
#include <map>
#include <set>
#include <string>
namespace vj {
struct CollectionRendering {
    nlohmann::json renderRects=nlohmann::json::array();
    // Derived bus -> (ordinary Out source, renderer collection context).
    std::map<std::string,std::pair<std::string,nlohmann::json>> contexts;
};
std::string collectionBusName(const std::string& mappingId,const std::string& collectionId);
nlohmann::json particleFaceChart(const nlohmann::json& face,const nlohmann::json& rect,double aspect=16.0/9.0,double metricAspect=0);
nlohmann::json collectionGeometry(const nlohmann::json& document);
// Input project must already have normalized/generated faces and mesh. Saved
// surfaces remain unchanged; derived draw rectangles live only in the result.
CollectionRendering collectionRendering(const nlohmann::json& project,const std::string& mappingId,
    const std::set<std::string>& activeSources,const std::set<std::string>& traceSources={});
}
