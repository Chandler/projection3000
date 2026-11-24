#pragma once
#include "model.hpp"
namespace vj {
void validateMappingProject(Json& project);
Json captureMappingClipboard(const Json& mapping,const Json& ids,const std::string& mid,const std::string& trace={});
Json mappingSnapshot(const Json& document,const std::string& mid,const Json& selection=Json::array(),bool collectionsNormalized=false);
Json mappingRequest(Json& document,const std::string& method,const std::vector<std::string>& path,const Json& body);
Json mappingIds(const Json& project,const Json& ids,bool allowEmpty=false);
Json mappingLayouts(const Json& document);
}
