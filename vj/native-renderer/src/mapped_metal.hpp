#pragma once
#include "processor_frame.hpp"
#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>

class MappedMetalRenderer {
public:
    MappedMetalRenderer();
    ~MappedMetalRenderer();
    // Vertex input is eight floats: clip XY, projective UVQ, three mapped attributes.
    // librarySource is a static MSL source string shared across frames.
    // Fragment buffers 0/1 are application data and buffer 2 is MappedBlend.
    // Return mappedColor(straightRGBA,blend) from the fragment function.
    bool draw(const char* librarySource,const char* fragmentFunction,
              const float* vertices,std::size_t floatCount,const void* uniforms,std::size_t uniformBytes,
              const void* extra,std::size_t extraBytes,int width,int height,const std::string& blend,float opacity);
    bool process(const NativeProcessorEncoder& encode,const std::string& source,const std::string& destination,
                 double seconds,unsigned int inputFramebuffer,unsigned int outputFramebuffer,int width,int height,
                 const std::string& blend,float opacity,std::string& error);
    std::string lastError() const;
    std::uint64_t draws() const;
private:
    struct State;
    std::unique_ptr<State> state_;
};
