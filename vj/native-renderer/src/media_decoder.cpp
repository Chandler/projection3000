#include "media_decoder.hpp"

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/hwcontext.h>
#include <libavutil/display.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <libavutil/pixdesc.h>
#include <libswscale/swscale.h>
#ifdef VIBE_HAS_AVFILTER
#include <libavfilter/avfilter.h>
#include <libavfilter/buffersink.h>
#include <libavfilter/buffersrc.h>
#endif
}

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <deque>
#include <iostream>
#include <stdexcept>

namespace {

std::string ffmpeg_error(int code) {
    char text[AV_ERROR_MAX_STRING_SIZE]{};
    av_strerror(code, text, sizeof(text));
    return text;
}

struct FormatDeleter {
    void operator()(AVFormatContext *value) const {
        if (value) avformat_close_input(&value);
    }
};

struct CodecDeleter {
    void operator()(AVCodecContext *value) const {
        if (value) avcodec_free_context(&value);
    }
};

struct FrameDeleter {
    void operator()(AVFrame *value) const {
        if (value) av_frame_free(&value);
    }
};

struct PacketDeleter {
    void operator()(AVPacket *value) const {
        if (value) av_packet_free(&value);
    }
};

using FormatPtr = std::unique_ptr<AVFormatContext, FormatDeleter>;
using CodecPtr = std::unique_ptr<AVCodecContext, CodecDeleter>;
using FramePtr = std::unique_ptr<AVFrame, FrameDeleter>;
using PacketPtr = std::unique_ptr<AVPacket, PacketDeleter>;

struct HardwareSelection {
    AVPixelFormat pixel_format = AV_PIX_FMT_NONE;
    AVBufferRef *device = nullptr;
    std::string name = "software";
    bool allowed = true;
};

#ifdef VIBE_HAS_AVFILTER
struct SubtitleFilter {
    AVFilterGraph *graph = nullptr;
    AVFilterContext *source = nullptr;
    AVFilterContext *sink = nullptr;
    int width = 0;
    int height = 0;
    AVPixelFormat format = AV_PIX_FMT_NONE;

