#pragma once
#include <nlohmann/json.hpp>
#include <string>
namespace vj {
struct UiRequest { std::string method,path; nlohmann::json body; };
// Translate verified original /ws/ui messages without modifying a Model or
// opening devices. Unsupported commands throw ApiError(501).
UiRequest translateUiCommand(const nlohmann::json& message);
}
