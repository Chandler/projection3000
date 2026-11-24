#include "ndi_runtime.hpp"
#include "ndi_input.hpp"
#include "native_render_graph.hpp"
#include <SDL2/SDL.h>
#include <chrono>
#include <thread>
#include <iostream>
#include <fstream>
#include <filesystem>
#include <stdexcept>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>
#include <csignal>
extern char **environ;
using Clock = std::chrono::steady_clock;
static void require(bool v,const char *message) { if(!v) throw std::runtime_error(message); }
static void tick() {SDL_PumpEvents();std::this_thread::sleep_for(std::chrono::milliseconds(10));}
struct Window {
    SDL_Window *window=nullptr; SDL_GLContext context=nullptr;
    Window() {
        require(SDL_Init(SDL_INIT_VIDEO)==0,SDL_GetError());
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION,3);SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION,2);
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK,SDL_GL_CONTEXT_PROFILE_CORE);
        window=SDL_CreateWindow("Vibe NDI test",0,0,64,32,SDL_WINDOW_OPENGL|SDL_WINDOW_HIDDEN);
        require(window,SDL_GetError());context=SDL_GL_CreateContext(window);require(context,SDL_GetError());
    }
    ~Window(){SDL_GL_DeleteContext(context);SDL_DestroyWindow(window);SDL_Quit();}
};
static int sender(const char *name,const char *control) {
    auto runtime=NdiRuntime::get();require(runtime->api,runtime->error.c_str());
    const auto *api=runtime->api;
    NDIlib_send_create_t settings;settings.p_ndi_name=name;settings.clock_video=true;settings.clock_audio=false;
    auto output=api->send_create(&settings);require(output,"sender unavailable");
    for(int i=0;i<1800;++i) {
        int width=64;{std::ifstream file(control);file>>width;}width=width==96?96:64;
        constexpr int height=32;
        // Padded rows check SDK handling of pitch as well as actual network pixels.
        const int stride=width*4+32;
        std::vector<std::uint8_t> pixels(stride*height,0);
        for(int y=0;y<height;++y)for(int x=0;x<width;++x) {
            auto *p=&pixels[y*stride+x*4];
            p[y<16?0:2]=255;p[3]=y<16?255:128;
        }
        NDIlib_video_frame_v2_t frame;
        frame.xres=width;frame.yres=height;frame.FourCC=NDIlib_FourCC_video_type_RGBA;
        frame.frame_rate_N=30;frame.frame_rate_D=1;frame.picture_aspect_ratio=float(width)/height;
        frame.frame_format_type=NDIlib_frame_format_type_progressive;
        frame.p_data=pixels.data();frame.line_stride_in_bytes=stride;
        api->send_send_video_v2(output,&frame);
    }
    api->send_destroy(output);return 0;
}
struct Child {
    pid_t pid=0;
    void stop(){if(pid){kill(pid,SIGKILL);waitpid(pid,nullptr,0);pid=0;}}
    ~Child(){stop();}
    void start(char *exe,std::string &name,std::string &path){
        char *args[]={exe,const_cast<char *>("--sender"),name.data(),path.data(),nullptr};
        require(posix_spawn(&pid,exe,nullptr,nullptr,args,environ)==0,"sender spawn failed");
    }
};
int main(int argc,char **argv){
    auto runtime=NdiRuntime::get();
    if(!runtime->api){std::cerr<<runtime->error<<'\n';return 77;}
    try {
        if(argc==4)return sender(argv[2],argv[3]);
        std::string name="Vibe-NDI-Test-"+std::to_string(getpid());
        std::string path=(std::filesystem::temp_directory_path()/(name+".txt")).string();
        struct Remove{std::string path;~Remove(){std::filesystem::remove(path);}} remove{path};
        {std::ofstream file(path);file<<64;}
        Child child;child.start(argv[0],name,path);
        NDIlib_find_create_t settings;settings.show_local_sources=true;
        auto finder=runtime->api->find_create_v2(&settings);require(finder,"finder unavailable");
        nlohmann::json selection;
        for(int i=0;i<80;++i){
            runtime->api->find_wait_for_sources(finder,100);
            uint32_t count=0;const auto *sources=runtime->api->find_get_current_sources(finder,&count);
            for(uint32_t n=0;n<count;++n)if(sources[n].p_ndi_name && std::string(sources[n].p_ndi_name).find(name)!=std::string::npos)
                selection={{"name",sources[n].p_ndi_name},{"url",sources[n].p_url_address?sources[n].p_url_address:""}};
            if(!selection.is_null())break;
        }
        runtime->api->find_destroy(finder);require(!selection.is_null(),"NDI discovery failed");
        Window window;NativeRenderGraph graph;
        graph.set_bus_sizes({{"preview",{64,32}},{"program",{64,32}}});
        NativeLayer bg;bg.generator="solid_color";bg.source_id="bg";bg.params={{"color","#00ff00"}};
        NativeLayer live;live.generator="ndi";live.source_id="ndi";live.resolved_file=selection.dump();
        live.params={{"fit","stretch"},{"disconnect","freeze"}};
        NativeScene scene;
        auto apply=[&]{scene.buses["preview"].layers={bg,live};scene.buses["program"]=scene.buses["preview"];graph.apply_scene(scene);};apply();
        auto await_frame=[&](int width){
            const auto deadline=Clock::now()+std::chrono::seconds(12);
            while(Clock::now()<deadline){tick();graph.render();auto d=graph.diagnostics();
                for(const auto &s:d["sources"])if(s["backend"]=="ndi"&&s["width"]==width&&s["connected"]==true&&s["error"]=="")return true;}
            std::cerr<<graph.diagnostics().dump()<<'\n';return false;
        };
        require(await_frame(64),"NDI receive failed");
        auto verify=[&]{for(const auto &bus:{"preview","program"}){
            auto pixels=graph.read_bus_rgb(bus,64,32);
            const auto top=(8*64+32)*3, bottom=(24*64+32)*3;
            if(!(pixels[top]>225&&pixels[top+1]<25&&pixels[top+2]<25)){
                std::cerr<<"top "<<int(pixels[top])<<','<<int(pixels[top+1])<<','<<int(pixels[top+2])<<'\n';throw std::runtime_error("NDI orientation/color failed");}
            require(pixels[bottom]<25&&std::abs(int(pixels[bottom+1])-127)<25&&std::abs(int(pixels[bottom+2])-128)<25,"NDI alpha failed");
        }};verify();
        require(graph.diagnostics()["sourceCount"]==1,"NDI duplicated receiver across buses");
        {std::ofstream file(path);file<<96;}require(await_frame(96),"live resolution change failed");verify();
        child.stop();bool offline=false;
        const auto deadline=Clock::now()+std::chrono::seconds(10);
        while(Clock::now()<deadline){tick();graph.render();auto d=graph.diagnostics();for(const auto &s:d["sources"])if(s["backend"]=="ndi"&&s["connected"]==false)offline=true;if(offline)break;}
        require(offline,"NDI loss not detected");verify();
        live.params["disconnect"]="black";apply();graph.render();auto black=graph.read_bus_rgb("preview",64,32);
        require(std::all_of(black.begin(),black.end(),[](auto v){return v<5;}),"NDI black fallback failed");
        child.start(argv[0],name,path);require(await_frame(96),"NDI sender restart failed");verify();
        scene.buses.clear();graph.apply_scene(scene);graph.render();require(graph.diagnostics()["sourceCount"]==0,"NDI source release failed");
        std::cout<<"PASS: NDI discovery, network receive, orientation, alpha, shared source, live resize, freeze/black, crash recovery, cleanup\n";
    }catch(const std::exception &e){std::cerr<<e.what()<<'\n';return 1;}
}
