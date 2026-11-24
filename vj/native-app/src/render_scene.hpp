#pragma once
#include "model.hpp"
#include "native_scene.hpp"

namespace vj {
// The UI and a future service render host share the same scene translation.
NativeScene renderScene(const Json& snapshot, const std::vector<std::string>& outputs,
                        double seconds);
}
