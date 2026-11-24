#pragma once
#include "model.hpp"
namespace vj {
// Pure snapshot decoration, except cached uname/gethostname. No discovery,
// network calls, renderer startup, or device access. Pass application uptime.
void decorateExternalSnapshot(Json& snapshot,double uptimeSeconds,bool wasmAvailable);
Json externalEffectsResponse(Json catalog,bool wasmAvailable);
std::filesystem::path defaultApiAssetRoot();
// Original /docs and allowlisted /sdk files; /api/v1 and /capabilities are
// native read-only discovery extensions. assetRoot is the checked-out VJ root
// or the equivalent bundled Resources directory. Missing files return 404.
std::optional<Reply> apiCompatibilityReply(const std::string& method,const std::string& path,
    const Json& snapshot,const Json& catalog,const std::filesystem::path& assetRoot);
}
