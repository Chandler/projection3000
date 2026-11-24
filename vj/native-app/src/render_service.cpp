#include "text_source.hpp"
#include "calibration_debug_codec.hpp"
#include "midi_runtime.hpp"
#include "link_runtime.hpp"
#include "calibration_capture.hpp"
#include "api_server.hpp"
#include "render_host.hpp"
#include "state_lock.hpp"
#include <csignal>
#include <iostream>
#include <thread>

namespace {volatile std::sig_atomic_t stopping=0;void stop(int){stopping=1;}}
int main(int argc,char** argv){
    try{
        std::filesystem::path root;std::string address="127.0.0.1",startupPolicy="isolated";unsigned short port=9120;
        vj::RenderHostOptions options;bool check=false;
        for(int i=1;i<argc;i++){
            std::string arg=argv[i];
            if(arg=="--help"){std::cout<<"vj-render-service --state-root DIRECTORY [--bind ADDRESS] [--port PORT] [--startup-policy isolated|restore] [--width PIXELS] [--height PIXELS] [--fps FPS] [--out BUS] [--check-render]\n";return 0;}
            if(arg=="--check-render"){check=true;continue;}
            if(i+1>=argc)throw std::runtime_error("Missing value for "+arg);
            std::string value=argv[++i];
            if(arg=="--state-root")root=value;
            else if(arg=="--bind")address=value;
            else if(arg=="--startup-policy")startupPolicy=value;
            else if(arg=="--out")options.outputs.push_back(value);
            else if(arg=="--port"||arg=="--width"||arg=="--height"||arg=="--fps"){
                std::size_t used=0;int n=std::stoi(value,&used);if(used!=value.size())throw std::runtime_error("Invalid number for "+arg);
                if(arg=="--port"){if(n<0||n>65535)throw std::runtime_error("Invalid port");port=static_cast<unsigned short>(n);}
                else if(arg=="--width")options.width=n;
                else if(arg=="--height")options.height=n;
                else options.fps=n;
            }else throw std::runtime_error("Unknown argument: "+arg);
        }
        if(startupPolicy!="isolated"&&startupPolicy!="restore")throw std::runtime_error("Invalid startup policy");
        if(root.empty())throw std::runtime_error("--state-root is required for the native development runtime");
#ifdef __APPLE__
        vj::installMacTextRasterizer();
#endif
        options.publishOutputs=!check;
        vj::installFFmpegMediaInspector();
        vj::installWasmtimeModuleValidator();vj::installLiveCalibrationCapture();vj::installCalibrationDebugPngCodec();
#ifdef VJ_HAS_PORTABLE_TEXT
        vj::installPortableTextBackends();
#endif
        vj::StateLock lock(root);vj::Model model(root);model.setRestoreDevices(!check&&startupPolicy=="restore");vj::RenderHost renderer(model,options);
        vj::LinkRuntime link({[&]{return model.snapshot();},[&](const vj::Json& status){model.setControlRuntime("link",status);},[&](const vj::Json& clock){model.setLinkClock(clock);}});
        std::signal(SIGINT,stop);std::signal(SIGTERM,stop);
        if(check){std::cout<<renderer.checkRendering().dump()<<std::endl;return 0;}
        vj::MidiRuntime midi({[&]{return model.snapshot();},[&]{return model.effectCatalog();},[&](const std::string& path,const vj::Json& body){auto reply=model.request("POST",path,body);if(reply.status>=400)throw std::runtime_error(reply.body.value("error",std::string("MIDI command failed")));},[&](const vj::Json& status){model.setControlRuntime("midi",status);}},
#ifdef VJ_HAS_MAC_MIDI
            vj::makeMacMidiBackend()
#else
            vj::makeMidiBackend()
#endif
        );midi.start();link.start();
        vj::ApiServer server(model,port,address);
        std::cout<<vj::Json({{"app","vj-render-service"},{"address",address},{"port",server.port()},{"stateRoot",std::filesystem::absolute(root).string()},{"featureParity",false},{"hardwareOutputs",false}}).dump()<<std::endl;
        const auto interval=std::chrono::nanoseconds(1'000'000'000/options.fps);
        auto next=std::chrono::steady_clock::now();
        while(!stopping&&renderer.tick()){
            next+=interval;const auto now=std::chrono::steady_clock::now();if(next<now-interval)next=now;
            std::this_thread::sleep_until(next);
        }
        return 0;
    }catch(const std::exception& error){std::cerr<<error.what()<<'\n';return 1;}
}
