#include "native_audio.hpp"

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/channel_layout.h>
#include <libavutil/error.h>
#include <libavutil/samplefmt.h>
#include <libswresample/swresample.h>
}

#include <algorithm>
#include <chrono>
#include <cmath>
#include <iomanip>
#include <limits>
#include <memory>
#include <sstream>
#include <thread>
#include <vector>

namespace {

using FormatPtr = std::unique_ptr<AVFormatContext, void (*)(AVFormatContext *)>;
using CodecPtr = std::unique_ptr<AVCodecContext, void (*)(AVCodecContext *)>;
using FramePtr = std::unique_ptr<AVFrame, void (*)(AVFrame *)>;
using PacketPtr = std::unique_ptr<AVPacket, void (*)(AVPacket *)>;
using SwrPtr = std::unique_ptr<SwrContext, void (*)(SwrContext *)>;

void close_format(AVFormatContext *context) {
    if (context) avformat_close_input(&context);
}

void free_codec(AVCodecContext *context) {
    avcodec_free_context(&context);
}

void free_frame(AVFrame *frame) {
    av_frame_free(&frame);
}

void free_packet(AVPacket *packet) {
    av_packet_free(&packet);
}

void free_swr(SwrContext *context) {
    swr_free(&context);
}

std::string ffmpeg_error(int code) {
    char buffer[AV_ERROR_MAX_STRING_SIZE]{};
    av_strerror(code, buffer, sizeof(buffer));
    return buffer;
}

double number(const SceneJson &params, const char *name, double fallback) {
    const auto value = params.find(name);
    if (value == params.end() || !value->is_number()) return fallback;
    return value->get<double>();
}

bool boolean(const SceneJson &params, const char *name, bool fallback) {
    const auto value = params.find(name);
    if (value == params.end() || !value->is_boolean()) return fallback;
    return value->get<bool>();
}

std::string text(
    const SceneJson &params, const char *name, const char *fallback) {
    const auto value = params.find(name);
    if (value == params.end() || !value->is_string()) return fallback;
    return value->get<std::string>();
}

}  // namespace

NativeAudioEngine::NativeAudioEngine() = default;

bool NativeAudioEngine::open_output() {
    if(device_)return true;
    // SDL audio and the device are acquired only for an explicitly enabled
    // audio clip. Each engine balances its own SDL subsystem reference.
    if(SDL_InitSubSystem(SDL_INIT_AUDIO)!=0){
        std::lock_guard lock(mutex_);
        error_=std::string("SDL audio initialization: ")+SDL_GetError();backend_="unavailable";return false;
    }
    audio_initialized_=true;
    SDL_AudioSpec wanted{};
    wanted.freq = 48000;
    wanted.format = AUDIO_F32SYS;
    wanted.channels = 2;
    wanted.samples = 1024;
    wanted.callback = nullptr;
    device_ = SDL_OpenAudioDevice(nullptr, 0, &wanted, &device_spec_, 0);
    if (!device_) {
        const auto error=std::string("SDL audio open: ")+SDL_GetError();
        SDL_QuitSubSystem(SDL_INIT_AUDIO);audio_initialized_=false;
        std::lock_guard lock(mutex_);error_=error;backend_="unavailable";return false;
    }
    bytes_per_second_ = static_cast<std::uint64_t>(device_spec_.freq)
        * device_spec_.channels * sizeof(float);
    const char *driver = SDL_GetCurrentAudioDriver();
    {std::lock_guard lock(mutex_);backend_=std::string("SDL/")+(driver?driver:"unknown");error_.clear();}
    SDL_PauseAudioDevice(device_,1);return true;
}

void NativeAudioEngine::close_output(){
    if(device_){SDL_CloseAudioDevice(device_);device_=0;}
    if(audio_initialized_){SDL_QuitSubSystem(SDL_INIT_AUDIO);audio_initialized_=false;}
    std::lock_guard lock(mutex_);backend_="disabled";error_.clear();
}

NativeAudioEngine::~NativeAudioEngine() {
    stop();close_output();
}

