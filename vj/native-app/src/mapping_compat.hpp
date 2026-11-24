#pragma once
#include "model.hpp"
namespace vj {
bool mappingCompatibilityRoute(const std::string& path);
// Operate on transaction copy. Caller owns history/persistence/reconciliation.
Json mappingCompatibilityCommand(Json& document,const std::string& path,const Json& body);
// Validate only; does not mutate or persist the document.
Json prepareMappingPreview(const std::string& mid,const Json& body);
Json mappingCompatibilityPreview(const Json& document,const std::string& mid,const Json& body);
// For render hosts only: persistent API/editor snapshots remain unchanged.
void applyMappingPreviews(Json& snapshot);
// One cache per render host; never changes committed/editor snapshots.
class MappingPreviewCache {
public:
    void apply(Json& snapshot);
private:
    uint64_t revision_=UINT64_MAX,media_=UINT64_MAX;
    Json previews_,derived_=Json::object();
};
}
