#pragma once
#include "calibration_capture.hpp"
#include "frame_transport.hpp"
#include <filesystem>
#include <optional>
namespace vj {
using CalibrationDebugDecoder=std::function<FrameImage(const std::vector<uint8_t>&)>;
// Installing a CPU PNG decoder performs no capture, discovery or file writes.
void installCalibrationDebugDecoder(CalibrationDebugDecoder decoder);
nlohmann::json createCalibrationDebug(const std::filesystem::path& root,const nlohmann::json& settings);
void saveCalibrationDebug(const std::filesystem::path& root,const std::string& token,
    nlohmann::json metadata,const CalibrationFrame& frame,const FrameTransport::Encoder& encode);
struct CalibrationDebugResponse {
    int status=200;nlohmann::json body=nlohmann::json::object();
    std::shared_ptr<const std::vector<uint8_t>> bytes;std::string contentType="application/json";
};
// Root should be Model::stateRoot()/"calibration-scans". Call outside Model lock.
// Original create/upload/read routes; nullopt for unrelated paths. Throws ApiError.
std::optional<CalibrationDebugResponse> calibrationDebugRequest(const std::filesystem::path& root,
    const std::string& method,const std::string& path,const nlohmann::json& body,
    const FrameTransport::Encoder& encode);
}
