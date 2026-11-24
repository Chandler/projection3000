#pragma once
#include "ndi_output.hpp"
#include "native_scene.hpp"
#define GL_GLEXT_PROTOTYPES
#include <SDL2/SDL.h>
#include <SDL2/SDL_opengl.h>
#include <functional>
#include <stdexcept>
#include <cstring>

// A projector-sized, stencil-capable target. The same mapping draw function is
// used for physical presentation and this network surface.
class ProjectorNdiOutput {
public:
    explicit ProjectorNdiOutput(const NativeNdiProjector &config)
        : output(config.name,config.width,config.height,config.fps) {}
    ~ProjectorNdiOutput() {
        if(depth_)glDeleteRenderbuffers(1,&depth_);
        if(texture_)glDeleteTextures(1,&texture_);
        if(framebuffer_)glDeleteFramebuffers(1,&framebuffer_);
    }
    NdiOutput output;
    void configure(const NativeNdiProjector &config) {output.configure(config.width,config.height,config.fps);}
    std::uint64_t render(const std::function<void(const SDL_Rect &)> &draw) {
        const int w=output.width,h=output.height;
        if(!framebuffer_) {
            glGenFramebuffers(1,&framebuffer_);glGenTextures(1,&texture_);glGenRenderbuffers(1,&depth_);
        }
        glBindFramebuffer(GL_FRAMEBUFFER,framebuffer_);
        if(width_!=w || height_!=h) {
            width_=w;height_=h;
            glBindTexture(GL_TEXTURE_2D,texture_);
            glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR);
            glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
            glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,w,h,0,GL_RGBA,GL_UNSIGNED_BYTE,nullptr);
            glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,texture_,0);
            glBindRenderbuffer(GL_RENDERBUFFER,depth_);
            glRenderbufferStorage(GL_RENDERBUFFER,GL_DEPTH24_STENCIL8,w,h);
            glFramebufferRenderbuffer(GL_FRAMEBUFFER,GL_DEPTH_STENCIL_ATTACHMENT,GL_RENDERBUFFER,depth_);
            if(glCheckFramebufferStatus(GL_FRAMEBUFFER)!=GL_FRAMEBUFFER_COMPLETE)
                throw std::runtime_error("NDI projector framebuffer incomplete");
        }
        glViewport(0,0,w,h);glDisable(GL_SCISSOR_TEST);glDisable(GL_STENCIL_TEST);
        glColorMask(GL_TRUE,GL_TRUE,GL_TRUE,GL_TRUE);glStencilMask(0xff);
        glClearColor(0,0,0,1);glClearStencil(0);glClear(GL_COLOR_BUFFER_BIT|GL_STENCIL_BUFFER_BIT);
        draw({0,0,w,h});
        glBindFramebuffer(GL_FRAMEBUFFER,framebuffer_);
        glPixelStorei(GL_PACK_ALIGNMENT,1);
        std::vector<std::uint8_t> bottom(static_cast<std::size_t>(w)*h*3),top(bottom.size());
        glReadPixels(0,0,w,h,GL_RGB,GL_UNSIGNED_BYTE,bottom.data());
        const auto pitch=static_cast<std::size_t>(w)*3;
        for(int y=0;y<h;++y)std::memcpy(top.data()+y*pitch,bottom.data()+(h-y-1)*pitch,pitch);
        const auto sequence=output.publish(std::move(top));
        glBindFramebuffer(GL_FRAMEBUFFER,0);return sequence;
    }
private:
    GLuint framebuffer_=0,texture_=0,depth_=0;
    int width_=0,height_=0;
};
