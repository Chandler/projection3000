#pragma once
#include <nlohmann/json.hpp>
#include <optional>
#include <string>
namespace vj {
using Json=nlohmann::json;
// Pure configuration; no files, preview subscriptions, or physical outputs are
// activated. Persist document.room in the same transaction as mapping changes.
Json roomDefaults();
void initializeRoom(Json& document);
Json roomSnapshot(const Json& document);
bool isRoomRoute(const std::string& path);
// Original GET/PUT /api/v1/room, POST /room/history, POST /room/map.
// Works on a private copy and assigns only on success. Model owns disk commit.
std::optional<Json> requestRoom(Json& document,const std::string& method,const std::string& path,const Json& body);
// UI-only geometry contract: world metres, Y up, Euler ZYX degrees. Box mesh
// contains world corners and faces; projector fields include lens/frustum data.
// The optional native GET /api/v1/room/preview returns this same descriptor.
Json roomPreviewSnapshot(const Json& document);
// /ws/room subscription helper; host owns per-client union and frame transport.
// Return {projectorId:{width:640,height:round(640/aspect)}} without activation.
Json roomPreviewDemand(const Json& document,const Json& projectorIds);
}
