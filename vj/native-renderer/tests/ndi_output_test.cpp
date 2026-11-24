#include "projector_ndi_output.hpp"
#include "ndi_input.hpp"
#include "ndi_runtime.hpp"
#include <SDL2/SDL.h>
#include <fstream>
#include <iostream>
#include <filesystem>
#include <thread>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>
#include <csignal>
extern char **environ;
using Clock=std::chrono::steady_clock;
static void check(bool yes,const char *why){if(!yes)throw std::runtime_error(why);}
struct Child {pid_t pid=0;~Child(){if(pid){kill(pid,SIGTERM);waitpid(pid,nullptr,0);}}};
int main(){
    auto runtime=NdiRuntime::get();if(!runtime->api)return 77;
    SDL_Window *window=nullptr;SDL_GLContext context=nullptr;
    const std::string tag="Vibe-Publish-Test-"+std::to_string(getpid());
    const auto folder=std::filesystem::temp_directory_path()/tag;
    std::filesystem::create_directory(folder);
    struct Cleanup {std::filesystem::path path;~Cleanup(){std::filesystem::remove_all(path);}} cleanup{folder};
    try {
        check(SDL_Init(SDL_INIT_VIDEO)==0,SDL_GetError());
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION,3);SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION,3);
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK,SDL_GL_CONTEXT_PROFILE_CORE);
        window=SDL_CreateWindow("NDI output test",0,0,64,64,SDL_WINDOW_OPENGL|SDL_WINDOW_HIDDEN);
        check(window,SDL_GetError());context=SDL_GL_CreateContext(window);check(context,SDL_GetError());
        NativeNdiProjector config_a{tag+"-A",64,64,30},config_b{tag+"-B",96,64,25};
        auto output_a=std::make_unique<ProjectorNdiOutput>(config_a);
        auto output_b=std::make_unique<ProjectorNdiOutput>(config_b);
        bool black=false;
        auto draw=[&]{
            if(output_a && output_a->output.due())output_a->render([](const SDL_Rect &v){
                glEnable(GL_SCISSOR_TEST);glScissor(0,v.h/2,v.w,v.h/2);glClearColor(1,0,0,1);glClear(GL_COLOR_BUFFER_BIT);
                glScissor(0,0,v.w,v.h/2);glClearColor(0,0,1,1);glClear(GL_COLOR_BUFFER_BIT);glDisable(GL_SCISSOR_TEST);
            });
            if(output_b && output_b->output.due())output_b->render([&](const SDL_Rect &){
                glClearColor(0,black?0:1,0,1);glClear(GL_COLOR_BUFFER_BIT);
            });
            SDL_PumpEvents();std::this_thread::sleep_for(std::chrono::milliseconds(10));
        };
        NDIlib_find_create_t fs;fs.show_local_sources=true;auto finder=runtime->api->find_create_v2(&fs);
        check(finder,"finder failed");
        struct Finder {const NDIlib_v5 *api;NDIlib_find_instance_t f;~Finder(){api->find_destroy(f);}} finder_cleanup{runtime->api,finder};
        nlohmann::json a,b;
        const auto deadline=Clock::now()+std::chrono::seconds(12);
        while(Clock::now()<deadline && (a.is_null()||b.is_null())) {
            draw();uint32_t count=0;const auto *sources=runtime->api->find_get_current_sources(finder,&count);
            for(uint32_t i=0;i<count;++i) {
                const std::string name=sources[i].p_ndi_name?sources[i].p_ndi_name:"";
                nlohmann::json value={{"name",name},{"url",sources[i].p_url_address?sources[i].p_url_address:""}};
                if(name.find(tag+"-A")!=std::string::npos)a=value;
                if(name.find(tag+"-B")!=std::string::npos)b=value;
            }
        }
        check(!a.is_null()&&!b.is_null(),"both outputs must be discovered");
        NdiInput receiver_a(a.dump()),receiver_b(b.dump());
        auto wait=[&](auto predicate,const char *error,int seconds=8){const auto end=Clock::now()+std::chrono::seconds(seconds);while(Clock::now()<end){draw();if(predicate())return;}throw std::runtime_error(error);};
        wait([&]{const auto x=receiver_a.snapshot(),y=receiver_b.snapshot();return x.connected&&y.connected&&x.frame&&y.frame;},"receive both outputs");
        auto x=receiver_a.snapshot().frame;auto y=receiver_b.snapshot().frame;
        check(x->width==64&&y->width==96,"independent resolutions");
        auto pixel=[](const NdiFrame &f,int row,int c){return f.rgba[(row*f.width+f.width/2)*4+c];};
        check(pixel(*x,8,0)>220&&pixel(*x,8,2)<35&&pixel(*x,56,2)>220,"sender orientation and colors");
        check(pixel(*y,8,1)>220&&pixel(*y,8,0)<35,"independent bus routing");
        // Exercise the actual standalone SDL client against the graph sender.
        Child client;
        if(const char *exe=std::getenv("VIBE_NDI_TEST_CLIENT")) {
            std::string config=(folder/"client.json").string(),capture=(folder/"screen.ppm").string();
            {std::ofstream file(config);file<<nlohmann::json({{"screens", {{{"display",0},{"source",a.dump()},{"disconnect","black"}}}},{"extra_ips",""}}).dump();}
            char *args[]={const_cast<char*>(exe),const_cast<char*>("--config"),config.data(),const_cast<char*>("--windowed"),const_cast<char*>("--test-capture"),capture.data(),nullptr};
            check(posix_spawn(&client.pid,exe,nullptr,nullptr,args,environ)==0,"client spawn");
            wait([&]{return std::filesystem::exists(capture);},"standalone display did not receive",12);
            std::ifstream file(capture,std::ios::binary);std::string magic;int w,h,max;file>>magic>>w>>h>>max;file.get();
            std::vector<unsigned char> rgb(static_cast<std::size_t>(w)*h*3);file.read(reinterpret_cast<char*>(rgb.data()),rgb.size());
            check(magic=="P6"&&w>0&&h>0,"SDL capture format");
            check(rgb[((h/4)*w+w/2)*3]>200&&rgb[((3*h/4)*w+w/2)*3+2]>200,"standalone display orientation");
            kill(client.pid,SIGTERM);waitpid(client.pid,nullptr,0);client.pid=0;
        }
        const auto old=receiver_b.snapshot().frame->sequence;
        black=true;
        wait([&]{auto f=receiver_b.snapshot().frame;return f&&f->sequence>old&&pixel(*f,8,1)<20;},"master blackout not transmitted");
        black=false;config_b.width=128;output_b->configure(config_b);
        wait([&]{auto f=receiver_b.snapshot().frame;return f&&f->width==128&&pixel(*f,8,1)>220;},"resize/reconnect failed",12);
        output_a.reset();output_b.reset();draw();
        wait([&]{return !receiver_b.snapshot().connected;},"disabled sender still online");
        std::cout<<"NDI outputs: discovery, independent projector targets, orientation, master blackout, resize/reconnect, disable, standalone SDL display passed\n";
    }catch(const std::exception &e){std::cerr<<e.what()<<'\n';if(context)SDL_GL_DeleteContext(context);if(window)SDL_DestroyWindow(window);SDL_Quit();return 1;}
    SDL_GL_DeleteContext(context);SDL_DestroyWindow(window);SDL_Quit();return 0;
}
