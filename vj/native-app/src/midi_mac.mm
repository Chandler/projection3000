#include "midi_runtime.hpp"
#import <CoreMIDI/CoreMIDI.h>
#import <Foundation/Foundation.h>
#include <chrono>
#include <stdexcept>
#include <mutex>
namespace vj {
namespace {
void checked(OSStatus result,const char* operation){if(result!=noErr)throw std::runtime_error(std::string(operation)+": "+std::to_string(result));}
std::string name(MIDIObjectRef object){CFStringRef value=nullptr;if(MIDIObjectGetStringProperty(object,kMIDIPropertyDisplayName,&value)!=noErr||!value){if(MIDIObjectGetStringProperty(object,kMIDIPropertyName,&value)!=noErr||!value)return {};}
    NSString* string=(__bridge NSString*)value;std::string result=string.UTF8String?:"";CFRelease(value);return result;
}
class CoreMidi final:public MidiBackend {
    MIDIClientRef client_=0;MIDIPortRef input_=0,output_=0;MIDIEndpointRef source_=0,destination_=0;
    struct Context {Receive receive;MidiByteParser parser;};
    std::unique_ptr<Context> context_;
    void client(){
        // This client lives on the MIDI worker, which does not run a CFRunLoop.
        // Let CoreMIDI deliver device-change notifications on its own thread.
        if(!client_)checked(MIDIClientCreateWithBlock(CFSTR("VJ"),&client_,^(const MIDINotification*){}),"MIDI client");
    }
    static void read(const MIDIPacketList* packets,void* ref,void*){
        auto* context=static_cast<Context*>(ref);const MIDIPacket* packet=&packets->packet[0];
        for(UInt32 i=0;i<packets->numPackets;i++){
            double now=std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
            context->parser.feed(packet->data,packet->length,now,context->receive);packet=MIDIPacketNext(packet);
        }
    }
public:
    ~CoreMidi()override{close();if(client_)MIDIClientDispose(client_);}
    bool available()const override{return true;}
    MidiPorts ports()override{@autoreleasepool {client();MidiPorts result;for(ItemCount i=0;i<MIDIGetNumberOfSources();i++)result.inputs.push_back(name(MIDIGetSource(i)));for(ItemCount i=0;i<MIDIGetNumberOfDestinations();i++)result.outputs.push_back(name(MIDIGetDestination(i)));return result;}}
    void open(const std::string& selected,bool controller,Receive receive)override{@autoreleasepool {
        close();client();try {
            for(ItemCount i=0;i<MIDIGetNumberOfSources();i++){auto endpoint=MIDIGetSource(i);if(name(endpoint)==selected){if(source_)throw std::runtime_error("Ambiguous MIDI input name");source_=endpoint;}}
            if(!source_)throw std::runtime_error("MIDI input disconnected");
            if(controller){std::vector<MIDIEndpointRef> matches;for(ItemCount i=0;i<MIDIGetNumberOfDestinations();i++){auto endpoint=MIDIGetDestination(i);auto label=name(endpoint);if(label==selected)destination_=endpoint;if(isApc40(label))matches.push_back(endpoint);}if(!destination_&&matches.size()==1)destination_=matches.front();if(!destination_)throw std::runtime_error("No unambiguous APC40 mkII MIDI output");checked(MIDIOutputPortCreate(client_,CFSTR("VJ feedback"),&output_),"MIDI output");}
            context_=std::make_unique<Context>();context_->receive=std::move(receive);
            checked(MIDIInputPortCreate(client_,CFSTR("VJ input"),read,context_.get(),&input_),"MIDI input");
            checked(MIDIPortConnectSource(input_,source_,nullptr),"MIDI connect");
            if(controller)send({0xf0,0x47,0x7f,0x29,0x60,0x00,0x04,0x41,0x01,0x00,0x00,0xf7});
        }catch(...){close();throw;}
    }}
    void send(const std::vector<uint8_t>& bytes)override{
        if(!output_||!destination_)throw std::runtime_error("MIDI output not connected");if(bytes.empty())return;
        if(bytes.size()>512)throw std::runtime_error("MIDI feedback packet too large");alignas(MIDIPacketList) uint8_t storage[1024]{};auto* packets=reinterpret_cast<MIDIPacketList*>(storage);auto* packet=MIDIPacketListInit(packets);if(!MIDIPacketListAdd(packets,sizeof(storage),packet,0,bytes.size(),bytes.data()))throw std::runtime_error("MIDI packet overflow");checked(MIDISend(output_,destination_,packets),"MIDI send");
    }
    void close()override{
        if(input_){if(source_)MIDIPortDisconnectSource(input_,source_);MIDIPortDispose(input_);}input_=0;source_=0;context_.reset();if(output_)MIDIPortDispose(output_);output_=0;destination_=0;
    }
};
}
std::unique_ptr<MidiBackend> makeMacMidiBackend(){return std::make_unique<CoreMidi>();}
}
