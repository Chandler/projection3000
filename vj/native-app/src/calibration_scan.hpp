#pragma once
#include "calibration_capture.hpp"
#include "calibration_detector.hpp"
#include <atomic>
#include <functional>
namespace vj {
struct CalibrationScanHooks {
    // Must return only after the revision was presented, or throw.
    std::function<CalibrationJson(const CalibrationJson&)> projector;
    std::function<void(const CalibrationJson&)> progress;
    // Optional inspectable capture archive; capture timing and samples are provided.
    std::function<void(const CalibrationJson&,const CalibrationFrame&)> capture;
};
// Waits for a changed camera frame; fresh=true requires receipt >request+80ms.
CalibrationFrame waitCalibrationFrame(const std::string& generation,uint64_t after,bool fresh,const std::atomic_bool& cancel,double timeoutSeconds=8);
// Synchronous worker operation. Uses shared capture provider, never owns a second camera.
// options: owner, cell=4, frameDelayMs=400, mappedSize=.9, previousProjectors=[]
// Returns {calibration,report:{kind,successes,failures,error}}; keeps prior valid results.
CalibrationJson runCalibrationScan(const CalibrationJson& cards,const CalibrationJson& projectors,const CalibrationJson& camera,const CalibrationJson& options,const CalibrationScanHooks& hooks,const std::atomic_bool& cancel);
}
