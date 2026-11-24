#pragma once
#include <nlohmann/json.hpp>
#include <cstdint>
#include <span>
#include <vector>
namespace vj {
using CalibrationJson=nlohmann::json;
CalibrationJson calibrationSequence(int width,int height,int cell=4);
CalibrationJson calibrationSamples(const CalibrationJson& cards,int width,int height);
// Input sample frames are luminance arrays or interleaved RGB arrays, one per pattern.
CalibrationJson calibrationDecode(const CalibrationJson& samples,const CalibrationJson& frames,const CalibrationJson& sequence,int width,int height,int cell=4,int skipBits=0,int channel=-1,double contrast=18);
CalibrationJson calibrationFit(const CalibrationJson& card,const CalibrationJson& matches,int width,int height,int cell=4);
CalibrationJson calibrationMappedArea(const CalibrationJson& corners,double size=.9);
// Captured-frame workflow: same luminance-first, RGB fallback and wider-cell retry order.
CalibrationJson calibrationSolve(const CalibrationJson& cards,const CalibrationJson& samples,const CalibrationJson& luminanceFrames,const CalibrationJson& rgbFrames,const CalibrationJson& projector,int cell=4,double mappedSize=.9);
// RGBA pixels, camera coordinates. No camera is opened by these functions.
CalibrationJson calibrationDetect(std::span<const uint8_t> rgba,int width,int height,const CalibrationJson& options=CalibrationJson::object());
CalibrationJson calibrationHint(std::span<const uint8_t> rgba,int width,int height,double x,double y,const CalibrationJson& options=CalibrationJson::object());
}
