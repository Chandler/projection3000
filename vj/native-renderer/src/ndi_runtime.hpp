#pragma once
#include <cstddef>
#include <cstdint>
#include <Processing.NDI.Lib.h>
#include <memory>
#include <string>

// The SDK headers are MIT licensed; the proprietary runtime is loaded separately.
class NdiRuntime {
public:
    static std::shared_ptr<NdiRuntime> get();
    ~NdiRuntime();
    const NDIlib_v5 *api = nullptr;
    std::string error;
    std::string version;
private:
    NdiRuntime();
    void *handle_ = nullptr;
};
