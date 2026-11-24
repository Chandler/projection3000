#include "live_capture.hpp"
#include <map>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavdevice/avdevice.h>
#include <libavformat/avformat.h>
#include <libswscale/swscale.h>
}

#include <algorithm>
#include <chrono>
#include <stdexcept>
#include <utility>

namespace {
using Clock = std::chrono::steady_clock;
using namespace std::chrono_literals;

void checked(int result, const char *operation) {
    if (result >= 0) return;
    char message[AV_ERROR_MAX_STRING_SIZE];
    av_strerror(result, message, sizeof(message));
    throw std::runtime_error(std::string(operation) + ": " + message);
}

struct Input {
    AVFormatContext *format = nullptr;
    AVCodecContext *codec = nullptr;
    AVPacket *packet = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    SwsContext *scaler = nullptr;
    ~Input() {
        sws_freeContext(scaler);
        av_frame_free(&frame);
        av_packet_free(&packet);
        avcodec_free_context(&codec);
        avformat_close_input(&format);
    }
};
}

struct LiveCapture::State {
    struct Registry {std::mutex mutex;std::map<std::string,std::weak_ptr<State>> sources;};
    static Registry& registry(){static Registry value;return value;}
    std::string key;unsigned subscribers=0;
    std::string device;
    std::string input_format;
    std::atomic<bool> stop{false};
    mutable std::mutex mutex;
    std::condition_variable changed;
    std::optional<DecodedVideoFrame> frame;
    Clock::time_point last_frame = Clock::now();
    std::string error = "Opening camera";
    std::uint64_t sequence = 0;

    bool wait(std::chrono::milliseconds delay) {
        std::unique_lock lock(mutex);
        return changed.wait_for(lock, delay, [&] { return stop.load(); });
    }
};

LiveCapture::LiveCapture(std::string device, std::string format) {
    auto& registry=State::registry();std::lock_guard lock(registry.mutex);
    const auto key=format+"\n"+device;state_=registry.sources[key].lock();
    if(!state_||state_->stop){state_=std::make_shared<State>();state_->key=key;state_->device=std::move(device);state_->input_format=std::move(format);registry.sources[key]=state_;std::thread([state=state_]{run(state);}).detach();}
    ++state_->subscribers;
}

LiveCapture::~LiveCapture() {
    auto& registry=State::registry();std::lock_guard lock(registry.mutex);
    if(--state_->subscribers==0){registry.sources.erase(state_->key);state_->stop=true;state_->changed.notify_all();}
}

std::optional<DecodedVideoFrame> LiveCapture::latest() const {
    std::lock_guard lock(state_->mutex);
    if (Clock::now() - state_->last_frame > 1s) return std::nullopt;
    return state_->frame;
}

std::string LiveCapture::error() const {
    std::lock_guard lock(state_->mutex);
    if (state_->error.empty() && Clock::now() - state_->last_frame > 1s)
        return "Camera stopped delivering frames";
    return state_->error;
}

