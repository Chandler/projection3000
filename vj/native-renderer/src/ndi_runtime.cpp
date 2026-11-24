#include "ndi_runtime.hpp"
#include <cstdlib>
#include <dlfcn.h>
#include <filesystem>
#include <vector>
#ifdef __APPLE__
#include <mach-o/dyld.h>
#else
#include <unistd.h>
#endif

std::shared_ptr<NdiRuntime> NdiRuntime::get() {
    static auto runtime = std::shared_ptr<NdiRuntime>(new NdiRuntime);
    return runtime;
}
NdiRuntime::NdiRuntime() {
    std::vector<std::string> candidates;
    const auto *override_path = std::getenv("VIBE_NDI_LIBRARY");
    if (override_path && *override_path) candidates.emplace_back(override_path);
    else {
        char exe[4096] = {};
#ifdef __APPLE__
        const std::string library = "libndi.dylib";
        uint32_t size = sizeof(exe);
        if (_NSGetExecutablePath(exe, &size) != 0) exe[0] = 0;
#else
        const std::string library = "libndi.so.6";
        const auto count = readlink("/proc/self/exe", exe, sizeof(exe)-1);
        if (count > 0) exe[count] = 0;
#endif
#ifdef __APPLE__
        if (*exe) candidates.push_back((std::filesystem::path(exe).parent_path().parent_path()/"Frameworks"/library).string());
#endif
        if (*exe) candidates.push_back((std::filesystem::path(exe).parent_path()/library).string());
        for (const auto *key : {"NDI_RUNTIME_DIR_V6", "NDI_RUNTIME_DIR_V5"})
            if (const auto *directory = std::getenv(key); directory && *directory)
                candidates.push_back((std::filesystem::path(directory)/library).string());
        candidates.push_back("/usr/local/lib/" + library);
#ifdef __APPLE__
        candidates.push_back("/Library/NDI SDK for Apple/lib/macOS/libndi.dylib");
#else
        candidates.push_back("/usr/lib/x86_64-linux-gnu/" + library);
#endif
        candidates.push_back(library);
    }
    for (const auto &candidate : candidates) {
        handle_ = dlopen(candidate.c_str(), RTLD_NOW | RTLD_LOCAL);
        if (!handle_) continue;
        auto load = reinterpret_cast<const NDIlib_v5 *(*)()>(dlsym(handle_, "NDIlib_v5_load"));
        if (load) {
            const auto *functions = load();
            if (functions && functions->initialize()) {
                api = functions;
                version = api->version();
                return;
            }
        }
        dlclose(handle_); handle_ = nullptr;
    }
    error = "NDI runtime unavailable";
}
NdiRuntime::~NdiRuntime() {
    if (api) api->destroy();
    if (handle_) dlclose(handle_);
}
