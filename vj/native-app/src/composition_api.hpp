#pragma once
#include <nlohmann/json.hpp>
#include <functional>
#include <string>
namespace vj {
using Json=nlohmann::json;
using CompositionGridExecutor=std::function<Json(Json&,const Json&)>;
// Call at startup with resetClocks=true and after grid edits before persistence.
// Supplying the actual grid command also renews live A instance IDs on relaunch.
void reconcileCompositionApi(Json& document,double now,double globalBeat,bool resetClocks=false,const Json& gridCommand=Json::object());
// Times are monotonic seconds and global beat; caller may apply video shift to
// both arguments when obtaining render clocks. Clocks are independent of mute.
Json compositionClock(const Json& document,const std::string& bus,double now,double globalBeat,double bpm);
// Original external snapshot's `outputs` object. Unsupported vector recipes and
// bank frame sockets are null rather than advertising nonexistent endpoints.
Json compositionOutputs(const Json& document,const Json& catalog,const Json& routing,double now,double globalBeat,double bpm);
// Apply ONLY on an isolated transaction copy. Executor must use its supplied
// document. Returns executed grid commands; caller commits once and returns the
// full external snapshot. Actual original route is POST /api/v1/outputs/{out}.
Json applyCompositionCommand(Json& document,const std::string& out,const Json& body,const Json& catalog,const CompositionGridExecutor& execute,double now,double globalBeat);
}
