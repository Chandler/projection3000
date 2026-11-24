#pragma once
#include <cstdint>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <vector>
namespace vj {
struct CalibrationFrame {
    int width=0,height=0;
    uint64_t sequence=0,timestampNs=0;
    std::string generation;
    std::shared_ptr<const std::vector<uint8_t>> rgba;
};
struct CalibrationCameraProvider {
    std::function<void(const std::string& device,const std::string& instance)> start;
    std::function<void()> stop;
    std::function<std::optional<CalibrationFrame>()> latest;
    std::function<std::string()> error;
};
// Portable callback registry, implemented in calibration_scan.cpp. No camera opens on install.
void installCalibrationCameraProvider(CalibrationCameraProvider provider);
bool calibrationCameraAvailable();
void startCalibrationCamera(const std::string& device,const std::string& instance);
void stopCalibrationCamera();
std::optional<CalibrationFrame> latestCalibrationCameraFrame();
std::string calibrationCameraError();
uint64_t calibrationTimeNs(); // steady_clock, same clock as frame timestampNs
// Optional LiveCapture/FFmpeg backend, implemented in calibration_capture.cpp.
void installLiveCalibrationCapture();
}
