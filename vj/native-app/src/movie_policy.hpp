#pragma once
#include <nlohmann/json.hpp>
#include <cmath>
namespace vj {
// Original projector eligibility: one visible normal Out 1 surface, no grid or traces.
inline bool movieMappingEligible(const nlohmann::json& project){
 const auto output=project.value("output",nlohmann::json::object());if(!output.value("enabled",true)||output.value("boundsGrid",false))return false;
 for(const auto& trace:project.value("traces",nlohmann::json::array()))if(trace.value("enabled",true))return false;
 const auto rects=project.value("rects",nlohmann::json::array());const nlohmann::json* visible=nullptr;for(const auto& rect:rects){if(rect.value("mode",std::string{})!="live"||rect.value("source",std::string("none"))=="none")continue;if(visible)return false;visible=&rect;}
 return visible&&visible->value("source",std::string{})=="out1"&&visible->value("blend",std::string("normal"))=="normal";
}
inline bool movieModeStable(double sinceStartup,double sinceCandidate){return sinceStartup>=6&&sinceCandidate>=1.5;}
inline bool movieDisplayModeMatches(size_t width,size_t height,size_t pixelsWide,size_t pixelsHigh,double refresh,
 size_t wantedWidth,size_t wantedHeight,size_t wantedPixelsWide,size_t wantedPixelsHigh){return width==wantedWidth&&height==wantedHeight&&pixelsWide==wantedPixelsWide&&pixelsHigh==wantedPixelsHigh&&std::isfinite(refresh)&&std::abs(refresh-24.)<.05;}
}
