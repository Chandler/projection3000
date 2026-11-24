#include "midi_runtime.hpp"
#include <alsa/asoundlib.h>
#include <atomic>
#include <chrono>
#include <thread>
#include <map>
#include <stdexcept>
#include <array>
namespace vj { namespace {
void check(int result,const char* action){if(result<0)throw std::runtime_error(std::string(action)+": "+snd_strerror(result));}
struct Port {std::string device;bool input=false,output=false;};
std::map<std::string,Port> discover(){std::map<std::string,Port> result;int card=-1;while(snd_card_next(&card)>=0&&card>=0){snd_ctl_t* control=nullptr;auto hardware="hw:"+std::to_string(card);if(snd_ctl_open(&control,hardware.c_str(),0)<0)continue;snd_ctl_card_info_t* cardInfo;snd_ctl_card_info_alloca(&cardInfo);if(snd_ctl_card_info(control,cardInfo)<0){snd_ctl_close(control);continue;}std::string identity=snd_ctl_card_info_get_id(cardInfo);int device=-1;while(snd_ctl_rawmidi_next_device(control,&device)>=0&&device>=0){for(auto stream:{SND_RAWMIDI_STREAM_INPUT,SND_RAWMIDI_STREAM_OUTPUT}){snd_rawmidi_info_t* info;snd_rawmidi_info_alloca(&info);snd_rawmidi_info_set_device(info,device);snd_rawmidi_info_set_subdevice(info,0);snd_rawmidi_info_set_stream(info,stream);if(snd_ctl_rawmidi_info(control,info)<0)continue;unsigned count=snd_rawmidi_info_get_subdevices_count(info);for(unsigned sub=0;sub<count;++sub){snd_rawmidi_info_set_subdevice(info,sub);if(snd_ctl_rawmidi_info(control,info)<0)continue;std::string address="hw:"+identity+","+std::to_string(device)+","+std::to_string(sub);const char* subName=snd_rawmidi_info_get_subdevice_name(info);std::string name=(subName&&*subName)?subName:snd_rawmidi_info_get_name(info);auto& port=result[name+" ["+address+"]"];port.device=address;if(stream==SND_RAWMIDI_STREAM_INPUT)port.input=true;else port.output=true;}}}snd_ctl_close(control);}return result;}
class AlsaMidi final:public MidiBackend {
 snd_rawmidi_t* input_=nullptr; snd_rawmidi_t* output_=nullptr;std::jthread reader_;std::atomic<int> error_{0};
public:
 ~AlsaMidi()override{close();}
 bool available()const override{return true;}
 MidiPorts ports()override{MidiPorts result;for(const auto& [name,port]:discover()){if(port.input)result.inputs.push_back(name);if(port.output)result.outputs.push_back(name);}return result;}
 void open(const std::string& name,bool controller,Receive receive)override{close();auto ports=discover();auto found=ports.find(name);if(found==ports.end()||!found->second.input)throw std::runtime_error("MIDI input disconnected");if(controller&&!found->second.output)throw std::runtime_error("MIDI feedback port unavailable");try{check(snd_rawmidi_open(&input_,controller?&output_:nullptr,found->second.device.c_str(),SND_RAWMIDI_NONBLOCK),"Open ALSA MIDI");error_=0;reader_=std::jthread([this,receive=std::move(receive)](std::stop_token stop){MidiByteParser parser;std::array<uint8_t,512> bytes;while(!stop.stop_requested()){auto n=snd_rawmidi_read(input_,bytes.data(),bytes.size());if(n>0){double now=std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();parser.feed(bytes.data(),n,now,receive);}else if(n<0&&n!=-EAGAIN&&n!=-EINTR){error_=n;return;}else std::this_thread::sleep_for(std::chrono::milliseconds(2));}});if(controller)send({0xf0,0x47,0x7f,0x29,0x60,0x00,0x04,0x41,0x01,0x00,0x00,0xf7});}catch(...){close();throw;}}
 void send(const std::vector<uint8_t>& bytes)override{if(error_.load()<0)check(error_.load(),"ALSA MIDI input");if(!output_)throw std::runtime_error("MIDI output not connected");if(bytes.size()>512)throw std::runtime_error("MIDI feedback packet too large");size_t sent=0;auto deadline=std::chrono::steady_clock::now()+std::chrono::milliseconds(20);while(sent<bytes.size()){auto n=snd_rawmidi_write(output_,bytes.data()+sent,bytes.size()-sent);if(n>0)sent+=n;else if(n==-EAGAIN||n==-EINTR){if(std::chrono::steady_clock::now()>=deadline)throw std::runtime_error("MIDI output backpressure");std::this_thread::sleep_for(std::chrono::milliseconds(1));}else check(n,"Write ALSA MIDI");}}
 void close()override{if(reader_.joinable()){reader_.request_stop();reader_.join();}if(output_){snd_rawmidi_drop(output_);snd_rawmidi_close(output_);output_=nullptr;}if(input_){snd_rawmidi_close(input_);input_=nullptr;}error_=0;}
};
}
std::unique_ptr<MidiBackend> makeMidiBackend(){return std::make_unique<AlsaMidi>();}
}
