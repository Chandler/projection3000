#pragma once
#include <nlohmann/json.hpp>
#include <optional>
#include <string>

namespace vj {
using Json = nlohmann::json;
// Configuration only: these functions never enumerate hardware or open outputs.
// Runtime data is injected by a host and must never be persisted with document.
Json outputDefaults();
Json validateNdiProjectors(const Json& raw);
Json migrateNdiOutputs(const Json& raw);
Json validateDisplayAssignments(const Json& raw);
void initializeOutputSettings(Json& document);
bool isOutputRoute(const std::string& path);
std::optional<Json> requestOutput(Json& document, const std::string& method,
    const std::string& path, const Json& body, const Json& runtime = Json::object());
// Fields to merge into the public state snapshot. All 20 internal Out bus names
// are present in output_projectors/output_destinations, as in the original app.
Json outputSnapshot(const Json& document, const Json& runtime = Json::object());
}
