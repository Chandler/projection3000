#include "plane_pattern.hpp"
#include <SDL2/SDL.h>
#ifdef __APPLE__
#include <OpenGL/gl3.h>
#else
#define GL_GLEXT_PROTOTYPES
#include <GL/gl.h>
#endif
#include <iostream>
#include <stdexcept>
#include <vector>
void require(bool ok,const char *message){if(!ok)throw std::runtime_error(message);}
GLuint shader(GLenum type,const char *source){
    auto s=glCreateShader(type);glShaderSource(s,1,&source,nullptr);glCompileShader(s);
    GLint ok;glGetShaderiv(s,GL_COMPILE_STATUS,&ok);
    if(!ok){char log[4096];glGetShaderInfoLog(s,sizeof(log),nullptr,log);throw std::runtime_error(log);}return s;
}
int main(){
    SDL_Window *window=nullptr;SDL_GLContext context=nullptr;int result=0;
    try{
        require(SDL_Init(SDL_INIT_VIDEO)==0,SDL_GetError());
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION,3);SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION,3);
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK,SDL_GL_CONTEXT_PROFILE_CORE);
        window=SDL_CreateWindow("Plane pattern test",0,0,256,256,SDL_WINDOW_OPENGL|SDL_WINDOW_HIDDEN);require(window,SDL_GetError());
        context=SDL_GL_CreateContext(window);require(context,SDL_GetError());
        const char *vs="#version 330 core\nlayout(location=0)in vec2 p;out vec2 uv;void main(){uv=p*.5+.5;gl_Position=vec4(p,0,1);}";
        const char *fs="#version 330 core\nin vec2 uv;out vec4 color;uniform vec2 extent;uniform bool circle;\n" VJ_PLANE_PATTERN_GLSL "\nvoid main(){color=planePattern(uv,extent,circle);}";
        auto program=glCreateProgram(),v=shader(GL_VERTEX_SHADER,vs),f=shader(GL_FRAGMENT_SHADER,fs);
        glAttachShader(program,v);glAttachShader(program,f);glLinkProgram(program);GLint ok;glGetProgramiv(program,GL_LINK_STATUS,&ok);require(ok,"pattern link failed");
        GLuint vao,vbo;glGenVertexArrays(1,&vao);glBindVertexArray(vao);glGenBuffers(1,&vbo);glBindBuffer(GL_ARRAY_BUFFER,vbo);
        const float vertices[]={-1,-1,1,-1,1,1,-1,-1,1,1,-1,1};glBufferData(GL_ARRAY_BUFFER,sizeof(vertices),vertices,GL_STATIC_DRAW);
        glVertexAttribPointer(0,2,GL_FLOAT,GL_FALSE,0,nullptr);glEnableVertexAttribArray(0);glUseProgram(program);glViewport(0,0,256,256);
        glUniform2f(glGetUniformLocation(program,"extent"),2,2);glUniform1i(glGetUniformLocation(program,"circle"),false);glDrawArrays(GL_TRIANGLES,0,6);
        std::vector<unsigned char> pixels(256*256*3);glReadPixels(0,0,256,256,GL_RGB,GL_UNSIGNED_BYTE,pixels.data());
        auto channel=[&](int x,int y,int c){return pixels[(y*256+x)*3+c];};
        require(channel(128,150,2)>180 && channel(128,150,0)<150,"top axis must be cyan");
        require(channel(150,128,0)>180 && channel(150,128,2)<150,"right axis must be red");
        require(channel(191,144,0)>120 && channel(191,144,2)>120,"reference square vanished after coverage expansion");
        require(channel(144,144,0)<10,"pattern interior should stay dark");
        glDeleteBuffers(1,&vbo);glDeleteVertexArrays(1,&vao);glDeleteProgram(program);glDeleteShader(v);glDeleteShader(f);
        std::cout<<"Plane pattern shader and directional crosshair pixels passed\n";
    }catch(const std::exception &e){std::cerr<<e.what()<<'\n';result=1;}
    if(context)SDL_GL_DeleteContext(context);if(window)SDL_DestroyWindow(window);SDL_Quit();return result;
}
