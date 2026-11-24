#include "calibration_scan.hpp"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <mutex>
#include <stdexcept>
#include <thread>
namespace vj { namespace {
std::mutex providerMutex;CalibrationCameraProvider provider;
CalibrationCameraProvider cameraProvider(){std::lock_guard lock(providerMutex);return provider;}
void delay(int milliseconds,const std::atomic_bool& cancel){for(int elapsed=0;elapsed<milliseconds;elapsed+=10){if(cancel)throw std::runtime_error("Scan cancelled");std::this_thread::sleep_for(std::chrono::milliseconds(std::min(10,milliseconds-elapsed)));}}
using J=CalibrationJson;
}
void installCalibrationCameraProvider(CalibrationCameraProvider value){CalibrationCameraProvider old;{std::lock_guard lock(providerMutex);old=std::move(provider);provider=std::move(value);}if(old.stop)old.stop();}
bool calibrationCameraAvailable(){auto p=cameraProvider();return bool(p.start)&&bool(p.stop)&&bool(p.latest);}
void startCalibrationCamera(const std::string& device,const std::string& instance){auto p=cameraProvider();if(!p.start)throw std::runtime_error("Camera capture is unavailable on this build");p.start(device,instance);}
void stopCalibrationCamera(){auto p=cameraProvider();if(p.stop)p.stop();}
std::optional<CalibrationFrame> latestCalibrationCameraFrame(){auto p=cameraProvider();return p.latest?p.latest():std::nullopt;}
std::string calibrationCameraError(){auto p=cameraProvider();return p.error?p.error():"Camera capture is unavailable on this build";}
uint64_t calibrationTimeNs(){return std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();}
CalibrationFrame waitCalibrationFrame(const std::string& generation,uint64_t after,bool fresh,const std::atomic_bool& cancel,double timeout){const auto started=calibrationTimeNs();if(!std::isfinite(timeout)||timeout<=0||timeout>60)throw std::invalid_argument("Invalid camera frame timeout");while(calibrationTimeNs()-started<uint64_t(timeout*1e9)){if(cancel)throw std::runtime_error("Scan cancelled");auto frame=latestCalibrationCameraFrame();if(frame){if(frame->generation!=generation)throw std::runtime_error("Camera changed. Reconnect");if(frame->sequence>after&&(!fresh||frame->timestampNs>started+80'000'000))return *frame;}delay(10,cancel);}auto error=calibrationCameraError();throw std::runtime_error(error.empty()?"No camera frames from native renderer":error);}
J runCalibrationScan(const J& cards,const J& projectors,const J& camera,const J& options,const CalibrationScanHooks& hooks,const std::atomic_bool& cancel){
 if(!hooks.projector)throw std::invalid_argument("Calibration projector control is unavailable");
 const int width=camera.at("width"),height=camera.at("height"),cell=options.value("cell",4),wait=std::clamp(options.value("frameDelayMs",400),150,2000);const double mappedSize=options.value("mappedSize",.9);const auto generation=camera.at("generation").get<std::string>(),owner=options.at("owner").get<std::string>();if(owner.empty()||projectors.empty())throw std::invalid_argument("Select projectors before scanning");if(!std::isfinite(mappedSize)||mappedSize<=0||mappedSize>1)throw std::invalid_argument("Invalid mapped size");
 auto samples=calibrationSamples(cards,width,height);if(samples.empty())throw std::invalid_argument("Selected cards are too small");J results=options.value("previousProjectors",J::array()),report={{"kind","scanning"},{"successes",0},{"failures",0},{"error",""}};bool claimed=false;size_t total=0,done=0;for(auto& target:projectors)total+=calibrationSequence(target.at("width"),target.at("height"),cell).size();
 auto command=[&](J value){value["owner"]=owner;return hooks.projector(value);};auto progress=[&](J value){value["done"]=done;value["total"]=total;if(hooks.progress)hooks.progress(value);};
 try{
  command({{"op","claim"}});claimed=true;J targets=J::array();for(auto& p:projectors)targets.push_back(p.at("id"));command({{"op","black"}});
  for(auto& target:projectors){if(cancel)throw std::runtime_error("Scan cancelled");auto sequence=calibrationSequence(target.at("width"),target.at("height"),cell);J frames=J::array(),colors=J::array();uint64_t after=0;
   for(size_t index=0;index<sequence.size();++index){if(cancel)throw std::runtime_error("Scan cancelled");progress({{"phase","capturing"},{"target",target["id"]},{"pattern",index+1},{"patterns",sequence.size()}});const auto requested=calibrationTimeNs();auto status=command({{"op","render"},{"target",target["id"]},{"pattern",sequence[index]}});const auto acknowledged=calibrationTimeNs();if(status.contains("displays")){bool same=false;for(auto& display:status["displays"])if(display["id"]==target["id"]&&display.value("active",true)){same=display.value("physical",J())==target.value("physical",J())&&display.value("name",J())==target.value("name",J())&&display["width"]==target["width"]&&display["height"]==target["height"];}if(!same)throw std::runtime_error("Projector changed. Scan again");}
    delay(wait,cancel);auto frame=waitCalibrationFrame(generation,after,true,cancel);after=frame.sequence;if(frame.width!=width||frame.height!=height||!frame.rgba||frame.rgba->size()!=size_t(width)*height*4)throw std::runtime_error("Camera resolution changed");J luminance=J::array(),rgb=J::array();for(auto& sample:samples){int x=sample.at("x"),y=sample.at("y");size_t offset=(size_t(y)*width+x)*4;auto& data=*frame.rgba;double r=data[offset],g=data[offset+1],b=data[offset+2];luminance.push_back(r*.299+g*.587+b*.114);rgb.push_back(r);rgb.push_back(g);rgb.push_back(b);}if(hooks.capture)hooks.capture({{"target",target["id"]},{"index",index},{"pattern",sequence[index]},{"requestedAtNs",requested},{"acknowledgedAtNs",acknowledged},{"capturedAtNs",frame.timestampNs},{"samples",luminance},{"rgbSamples",rgb}},frame);frames.push_back(std::move(luminance));colors.push_back(std::move(rgb));++done;
   }
   command({{"op","black"}});progress({{"phase","fitting"},{"target",target["id"]}});auto result=calibrationSolve(cards,samples,frames,colors,target,cell,mappedSize);int successes=0;for(auto& card:result["cards"])if(card.contains("mapping"))++successes;report["successes"]=report["successes"].get<int>()+successes;report["failures"]=report["failures"].get<int>()+int(cards.size())-successes;if(successes){auto existing=std::find_if(results.begin(),results.end(),[&](const J& old){return old["projector"]["id"]==target["id"];});if(existing==results.end())results.push_back(std::move(result));else *existing=std::move(result);}
  }
  report["kind"]=report["successes"]==0?"failed":report["failures"]==0?"complete":"partial";
 }catch(const std::exception& error){report["kind"]=cancel?"cancelled":"failed";report["error"]=error.what();}
 if(claimed){try{command({{"op","release"}});}catch(const std::exception& error){if(report["error"]=="")report["error"]=error.what();}}
 J document={{"version",3},{"mappedSizePercent",mappedSize*100},{"method","gray-code + per-card homography"},{"renderer","native SDL2"},{"camera",camera},{"projectors",results}};progress({{"phase","finished"},{"report",report}});return {{"calibration",document},{"report",report}};
}
}