std::optional<NativeAudioEngine::Request>
NativeAudioEngine::select_request(const NativeScene &scene) {
    for (const auto &bus_name : scene.outputs) {
        const auto bus = scene.buses.find(bus_name);
        if (bus == scene.buses.end()) continue;
        for (const auto &layer : bus->second.layers) {
            if (!layer.enabled || layer.generator != "video"
                || layer.resolved_file.empty()
                || !boolean(layer.params, "audio_enabled", false)
                || text(layer.params, "loop_mode", "forward")
                    == "ping-pong") {
                continue;
            }
            Request request;
            request.source_id = layer.source_id;
            request.path = layer.resolved_file;
            request.playing = boolean(layer.params, "playing", true);
            request.speed = std::clamp(
                number(layer.params, "speed", 1.0), 0.1, 3.0);
            request.loop_start = std::clamp(
                number(layer.params, "loop_start", 0.0), 0.0, 1.0);
            request.loop_end = std::clamp(
                number(layer.params, "loop_end", 1.0), 0.0, 1.0);
            request.position = std::clamp(
                number(layer.params, "position", 0.0), 0.0, 1.0);
            request.seek_nonce = number(layer.params, "seek_nonce", 0.0);
            request.gain = std::clamp(
                number(layer.params, "audio_gain", 1.0), 0.0, 2.0);
            return request;
        }
    }
    return std::nullopt;
}

bool NativeAudioEngine::same_timeline(
    const Request &left, const Request &right) {
    return left.source_id == right.source_id
        && left.path == right.path
        && left.speed == right.speed
        && left.loop_start == right.loop_start
        && left.loop_end == right.loop_end
        && left.position == right.position
        && left.seek_nonce == right.seek_nonce;
}

void NativeAudioEngine::apply_scene(const NativeScene &scene) {
    auto selected = select_request(scene);
    bool continue_from_playhead = false;
    {
        std::lock_guard lock(mutex_);
        if (device_ && request_ && selected && same_timeline(*request_, *selected)) {
            request_->gain = selected->gain;
            gain_.store(selected->gain);
            if (request_->playing != selected->playing) {
                request_->playing = selected->playing;
                playing_.store(selected->playing);
                if (device_) {
                    SDL_PauseAudioDevice(
                        device_, selected->playing && !suspended_.load()
                            ? 0 : 1);
                }
            }
            return;
        }
        if (!request_ && !selected) return;
        continue_from_playhead = request_ && selected
            && request_->source_id == selected->source_id
            && request_->path == selected->path
            && request_->seek_nonce == selected->seek_nonce;
    }
    if (continue_from_playhead && selected) {
        selected->start_seconds = playhead_for(selected->source_id);
    }
    stop();
    {
        std::lock_guard lock(mutex_);
        request_ = selected;
    }
    if(selected){if(open_output())start(*selected);}
    else close_output();
}

void NativeAudioEngine::suspend_output() {
    suspended_.store(true);
    if (device_) SDL_PauseAudioDevice(device_, 1);
}

void NativeAudioEngine::resume_output() {
    suspended_.store(false);
    if (device_ && ready_.load() && playing_.load()) {
        SDL_PauseAudioDevice(device_, 0);
    }
}

void NativeAudioEngine::start(Request request) {
    if (!device_) return;
    stop_requested_.store(false);
    ready_.store(false);
    playing_.store(request.playing);
    speed_.store(request.speed);
    gain_.store(request.gain);
    queued_media_seconds_.store(0.0);
    SDL_ClearQueuedAudio(device_);
    SDL_PauseAudioDevice(device_, 1);
    thread_ = std::thread(&NativeAudioEngine::run, this, std::move(request));
}

void NativeAudioEngine::stop() {
    stop_requested_.store(true);
    if (thread_.joinable()) thread_.join();
    if (device_) {
        SDL_PauseAudioDevice(device_, 1);
        SDL_ClearQueuedAudio(device_);
    }
    ready_.store(false);
    queued_media_seconds_.store(0.0);
    std::lock_guard lock(mutex_);
    request_.reset();
}

bool NativeAudioEngine::owns_source(const std::string &source_id) const {
    std::lock_guard lock(mutex_);
    return request_ && request_->source_id == source_id;
}

std::optional<double> NativeAudioEngine::playhead_for(
    const std::string &source_id) const {
    if (!device_ || !ready_.load()) return std::nullopt;
    {
        std::lock_guard lock(mutex_);
        if (!request_ || request_->source_id != source_id) return std::nullopt;
    }
    const double queued_wall_seconds = bytes_per_second_ > 0
        ? static_cast<double>(SDL_GetQueuedAudioSize(device_))
            / static_cast<double>(bytes_per_second_)
        : 0.0;
    const double consumed = std::max(
        0.0, queued_media_seconds_.load()
            - queued_wall_seconds * speed_.load());
    const double start = loop_start_seconds_.load();
    const double end = loop_end_seconds_.load();
    const double span = std::max(0.001, end - start);
    double position = initial_position_.load() + consumed;
    if (position >= end) {
        position = start + std::fmod(position - start, span);
    }
    return std::clamp(position, start, end);
}

