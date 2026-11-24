#include "calibration_debug_codec.hpp"
#include "calibration_debug.hpp"
#include <array>
#include <cstring>
#include <stdexcept>
extern "C" {
#include <libavcodec/avcodec.h>
#include <libswscale/swscale.h>
}
namespace vj { namespace {
struct Codec{AVCodecContext* p=nullptr;~Codec(){avcodec_free_context(&p);}};
struct Frame{AVFrame* p=av_frame_alloc();~Frame(){av_frame_free(&p);}};
struct Packet{AVPacket* p=av_packet_alloc();~Packet(){av_packet_free(&p);}};
void check(int status){if(status<0)throw std::runtime_error("Invalid calibration PNG");}
FrameImage decode(const std::vector<uint8_t>& bytes){
 constexpr std::array<uint8_t,8> signature={137,80,78,71,13,10,26,10};
 if(bytes.size()<33||bytes.size()>48u*1024*1024||!std::equal(signature.begin(),signature.end(),bytes.begin())||std::memcmp(bytes.data()+12,"IHDR",4))throw std::runtime_error("Invalid PNG header");
 auto integer=[&](size_t offset){return uint32_t(bytes[offset])<<24|uint32_t(bytes[offset+1])<<16|uint32_t(bytes[offset+2])<<8|bytes[offset+3];};
 const auto width=integer(16),height=integer(20);if(!width||!height||width>8192||height>8192||uint64_t(width)*height*4>32u*1024*1024)throw std::runtime_error("Calibration PNG exceeds pixel limit");
 auto* implementation=avcodec_find_decoder(AV_CODEC_ID_PNG);if(!implementation)throw std::runtime_error("PNG decoder unavailable");Codec codec;codec.p=avcodec_alloc_context3(implementation);if(!codec.p)throw std::runtime_error("PNG allocation failed");codec.p->thread_count=1;codec.p->max_pixels=8u*1024*1024;check(avcodec_open2(codec.p,implementation,nullptr));Frame frame;Packet packet;if(!frame.p||!packet.p)throw std::runtime_error("PNG allocation failed");check(av_new_packet(packet.p,bytes.size()));std::memcpy(packet.p->data,bytes.data(),bytes.size());check(avcodec_send_packet(codec.p,packet.p));check(avcodec_receive_frame(codec.p,frame.p));if(frame.p->width!=int(width)||frame.p->height!=int(height))throw std::runtime_error("PNG dimensions changed");
 auto pixels=std::make_shared<std::vector<uint8_t>>(size_t(width)*height*4);auto* scaler=sws_getContext(width,height,AVPixelFormat(frame.p->format),width,height,AV_PIX_FMT_RGBA,SWS_POINT,nullptr,nullptr,nullptr);if(!scaler)throw std::runtime_error("PNG conversion unavailable");uint8_t* destination[]={pixels->data()};int strides[]={int(width)*4};int status=sws_scale(scaler,frame.p->data,frame.p->linesize,0,height,destination,strides);sws_freeContext(scaler);check(status);FrameImage result;result.width=width;result.height=height;result.channels=4;result.rgb=std::move(pixels);return result;
}
}
void installCalibrationDebugPngCodec(){installCalibrationDebugDecoder(decode);}
}
