#pragma once
#include "frame_transport.hpp"
namespace vj {
// Engine backend for FrameTransport::setEncoder. CPU JPEG/PNG only, no GL.
std::vector<std::uint8_t> encodeFrameImage(const FrameImage& image,const FrameEncoding& encoding);
}
