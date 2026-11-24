#include "native_render_graph.hpp"
#include "syphon_input.hpp"
#import <Syphon/SyphonOpenGLServer.h>
#import <Cocoa/Cocoa.h>
#import <OpenGL/OpenGL.h>
#include <SDL2/SDL.h>
#include <chrono>
#include <thread>
#include <iostream>
#include <stdexcept>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>
extern char **environ;
static void require(bool v, const char *s) { if (!v) throw std::runtime_error(s); }
static void tick() { SDL_PumpEvents(); syphon_poll(); std::this_thread::sleep_for(std::chrono::milliseconds(10)); }
struct Window {
    SDL_Window *window;
    SDL_GLContext context;
    Window() {
        require(SDL_Init(SDL_INIT_VIDEO) == 0, SDL_GetError());
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 2);
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);
        window = SDL_CreateWindow("Vibe Syphon test", 0, 0, 32, 32, SDL_WINDOW_OPENGL | SDL_WINDOW_HIDDEN);
        require(window, SDL_GetError()); context = SDL_GL_CreateContext(window);
        require(context, SDL_GetError());
    }
    ~Window() { SDL_GL_DeleteContext(context); SDL_DestroyWindow(window); SDL_Quit(); }
};
static int sender(const char *name, int width) {
    Window window;
    @autoreleasepool {
        auto *server = [[SyphonOpenGLServer alloc] initWithName:@(name)
            context:CGLGetCurrentContext() options:nil];
        GLuint tex; glGenTextures(1, &tex); glBindTexture(GL_TEXTURE_2D, tex);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        std::vector<unsigned char> pixels(width * 2 * 4);
        for (int x=0; x<width; ++x) {
            // Bottom blue at 50% alpha; top opaque red.
            pixels[x*4+2]=255; pixels[x*4+3]=128;
            pixels[(width+x)*4]=255; pixels[(width+x)*4+3]=255;
        }
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, width, 2, 0, GL_RGBA, GL_UNSIGNED_BYTE, pixels.data());
        for (int i=0; i<3000; ++i) {
            [server publishFrameTexture:tex textureTarget:GL_TEXTURE_2D
                imageRegion:NSMakeRect(0,0,width,2) textureDimensions:NSMakeSize(width,2) flipped:NO];
            tick();
        }
        [server stop]; glDeleteTextures(1,&tex);
    }
    return 0;
}
struct Child {
    pid_t pid=0;
    void stop() { if(pid) { kill(pid,SIGKILL); waitpid(pid,nullptr,0); pid=0; } }
    ~Child() { stop(); }
    void start(char *exe, std::string &name, char *width) {
        char *args[]={exe,const_cast<char *>("--sender"),name.data(),width,nullptr};
        require(posix_spawn(&pid,exe,nullptr,nullptr,args,environ)==0,"spawn failed");
    }
};
int main(int argc, char **argv) {
    try {
        if(argc==4) return sender(argv[2],std::stoi(argv[3]));
        Child child;
        std::string name="Vibe-Syphon-Test-"+std::to_string(getpid());
        child.start(argv[0],name,const_cast<char *>("4"));
        Window window;
        NativeRenderGraph graph;
        graph.set_bus_sizes({{"preview",{4,2}}, {"program",{4,2}}});
        nlohmann::json selected;
        for(int i=0;i<500;++i) {
            tick();
            for(auto &s:syphon_sources()) if(s["name"]==name) selected=s;
            if(!selected.is_null())break;
        }
        require(!selected.is_null(),"cross-process discovery failed");
        NativeLayer bg;bg.generator="solid_color";bg.source_id="bg";bg.params={{"color","#00ff00"}};
        NativeLayer live;live.generator="syphon";live.source_id="live";
        live.resolved_file=selected["selection"].get<std::string>();live.params={{"fit","stretch"},{"disconnect","freeze"}};
        NativeScene scene;
        auto apply=[&] {scene.buses["preview"].layers={bg,live};scene.buses["program"]=scene.buses["preview"];graph.apply_scene(scene);};
        apply();
        auto await_frame=[&](int width) {
            for(int i=0;i<500;++i) {
                tick();graph.render();
                for(const auto &s:graph.diagnostics().at("sources").get<std::vector<nlohmann::json>>()) {
                    if(s["backend"]=="syphon" && s["width"]==width && s["error"]=="") return true;
                }
            }
            std::cerr << graph.diagnostics().dump() << std::endl;
            return false;
        };
        require(await_frame(4),"Syphon GPU receive failed");
        auto verify=[&] {
            for(const auto &bus:{"preview","program"}) {
                auto p=graph.read_bus_rgb(bus,4,2);
                require(p[0]>245 && p[1]<5 && p[2]<5,"top-origin/red failed");
                require(p[12]<5 && std::abs(p[13]-127)<5 && std::abs(p[14]-128)<5,"alpha/blue failed");
            }
        };
        verify();
        require(graph.diagnostics()["sourceCount"]==1,"duplicate receiver across buses");
        child.stop();
        bool offline=false;
        for(int i=0;i<500;++i) {tick();graph.render();for(const auto &s:graph.diagnostics().at("sources").get<std::vector<nlohmann::json>>())if(s["backend"]=="syphon" && !s["connected"].get<bool>())offline=true;if(offline)break;}
        require(offline,"sender shutdown not detected"); verify();
        live.params["disconnect"]="black";apply();graph.render();
        auto black=graph.read_bus_rgb("preview",4,2);
        require(std::all_of(black.begin(),black.end(),[](auto v){return v<5;}),"offline black failed");
        child.start(argv[0],name,const_cast<char *>("8"));
        require(await_frame(8),"restart/name fallback/resize failed");verify();
        scene.buses.clear();graph.apply_scene(scene);graph.render();
        require(graph.diagnostics()["sourceCount"]==0,"receiver not released");
        std::cout << "PASS: discovery, GPU frames, orientation, alpha, shared receiver, freeze/black, restart, resize, cleanup\n";
    } catch(const std::exception &e) {std::cerr<<e.what()<<'\n';return 1;}
}
