#pragma once

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libswscale/swscale.h>
}

#include <cstdint>
#include <algorithm>
#include <cmath>
#include <optional>
#include <string>
#include <vector>

struct RgbaImage {
    int width = 0;
    int height = 0;
    // Premultiplied alpha prevents dark fringes during texture filtering.
    std::vector<std::uint8_t> pixels;
};

inline std::optional<RgbaImage> load_static_image(const std::string &path, int max_dimension = 0) {
    AVFormatContext *format = nullptr;
    AVCodecContext *decoder = nullptr;
    AVPacket *packet = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    SwsContext *scaler = nullptr;
    std::optional<RgbaImage> result;
    auto cleanup = [&] {
        sws_freeContext(scaler);
        av_frame_free(&frame);
        av_packet_free(&packet);
        avcodec_free_context(&decoder);
        avformat_close_input(&format);
    };
    if (!packet || !frame
        || avformat_open_input(&format, path.c_str(), nullptr, nullptr) < 0
        || avformat_find_stream_info(format, nullptr) < 0) {
        cleanup();
        return result;
    }
    const int stream = av_find_best_stream(format, AVMEDIA_TYPE_VIDEO,
                                           -1, -1, nullptr, 0);
    if (stream < 0) { cleanup(); return result; }
    const auto *params = format->streams[stream]->codecpar;
    const auto *codec = avcodec_find_decoder(params->codec_id);
    decoder = codec ? avcodec_alloc_context3(codec) : nullptr;
    if (!decoder || avcodec_parameters_to_context(decoder, params) < 0
        || avcodec_open2(decoder, codec, nullptr) < 0) {
        cleanup();
        return result;
    }
    bool decoded = false;
    while (av_read_frame(format, packet) >= 0) {
        if (packet->stream_index == stream
            && avcodec_send_packet(decoder, packet) >= 0) {
            decoded = avcodec_receive_frame(decoder, frame) >= 0;
        }
        av_packet_unref(packet);
        if (decoded) break;
    }
    if (!decoded && avcodec_send_packet(decoder, nullptr) >= 0) {
        decoded = avcodec_receive_frame(decoder, frame) >= 0;
    }
    if (decoded && frame->width > 0 && frame->height > 0
        && frame->width <= 16384 && frame->height <= 16384) {
        RgbaImage image;
        const double scale=max_dimension>0?std::min(1.,double(max_dimension)/std::max(frame->width,frame->height)):1.;
        image.width = std::max(1,int(std::round(frame->width*scale)));
        image.height = std::max(1,int(std::round(frame->height*scale)));
        image.pixels.resize(static_cast<std::size_t>(image.width) * image.height * 4);
        scaler = sws_getContext(frame->width, frame->height,
            static_cast<AVPixelFormat>(frame->format), image.width, image.height,
            AV_PIX_FMT_RGBA, SWS_BILINEAR, nullptr, nullptr, nullptr);
        if (scaler) {
            std::uint8_t *planes[] = {image.pixels.data(), nullptr, nullptr, nullptr};
            int strides[] = {image.width * 4, 0, 0, 0};
            if (sws_scale(scaler, frame->data, frame->linesize, 0,
                          frame->height, planes, strides) == image.height) {
                for (std::size_t i = 0; i < image.pixels.size(); i += 4) {
                    const unsigned alpha = image.pixels[i + 3];
                    for (int c = 0; c < 3; ++c)
                        image.pixels[i + c] = (image.pixels[i + c] * alpha + 127) / 255;
                }
                result = std::move(image);
            }
        }
    }
    cleanup();
    return result;
}