void LiveCapture::run(const std::shared_ptr<State> &state) {
    static std::once_flag registered;
    std::call_once(registered, avdevice_register_all);
    while (!state->stop) {
        try {
            Input input;
            if (!input.packet || !input.frame) throw std::bad_alloc();
            const auto *format = av_find_input_format(state->input_format.c_str());
            if (!format) throw std::runtime_error("Camera input backend unavailable");
            int opened = AVERROR(EINVAL);
            // Prefer modest-bandwidth MJPEG. Fall back to the camera's raw
            // format, then its default mode for devices without 720p support.
            for (int attempt = 0; attempt < 3 && !state->stop; ++attempt) {
                input.format = avformat_alloc_context();
                if (!input.format) throw std::bad_alloc();
                input.format->flags |= AVFMT_FLAG_NONBLOCK;
                input.format->interrupt_callback = {
                    [](void *opaque) -> int {
                        return static_cast<State *>(opaque)->stop.load();
                    }, state.get()};
                AVDictionary *options = nullptr;
                if (state->input_format == "v4l2" && attempt < 2) {
                    av_dict_set(&options, "video_size", "1280x720", 0);
                    av_dict_set(&options, "framerate", "30", 0);
                    if (attempt == 0)
                        av_dict_set(&options, "input_format", "mjpeg", 0);
                }
                if (state->input_format == "avfoundation") {
                    av_dict_set(&options, "pixel_format", "nv12", 0);
                    // 720p30, then the device's default size at 30 fps, then
                    // default size/cadence. Do not assume every camera is HD.
                    if (attempt == 0)
                        av_dict_set(&options, "video_size", "1280x720", 0);
                    if (attempt < 2)
                        av_dict_set(&options, "framerate", "30", 0);
                }
                const std::string device = state->device
                    + (state->input_format == "avfoundation" ? ":none" : "");
                opened = avformat_open_input(&input.format,
                    device.c_str(), format, &options);
                av_dict_free(&options);
                if (opened >= 0) break;
                avformat_close_input(&input.format);
            }
            if (state->stop) break;
            checked(opened, "Open camera");
            // V4L2 provides codec parameters in its header. Stream probing can
            // buffer live frames, so do not use avformat_find_stream_info.
            const int stream = av_find_best_stream(input.format,
                AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
            checked(stream, "Find camera video");
            auto *parameters = input.format->streams[stream]->codecpar;
            const auto *decoder = avcodec_find_decoder(parameters->codec_id);
            if (!decoder) throw std::runtime_error("Camera video codec unavailable");
            input.codec = avcodec_alloc_context3(decoder);
            if (!input.codec) throw std::bad_alloc();
            checked(avcodec_parameters_to_context(input.codec, parameters), "Camera codec");
            input.codec->thread_count = 1;
            // Some UVC cameras include malformed optional JPEG APP metadata on
            // every frame. Keep those warnings out of the show log; failures
            // still propagate through checked() into camera status.
            input.codec->log_level_offset = AV_LOG_DEBUG - AV_LOG_ERROR;
            checked(avcodec_open2(input.codec, decoder, nullptr), "Open camera codec");
            auto received = Clock::now();
            while (!state->stop) {
                int result = av_read_frame(input.format, input.packet);
                if (result == AVERROR(EAGAIN)) {
                    if (Clock::now() - received > 2s)
                        throw std::runtime_error("Camera timed out; reconnecting");
                    state->wait(5ms);
                    continue;
                }
                checked(result, "Read camera");
                if (input.packet->stream_index != stream) {
                    av_packet_unref(input.packet);
                    continue;
                }
                result = avcodec_send_packet(input.codec, input.packet);
                av_packet_unref(input.packet);
                checked(result, "Decode camera packet");
                while (!state->stop) {
                    result = avcodec_receive_frame(input.codec, input.frame);
                    if (result == AVERROR(EAGAIN) || result == AVERROR_EOF) break;
                    checked(result, "Decode camera frame");
                    const int width = input.frame->width;
                    const int height = input.frame->height;
                    if (width <= 0 || height <= 0)
                        throw std::runtime_error("Invalid camera dimensions");
                    const double scale = std::min({1.0, 1280.0 / width, 720.0 / height});
                    DecodedVideoFrame output;
                    output.width = std::max(1, static_cast<int>(width * scale));
                    output.height = std::max(1, static_cast<int>(height * scale));
                    output.stride = output.width * 3;
                    output.sequence = ++state->sequence;
                    output.seconds = input.frame->best_effort_timestamp == AV_NOPTS_VALUE
                        ? 0.0 : input.frame->best_effort_timestamp
                            * av_q2d(input.format->streams[stream]->time_base);
                    auto pixels = std::make_shared<std::vector<std::uint8_t>>(
                        output.stride * output.height);
                    auto pixel_format = static_cast<AVPixelFormat>(input.frame->format);
                    bool full_range = input.frame->color_range == AVCOL_RANGE_JPEG;
                    // YUVJ aliases otherwise make swscale recreate its context
                    // and warn on every MJPEG frame. Specify range explicitly.
                    switch (pixel_format) {
                        case AV_PIX_FMT_YUVJ420P: pixel_format = AV_PIX_FMT_YUV420P; full_range = true; break;
                        case AV_PIX_FMT_YUVJ422P: pixel_format = AV_PIX_FMT_YUV422P; full_range = true; break;
                        case AV_PIX_FMT_YUVJ444P: pixel_format = AV_PIX_FMT_YUV444P; full_range = true; break;
                        default: break;
                    }
                    input.scaler = sws_getCachedContext(input.scaler, width, height,
                        pixel_format,
                        output.width, output.height, AV_PIX_FMT_RGB24,
                        SWS_FAST_BILINEAR, nullptr, nullptr, nullptr);
                    if (!input.scaler) throw std::runtime_error("Camera color conversion failed");
                    const auto *coefficients = sws_getCoefficients(
                        input.frame->colorspace == AVCOL_SPC_BT709 ? SWS_CS_ITU709 : SWS_CS_ITU601);
                    checked(sws_setColorspaceDetails(input.scaler,
                        coefficients, full_range ? 1 : 0, coefficients, 1,
                        0, 1 << 16, 1 << 16), "Camera color range");
                    std::uint8_t *destination[] = {pixels->data(), nullptr, nullptr, nullptr};
                    int strides[] = {output.stride, 0, 0, 0};
                    checked(sws_scale(input.scaler, input.frame->data, input.frame->linesize,
                        0, height, destination, strides), "Convert camera frame");
                    av_frame_unref(input.frame);
                    output.rgb = std::move(pixels);
                    received = Clock::now();
                    std::lock_guard lock(state->mutex);
                    state->frame = std::move(output);
                    state->last_frame = received;
                    state->error.clear();
                }
            }
        } catch (const std::exception &error) {
            std::lock_guard lock(state->mutex);
            state->frame.reset();
            state->error = error.what();
        }
        if (!state->stop) state->wait(1s);
    }
}
