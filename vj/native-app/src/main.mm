#include "calibration_debug_codec.hpp"
#include "calibration_capture.hpp"
#include "vector_catalog.hpp"
#import "app.hpp"
#import "show_library.hpp"
#include "api_server.hpp"
#include "remote_server.hpp"
#include "state_lock.hpp"
#include "midi_runtime.hpp"
#include <iostream>
int main(int argc,char** argv){@autoreleasepool{
    try{
        std::filesystem::path root;unsigned short port=9120,remotePort=9125;bool check=false;std::string address="127.0.0.1",startupPolicy;
        for(int i=1;i<argc;i++){
            std::string arg=argv[i];
            if(arg=="--check-ui"){check=true;continue;}
            if(arg=="--help"){std::cout<<"VJ [--state-root DIRECTORY] [--port PORT] [--startup-policy isolated|restore] [--bind ADDRESS] [--remote-port PORT] [--check-ui]\n";return 0;}
            if(i+1>=argc)throw std::runtime_error("Missing value for "+arg);
            if(arg=="--state-root")root=argv[++i];
            else if(arg=="--bind")address=argv[++i];
            else if(arg=="--startup-policy")startupPolicy=argv[++i];
            else if(arg=="--port"||arg=="--remote-port"){std::string raw=argv[++i];size_t used;int value=std::stoi(raw,&used);if(used!=raw.size()||value<0||value>65535)throw std::runtime_error("Invalid port");(arg=="--port"?port:remotePort)=value;}
            else throw std::runtime_error("Unknown argument: "+arg);
        }
        const bool defaultRoot=root.empty();
        if(root.empty())root=vj::shows::startupRoot();
        const bool libraryShow=vj::shows::inLibrary(root);
        if(startupPolicy.empty())startupPolicy=(defaultRoot||libraryShow)&&!check?"restore":"isolated";
        if(startupPolicy!="isolated"&&startupPolicy!="restore")throw std::runtime_error("Invalid startup policy");
        vj::installMacTextRasterizer();
        vj::installMacVectorTextOutliner();
        vj::installFFmpegMediaInspector();
        vj::installWasmtimeModuleValidator();vj::installLiveCalibrationCapture();vj::installCalibrationDebugPngCodec();
        vj::StateLock lock(root);
        if(!check){
            if(libraryShow){vj::shows::relocate(root);vj::shows::remember(root);}
            if(!getenv("VJ_PATCH_SESSION"))setenv("VJ_PATCH_SESSION",(root/"Patch/session.json").c_str(),1);
        }
        vj::Model model(root);
        model.setRestoreDevices(!check&&startupPolicy=="restore");vj::ApiServer server(model,port,address);
        // Phone mapping remote on the LAN; 0 disables. The key persists so saved links keep working.
        std::unique_ptr<vj::RemoteServer> remote;if(!check&&remotePort){
            auto defaults=NSUserDefaults.standardUserDefaults;NSString* key=[defaults stringForKey:@"VJRemoteKey"];
            if(key.length<8){key=[[NSUUID.UUID.UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""] substringToIndex:12].lowercaseString;[defaults setObject:key forKey:@"VJRemoteKey"];}
            try{remote=std::make_unique<vj::RemoteServer>(model,remotePort,key.UTF8String);}catch(const std::exception& e){model.setControlRuntime("remote",{{"error",e.what()}});}
        }
        vj::MidiRuntime midi({[&]{return model.midiSnapshot();},[&]{return model.effectCatalog();},[&](const std::string& path,const vj::Json& body){auto result=model.request("POST",path,body);if(result.status>=400)throw std::runtime_error(result.body.value("error",std::string("MIDI command failed")));},[&](const vj::Json& status){model.setControlRuntime("midi",status);},[&](int channel,double value){return model.receiveChannelFader(channel,value);},[&](int status,int number,int value){return model.receivePatchAPC(status,number,value);},[&]{return model.patchAPCOwned();}},vj::makeMacMidiBackend());
        [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        auto menu=[[NSMenu alloc] initWithTitle:@"VJ"];
        auto item=[[NSMenuItem alloc] initWithTitle:@"VJ" action:nil keyEquivalent:@""];
        auto submenu=[[NSMenu alloc] initWithTitle:@"VJ"];
        [submenu addItemWithTitle:@"Quit VJ" action:@selector(terminate:) keyEquivalent:@"q"];
        item.submenu=submenu;[menu addItem:item];NSApp.mainMenu=menu;
        auto edit=[[NSMenuItem alloc] initWithTitle:@"Edit" action:nil keyEquivalent:@""];
        auto editMenu=[[NSMenu alloc] initWithTitle:@"Edit"];
        [editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
        [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
        [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
        [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
        edit.submenu=editMenu;[menu addItem:edit];
        auto app=[[VJApplication alloc] initWithModel:&model port:server.port() address:[NSString stringWithUTF8String:address.c_str()]];NSApp.delegate=app;
        if(check){bool ok=[app checkInterface];std::cout<<(ok?"Native interface constructed\n":"Interface check failed\n");return ok?0:1;}
        midi.start();[NSApp run];midi.stop();return 0;
    }catch(const std::exception& error){std::cerr<<error.what()<<'\n';return 1;}
}}
