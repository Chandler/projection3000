#include "ndi_input.hpp"
#include "ndi_runtime.hpp"
#include <nlohmann/json.hpp>
#include <atomic>
#include <chrono>
#include <cstring>
#include <mutex>
#include <thread>
#include <algorithm>
#include <deque>
#include <cmath>

using Clock = std::chrono::steady_clock;
struct NdiInput::State {
    std::atomic<bool> stop{false};
    mutable std::mutex mutex;
    NdiSnapshot latest{nullptr, false, "Connecting"};
    Clock::time_point last_frame{}, next_due{};
    int buffer_ms=0, effective_ms=0;
    std::deque<std::pair<Clock::time_point,std::shared_ptr<const NdiFrame>>> queue;
    std::shared_ptr<const NdiFrame> presented;
    std::size_t queue_bytes=0;
};
NdiInput::NdiInput(std::string selection) : state_(std::make_shared<State>()) {
    // Only shared worker state outlives a removed clip; never the graph or GL context.
    std::thread([state=state_, selection=std::move(selection)] { run(state, selection); }).detach();
}
NdiInput::~NdiInput() { state_->stop = true; }
void NdiInput::set_buffer_ms(int milliseconds) {
    std::lock_guard lock(state_->mutex);
    milliseconds=std::clamp(milliseconds,0,500);
    if(state_->buffer_ms==milliseconds)return;
    state_->buffer_ms=milliseconds;state_->effective_ms=milliseconds;
    state_->queue.clear();state_->queue_bytes=0;state_->next_due={};
    // Keep the current image while refilling after a setting change.
}
NdiSnapshot NdiInput::snapshot() const {
    std::lock_guard lock(state_->mutex);
    auto result = state_->latest;
    if (result.connected && result.frame) {
        const double allowance = std::clamp(3.0 / std::max(0.1, result.frame->fps), 3.0, 30.0);
        if (std::chrono::duration<double>(Clock::now()-state_->last_frame).count() > allowance) {
            result.connected = false;
            result.error = "No recent frames";
        }
    }
    result.buffer_ms=state_->effective_ms;
    if(state_->buffer_ms>0 && state_->effective_ms>0){
        const auto now=Clock::now();
        while(!state_->queue.empty() && state_->queue.front().first<=now){
            state_->presented=state_->queue.front().second;
            state_->queue_bytes-=state_->presented->rgba.size();state_->queue.pop_front();
        }
        result.frame=state_->presented;
        result.queued_frames=static_cast<int>(state_->queue.size());
    }
    return result;
}
void NdiInput::run(const std::shared_ptr<State> &state, const std::string &selection) {
    std::shared_ptr<NdiRuntime> runtime;
    const NDIlib_v5 *api = nullptr;
    NDIlib_recv_instance_t receiver = nullptr;
    NDIlib_find_instance_t finder = nullptr;
    auto status = [&](bool connected, const std::string &error) {
        std::lock_guard lock(state->mutex);
        state->latest.connected = connected;
        state->latest.error = error;
    };
    try {
        runtime = NdiRuntime::get();
        api = runtime->api;
        if (!api) throw std::runtime_error(runtime->error);
        const auto source = nlohmann::json::parse(selection);
        const auto name = source.at("name").get<std::string>();
        std::string url = source.value("url", "");
        const auto extra = source.value("extra_ips", std::string{});
        const auto extra_ips = extra.empty() ? std::string("127.0.0.1") : "127.0.0.1," + extra;
        if (name.empty()) throw std::runtime_error("Invalid NDI source");
        NDIlib_find_create_t find_settings;
        find_settings.show_local_sources = true;
        find_settings.p_extra_ips = extra_ips.empty() ? nullptr : extra_ips.c_str();
        finder = api->find_create_v2(&find_settings);
        NDIlib_recv_create_v3_t settings;
        settings.source_to_connect_to = {name.c_str(), url.empty() ? nullptr : url.c_str()};
        settings.color_format = NDIlib_recv_color_format_RGBX_RGBA;
        settings.allow_video_fields = false;
        settings.bandwidth = NDIlib_recv_bandwidth_highest;
        settings.p_ndi_recv_name = "Vibe live clip";
        receiver = api->recv_create_v3(&settings);
        if (!receiver) throw std::runtime_error("NDI receiver unavailable");
        auto rediscover = Clock::now();
        std::uint64_t sequence = 0;
        while (!state->stop) {
            // Refresh addresses for saved sources, including DHCP changes.
            if (finder && Clock::now() >= rediscover) {
                rediscover = Clock::now() + std::chrono::seconds(1);
                api->find_wait_for_sources(finder, 1);
                uint32_t count = 0;
                const auto *sources = api->find_get_current_sources(finder, &count);
                for (uint32_t i=0; i<count; ++i) {
                    if (sources[i].p_ndi_name && name == sources[i].p_ndi_name) {
                        std::string current = sources[i].p_url_address ? sources[i].p_url_address : "";
                        // A sender on several networks advertises only one; prefer the first
                        // Remote IP (e.g. a direct cable) at the advertised port.
                        const auto preferred = extra.substr(0, extra.find(','));
                        const auto colon = current.rfind(':');
                        if (!preferred.empty() && colon != std::string::npos)
                            current = preferred + current.substr(colon);
                        if (url != current) {
                            // recv_connect does not reliably switch a receiver's address; recreate it.
                            url = current;
                            settings.source_to_connect_to = {name.c_str(), url.c_str()};
                            if (auto next = api->recv_create_v3(&settings)) { api->recv_destroy(receiver); receiver = next; }
                        }
                        break;
                    }
                }
            }
            NDIlib_video_frame_v2_t video;
            const auto type = api->recv_capture_v3(receiver, &video, nullptr, nullptr, 50);
            if (type == NDIlib_frame_type_video) {
                // Always release SDK-owned frames, including rejected formats.
                struct Release {
                    const NDIlib_v5 *api; NDIlib_recv_instance_t receiver; NDIlib_video_frame_v2_t *frame;
                    ~Release() { api->recv_free_video_v2(receiver, frame); }
                } release{api,receiver,&video};
                const auto bytes = std::int64_t(video.xres) * video.yres * 4;
                if (!video.p_data || video.xres <= 0 || video.yres <= 0
                    || video.xres > 16384 || video.yres > 16384 || bytes > 256*1024*1024
                    || video.line_stride_in_bytes < std::int64_t(video.xres)*4
                    || (video.FourCC != NDIlib_FourCC_video_type_RGBA && video.FourCC != NDIlib_FourCC_video_type_RGBX)) {
                    status(false, "Unsupported NDI frame"); continue;
                }
                auto frame = std::make_shared<NdiFrame>();
                frame->width = video.xres; frame->height = video.yres;
                frame->fps = video.frame_rate_D > 0 ? double(video.frame_rate_N)/video.frame_rate_D : 0;
                frame->sequence = ++sequence;
                frame->rgba.resize(static_cast<std::size_t>(bytes));
                const auto row_bytes = static_cast<std::size_t>(video.xres)*4;
                for (int row=0; row<video.yres; ++row)
                    std::memcpy(frame->rgba.data()+row*row_bytes,
                        video.p_data+std::size_t(row)*video.line_stride_in_bytes, row_bytes);
                if (video.FourCC == NDIlib_FourCC_video_type_RGBX)
                    for (std::size_t i=3;i<frame->rgba.size();i+=4) frame->rgba[i]=255;
                {
                    std::lock_guard lock(state->mutex);
                    const auto now=Clock::now();
                    if(state->buffer_ms>0){
                        const auto previous=state->latest.frame;
                        const auto period=std::chrono::duration_cast<Clock::duration>(std::chrono::duration<double>(1.0/std::clamp(frame->fps,1.0,240.0)));
                        const auto capacity=std::max<std::size_t>(1,(128*1024*1024)/frame->rgba.size());
                        state->effective_ms=std::min(state->buffer_ms,static_cast<int>(std::chrono::duration_cast<std::chrono::milliseconds>(period*static_cast<int>(capacity-1)).count()));
                        if(!previous || previous->width!=frame->width || previous->height!=frame->height || std::abs(previous->fps-frame->fps)>.01 || state->next_due<now){
                            state->queue.clear();state->queue_bytes=0;
                            state->next_due=now+std::chrono::milliseconds(state->effective_ms);
                        }
                        state->queue.emplace_back(state->next_due,frame);state->queue_bytes+=frame->rgba.size();state->next_due+=period;
                        // Bound memory even if rendering stalls or a source bursts frames.
                        const auto frame_limit=static_cast<std::size_t>(std::ceil(state->effective_ms*.001*std::clamp(frame->fps,1.0,240.0)))+2;
                        bool trimmed=false;
                        while(state->queue.size()>frame_limit || state->queue_bytes>128*1024*1024){
                            state->queue_bytes-=state->queue.front().second->rgba.size();state->queue.pop_front();trimmed=true;
                        }
                        if(trimmed || state->next_due>now+std::chrono::milliseconds(state->effective_ms+100)){
                            auto due=now+std::chrono::milliseconds(state->effective_ms)-period*static_cast<int>(state->queue.empty()?0:state->queue.size()-1);
                            for(auto &entry:state->queue){entry.first=due;due+=period;}
                            state->next_due=due;
                        }
                    }
                    state->latest = {std::move(frame), true, ""};
                    state->last_frame = now;
                }
            } else if (type == NDIlib_frame_type_error) status(false, "NDI receive error");
            else if (api->recv_get_no_connections(receiver) == 0) status(false, "Source offline");
        }
    } catch (const std::exception &e) { status(false,e.what()); }
    if (receiver) api->recv_destroy(receiver);
    if (finder) api->find_destroy(finder);
}
