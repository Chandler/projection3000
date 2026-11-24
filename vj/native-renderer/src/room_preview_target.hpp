#pragma once
// Demand-only framebuffer for the room's final projector feed. No NDI sender.
class RoomPreviewTarget {
public:
    int width=640,height=360;
    std::chrono::steady_clock::time_point next{};
    ~RoomPreviewTarget(){if(depth)glDeleteRenderbuffers(1,&depth);if(texture)glDeleteTextures(1,&texture);if(fbo)glDeleteFramebuffers(1,&fbo);}
    void render(const std::function<void(const SDL_Rect&)> &draw){
        if(!fbo){glGenFramebuffers(1,&fbo);glGenTextures(1,&texture);glGenRenderbuffers(1,&depth);}
        glBindFramebuffer(GL_FRAMEBUFFER,fbo);
        if(allocated_w!=width||allocated_h!=height){
            allocated_w=width;allocated_h=height;
            glBindTexture(GL_TEXTURE_2D,texture);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
            glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,width,height,0,GL_RGBA,GL_UNSIGNED_BYTE,nullptr);
            glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,texture,0);
            glBindRenderbuffer(GL_RENDERBUFFER,depth);glRenderbufferStorage(GL_RENDERBUFFER,GL_DEPTH24_STENCIL8,width,height);
            glFramebufferRenderbuffer(GL_FRAMEBUFFER,GL_DEPTH_STENCIL_ATTACHMENT,GL_RENDERBUFFER,depth);
            if(glCheckFramebufferStatus(GL_FRAMEBUFFER)!=GL_FRAMEBUFFER_COMPLETE)throw std::runtime_error("Room preview framebuffer incomplete");
        }
        glViewport(0,0,width,height);glDisable(GL_SCISSOR_TEST);glDisable(GL_STENCIL_TEST);
        glColorMask(GL_TRUE,GL_TRUE,GL_TRUE,GL_TRUE);glStencilMask(0xff);glClearColor(0,0,0,1);glClearStencil(0);
        glClear(GL_COLOR_BUFFER_BIT|GL_STENCIL_BUFFER_BIT);draw({0,0,width,height});glBindFramebuffer(GL_FRAMEBUFFER,0);
    }
private:GLuint fbo=0,texture=0,depth=0;int allocated_w=0,allocated_h=0;
};