void NativeAudioEngine::set_error(std::string message) {
    std::lock_guard lock(mutex_);
    error_ = std::move(message);
}

void NativeAudioEngine::run(Request request) {
    AVFormatContext *raw_format = nullptr;
    int result = avformat_open_input(
        &raw_format, request.path.c_str(), nullptr, nullptr);
    FormatPtr format(raw_format, close_format);
    if (result < 0) {
        set_error("audio input: " + ffmpeg_error(result));
        return;
    }
    result = avformat_find_stream_info(format.get(), nullptr);
    if (result < 0) {
        set_error("audio stream info: " + ffmpeg_error(result));
        return;
    }
    const AVCodec *codec = nullptr;
    const int stream_index = av_find_best_stream(
        format.get(), AVMEDIA_TYPE_AUDIO, -1, -1, &codec, 0);
    if (stream_index < 0 || !codec) {
        set_error("media has no decodable audio stream");
        return;
    }
    AVStream *stream = format->streams[stream_index];
    CodecPtr context(avcodec_alloc_context3(codec), free_codec);
    if (!context) {
        set_error("audio codec allocation failed");
        return;
    }
    avcodec_parameters_to_context(context.get(), stream->codecpar);
    result = avcodec_open2(context.get(), codec, nullptr);
    if (result < 0) {
        set_error("audio decoder: " + ffmpeg_error(result));
        return;
    }

    double duration = format->duration > 0
        ? static_cast<double>(format->duration) / AV_TIME_BASE
        : stream->duration * av_q2d(stream->time_base);
    duration = std::max(0.001, duration);
    const double loop_start = duration * request.loop_start;
    const double loop_end = std::max(
        loop_start + 0.001, duration * request.loop_end);
    const double span = loop_end - loop_start;
    double initial = loop_start + request.position * span;
    if (request.start_seconds) {
        initial = *request.start_seconds;
        if (initial < loop_start || initial >= loop_end) {
            initial = loop_start
                + std::fmod(std::fmod(initial - loop_start, span) + span, span);
        }
    }
    initial_position_.store(initial);
    loop_start_seconds_.store(loop_start);
    loop_end_seconds_.store(loop_end);

    AVChannelLayout output_layout{};
    av_channel_layout_default(&output_layout, device_spec_.channels);
    const int resample_rate = std::max(
        4000, static_cast<int>(std::lround(device_spec_.freq / request.speed)));
    SwrContext *raw_swr = nullptr;
    result = swr_alloc_set_opts2(
        &raw_swr, &output_layout, AV_SAMPLE_FMT_FLT, resample_rate,
        &context->ch_layout, context->sample_fmt, context->sample_rate,
        0, nullptr);
    av_channel_layout_uninit(&output_layout);
    SwrPtr swr(raw_swr, free_swr);
    if (result < 0 || !swr || (result = swr_init(swr.get())) < 0) {
        set_error("audio resampler: " + ffmpeg_error(result));
        return;
    }

    FramePtr frame(av_frame_alloc(), free_frame);
    PacketPtr packet(av_packet_alloc(), free_packet);
    if (!frame || !packet) {
        set_error("audio frame allocation failed");
        return;
    }

    const auto seek_to = [&](double seconds) {
        const std::int64_t timestamp = static_cast<std::int64_t>(
            seconds / av_q2d(stream->time_base));
        avformat_seek_file(
            format.get(), stream_index,
            std::numeric_limits<std::int64_t>::min(),
            timestamp, timestamp, AVSEEK_FLAG_BACKWARD);
        avcodec_flush_buffers(context.get());
        swr_close(swr.get());
        swr_init(swr.get());
    };
    seek_to(initial);

    double cursor = initial;
    bool first_audio = true;
    const std::uint32_t queue_limit = static_cast<std::uint32_t>(
        bytes_per_second_ / 5);  // 200 ms, included in the master clock.
    {
        std::lock_guard lock(mutex_);
        error_.clear();
    }

    while (!stop_requested_.load()) {
        while (!stop_requested_.load()
               && SDL_GetQueuedAudioSize(device_) > queue_limit) {
            std::this_thread::sleep_for(std::chrono::milliseconds(2));
        }
        if (stop_requested_.load()) break;

        result = av_read_frame(format.get(), packet.get());
        if (result < 0) {
            seek_to(loop_start);
            cursor = loop_start;
            first_audio = false;
            continue;
        }
        if (packet->stream_index != stream_index) {
            av_packet_unref(packet.get());
            continue;
        }
        result = avcodec_send_packet(context.get(), packet.get());
        av_packet_unref(packet.get());
        if (result < 0 && result != AVERROR(EAGAIN)) continue;

        while (!stop_requested_.load()
               && avcodec_receive_frame(context.get(), frame.get()) >= 0) {
            const std::int64_t pts =
                frame->best_effort_timestamp == AV_NOPTS_VALUE
                ? frame->pts : frame->best_effort_timestamp;
            const double frame_start = pts == AV_NOPTS_VALUE
                ? cursor : pts * av_q2d(stream->time_base);
            const int maximum = static_cast<int>(av_rescale_rnd(
                swr_get_delay(swr.get(), context->sample_rate)
                    + frame->nb_samples,
                resample_rate, context->sample_rate, AV_ROUND_UP));
            std::vector<float> converted(
                static_cast<std::size_t>(maximum) * device_spec_.channels);
            std::uint8_t *output[] = {
                reinterpret_cast<std::uint8_t *>(converted.data())};
            const int samples = swr_convert(
                swr.get(), output, maximum,
                const_cast<const std::uint8_t **>(frame->extended_data),
                frame->nb_samples);
            if (samples <= 0) continue;

            int first = 0;
            if (first_audio && frame_start < initial) {
                first = std::clamp(
                    static_cast<int>(std::ceil(
                        (initial - frame_start) * resample_rate)),
                    0, samples);
            }
            int last = samples;
            if (frame_start < loop_end) {
                last = std::min(last, std::max(
                    0, static_cast<int>(std::floor(
                        (loop_end - frame_start) * resample_rate))));
            } else {
                last = 0;
            }
            first_audio = false;
            if (last > first) {
                const int queued_samples = last - first;
                float *begin = converted.data()
                    + static_cast<std::size_t>(first)
                        * device_spec_.channels;
                const std::size_t values =
                    static_cast<std::size_t>(queued_samples)
                    * device_spec_.channels;
                const double gain = gain_.load();
                if (gain != 1.0) {
                    for (std::size_t index = 0; index < values; ++index) {
                        begin[index] = std::clamp(
                            begin[index] * static_cast<float>(gain),
                            -1.0f, 1.0f);
                    }
                }
                const std::uint32_t bytes = static_cast<std::uint32_t>(
                    values * sizeof(float));
                if (SDL_QueueAudio(device_, begin, bytes) != 0) {
                    set_error(std::string("SDL audio queue: ") + SDL_GetError());
                    return;
                }
                queued_media_seconds_.fetch_add(
                    static_cast<double>(queued_samples) / resample_rate);
                if (!ready_.exchange(true) && playing_.load()
                    && !suspended_.load()) {
                    SDL_PauseAudioDevice(device_, 0);
                }
            }
            cursor = frame_start
                + static_cast<double>(frame->nb_samples)
                    / std::max(1, context->sample_rate);
            if (cursor >= loop_end - 0.000001) {
                seek_to(loop_start);
                cursor = loop_start;
                break;
            }
        }
    }
}

std::string NativeAudioEngine::stats() const {
    std::ostringstream text;
    std::optional<Request> request;
    std::string error;
    std::string backend;
    {
        std::lock_guard lock(mutex_);
        request = request_;
        error = error_;
        backend = backend_;
    }
    text << "audio " << backend;
    if (request) {
        text << " " << request->source_id;
        if (const auto clock = playhead_for(request->source_id)) {
            text << " clock " << std::fixed << std::setprecision(3) << *clock;
        } else {
            text << " opening";
        }
        text << (suspended_.load() ? " suspended"
                                  : playing_.load() ? " playing" : " paused")
             << " x" << std::fixed << std::setprecision(2) << speed_.load()
             << " q" << SDL_GetQueuedAudioSize(device_) / 1024 << "K";
    } else {
        text << " idle";
    }
    if (!error.empty()) text << " error=" << error;
    return text.str();
}
