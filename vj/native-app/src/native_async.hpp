#pragma once
#include "model.hpp"
// A single serial command lane for the editor. Validation and persistence stay
// in Model; AppKit receives completed authoritative state on its own queue.
void VJSubmitUiCommand(vj::Model*,std::string method,std::string path,vj::Json body,void (^completion)(const vj::Reply&),std::string coalescingKey={});
bool VJUiCommandsIdle(vj::Model*);
void VJStopUiCommands(vj::Model*);

void VJPublishUiOutputRuntime(vj::Model*,vj::Json runtime);