    ~SubtitleFilter() {
        if (graph) avfilter_graph_free(&graph);
    }
};

std::unique_ptr<SubtitleFilter> make_subtitle_filter(
    const std::string &asset, const AVFrame *frame, AVRational time_base) {
    if (asset.empty() || !frame) return nullptr;
    const auto failed = [&](const char *stage, int code = 0) {
        std::cerr << "optional subtitle filter " << stage << " failed";
        if (code < 0) std::cerr << ": " << ffmpeg_error(code);
        std::cerr << "\n";
        return std::unique_ptr<SubtitleFilter>{};
    };
    auto filter = std::make_unique<SubtitleFilter>();
    filter->graph = avfilter_graph_alloc();
    if (!filter->graph) return failed("allocation");
    const AVFilter *buffer = avfilter_get_by_name("buffer");
    const AVFilter *ass = avfilter_get_by_name("ass");
    const AVFilter *sink = avfilter_get_by_name("buffersink");
    if (!buffer) return failed("buffer lookup");
    if (!ass) return failed("ass lookup");
    if (!sink) return failed("buffersink lookup");
    AVRational aspect = frame->sample_aspect_ratio;
    if (aspect.num <= 0 || aspect.den <= 0) aspect = AVRational{1, 1};
    char arguments[256]{};
    std::snprintf(arguments, sizeof(arguments),
                  "video_size=%dx%d:pix_fmt=%d:time_base=%d/%d:"
                  "pixel_aspect=%d/%d",
                  frame->width, frame->height, frame->format,
                  time_base.num, time_base.den, aspect.num, aspect.den);
    int result = avfilter_graph_create_filter(
        &filter->source, buffer, "video", arguments, nullptr,
        filter->graph);
    if (result < 0) return failed("source", result);
    AVFilterContext *subtitle =
        avfilter_graph_alloc_filter(filter->graph, ass, "subtitles");
    if (!subtitle) return failed("allocation");
    result = av_opt_set(
        subtitle, "filename", asset.c_str(), AV_OPT_SEARCH_CHILDREN);
    if (result < 0) return failed("filename", result);
    result = avfilter_init_str(subtitle, nullptr);
    if (result < 0) return failed("initialization", result);
    result = avfilter_graph_create_filter(
        &filter->sink, sink, "output", nullptr, nullptr, filter->graph);
    if (result < 0) return failed("sink", result);
    result = avfilter_link(filter->source, 0, subtitle, 0);
    if (result < 0) return failed("source link", result);
    result = avfilter_link(subtitle, 0, filter->sink, 0);
    if (result < 0) return failed("sink link", result);
    result = avfilter_graph_config(filter->graph, nullptr);
    if (result < 0) return failed("configuration", result);
    filter->width = frame->width;
    filter->height = frame->height;
    filter->format = static_cast<AVPixelFormat>(frame->format);
    return filter;
}
#endif

AVPixelFormat hardware_format(AVCodecContext *context,
                              const AVPixelFormat *formats) {
    auto *selection = static_cast<HardwareSelection *>(context->opaque);
    if (selection && selection->allowed) {
        for (const AVPixelFormat *format = formats;
             *format != AV_PIX_FMT_NONE; ++format) {
            if (*format == selection->pixel_format) return *format;
        }
        // FFmpeg calls get_format again without the failed hardware format
        // when device creation succeeded but this codec/profile is unsupported.
        // Keep software selected for subsequent frames and seeks as well.
        selection->allowed = false;
        selection->name = "software";
    }
    for (const AVPixelFormat *format = formats;
         *format != AV_PIX_FMT_NONE; ++format) {
        const auto *description = av_pix_fmt_desc_get(*format);
        if (description && !(description->flags & AV_PIX_FMT_FLAG_HWACCEL))
            return *format;
    }
    return AV_PIX_FMT_NONE;
}

HardwareSelection select_hardware(
    const AVCodec *codec, AVCodecContext *context) {
    HardwareSelection selection;
#ifdef __APPLE__
    constexpr const char *preferred[] = {"videotoolbox"};
#else
    constexpr const char *preferred[] = {"vaapi"};
#endif
    for (const char *name : preferred) {
        const AVHWDeviceType type = av_hwdevice_find_type_by_name(name);
        if (type == AV_HWDEVICE_TYPE_NONE) continue;
        for (int index = 0;; ++index) {
            const AVCodecHWConfig *config =
                avcodec_get_hw_config(codec, index);
            if (!config) break;
            if (!(config->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX)
                || config->device_type != type) {
                continue;
            }
            AVBufferRef *device = nullptr;
            const int result =
                av_hwdevice_ctx_create(&device, type, nullptr, nullptr, 0);
            if (result < 0) continue;
            selection.pixel_format = config->pix_fmt;
            selection.device = device;
            selection.name = name;
            context->hw_device_ctx = av_buffer_ref(device);
            return selection;
        }
    }
    return selection;
}

}  // namespace

MediaDecoder::MediaDecoder(
    std::string path, int output_width, int output_height,
    std::string subtitle_asset, bool cache_frames)
    : path_(std::move(path)),
      subtitle_asset_(std::move(subtitle_asset)),
      cache_frames_(cache_frames),
      output_width_(std::max(1, output_width)),
      output_height_(std::max(1, output_height)),
      thread_(&MediaDecoder::run, this) {}

MediaDecoder::~MediaDecoder() {
    stop_.store(true);
    changed_.notify_all();
    if (thread_.joinable()) thread_.join();
}

void MediaDecoder::request(double seconds) {
    const double requested = std::max(0.0, seconds);
    const double previous = requested_seconds_.exchange(requested);
    if (std::abs(previous - requested) <= 0.0001) return;
    changed_.notify_one();
}

