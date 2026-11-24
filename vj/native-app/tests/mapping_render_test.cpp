#include "mapping_render_pass.hpp"
#include <SDL2/SDL.h>
#include <iostream>
#include <stdexcept>

using nlohmann::json;
namespace {
void require(bool valid, const char* message) {
    if (!valid) throw std::runtime_error(message);
}
GLuint texture(std::array<unsigned char, 4> color) {
    GLuint id; glGenTextures(1, &id); glBindTexture(GL_TEXTURE_2D, id);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 1, 1, 0, GL_RGBA, GL_UNSIGNED_BYTE, color.data());
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    return id;
}
std::array<unsigned char, 4> pixel(int x, int y) {
    std::array<unsigned char, 4> result{};
    glReadPixels(x, 63-y, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, result.data());
    return result;
}
}

int main() {
    try {
        require(SDL_Init(SDL_INIT_VIDEO)==0, "SDL initialization");
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 3);
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);
        auto window=SDL_CreateWindow("Mapping regression", 0, 0, 64, 64, SDL_WINDOW_OPENGL|SDL_WINDOW_HIDDEN);
        require(window, "Hidden GL window");
        auto context=SDL_GL_CreateContext(window); require(context, "GL context");
        GLuint fbo, color, stencil;
        glGenFramebuffers(1, &fbo); glBindFramebuffer(GL_FRAMEBUFFER, fbo);
        glGenTextures(1, &color); glBindTexture(GL_TEXTURE_2D, color);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 64, 64, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, color, 0);
        glGenRenderbuffers(1, &stencil); glBindRenderbuffer(GL_RENDERBUFFER, stencil);
        glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8, 64, 64);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_RENDERBUFFER, stencil);
        require(glCheckFramebufferStatus(GL_FRAMEBUFFER)==GL_FRAMEBUFFER_COMPLETE, "Complete framebuffer");
        auto red=texture({255,0,0,255}), green=texture({0,255,0,255});
        json surface={{"id","base"},{"source","out1"},{"mode","live"},
            {"corners",{{.2,.2},{.8,.2},{.8,.8},{.2,.8}}}};
        json overlay={{"id","overlay"},{"kind","overlay"},{"source","out2"},{"mode","live"},
            {"corners",{{.5,.1},{1.,.1},{1.,.9},{.5,.9}}},{"config",{{"color","#0000ff"}}}};
        json mapping={{"project",{{"rects",json::array({surface,overlay})},{"output",{{"enabled",true}}}}}};
        {
            vj::MappingRenderPass pass;
            bool connected=true, spanOut=false; int out2Lookups=0, feedWidth=1;
            auto render=[&] {
                pass.render(mapping,64,64,[&](const std::string& bus) {
                    if(bus=="out2"||bus=="collection-feed") {
                        ++out2Lookups;
                        return connected?NativeBusTexture{green,feedWidth,1,1,spanOut}:NativeBusTexture{};
                    }
                    return NativeBusTexture{red,1,1,1};
                });
                require(glGetError()==GL_NO_ERROR,"Mapping GL error");
            };
            render();
            require(out2Lookups>0,"Live overlay must request its selected Out texture");
            require(pixel(40,32)[1]>250&&pixel(40,32)[0]<5,"Live overlay must show Out 2 pixels");
            require(pixel(24,32)[0]>250,"Underlying surface outside overlay must survive");
            require(pixel(58,32)[1]<5,"Overlay must remain clipped to lower surfaces");
            auto& rects=mapping["project"]["rects"];
            rects[1]["nativeBus"]="collection-feed"; render();
            require(pixel(40,32)[1]>250,"Overlay must honor native collection texture routing");
            rects[1].erase("nativeBus"); rects[1]["mode"]="grid"; render();
            require(pixel(40,32)[2]>250&&pixel(40,32)[1]<5,"Pattern overlay must use configured color");
            rects[1]["mode"]="live"; connected=false; render();
            require(pixel(40,32)[0]<5&&pixel(40,32)[1]<5&&pixel(40,32)[2]<5,"Missing overlay signal must remain black");
            connected=true; rects[1]["source"]="none"; render();
            require(pixel(40,32)[0]>250,"Muted overlay must leave lower surfaces visible");
            // One continuous image spans two separate faces, without filling
            // their gap or restarting the video coordinates on each face.
            auto left=surface, right=surface, spanning=overlay;
            left["corners"]={{.1,.1},{.4,.1},{.4,.9},{.1,.9}};
            right["id"]="right"; right["corners"]={{.6,.1},{.9,.1},{.9,.9},{.6,.9}};
            spanning["corners"]={{0,0},{1,0},{1,1},{0,1}};
            const unsigned char split[]={0,255,0,255, 0,0,255,255};
            glBindTexture(GL_TEXTURE_2D,green);
            glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,2,1,0,GL_RGBA,GL_UNSIGNED_BYTE,split);
            feedWidth=2; rects=json::array({left,right,spanning}); render();
            require(pixel(20,32)[1]>250,"Spanning overlay left face must sample left video region");
            require(pixel(44,32)[2]>250,"Spanning overlay right face must sample right video region");
            require(pixel(32,32)[1]<5&&pixel(32,32)[2]<5,"Spanning overlay must leave inter-surface gaps black");
            rects=json::array({overlay}); render();
            require(pixel(40,32)[1]<5,"Overlay alone must not bypass lower-surface mask");
            // Rect order is stacking order. An occluding surface hides the overlapped
            // part of surfaces behind it, even with additive blend.
            auto front=surface, back=surface;
            front["id"]="front"; front["source"]="out2"; front["blend"]="add"; front["occlude"]=true;
            front["corners"]={{.2,.2},{.6,.2},{.6,.8},{.2,.8}};
            back["id"]="back"; back["corners"]={{.4,.2},{.9,.2},{.9,.8},{.4,.8}};
            rects=json::array({back,front}); render();
            require(pixel(32,32)[2]>250&&pixel(32,32)[0]<5,"Occluding surface must hide the surface behind it");
            require(pixel(52,32)[0]>250,"Occluded surface outside the overlap must survive");
            rects[1]["occlude"]=false; render();
            require(pixel(32,32)[0]>250&&pixel(32,32)[2]>250,"Without occlusion an additive surface mixes with the one behind");
            rects=json::array({front,back}); rects[0]["occlude"]=true; render();
            require(pixel(32,32)[0]>250,"Occlusion never lifts a surface above later ones");
            // An occluding hemisphere hides the ball behind it only inside its
            // circle; its square's corners leave the back surface visible.
            auto dome=front;
            dome["blend"]="normal"; dome["hemisphere"]={{"enabled",true},{"feather",0.}};
            back["corners"]={{.1,.1},{.9,.1},{.9,.9},{.1,.9}};
            rects=json::array({back,dome}); render();
            require(pixel(26,32)[0]<5,"Hemisphere center must show its own content");
            require(pixel(14,22)[0]>250,"Hemisphere must not occlude outside its circle");
            rects=json::array({dome}); render();
            require(pixel(14,22)[0]<5&&pixel(14,22)[1]<5&&pixel(14,22)[2]<5,"Hemisphere must stay clipped to its circle");
            mapping["project"]["output"]["boundsGrid"]=true; render();
            require(pixel(0,20)[0]>60&&pixel(0,20)[1]>60&&pixel(0,20)[2]>60,"Projector grid must stay flat outside hemispheres");
            mapping["project"]["output"]["boundsGrid"]=false;
            // A face following its Out repeats the whole image unless the Out's
            // top cell asks to span, then it shows only its share of the plane.
            auto face=surface;face["source"]="out2";face["corners"]={{0,0},{1,0},{1,1},{0,1}};
            face["spanUvs"]={{0,1},{.5,1},{.5,0},{0,0}};rects=json::array({face});
            render();
            require(pixel(48,32)[2]>250,"Repeating face shows the whole Out");
            spanOut=true;render();
            require(pixel(48,32)[1]>250&&pixel(48,32)[2]<5,"Spanning face shows only its share");
        }
        glDeleteTextures(1,&red); glDeleteTextures(1,&green); glDeleteTextures(1,&color);
        glDeleteRenderbuffers(1,&stencil); glDeleteFramebuffers(1,&fbo);
        SDL_GL_DeleteContext(context); SDL_DestroyWindow(window); SDL_Quit();
        std::cout<<"PASS live overlay routing, pixels, clipping, native bus, pattern, missing signal, mute, occlusion and follow layout\n";
    } catch(const std::exception& error) {
        std::cerr<<error.what()<<'\n'; SDL_Quit(); return 1;
    }
}
