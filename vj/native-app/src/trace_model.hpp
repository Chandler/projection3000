#pragma once
#include <nlohmann/json.hpp>
#include <string>
namespace vj {
// Mapping trace objects are projected LED paths. Their fixture route is separate
// from the trace appearance and from surface/collection trace effects.
void normalizeMappingTraces(nlohmann::json& project);
nlohmann::json requestMappingTrace(nlohmann::json& project,const std::string& method,const std::string& id,const nlohmann::json& body);
std::string mappingTraceFixtureId(const std::string& mappingId,const std::string& traceId);
// Reconcile virtual fixtures after mapping load/edit/undo/layout/copy. Physical
// fixtures and existing virtual fixture routing/composition remain untouched.
void reconcileMappingTraceFixtures(nlohmann::json& document);
// Ordered topology descriptors for API/UI/render consumers; point motion does
// not recreate fixtures or reset routes.
nlohmann::json mappingTraceTopology(const nlohmann::json& document);
}
