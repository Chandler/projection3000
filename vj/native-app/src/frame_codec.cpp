#include "frame_codec.hpp"
#include <algorithm>
#include <csetjmp>
#include <cstdlib>
#include <cstring>
#include <stdexcept>
extern "C" {
#include <jpeglib.h>
#include <libavcodec/avcodec.h>
#include <libavutil/opt.h>
#include <libswscale/swscale.h>
}
namespace vj {
namespace {
struct JpegError {jpeg_error_mgr manager;std::jmp_buf jump;char message[JMSG_LENGTH_MAX]{};};
void jpegFailure(j_common_ptr c){auto* error=reinterpret_cast<JpegError*>(c->err);(*c->err->format_message)(c,error->message);std::longjmp(error->jump,1);}
struct Codec {AVCodecContext* value=nullptr;~Codec(){avcodec_free_context(&value);}};
struct Frame {AVFrame* value=av_frame_alloc();~Frame(){av_frame_free(&value);}};
struct Packet {AVPacket* value=av_packet_alloc();~Packet(){av_packet_free(&value);}};
void check(int result,const char* operation){if(result<0){char message[AV_ERROR_MAX_STRING_SIZE]{};av_strerror(result,message,sizeof(message));throw std::runtime_error(std::string(operation)+": "+message);}}
}
std::vector<std::uint8_t> encodeFrameImage(const FrameImage& image,const FrameEncoding& encoding){
    const auto valid=[](int w,int h,int channels){return (channels==3||channels==4)&&w>0&&h>0&&w<=8192&&h<=8192&&size_t(w)*h*channels<=32u*1024*1024;};
    const int outputChannels=encoding.png?image.channels:3;const auto inputFormat=image.channels==4?AV_PIX_FMT_RGBA:AV_PIX_FMT_RGB24,outputFormat=outputChannels==4?AV_PIX_FMT_RGBA:AV_PIX_FMT_RGB24;
    if(!image.rgb||!valid(image.width,image.height,image.channels)||image.rgb->size()!=size_t(image.width)*image.height*image.channels||!valid(encoding.width,encoding.height,outputChannels))throw std::runtime_error("Invalid RGB frame");
    const auto* pixels=image.rgb->data();std::vector<std::uint8_t> resized;
    if(image.width!=encoding.width||image.height!=encoding.height||inputFormat!=outputFormat){
        auto* scale=sws_getContext(image.width,image.height,inputFormat,encoding.width,encoding.height,outputFormat,encoding.width<image.width?SWS_AREA:SWS_BICUBIC,nullptr,nullptr,nullptr);
        if(!scale)throw std::runtime_error("Frame resize allocation failed");
        resized.resize(size_t(encoding.width)*encoding.height*outputChannels);const std::uint8_t* input[]={pixels};int inputStride[]={image.width*image.channels};std::uint8_t* output[]={resized.data()};int outputStride[]={encoding.width*outputChannels};
        const int result=sws_scale(scale,input,inputStride,0,image.height,output,outputStride);sws_freeContext(scale);check(result,"Frame resize");pixels=resized.data();
    }
    if(!encoding.png){
        auto compressorStorage=std::make_unique<jpeg_compress_struct>();auto errorStorage=std::make_unique<JpegError>();auto& compressor=*compressorStorage;auto& error=*errorStorage;compressor.err=jpeg_std_error(&error.manager);error.manager.error_exit=jpegFailure;
        // libjpeg can longjmp after allocating destination memory. Its address
        // and size live outside the setjmp frame so cleanup remains well-defined.
        struct Destination {unsigned char* bytes=nullptr;unsigned long size=0;};
        auto storage=std::make_unique<Destination>();
        if(setjmp(error.jump)){jpeg_destroy_compress(&compressor);std::free(storage->bytes);throw std::runtime_error(std::string("JPEG encoding: ")+error.message);}
        jpeg_create_compress(&compressor);jpeg_mem_dest(&compressor,&storage->bytes,&storage->size);
        compressor.image_width=encoding.width;compressor.image_height=encoding.height;compressor.input_components=3;compressor.in_color_space=JCS_RGB;
        jpeg_set_defaults(&compressor);jpeg_set_quality(&compressor,std::clamp(encoding.quality,1,100),TRUE);compressor.optimize_coding=FALSE;jpeg_start_compress(&compressor,TRUE);
        while(compressor.next_scanline<compressor.image_height){JSAMPROW row=const_cast<JSAMPROW>(pixels+size_t(compressor.next_scanline)*encoding.width*3);jpeg_write_scanlines(&compressor,&row,1);}
        jpeg_finish_compress(&compressor);jpeg_destroy_compress(&compressor);std::vector<std::uint8_t> result(storage->bytes,storage->bytes+storage->size);std::free(storage->bytes);return result;
    }
    const auto* png=avcodec_find_encoder(AV_CODEC_ID_PNG);if(!png)throw std::runtime_error("PNG encoder unavailable");Codec codec;codec.value=avcodec_alloc_context3(png);if(!codec.value)throw std::runtime_error("PNG allocation failed");
    codec.value->width=encoding.width;codec.value->height=encoding.height;codec.value->pix_fmt=outputFormat;codec.value->time_base={1,1};codec.value->thread_count=1;codec.value->compression_level=1;check(avcodec_open2(codec.value,png,nullptr),"PNG open");
    Frame frame;Packet packet;if(!frame.value||!packet.value)throw std::runtime_error("PNG buffer allocation failed");frame.value->format=outputFormat;frame.value->width=encoding.width;frame.value->height=encoding.height;check(av_frame_get_buffer(frame.value,32),"PNG frame buffer");
    for(int y=0;y<encoding.height;y++)std::memcpy(frame.value->data[0]+y*frame.value->linesize[0],pixels+size_t(y)*encoding.width*outputChannels,size_t(encoding.width)*outputChannels);
    check(avcodec_send_frame(codec.value,frame.value),"PNG send frame");check(avcodec_receive_packet(codec.value,packet.value),"PNG receive packet");return {packet.value->data,packet.value->data+packet.value->size};
}
}