std::optional<DecodedVideoFrame> MediaDecoder::latest() const {
    std::lock_guard lock(mutex_);
    return latest_;
}

double MediaDecoder::duration() const {
    return duration_.load();
}

double MediaDecoder::frame_rate() const {
    return frame_rate_.load();
}

std::string MediaDecoder::backend() const {
    std::lock_guard lock(mutex_);
    return backend_;
}

std::string MediaDecoder::error() const {
    std::lock_guard lock(mutex_);
    return error_;
}

void MediaDecoder::run() {
    AVFormatContext *raw_format = nullptr;
    int result = avformat_open_input(&raw_format, path_.c_str(), nullptr, nullptr);
    if (result < 0) {
        std::lock_guard lock(mutex_);
        error_ = "open: " + ffmpeg_error(result);
        backend_ = "failed";
        return;
    }
    FormatPtr format(raw_format);
    result = avformat_find_stream_info(format.get(), nullptr);
    if (result < 0) {
        std::lock_guard lock(mutex_);
        error_ = "stream info: " + ffmpeg_error(result);
        backend_ = "failed";
        return;
    }
    const int stream_index =
        av_find_best_stream(format.get(), AVMEDIA_TYPE_VIDEO, -1, -1,
                            nullptr, 0);
    if (stream_index < 0) {
        std::lock_guard lock(mutex_);
        error_ = "no video stream";
        backend_ = "failed";
        return;
    }
    AVStream *stream = format->streams[stream_index];
    const AVCodec *codec =
        avcodec_find_decoder(stream->codecpar->codec_id);
    if (!codec) {
        std::lock_guard lock(mutex_);
        error_ = "decoder unavailable";
        backend_ = "failed";
        return;
    }
    CodecPtr context(avcodec_alloc_context3(codec));
    if (!context) {
        std::lock_guard lock(mutex_);
        error_ = "decoder allocation failed";
        backend_ = "failed";
        return;
    }
    result = avcodec_parameters_to_context(context.get(), stream->codecpar);
    if (result < 0) {
        std::lock_guard lock(mutex_);
        error_ = "decoder parameters: " + ffmpeg_error(result);
        backend_ = "failed";
        return;
    }
    HardwareSelection hardware = select_hardware(codec, context.get());
    const auto open_software = [&]() {
        // Recreate the context: partially initialized hardware codec state is
        // not safe to reuse after an open/send/receive/transfer failure.
        context.reset(avcodec_alloc_context3(codec));
        if (hardware.device) av_buffer_unref(&hardware.device);
        hardware.allowed = false;
        hardware.pixel_format = AV_PIX_FMT_NONE;
        hardware.name = "software";
        if (!context) return AVERROR(ENOMEM);
        int opened = avcodec_parameters_to_context(context.get(), stream->codecpar);
        if (opened < 0) return opened;
        // Exclude all hardware formats even if FFmpeg offers another backend.
        context->opaque = &hardware;
        context->get_format = hardware_format;
        return avcodec_open2(context.get(), codec, nullptr);
    };
    if (hardware.device) {
        context->opaque = &hardware;
        context->get_format = hardware_format;
    }
    result = avcodec_open2(context.get(), codec, nullptr);
    if (result < 0 && hardware.device) result = open_software();
    if (result < 0) {
        if (hardware.device) av_buffer_unref(&hardware.device);
        std::lock_guard lock(mutex_);
        error_ = "decoder open: " + ffmpeg_error(result);
        backend_ = "failed";
        return;
    }
    {
        std::lock_guard lock(mutex_);
        backend_ = hardware.name;
    }
    if (format->duration > 0) {
        duration_.store(
            static_cast<double>(format->duration) / AV_TIME_BASE);
    } else if (stream->duration > 0) {
        duration_.store(stream->duration * av_q2d(stream->time_base));
    }
    // libavcodec returns encoded pixels; unlike the ffmpeg CLI it does not
    // apply phone/camera display orientation automatically.
    const std::int32_t *display_matrix = nullptr;
#if LIBAVCODEC_VERSION_MAJOR >= 61
    if (const auto *side = av_packet_side_data_get(
            stream->codecpar->coded_side_data, stream->codecpar->nb_coded_side_data,
            AV_PKT_DATA_DISPLAYMATRIX); side && side->size >= 9 * sizeof(std::int32_t)) {
        display_matrix = reinterpret_cast<const std::int32_t *>(side->data);
    }
#endif
#if LIBAVFORMAT_VERSION_MAJOR < 62
    size_t matrix_size = 0;
    const auto *matrix_data = av_stream_get_side_data(
        stream, AV_PKT_DATA_DISPLAYMATRIX, &matrix_size);
    if (!display_matrix && matrix_data && matrix_size >= 9 * sizeof(std::int32_t))
        display_matrix = reinterpret_cast<const std::int32_t *>(matrix_data);
#endif
    const double angle = display_matrix ? av_display_rotation_get(display_matrix) : 0;
    const int turns = std::isfinite(angle)
        ? (static_cast<int>(std::lround(angle / 90.0)) % 4 + 4) % 4 : 0;
    const int bound_width = turns % 2 ? output_height_ : output_width_;
    const int bound_height = turns % 2 ? output_width_ : output_height_;
    const double source_aspect =
        (context->height > 0
         ? static_cast<double>(context->width) / context->height : 1.0);
    int decoded_width = bound_width;
    int decoded_height = std::max(
        1, static_cast<int>(std::lround(decoded_width / source_aspect)));
    if (decoded_height > bound_height) {
        decoded_height = bound_height;
        decoded_width = std::max(
            1, static_cast<int>(std::lround(decoded_height * source_aspect)));
    }
    // YUV hardware paths and texture upload are happiest with even dimensions.
    decoded_width = std::max(2, decoded_width & ~1);
    decoded_height = std::max(2, decoded_height & ~1);

    FramePtr decoded(av_frame_alloc());
    FramePtr software(av_frame_alloc());
#ifdef VIBE_HAS_AVFILTER
    FramePtr filtered(av_frame_alloc());
    std::unique_ptr<SubtitleFilter> subtitle_filter;
    bool subtitle_available = !subtitle_asset_.empty();
    bool subtitle_reported = false;
#endif
    PacketPtr packet(av_packet_alloc());
    SwsContext *scale = nullptr;
    AVPixelFormat scale_format = AV_PIX_FMT_NONE;
    int scale_width = 0;
    int scale_height = 0;
    double current_seconds = -1.0;
    double last_request = -1000.0;
    std::uint64_t sequence = 0;
    std::optional<DecodedVideoFrame> pending;
    const AVRational guessed_rate =
        av_guess_frame_rate(format.get(), stream, nullptr);
    if (guessed_rate.num > 0 && guessed_rate.den > 0) {
        frame_rate_.store(av_q2d(guessed_rate));
    }
    const double nominal_frame_seconds =
        guessed_rate.num > 0 && guessed_rate.den > 0
        ? av_q2d(av_inv_q(guessed_rate)) : 1.0 / 30.0;

    // Reverse inter-frame decoding is not available from FFmpeg codecs. A
    // bounded cache makes ping-pong playback read already-decoded frames in
    // reverse. On a cache miss, normal keyframe seek + forward decode fills
    // the missing GOP, so memory stays bounded even for long source files.
    constexpr std::size_t max_cache_bytes = 192u * 1024u * 1024u;
    constexpr std::size_t max_cache_frames = 360u;
    std::deque<DecodedVideoFrame> frame_cache;
    std::size_t frame_cache_bytes = 0;
    bool cache_playback = false;
    bool decode_failed = false;
    unsigned consecutive_errors = 0;
    std::uint64_t sequence_at_eof = 0;
    bool reached_eof = false;

    const auto fail = [&](const std::string& stage, int code) {
        std::lock_guard lock(mutex_);
        error_ = stage + ": " + ffmpeg_error(code);
        backend_ = "failed";
        decode_failed = true;
    };
    const auto fallback = [&]() {
        if (!hardware.device) return false;
        av_frame_unref(decoded.get());
        av_frame_unref(software.get());
        const int opened = open_software();
        if (opened < 0) {
            fail("software decoder open", opened);
            return true;
        }
        const auto timestamp = static_cast<std::int64_t>(
            requested_seconds_.load() / av_q2d(stream->time_base));
        const int sought = av_seek_frame(format.get(), stream_index, timestamp,
                                         AVSEEK_FLAG_BACKWARD);
        if (sought < 0) fail("software fallback seek", sought);
        current_seconds = -1.0;
        pending.reset();
        consecutive_errors = 0;
        reached_eof = false;
#ifdef VIBE_HAS_AVFILTER
        subtitle_filter.reset();
        subtitle_reported = false;
#endif
        if (!decode_failed) {
            std::lock_guard lock(mutex_);
            backend_ = "software";
        }
        return true;
    };

    const auto remember = [&](const DecodedVideoFrame &frame) {
        if (!cache_frames_ || !frame.rgb) return;
        const double duplicate_window = nominal_frame_seconds * 0.25;
        for (auto &cached : frame_cache) {
            if (std::abs(cached.seconds - frame.seconds) <= duplicate_window) {
                cached = frame;
                return;
            }
        }
        frame_cache_bytes += frame.rgb->size();
        frame_cache.push_back(frame);
        while (!frame_cache.empty()
               && (frame_cache.size() > max_cache_frames
                   || frame_cache_bytes > max_cache_bytes)) {
            frame_cache_bytes -= frame_cache.front().rgb
                ? frame_cache.front().rgb->size() : 0;
            frame_cache.pop_front();
        }
    };

    const auto cached_frame_at = [&](double wanted)
        -> std::optional<DecodedVideoFrame> {
        const DecodedVideoFrame *best = nullptr;
        for (const auto &frame : frame_cache) {
            if (frame.seconds <= wanted + 0.000001
                && (!best || frame.seconds > best->seconds)) {
                best = &frame;
            }
        }
        if (!best
            || wanted - best->seconds
                > std::max(0.05, nominal_frame_seconds * 1.5)) {
            return std::nullopt;
        }
        return *best;
    };

    const auto publish = [&](DecodedVideoFrame frame) {
        current_seconds = frame.seconds;
        std::lock_guard lock(mutex_);
        latest_ = std::move(frame);
    };

    while (!stop_.load() && !decode_failed) {
        const double wanted = requested_seconds_.load();
        if (cache_frames_
            && wanted + nominal_frame_seconds * 0.1 < last_request) {
            cache_playback = true;
        }
        if (cache_playback) {
            if (const auto cached = cached_frame_at(wanted)) {
                publish(*cached);
                last_request = wanted;
                std::unique_lock lock(mutex_);
                changed_.wait_for(lock, std::chrono::milliseconds(4), [&] {
                    return stop_.load()
                        || std::abs(requested_seconds_.load() - last_request)
                            > 0.0001;
                });
                continue;
            }
            // The requested portion was evicted or has not been decoded yet.
            // Force one ordinary seek/decode pass; subsequent descending
            // requests can consume the GOP frames it adds to the cache.
            cache_playback = false;
            current_seconds = -1.0;
            pending.reset();
#ifdef VIBE_HAS_AVFILTER
            subtitle_filter.reset();
#endif
        }
        const bool seek = (!pending && current_seconds < 0.0)
            || wanted + 0.1 < current_seconds
            || wanted - current_seconds > 2.0;
        if (seek) {
            const std::int64_t timestamp = static_cast<std::int64_t>(
                wanted / av_q2d(stream->time_base));
            av_seek_frame(format.get(), stream_index, timestamp,
                          AVSEEK_FLAG_BACKWARD);
            avcodec_flush_buffers(context.get());
            current_seconds = -1.0;
            pending.reset();
#ifdef VIBE_HAS_AVFILTER
            // libass consumes media PTS. Recreate its graph after a backwards
            // seek/loop so the next frame can begin a fresh timestamp run.
            subtitle_filter.reset();
#endif
        }

        // Decoding one frame ahead is essential when the render clock is
        // faster than the source frame rate. Keep that future frame pending
        // until its PTS arrives; otherwise a 23.976 fps source advances once
        // per 30 fps render tick and plays about 25% too fast.
        if (pending) {
            if (pending->seconds <= wanted + 0.000001) {
                publish(std::move(*pending));
                pending.reset();
            } else {
                last_request = wanted;
                std::unique_lock lock(mutex_);
                changed_.wait_for(lock, std::chrono::milliseconds(20), [&] {
                    return stop_.load()
                        || std::abs(requested_seconds_.load() - last_request)
                            > 0.0001;
                });
                continue;
            }
        }

        while (!stop_.load() && !pending && !decode_failed) {
            result = av_read_frame(format.get(), packet.get());
            if (result < 0) {
                if (result != AVERROR_EOF) {
                    fail("read", result);
                    break;
                }
                if (reached_eof && sequence == sequence_at_eof) {
                    fail("no decodable video frames", AVERROR_INVALIDDATA);
                    break;
                }
                reached_eof = true;
                sequence_at_eof = sequence;
                av_seek_frame(format.get(), stream_index, 0, AVSEEK_FLAG_BACKWARD);
                avcodec_flush_buffers(context.get());
                current_seconds = -1.0;
                pending.reset();
                break;
            }
            if (packet->stream_index != stream_index) {
                av_packet_unref(packet.get());
                continue;
            }
            result = avcodec_send_packet(context.get(), packet.get());
            av_packet_unref(packet.get());
            if (result < 0 && result != AVERROR(EAGAIN)) {
                if (fallback()) continue;
                if (++consecutive_errors >= 32) fail("decode packet", result);
                continue;
            }
            bool restarted = false;
            while ((result = avcodec_receive_frame(
                        context.get(), decoded.get())) >= 0) {
                const std::int64_t pts =
                    decoded->best_effort_timestamp == AV_NOPTS_VALUE
                    ? decoded->pts : decoded->best_effort_timestamp;
                const double decoded_seconds = pts == AV_NOPTS_VALUE
                    ? (current_seconds < 0.0
                       ? wanted
                       : current_seconds + nominal_frame_seconds)
                    : pts * av_q2d(stream->time_base);
                AVFrame *source = decoded.get();
                if (hardware.pixel_format != AV_PIX_FMT_NONE
                    && decoded->format == hardware.pixel_format) {
                    av_frame_unref(software.get());
                    const int transferred = av_hwframe_transfer_data(
                            software.get(), decoded.get(), 0);
                    if (transferred < 0) {
                        restarted = fallback();
                        if (!restarted) fail("hardware frame transfer", transferred);
                        break;
                    }
                    source = software.get();
                }
                {
                    std::lock_guard lock(mutex_);
                    if (backend_ != hardware.name
                        && backend_ != hardware.name + "+ass")
                        backend_ = hardware.name;
                }

#ifdef VIBE_HAS_AVFILTER
                if (subtitle_available) {
                    source->pts = pts == AV_NOPTS_VALUE
                        ? static_cast<std::int64_t>(std::llround(
                            decoded_seconds / av_q2d(stream->time_base)))
                        : pts;
                    const auto source_format =
                        static_cast<AVPixelFormat>(source->format);
                    if (!subtitle_filter
                        || subtitle_filter->width != source->width
                        || subtitle_filter->height != source->height
                        || subtitle_filter->format != source_format) {
                        subtitle_filter = make_subtitle_filter(
                            subtitle_asset_, source, stream->time_base);
                        if (!subtitle_filter) {
                            subtitle_available = false;
                        } else if (!subtitle_reported) {
                            std::lock_guard lock(mutex_);
                            backend_ += "+ass";
                            subtitle_reported = true;
                        }
                    }
                    if (subtitle_filter) {
                        av_frame_unref(filtered.get());
                        const int pushed = av_buffersrc_add_frame_flags(
                            subtitle_filter->source, source,
                            AV_BUFFERSRC_FLAG_KEEP_REF);
                        const int pulled = pushed < 0 ? pushed
                            : av_buffersink_get_frame(
                                subtitle_filter->sink, filtered.get());
                        if (pulled >= 0) {
                            source = filtered.get();
                        } else {
                            // Subtitles are strictly optional. If libass ever
                            // rejects this asset or timestamp, continue with
                            // the original decoded video for this and all
                            // subsequent frames.
                            subtitle_filter.reset();
                            subtitle_available = false;
                        }
                    }
                }
#endif

                const auto source_format =
                    static_cast<AVPixelFormat>(source->format);
                if (!scale || source_format != scale_format
                    || source->width != scale_width
                    || source->height != scale_height) {
                    sws_freeContext(scale);
                    scale = sws_getContext(
                        source->width, source->height, source_format,
                        decoded_width, decoded_height, AV_PIX_FMT_RGB24,
                        SWS_FAST_BILINEAR, nullptr, nullptr, nullptr);
                    scale_format = source_format;
                    scale_width = source->width;
                    scale_height = source->height;
                }
                if (!scale) {
                    fail("video pixel conversion", AVERROR(EINVAL));
                    break;
                }
                auto pixels = std::make_shared<std::vector<std::uint8_t>>(
                    static_cast<std::size_t>(
                        decoded_width * decoded_height * 3));
                std::uint8_t *destination[] = {pixels->data()};
                const int strides[] = {decoded_width * 3};
                sws_scale(scale, source->data, source->linesize, 0,
                          source->height, destination, strides);
                DecodedVideoFrame frame;
                frame.width = decoded_width;
                frame.height = decoded_height;
                frame.stride = strides[0];
                frame.seconds = decoded_seconds;
                frame.sequence = ++sequence;
                consecutive_errors = 0;
                if (turns) {
                    const int width = turns % 2 ? decoded_height : decoded_width;
                    const int height = turns % 2 ? decoded_width : decoded_height;
                    auto oriented = std::make_shared<std::vector<std::uint8_t>>(pixels->size());
                    for (int y = 0; y < decoded_height; ++y) {
                        for (int x = 0; x < decoded_width; ++x) {
                            const int dx = turns == 1 ? y : turns == 2 ? decoded_width - 1 - x : decoded_height - 1 - y;
                            const int dy = turns == 1 ? decoded_width - 1 - x : turns == 2 ? decoded_height - 1 - y : x;
                            std::copy_n(pixels->data() + (y * decoded_width + x) * 3, 3,
                                        oriented->data() + (dy * width + dx) * 3);
                        }
                    }
                    pixels = std::move(oriented);
                    frame.width = width;
                    frame.height = height;
                    frame.stride = width * 3;
                }
                frame.rgb = std::move(pixels);
                remember(frame);
                if (decoded_seconds <= wanted + 0.000001) {
                    publish(std::move(frame));
                } else {
                    pending = std::move(frame);
                    break;
                }
            }
            if (!restarted && !decode_failed && result < 0
                && result != AVERROR(EAGAIN) && result != AVERROR_EOF) {
                if (!fallback() && ++consecutive_errors >= 32)
                    fail("decode frame", result);
            }
        }

        last_request = wanted;
        std::unique_lock lock(mutex_);
        changed_.wait_for(lock, std::chrono::milliseconds(4), [&] {
            return stop_.load()
                || std::abs(requested_seconds_.load() - last_request) > 0.0001;
        });
    }

    sws_freeContext(scale);
    if (hardware.device) av_buffer_unref(&hardware.device);
}
