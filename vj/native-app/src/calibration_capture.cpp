#include "calibration_capture.hpp"
#include "live_capture.hpp"
#include <atomic>
#include <chrono>
#include <mutex>
#include <thread>
namespace vj { namespace {
class Capture {
    std::mutex mutex_;
    std::shared_ptr<LiveCapture> camera_;
    std::optional<CalibrationFrame> frame_;
    std::string generation_,device_;
    std::atomic_bool running_{true};
    std::thread worker_;
public:
    Capture():worker_([this]{run();}){}
    ~Capture(){running_=false;worker_.join();}
    void start(const std::string& device,const std::string& instance){std::lock_guard lock(mutex_);const auto generation=instance+":"+device;if(generation==generation_&&camera_)return;camera_=std::make_shared<LiveCapture>(device);device_=device;generation_=generation;frame_.reset();}
    void stop(){std::lock_guard lock(mutex_);camera_.reset();frame_.reset();generation_.clear();device_.clear();}
    std::optional<CalibrationFrame> latest(){std::lock_guard lock(mutex_);return frame_;}
    std::string error(){std::lock_guard lock(mutex_);return camera_?camera_->error():"Camera is not connected";}
private:
    void run(){while(running_){std::shared_ptr<LiveCapture> camera;std::string generation;uint64_t sequence=0;{std::lock_guard lock(mutex_);camera=camera_;generation=generation_;if(frame_)sequence=frame_->sequence;}if(camera){auto input=camera->latest();if(input&&input->rgb&&input->sequence!=sequence&&input->width>0&&input->height>0&&input->stride>=input->width*3&&input->rgb->size()>=size_t(input->stride)*input->height){auto timestamp=calibrationTimeNs();auto pixels=std::make_shared<std::vector<uint8_t>>(size_t(input->width)*input->height*4);for(int y=0;y<input->height;++y)for(int x=0;x<input->width;++x){size_t src=size_t(y)*input->stride+x*3,dst=(size_t(y)*input->width+x)*4;(*pixels)[dst]=(*input->rgb)[src];(*pixels)[dst+1]=(*input->rgb)[src+1];(*pixels)[dst+2]=(*input->rgb)[src+2];(*pixels)[dst+3]=255;}std::lock_guard lock(mutex_);if(camera==camera_&&generation==generation_)frame_=CalibrationFrame{input->width,input->height,input->sequence,timestamp,generation,std::move(pixels)};}}std::this_thread::sleep_for(std::chrono::milliseconds(5));}}
};
}
void installLiveCalibrationCapture(){auto shared=std::make_shared<Capture>();installCalibrationCameraProvider({[shared](const std::string& device,const std::string& instance){shared->start(device,instance);},[shared]{shared->stop();},[shared]{return shared->latest();},[shared]{return shared->error();}});}
}
