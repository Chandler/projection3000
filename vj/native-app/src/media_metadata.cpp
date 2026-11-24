#include "media_library.hpp"
#include "media_thumbnail.hpp"
#include <boost/uuid/detail/sha1.hpp>
extern "C" {
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/display.h>
#include <libavutil/imgutils.h>
#include <libswscale/swscale.h>
}
#include <algorithm>
#include <chrono>
#include <cmath>
#include <fstream>
#include <iomanip>
#include <memory>
#include <mutex>
#include <sstream>
#include <stdexcept>
#include <unistd.h>
namespace vj {
namespace {
using Json=nlohmann::json;
namespace fs=std::filesystem;
std::timed_mutex cacheMutex;
struct Format {AVFormatContext* value=avformat_alloc_context();~Format(){if(value)avformat_close_input(&value);}};
struct Codec {AVCodecContext* value=nullptr;~Codec(){avcodec_free_context(&value);}};
struct Frame {AVFrame* value=av_frame_alloc();~Frame(){av_frame_free(&value);}};
struct Packet {AVPacket* value=av_packet_alloc();~Packet(){av_packet_free(&value);}};
struct Scaler {SwsContext* value=nullptr;~Scaler(){sws_freeContext(value);}};
struct Deadline {std::chrono::steady_clock::time_point end=std::chrono::steady_clock::now()+std::chrono::seconds(8);std::function<bool()> cancelled;};
int interrupt(void* opaque){auto deadline=static_cast<Deadline*>(opaque);return std::chrono::steady_clock::now()>deadline->end||(deadline->cancelled&&deadline->cancelled());}
void require(int result,const char* message){if(result<0){char reason[AV_ERROR_MAX_STRING_SIZE];av_strerror(result,reason,sizeof(reason));throw std::runtime_error(std::string(message)+": "+reason);}}
std::string digest(const std::string& key){boost::uuids::detail::sha1 sha;sha.process_bytes(key.data(),key.size());boost::uuids::detail::sha1::digest_type hash;sha.get_digest(hash);std::ostringstream out;for(auto n:hash)out<<std::hex<<std::setfill('0')<<std::setw(2*sizeof(n))<<static_cast<uint32_t>(n);return out.str();}
std::string base64(const std::vector<unsigned char>& data){static constexpr char alphabet[]="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";std::string result;result.reserve((data.size()+2)/3*4);for(size_t i=0;i<data.size();i+=3){uint32_t word=static_cast<uint32_t>(data[i])<<16;if(i+1<data.size())word|=static_cast<uint32_t>(data[i+1])<<8;if(i+2<data.size())word|=data[i+2];result+=alphabet[(word>>18)&63];result+=alphabet[(word>>12)&63];result+=i+1<data.size()?alphabet[(word>>6)&63]:'=';result+=i+2<data.size()?alphabet[word&63]:'=';}return result;}
std::vector<unsigned char> readFile(const fs::path& path){std::ifstream input(path,std::ios::binary);if(!input)throw std::runtime_error("Cannot read cached thumbnail");return std::vector<unsigned char>(std::istreambuf_iterator<char>(input),{});}
void writeAtomic(const fs::path& path,const unsigned char* bytes,size_t size){auto temporary=path.string()+".tmp-"+std::to_string(getpid());{std::ofstream output(temporary,std::ios::binary|std::ios::trunc);output.write(reinterpret_cast<const char*>(bytes),size);if(!output){fs::remove(temporary);throw std::runtime_error("Cannot write media cache");}}try{fs::rename(temporary,path);}catch(...){std::error_code ignored;fs::remove(temporary,ignored);throw;}}
int rotation(AVStream* stream){
    const uint8_t* matrix=nullptr;
#if LIBAVCODEC_VERSION_MAJOR >= 61
    const auto side=av_packet_side_data_get(stream->codecpar->coded_side_data,stream->codecpar->nb_coded_side_data,AV_PKT_DATA_DISPLAYMATRIX);if(side&&side->size>=9*sizeof(int32_t))matrix=side->data;
#else
    size_t size=0;matrix=av_stream_get_side_data(stream,AV_PKT_DATA_DISPLAYMATRIX,&size);if(size<9*sizeof(int32_t))matrix=nullptr;
#endif
    double degrees=matrix?-av_display_rotation_get(reinterpret_cast<const int32_t*>(matrix)):0.;if(!std::isfinite(degrees))degrees=0.;int rounded=static_cast<int>(std::round(degrees/90.))*90;return ((rounded%360)+360)%360;
}
bool decodeAt(AVFormatContext* format,AVCodecContext* codec,int streamIndex,double seconds,AVFrame* frame,Deadline& deadline){
    auto stream=format->streams[streamIndex];const auto start=stream->start_time==AV_NOPTS_VALUE?0:stream->start_time;const auto target=start+static_cast<int64_t>(seconds/av_q2d(stream->time_base));
    if(av_seek_frame(format,streamIndex,target,AVSEEK_FLAG_BACKWARD)>=0)avcodec_flush_buffers(codec);
    Packet packet;Frame last;bool haveLast=false;
    auto receive=[&](){while(!interrupt(&deadline)&&avcodec_receive_frame(codec,frame)>=0){const double timestamp=frame->best_effort_timestamp==AV_NOPTS_VALUE?seconds:(frame->best_effort_timestamp-start)*av_q2d(stream->time_base);if(timestamp+.001>=seconds)return true;av_frame_unref(last.value);require(av_frame_ref(last.value,frame),"Cannot retain poster frame");haveLast=true;av_frame_unref(frame);}return false;};
    for(unsigned attempts=0;attempts<4096&&!interrupt(&deadline);++attempts){
        int result=av_read_frame(format,packet.value);if(result<0){avcodec_send_packet(codec,nullptr);if(receive())return true;if(haveLast&&!interrupt(&deadline)){av_frame_unref(frame);require(av_frame_ref(frame,last.value),"Cannot retain final poster frame");return true;}return false;}
        if(packet.value->stream_index==streamIndex){result=avcodec_send_packet(codec,packet.value);av_packet_unref(packet.value);if(result<0&&result!=AVERROR(EAGAIN))continue;if(receive())return true;}else av_packet_unref(packet.value);
    }
    return false;
}

Json thumbnail(AVFormatContext* format,int streamIndex,int degrees,const fs::path& destination,Deadline& deadline,double seconds=-1){
    const auto stream=format->streams[streamIndex];const auto decoder=avcodec_find_decoder(stream->codecpar->codec_id);if(!decoder)throw std::runtime_error("Video codec is unavailable");
    Codec context;context.value=avcodec_alloc_context3(decoder);if(!context.value)throw std::runtime_error("Cannot allocate media decoder");require(avcodec_parameters_to_context(context.value,stream->codecpar),"Cannot initialize decoder");context.value->thread_count=1;require(avcodec_open2(context.value,decoder,nullptr),"Cannot open media decoder");
    Frame decoded;if(!decoded.value)throw std::runtime_error("Cannot allocate media frame");
    const double duration=format->duration>0?format->duration/static_cast<double>(AV_TIME_BASE):0.;
    if(!decodeAt(format,context.value,streamIndex,seconds>=0?seconds:(duration>1?1:0),decoded.value,deadline)&&!decodeAt(format,context.value,streamIndex,0,decoded.value,deadline))throw std::runtime_error("No media frame decoded within limit");
    if(decoded.value->width<1||decoded.value->height<1||static_cast<int64_t>(decoded.value->width)*decoded.value->height>134217728)throw std::runtime_error("Media dimensions exceed thumbnail limit");
    const bool swap=degrees==90||degrees==270;
    double aspect=av_q2d(av_guess_sample_aspect_ratio(format,stream,decoded.value));if(!std::isfinite(aspect)||aspect<=0)aspect=1;
    const double displayWidth=swap?decoded.value->height:decoded.value->width*aspect,displayHeight=swap?decoded.value->width*aspect:decoded.value->height;
    const double scale=std::min(320./displayWidth,180./displayHeight);const int width=std::max(1,static_cast<int>(std::round(displayWidth*scale))),height=std::max(1,static_cast<int>(std::round(displayHeight*scale)));
    const int scaledWidth=swap?height:width,scaledHeight=swap?width:height;
    std::vector<unsigned char> rgba(static_cast<size_t>(scaledWidth)*scaledHeight*4);
    Scaler scaler;scaler.value=sws_getContext(decoded.value->width,decoded.value->height,static_cast<AVPixelFormat>(decoded.value->format),scaledWidth,scaledHeight,AV_PIX_FMT_RGBA,SWS_BILINEAR,nullptr,nullptr,nullptr);if(!scaler.value)throw std::runtime_error("Cannot scale thumbnail");uint8_t* output[]={rgba.data()};int strides[]={scaledWidth*4};require(sws_scale(scaler.value,decoded.value->data,decoded.value->linesize,0,decoded.value->height,output,strides),"Cannot scale thumbnail");
    const auto png=avcodec_find_encoder(AV_CODEC_ID_PNG);if(!png)throw std::runtime_error("PNG encoder is unavailable");Codec encoder;encoder.value=avcodec_alloc_context3(png);if(!encoder.value)throw std::runtime_error("Cannot allocate PNG encoder");encoder.value->width=width;encoder.value->height=height;encoder.value->pix_fmt=AV_PIX_FMT_RGBA;encoder.value->time_base=AVRational{1,1};encoder.value->thread_count=1;require(avcodec_open2(encoder.value,png,nullptr),"Cannot initialize PNG encoder");Frame encoded;if(!encoded.value)throw std::runtime_error("Cannot allocate PNG frame");encoded.value->format=AV_PIX_FMT_RGBA;encoded.value->width=width;encoded.value->height=height;require(av_frame_get_buffer(encoded.value,32),"Cannot allocate PNG frame");
    for(int y=0;y<height;++y)for(int x=0;x<width;++x){int sx=x,sy=y;if(degrees==90){sx=y;sy=scaledHeight-1-x;}else if(degrees==180){sx=scaledWidth-1-x;sy=scaledHeight-1-y;}else if(degrees==270){sx=scaledWidth-1-y;sy=x;}std::copy_n(rgba.data()+(static_cast<size_t>(sy)*scaledWidth+sx)*4,4,encoded.value->data[0]+y*encoded.value->linesize[0]+x*4);}
    require(avcodec_send_frame(encoder.value,encoded.value),"Cannot encode thumbnail");Packet packet;require(avcodec_receive_packet(encoder.value,packet.value),"Cannot read encoded thumbnail");writeAtomic(destination,packet.value->data,packet.value->size);
    return {{"path",destination.string()},{"mime","image/png"},{"width",width},{"height",height}};
}
Json inspect(const fs::path& file,const fs::path& root,bool poster){
    std::lock_guard lock(cacheMutex);
    const auto key=digest(Json::array({"ffmpeg-media-v2",fs::weakly_canonical(file).string(),fs::file_size(file),fs::last_write_time(file).time_since_epoch().count()}).dump());
    fs::create_directories(root);const auto manifest=root/(key+".json"),image=root/(key+".png");
    Json result;try{std::ifstream input(manifest);if(input)input>>result;}catch(...){result=Json();}
    if(result.is_object()&&result.value("schema",0)==1&&(!poster||fs::is_regular_file(image))){if(poster){auto data=readFile(image);result["thumbnail"]["data"]=base64(data);}else result.erase("thumbnail");return result;}
    Deadline deadline;Format format;if(!format.value)throw std::runtime_error("Cannot allocate media probe");format.value->interrupt_callback={interrupt,&deadline};
    AVDictionary* options=nullptr;av_dict_set(&options,"protocol_whitelist","file",0);av_dict_set(&options,"probesize","8388608",0);av_dict_set(&options,"analyzeduration","2000000",0);
    const auto opened=avformat_open_input(&format.value,file.c_str(),nullptr,&options);av_dict_free(&options);require(opened,"Cannot inspect media");require(avformat_find_stream_info(format.value,nullptr),"Cannot read media streams");
    const int streamIndex=av_find_best_stream(format.value,AVMEDIA_TYPE_VIDEO,-1,-1,nullptr,0);require(streamIndex,"Media has no video stream");const auto stream=format.value->streams[streamIndex];
    const auto rate=av_guess_frame_rate(format.value,stream,nullptr);double duration=format.value->duration>0?format.value->duration/static_cast<double>(AV_TIME_BASE):stream->duration>0?stream->duration*av_q2d(stream->time_base):0.;if(!std::isfinite(duration))duration=0.;
    result={{"schema",1},{"width",stream->codecpar->width},{"height",stream->codecpar->height},{"durationSeconds",duration},{"frameRate",rate.num>0&&rate.den>0?av_q2d(rate):0.},{"hasAudio",av_find_best_stream(format.value,AVMEDIA_TYPE_AUDIO,-1,-1,nullptr,0)>=0},{"codec",avcodec_get_name(stream->codecpar->codec_id)},{"rotationDegrees",rotation(stream)}};
    Json subtitles=Json::array();for(unsigned index=0;index<format.value->nb_streams;++index){auto track=format.value->streams[index];if(track->codecpar->codec_type!=AVMEDIA_TYPE_SUBTITLE)continue;const auto language=av_dict_get(track->metadata,"language",nullptr,0),title=av_dict_get(track->metadata,"title",nullptr,0);std::string codec=avcodec_get_name(track->codecpar->codec_id);const bool selectable=codec=="ass"||codec=="ssa"||codec=="subrip"||codec=="srt"||codec=="text"||codec=="mov_text"||codec=="webvtt";subtitles.push_back({{"streamIndex",index},{"id",std::to_string(index)},{"codec",codec},{"selectable",selectable},{"default",bool(track->disposition&AV_DISPOSITION_DEFAULT)},{"forced",bool(track->disposition&AV_DISPOSITION_FORCED)},{"language",language?language->value:""},{"title",title?title->value:""}});}result["subtitleStreams"]=subtitles;
    if(poster)result["thumbnail"]=thumbnail(format.value,streamIndex,result["rotationDegrees"],image,deadline);
    const auto serialized=result.dump();writeAtomic(manifest,reinterpret_cast<const unsigned char*>(serialized.data()),serialized.size());
    if(poster)result["thumbnail"]["data"]=base64(readFile(image));return result;
}
}
std::filesystem::path mediaClipThumbnail(const fs::path& file,const fs::path& root,const Json& params,const std::function<bool()>& cancelled){
    Deadline deadline;deadline.cancelled=cancelled;std::unique_lock<std::timed_mutex> lock(cacheMutex,std::defer_lock);while(!lock.try_lock_for(std::chrono::milliseconds(50)))if(interrupt(&deadline))throw std::runtime_error("Thumbnail cancelled or timed out");
    if(!fs::is_regular_file(file))throw std::runtime_error("Thumbnail media is unavailable");
    auto bounded=[&](const char* name,double fallback){auto value=params.value(name,fallback);return std::isfinite(value)?std::clamp(value,0.,1.):fallback;};const double start=bounded("loop_start",0),end=bounded("loop_end",1),position=bounded("position",0);
    const auto key=digest(Json::array({"clip-poster-v1",fs::weakly_canonical(file).string(),fs::file_size(file),fs::last_write_time(file).time_since_epoch().count(),start,end,position}).dump());fs::create_directories(root);auto image=root/("poster-"+key+".png");if(fs::is_regular_file(image))return image;
    Format format;if(!format.value)throw std::runtime_error("Cannot allocate media probe");format.value->interrupt_callback={interrupt,&deadline};AVDictionary* options=nullptr;av_dict_set(&options,"protocol_whitelist","file",0);av_dict_set(&options,"probesize","8388608",0);av_dict_set(&options,"analyzeduration","2000000",0);auto opened=avformat_open_input(&format.value,file.c_str(),nullptr,&options);av_dict_free(&options);require(opened,"Cannot inspect thumbnail media");require(avformat_find_stream_info(format.value,nullptr),"Cannot read thumbnail streams");int index=av_find_best_stream(format.value,AVMEDIA_TYPE_VIDEO,-1,-1,nullptr,0);require(index,"Media has no video stream");auto stream=format.value->streams[index];double duration=format.value->duration>0?format.value->duration/static_cast<double>(AV_TIME_BASE):stream->duration>0?stream->duration*av_q2d(stream->time_base):0.;auto rate=av_guess_frame_rate(format.value,stream,nullptr);double frame=rate.num>0&&rate.den>0?1./av_q2d(rate):.001;double seconds=duration*(start+position*std::max(0.,end-start));seconds=std::clamp(seconds,0.,std::max(0.,duration-frame));
    thumbnail(format.value,index,rotation(stream),image,deadline,seconds);return image;
}
void installFFmpegMediaInspector(){installMediaInspector(inspect);}
}
