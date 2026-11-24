#pragma once
#include <nlohmann/json.hpp>
#include <string>
namespace vj {
nlohmann::json mappingEditorVisibility(const nlohmann::json& project,const nlohmann::json& stored);
bool mappingEditorVisible(const nlohmann::json& mapping,const nlohmann::json& id,bool trace=false);
nlohmann::json mappingEditorView(const nlohmann::json& mapping,const std::string& mappingId);
// Geometry uses normalized coordinates in the unrotated editor canvas.
// Pixel proportions swap when a projector is mounted in portrait orientation.
double mappingCanvasAspect(const nlohmann::json& project);
nlohmann::json defaultMappingSurfaceCorners(const nlohmann::json& project);
nlohmann::json mappingQuadPoint(const nlohmann::json& corners,double u,double v);
nlohmann::json mappingSubdivisionCells(const nlohmann::json& surface,int columns,int rows,int orientation=0);
// Original mapping_fold edit order plus mapping_curvature/pin patch semantics.
// Changes are committed to rect only after the full candidate validates.
void editMappingGeometry(nlohmann::json& rect,const nlohmann::json& patch);
// Normalizes coordinates, UV defaults, and curvature/pin defaults as the server
// does. Unknown non-geometry surface fields are preserved.
void validateMappingGeometry(nlohmann::json& rect);
void validateMappingGeometry(const nlohmann::json& rect);
}
