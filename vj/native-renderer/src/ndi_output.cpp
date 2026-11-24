#include "ndi_output.hpp"
#include "ndi_runtime.hpp"
#include <condition_variable>
#include <mutex>
#include <thread>

struct NdiOutput::State {
    std::mutex mutex;
    std::condition_variable wake;
    bool stop=false, ready=false;
    std::vector<std::uint8_t> pending;
    int width=0,height=0,fps=0;
    std::string error;
    std::string source_name;
    std::uint64_t sent=0, dropped=0, queuedSequence=0, sentSequence=0;
    int receivers=0;
};
NdiOutput::NdiOutput(std::string label,int w,int h,int rate)
    : name(std::move(label)),width(w),height(h),fps(rate),state_(std::make_shared<State>()) {
    std::thread([state=state_,label=name] {
        std::shared_ptr<NdiRuntime> runtime;
        const NDIlib_v5 *api=nullptr;
        NDIlib_send_instance_t sender=nullptr;
        try {
        runtime=NdiRuntime::get();
        api=runtime->api;
        if(!api) { std::lock_guard lock(state->mutex);state->error=runtime->error;return; }
        NDIlib_send_create_t settings;
        settings.p_ndi_name=label.c_str();settings.clock_video=false;settings.clock_audio=false;
        sender=api->send_create(&settings);
        if(!sender) {std::lock_guard lock(state->mutex);state->error="NDI sender unavailable";return;}
        {std::lock_guard lock(state->mutex);
         const auto *source=api->send_get_source_name(sender);
         if(source && source->p_ndi_name)state->source_name=source->p_ndi_name;
         state->ready=true;}
        std::vector<std::uint8_t> rgba;
        while(true) {
            std::vector<std::uint8_t> rgb;
            int w,h,rate;std::uint64_t sequence=0;
            {
                std::unique_lock lock(state->mutex);
                state->wake.wait(lock,[&]{return state->stop || !state->pending.empty();});
                if(state->stop)break;
                rgb=std::move(state->pending);sequence=state->queuedSequence;
                w=state->width;h=state->height;rate=state->fps;
            }
            rgba.resize(static_cast<std::size_t>(w)*h*4);
            for(std::size_t i=0,j=0;i<rgb.size();i+=3,j+=4) {
                rgba[j]=rgb[i];rgba[j+1]=rgb[i+1];rgba[j+2]=rgb[i+2];rgba[j+3]=255;
            }
            NDIlib_video_frame_v2_t frame;
            frame.xres=w;frame.yres=h;frame.FourCC=NDIlib_FourCC_video_type_RGBX;
            frame.frame_rate_N=rate;frame.frame_rate_D=1;
            frame.picture_aspect_ratio=float(w)/h;
            frame.frame_format_type=NDIlib_frame_format_type_progressive;
            frame.p_data=rgba.data();frame.line_stride_in_bytes=w*4;
            api->send_send_video_v2(sender,&frame); // Buffer owned until synchronous send returns.
            const int receivers=api->send_get_no_connections(sender,0);
            {std::lock_guard lock(state->mutex);++state->sent;state->sentSequence=sequence;state->receivers=receivers;}
        }
        } catch (const std::exception &error) {
            std::lock_guard lock(state->mutex);
            state->ready=false;state->error=error.what();state->pending.clear();
        } catch (...) {
            std::lock_guard lock(state->mutex);
            state->ready=false;state->error="NDI output failed";state->pending.clear();
        }
        if(sender && api)api->send_destroy(sender);
    }).detach();
}
NdiOutput::~NdiOutput() {
    {std::lock_guard lock(state_->mutex);state_->stop=true;state_->pending.clear();}
    state_->wake.notify_one();
}
void NdiOutput::configure(int w,int h,int rate) {
    width=w;height=h;fps=rate;
}
bool NdiOutput::due() {
    const auto now=std::chrono::steady_clock::now();
    if(now<next_)return false;
    {std::lock_guard lock(state_->mutex);if(!state_->ready)return false;}
    const auto period=std::chrono::microseconds(1000000/fps);
    next_=(next_.time_since_epoch().count()==0 || now-next_>period)?now+period:next_+period;
    return true;
}
std::uint64_t NdiOutput::publish(std::vector<std::uint8_t> rgb) {
    if(rgb.size()!=static_cast<std::size_t>(width)*height*3)return 0;
    std::uint64_t sequence=0;
    {std::lock_guard lock(state_->mutex);if(!state_->pending.empty())++state_->dropped;state_->pending=std::move(rgb);state_->width=width;state_->height=height;state_->fps=fps;sequence=++state_->queuedSequence;}
    state_->wake.notify_one();return sequence;
}
nlohmann::json NdiOutput::diagnostics() const {
    std::lock_guard lock(state_->mutex);
    return {{"name",name},{"source_name",state_->source_name},{"ready",state_->ready},{"error",state_->error},{"sent",state_->sent},
            {"sentSequence",state_->sentSequence},{"queuedSequence",state_->queuedSequence},{"dropped",state_->dropped},{"receivers",state_->receivers},{"width",width},{"height",height},{"fps",fps}};
}
