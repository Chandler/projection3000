#include "midi_runtime.hpp"
#include "link_runtime.hpp"
#include "api_server.hpp"
#include "remote_server.hpp"
#include "state_lock.hpp"
#include "fixture_output.hpp"
#include <csignal>
#include <iostream>
#include <thread>
namespace { volatile std::sig_atomic_t stopping=0;void stop(int){stopping=1;} }
int main(int argc,char** argv){
    try{
        std::filesystem::path root;std::string address="127.0.0.1",startupPolicy="isolated";unsigned short port=9120,remotePort=0;std::string remoteKey;
        for(int i=1;i<argc;i++){
            const std::string arg=argv[i];
            if(arg=="--help"){std::cout<<"vj-headless --state-root DIRECTORY [--bind ADDRESS] [--port PORT] [--startup-policy isolated|restore] [--remote-port PORT --remote-key KEY]\n";return 0;}
            if(i+1>=argc)throw std::runtime_error("Missing value for "+arg);
            if(arg=="--state-root")root=argv[++i];
            else if(arg=="--bind")address=argv[++i];
            else if(arg=="--startup-policy")startupPolicy=argv[++i];
            else if(arg=="--remote-key")remoteKey=argv[++i];
            else if(arg=="--port"||arg=="--remote-port"){std::string value=argv[++i];size_t used=0;int n=std::stoi(value,&used);if(used!=value.size()||n<0||n>65535)throw std::runtime_error("Invalid port");(arg=="--port"?port:remotePort)=static_cast<unsigned short>(n);}
            else throw std::runtime_error("Unknown argument: "+arg);
        }
        if(startupPolicy!="isolated"&&startupPolicy!="restore")throw std::runtime_error("Invalid startup policy");
        if(root.empty())throw std::runtime_error("--state-root is required for the native development runtime");
#ifdef VJ_HAS_PORTABLE_TEXT
        vj::installPortableTextBackends();
#endif
        vj::StateLock lock(root);vj::Model model(root);model.setRestoreDevices(startupPolicy=="restore");vj::ApiServer server(model,port,address);
        std::unique_ptr<vj::RemoteServer> remote;if(remotePort)remote=std::make_unique<vj::RemoteServer>(model,remotePort,remoteKey);
        vj::FixtureOutputRuntime fixtures({[&]{return model.snapshot();},[&](const std::string& kind,const vj::Json& status){model.setControlRuntime(kind,status);}});fixtures.start();
        vj::LinkRuntime link({[&]{return model.snapshot();},[&](const vj::Json& status){model.setControlRuntime("link",status);},[&](const vj::Json& clock){model.setLinkClock(clock);}});
        std::signal(SIGINT,stop);std::signal(SIGTERM,stop);
        vj::MidiRuntime midi({[&]{return model.midiSnapshot();},[&]{return model.effectCatalog();},[&](const std::string& path,const vj::Json& body){auto reply=model.request("POST",path,body);if(reply.status>=400)throw std::runtime_error(reply.body.value("error",std::string("MIDI command failed")));},[&](const vj::Json& status){model.setControlRuntime("midi",status);}},
#ifdef VJ_HAS_MAC_MIDI
            vj::makeMacMidiBackend()
#else
            vj::makeMidiBackend()
#endif
        );midi.start();link.start();
        std::cout<<vj::Json({{"app","vj-headless"},{"address",address},{"port",server.port()},{"stateRoot",std::filesystem::absolute(root).string()},{"featureParity",false}}).dump()<<std::endl;
        while(!stopping)std::this_thread::sleep_for(std::chrono::milliseconds(100));
        return 0;
    }catch(const std::exception& error){std::cerr<<error.what()<<'\n';return 1;}
}
