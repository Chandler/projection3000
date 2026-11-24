#pragma once
#include <functional>
#include <string>

// Borrowed Metal objects are valid for the synchronous duration of encode.
// Textures have top-left orientation and matching premultiplied BGRA dimensions.
struct NativeProcessorFrame {
    const std::string& source;
    const std::string& destination;
    double seconds;
    void* inputTexture;
    void* outputTexture;
    void* commandBuffer;
};
using NativeProcessorEncoder=std::function<bool(const NativeProcessorFrame&,std::string& error)>;
