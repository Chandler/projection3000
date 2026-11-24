#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>
#import <OpenGL/OpenGL.h>
#import <OpenGL/CGLIOSurface.h>
#import <OpenGL/gl3.h>
#include "mapped_metal.hpp"
#include <algorithm>
#include <map>
#include <stdexcept>
#include <vector>

namespace {
constexpr const char* commonSource=R"MSL(
#include <metal_stdlib>
using namespace metal;
struct MappedVertexOut { float4 position [[position]]; float3 uv; float3 graph; };
struct MappedBlend { float opacity; uint mode; };
vertex MappedVertexOut mappedVertex(uint i [[vertex_id]],device const float* vertices [[buffer(0)]]) {
    device const float* p=vertices+i*8;
    // IOSurface row zero is the bottom GL texture row and the top Metal render row.
    return {float4(p[0],-p[1],0,1),float3(p[2],p[3],p[4]),float3(p[5],p[6],p[7])};
}
float4 mappedColor(float4 straight,constant MappedBlend& blend) {
    float a=saturate(straight.a*blend.opacity);
    return float4(blend.mode==4?mix(float3(1),straight.rgb,a):straight.rgb*a,a);
}
)MSL";
enum Blend:unsigned { sourceOver,add,subtract,screen,multiply };
Blend mode(const std::string& value) {
    if(value=="add")return add;if(value=="subtract")return subtract;
    if(value=="screen")return screen;if(value=="multiply")return multiply;return sourceOver;
}
struct Target {
    int width,height;
    IOSurfaceRef surface=nullptr;
    id<MTLTexture> metal=nil;
    GLuint texture=0,framebuffer=0;
    GLsync pending=nullptr;
    Target(int w,int h):width(w),height(h){}
    ~Target(){
        if(pending)glDeleteSync(pending);
        if(framebuffer)glDeleteFramebuffers(1,&framebuffer);
        if(texture)glDeleteTextures(1,&texture);
        if(surface)CFRelease(surface);
    }
    GLuint attachment(){
        if(!framebuffer){
            glGenFramebuffers(1,&framebuffer);glBindFramebuffer(GL_DRAW_FRAMEBUFFER,framebuffer);
            glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_RECTANGLE,texture,0);
            if(glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER)!=GL_FRAMEBUFFER_COMPLETE){
                glDeleteFramebuffers(1,&framebuffer);framebuffer=0;
                throw std::runtime_error("Could not attach processor IOSurface to GL");
            }
        }
        return framebuffer;
    }
    void usedByGL(){pending=glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE,0);if(!pending)glFinish();}
    bool available(bool wait){
        if(!pending)return true;
        GLenum result=glClientWaitSync(pending,GL_SYNC_FLUSH_COMMANDS_BIT,wait?GL_TIMEOUT_IGNORED:0);
        if(result==GL_WAIT_FAILED)throw std::runtime_error("Mapped Metal GL fence failed");
        if(result==GL_TIMEOUT_EXPIRED)return false;
        glDeleteSync(pending);pending=nullptr;return true;
    }
};
GLuint shader(GLenum type,const char* source){
    GLuint handle=glCreateShader(type);glShaderSource(handle,1,&source,nullptr);glCompileShader(handle);
    GLint ok;glGetShaderiv(handle,GL_COMPILE_STATUS,&ok);
    if(!ok){glDeleteShader(handle);throw std::runtime_error("Mapped Metal presentation shader failed");}
    return handle;
}
struct GLState {
    GLint program,vao,active,rect,srcRGB,dstRGB,srcAlpha,dstAlpha,eqRGB,eqAlpha;
    GLboolean blending;
    GLState(){
        glGetIntegerv(GL_CURRENT_PROGRAM,&program);glGetIntegerv(GL_VERTEX_ARRAY_BINDING,&vao);
        glGetIntegerv(GL_ACTIVE_TEXTURE,&active);glActiveTexture(GL_TEXTURE0);glGetIntegerv(GL_TEXTURE_BINDING_RECTANGLE,&rect);
        blending=glIsEnabled(GL_BLEND);glGetIntegerv(GL_BLEND_SRC_RGB,&srcRGB);glGetIntegerv(GL_BLEND_DST_RGB,&dstRGB);
        glGetIntegerv(GL_BLEND_SRC_ALPHA,&srcAlpha);glGetIntegerv(GL_BLEND_DST_ALPHA,&dstAlpha);
        glGetIntegerv(GL_BLEND_EQUATION_RGB,&eqRGB);glGetIntegerv(GL_BLEND_EQUATION_ALPHA,&eqAlpha);
    }
    ~GLState(){
        glBindTexture(GL_TEXTURE_RECTANGLE,rect);glActiveTexture(active);glUseProgram(program);glBindVertexArray(vao);
        glBlendFuncSeparate(srcRGB,dstRGB,srcAlpha,dstAlpha);glBlendEquationSeparate(eqRGB,eqAlpha);
        if(blending)glEnable(GL_BLEND);else glDisable(GL_BLEND);
    }
};
}

struct MappedMetalRenderer::State {
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    struct Pipeline {id<MTLRenderPipelineState> value=nil;std::string error;};
    std::map<std::tuple<const char*,std::string,Blend>,Pipeline> pipelines;
    std::map<const char*,id<MTLLibrary>> libraries;
    std::vector<std::unique_ptr<Target>> targets;
    std::map<std::string,std::string> errors;
    uint64_t draws=0;
    GLuint program=0,processorProgram=0,vao=0;
    ~State(){if(processorProgram)glDeleteProgram(processorProgram);if(program)glDeleteProgram(program);if(vao)glDeleteVertexArrays(1,&vao);}
    void prepare(){
        if(!device)device=MTLCreateSystemDefaultDevice();
        if(!queue)queue=[device newCommandQueue];
        if(!queue)throw std::runtime_error("Metal device unavailable for mapped rendering");
        if(program)return;
        program=makeComposite(R"GLSL(#version 330 core
        uniform sampler2DRect layer;uniform vec2 origin;out vec4 color;
        void main(){color=texture(layer,gl_FragCoord.xy-origin);if(color.a==0.)discard;})GLSL");
        glGenVertexArrays(1,&vao);
    }
    static GLuint makeComposite(const char* fragment){
        auto v=shader(GL_VERTEX_SHADER,R"GLSL(#version 330 core
        void main(){vec2 p=vec2((gl_VertexID<<1)&2,gl_VertexID&2);gl_Position=vec4(p*2.-1.,0,1);})GLSL");
        auto f=shader(GL_FRAGMENT_SHADER,fragment);
        GLuint composite=glCreateProgram();glAttachShader(composite,v);glAttachShader(composite,f);glLinkProgram(composite);
        glDeleteShader(v);glDeleteShader(f);GLint ok;glGetProgramiv(composite,GL_LINK_STATUS,&ok);
        if(!ok){glDeleteProgram(composite);throw std::runtime_error("Metal presentation program failed");}
        return composite;
    }
    void prepareProcessor(){
        prepare();
        if(processorProgram)return;
        processorProgram=makeComposite(R"GLSL(#version 330 core
        uniform sampler2DRect original,processed;
        uniform float opacity,height;uniform int mode;out vec4 color;
        void main(){
            vec2 p=vec2(gl_FragCoord.x,height-gl_FragCoord.y);
            vec4 a=texture(original,p),b=texture(processed,p);
            if(mode==0){color=mix(a,b,opacity);return;}
            vec3 bottom=a.a>0?a.rgb/a.a:vec3(0),top=b.a>0?b.rgb/b.a:vec3(0);
            vec3 result=mode==1?min(bottom+top,1.):mode==2?max(bottom-top,0.):mode==3?1.-(1.-bottom)*(1.-top):bottom*top;
            color=vec4(mix(bottom,result,opacity*b.a)*a.a,a.a);
        })GLSL");
    }
    Target& target(int w,int h,const Target* reserved=nullptr){
        for(auto it=targets.begin();it!=targets.end();++it){
            if(it->get()!=reserved&&(*it)->width==w&&(*it)->height==h&&(*it)->available(false)){
                std::rotate(it,it+1,targets.end());return *targets.back();
            }
        }
        if(targets.size()>=4){
            auto& old=*targets.front();old.available(true);
            if(old.width==w&&old.height==h){std::rotate(targets.begin(),targets.begin()+1,targets.end());return *targets.back();}
            targets.erase(targets.begin());
        }
        auto t=std::make_unique<Target>(w,h);
        NSDictionary* properties=@{(id)kIOSurfaceWidth:@(w),(id)kIOSurfaceHeight:@(h),
            (id)kIOSurfaceBytesPerElement:@4,(id)kIOSurfacePixelFormat:@(0x42475241)};
        t->surface=IOSurfaceCreate((__bridge CFDictionaryRef)properties);
        if(!t->surface)throw std::runtime_error("Could not allocate mapped IOSurface");
        auto descriptor=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:NO];
        descriptor.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite;
        descriptor.storageMode=device.hasUnifiedMemory?MTLStorageModeShared:MTLStorageModeManaged;
        t->metal=[device newTextureWithDescriptor:descriptor iosurface:t->surface plane:0];
        if(!t->metal)throw std::runtime_error("Could not bind mapped IOSurface to Metal");
        glGenTextures(1,&t->texture);glBindTexture(GL_TEXTURE_RECTANGLE,t->texture);
        auto result=CGLTexImageIOSurface2D(CGLGetCurrentContext(),GL_TEXTURE_RECTANGLE,GL_RGBA8,w,h,GL_BGRA,GL_UNSIGNED_INT_8_8_8_8_REV,t->surface,0);
        if(result!=kCGLNoError)throw std::runtime_error(CGLErrorString(result));
        glTexParameteri(GL_TEXTURE_RECTANGLE,GL_TEXTURE_MIN_FILTER,GL_NEAREST);glTexParameteri(GL_TEXTURE_RECTANGLE,GL_TEXTURE_MAG_FILTER,GL_NEAREST);
        targets.push_back(std::move(t));return *targets.back();
    }
    id<MTLRenderPipelineState> pipeline(const char* source,const char* name,Blend blending){
        auto [it,inserted]=pipelines.try_emplace({source,name,blending});auto& result=it->second;
        if(inserted){
            NSError* failure=nil;
            auto& lib=libraries[source];
            if(!lib){
                NSString* code=[@(commonSource) stringByAppendingString:@(source)];
                lib=[device newLibraryWithSource:code options:nil error:&failure];
            }
            if(lib){
                auto desc=[[MTLRenderPipelineDescriptor alloc]init];desc.vertexFunction=[lib newFunctionWithName:@"mappedVertex"];desc.fragmentFunction=[lib newFunctionWithName:@(name)];
                auto color=desc.colorAttachments[0];color.pixelFormat=MTLPixelFormatBGRA8Unorm;color.blendingEnabled=YES;
                color.sourceAlphaBlendFactor=MTLBlendFactorOne;color.destinationAlphaBlendFactor=MTLBlendFactorOneMinusSourceAlpha;
                color.sourceRGBBlendFactor=blending==multiply?MTLBlendFactorDestinationColor:MTLBlendFactorOne;
                color.destinationRGBBlendFactor=blending==sourceOver?MTLBlendFactorOneMinusSourceAlpha:blending==screen?MTLBlendFactorOneMinusSourceColor:blending==multiply?MTLBlendFactorZero:MTLBlendFactorOne;
                if(desc.fragmentFunction)result.value=[device newRenderPipelineStateWithDescriptor:desc error:&failure];
            }
            if(!result.value)result.error=failure.localizedDescription.UTF8String?:"Mapped Metal function unavailable";
        }
        if(!result.value)throw std::runtime_error(result.error);
        return result.value;
    }
};

MappedMetalRenderer::MappedMetalRenderer():state_(std::make_unique<State>()){}
MappedMetalRenderer::~MappedMetalRenderer()=default;
std::string MappedMetalRenderer::lastError()const{
    std::string result;
    for(const auto& [function,reason]:state_->errors){
        if(!result.empty())result+=" / ";
        result+=function+": "+reason;
    }
    return result;
}
uint64_t MappedMetalRenderer::draws()const{return state_->draws;}
bool MappedMetalRenderer::draw(const char* library,const char* fragment,const float* vertices,std::size_t count,
                    const void* uniforms,std::size_t bytes,const void* extra,std::size_t extraBytes,
                    int width,int height,const std::string& blend,float opacity){
    if(!count)return true;
    @autoreleasepool {try{
        if(count%24||!vertices||!uniforms||!bytes||width<=0||height<=0)throw std::runtime_error("Invalid mapped triangle pass");
        auto& s=*state_;GLState saved;s.prepare();const Blend blending=mode(blend);
        auto pipeline=s.pipeline(library,fragment,blending);auto& target=s.target(width,height);
        auto cmd=[s.queue commandBuffer];auto pass=[MTLRenderPassDescriptor renderPassDescriptor];auto attachment=pass.colorAttachments[0];
        attachment.texture=target.metal;attachment.loadAction=MTLLoadActionClear;attachment.storeAction=MTLStoreActionStore;
        const double base=blending==multiply?1.:0.;attachment.clearColor=MTLClearColorMake(base,base,base,0);
        auto encoder=[cmd renderCommandEncoderWithDescriptor:pass];if(!encoder)throw std::runtime_error("Could not encode mapped Metal pass");
        [encoder setRenderPipelineState:pipeline];
        auto buffer=[s.device newBufferWithBytes:vertices length:count*sizeof(float) options:MTLResourceStorageModeShared];
        if(!buffer)throw std::runtime_error("Could not upload mapped geometry");
        [encoder setVertexBuffer:buffer offset:0 atIndex:0];
        auto bind=[&](const void* data,std::size_t size,NSUInteger index){
            if(size<=4096){[encoder setFragmentBytes:data length:size atIndex:index];return;}
            auto upload=[s.device newBufferWithBytes:data length:size options:MTLResourceStorageModeShared];
            if(!upload)throw std::runtime_error("Could not upload mapped shader data");
            [encoder setFragmentBuffer:upload offset:0 atIndex:index];
        };
        bind(uniforms,bytes,0);if(extraBytes)bind(extra,extraBytes,1);
        struct {float opacity;unsigned mode;} settings{opacity,blending};
        bind(&settings,sizeof(settings),2);[encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:count/8];
        [encoder endEncoding];
        if(target.metal.storageMode==MTLStorageModeManaged){
            auto sync=[cmd blitCommandEncoder];[sync synchronizeResource:target.metal];[sync endEncoding];
        }
        [cmd commit];[cmd waitUntilCompleted];
        if(cmd.status!=MTLCommandBufferStatusCompleted)throw std::runtime_error(cmd.error.localizedDescription.UTF8String?:"Mapped Metal command failed");
        glUseProgram(s.program);glBindVertexArray(s.vao);glBindTexture(GL_TEXTURE_RECTANGLE,target.texture);
        GLint viewport[4];glGetIntegerv(GL_VIEWPORT,viewport);
        glUniform1i(glGetUniformLocation(s.program,"layer"),0);glUniform2f(glGetUniformLocation(s.program,"origin"),viewport[0],viewport[1]);
        glEnable(GL_BLEND);glBlendEquationSeparate(blending==subtract?GL_FUNC_REVERSE_SUBTRACT:GL_FUNC_ADD,GL_FUNC_ADD);
        glBlendFuncSeparate(blending==multiply?GL_DST_COLOR:GL_ONE,blending==sourceOver?GL_ONE_MINUS_SRC_ALPHA:blending==multiply?GL_ZERO:blending==screen?GL_ONE_MINUS_SRC_COLOR:GL_ONE,blending==subtract?GL_ZERO:GL_ONE,blending==subtract?GL_ONE:GL_ONE_MINUS_SRC_ALPHA);
        glDrawArrays(GL_TRIANGLES,0,3);target.usedByGL();
        ++s.draws;s.errors.erase(fragment);return true;
    }catch(const std::exception& e){auto& error=state_->errors[fragment];
        if(error!=e.what())NSLog(@"Mapped Metal %s: %s",fragment,e.what());
        error=e.what();return false;}}
}

bool MappedMetalRenderer::process(const NativeProcessorEncoder& encode,const std::string& source,const std::string& destination,
                                  double seconds,unsigned int inputFramebuffer,unsigned int outputFramebuffer,
                                  int width,int height,const std::string& blend,float opacity,std::string& error){
    @autoreleasepool {try{
        if(!encode||width<=0||height<=0||inputFramebuffer==outputFramebuffer)throw std::runtime_error("Invalid Patch adjustment destination");
        GLState saved;
        struct ProcessorGL {
            GLint read,draw,rect1,viewport[4];
            GLboolean scissor,stencil,depth,cull,colorMask[4];
            ProcessorGL(){
                glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING,&read);glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING,&draw);glGetIntegerv(GL_VIEWPORT,viewport);
                glActiveTexture(GL_TEXTURE1);glGetIntegerv(GL_TEXTURE_BINDING_RECTANGLE,&rect1);glActiveTexture(GL_TEXTURE0);
                scissor=glIsEnabled(GL_SCISSOR_TEST);stencil=glIsEnabled(GL_STENCIL_TEST);depth=glIsEnabled(GL_DEPTH_TEST);
                cull=glIsEnabled(GL_CULL_FACE);glGetBooleanv(GL_COLOR_WRITEMASK,colorMask);
                glDisable(GL_CULL_FACE);glColorMask(GL_TRUE,GL_TRUE,GL_TRUE,GL_TRUE);
                glDisable(GL_SCISSOR_TEST);glDisable(GL_STENCIL_TEST);glDisable(GL_DEPTH_TEST);glDisable(GL_BLEND);
            }
            ~ProcessorGL(){
                glActiveTexture(GL_TEXTURE1);glBindTexture(GL_TEXTURE_RECTANGLE,rect1);glActiveTexture(GL_TEXTURE0);
                glBindFramebuffer(GL_READ_FRAMEBUFFER,read);glBindFramebuffer(GL_DRAW_FRAMEBUFFER,draw);
                glViewport(viewport[0],viewport[1],viewport[2],viewport[3]);
                if(scissor)glEnable(GL_SCISSOR_TEST);if(stencil)glEnable(GL_STENCIL_TEST);if(depth)glEnable(GL_DEPTH_TEST);
                if(cull)glEnable(GL_CULL_FACE);glColorMask(colorMask[0],colorMask[1],colorMask[2],colorMask[3]);
            }
        } restore;
        auto& state=*state_;state.prepareProcessor();
        auto& input=state.target(width,height);
        // The just-acquired input is the most recently used target. It must not become our output.
        auto& output=state.target(width,height,&input);
        glBindFramebuffer(GL_READ_FRAMEBUFFER,inputFramebuffer);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER,input.attachment());
        glBlitFramebuffer(0,0,width,height,0,height,width,0,GL_COLOR_BUFFER_BIT,GL_NEAREST);
        input.usedByGL();
        if(GLenum issue=glGetError();issue!=GL_NO_ERROR)throw std::runtime_error("Adjustment input transfer failed (GL "+std::to_string(issue)+")");
        input.available(true);
        auto command=[state.queue commandBuffer];
        if(!command)throw std::runtime_error("Could not start Patch adjustment command buffer");
        NativeProcessorFrame frame{source,destination,seconds,(__bridge void*)input.metal,(__bridge void*)output.metal,(__bridge void*)command};
        if(!encode(frame,error)){if(error.empty())error="Patch adjustment could not encode the frame";return false;}
        if(output.metal.storageMode==MTLStorageModeManaged){
            auto sync=[command blitCommandEncoder];[sync synchronizeResource:output.metal];[sync endEncoding];
        }
        [command commit];[command waitUntilCompleted];
        if(command.status!=MTLCommandBufferStatusCompleted)throw std::runtime_error(command.error.localizedDescription.UTF8String?:"Patch adjustment GPU command failed");
        const auto blending=mode(blend);
        if(opacity>=1.f&&blending==sourceOver){
            glBindFramebuffer(GL_READ_FRAMEBUFFER,output.attachment());
            glBindFramebuffer(GL_DRAW_FRAMEBUFFER,outputFramebuffer);
            glBlitFramebuffer(0,height,width,0,0,0,width,height,GL_COLOR_BUFFER_BIT,GL_NEAREST);
        }else{
            glBindFramebuffer(GL_DRAW_FRAMEBUFFER,outputFramebuffer);glViewport(0,0,width,height);
            glUseProgram(state.processorProgram);glBindVertexArray(state.vao);
            glActiveTexture(GL_TEXTURE0);glBindTexture(GL_TEXTURE_RECTANGLE,input.texture);
            glActiveTexture(GL_TEXTURE1);glBindTexture(GL_TEXTURE_RECTANGLE,output.texture);
            glUniform1i(glGetUniformLocation(state.processorProgram,"original"),0);
            glUniform1i(glGetUniformLocation(state.processorProgram,"processed"),1);
            glUniform1i(glGetUniformLocation(state.processorProgram,"mode"),int(blending));
            glUniform1f(glGetUniformLocation(state.processorProgram,"opacity"),opacity);
            glUniform1f(glGetUniformLocation(state.processorProgram,"height"),float(height));
            glDrawArrays(GL_TRIANGLES,0,3);input.usedByGL();
        }
        output.usedByGL();
        if(GLenum issue=glGetError();issue!=GL_NO_ERROR)throw std::runtime_error("Adjustment output transfer failed (GL "+std::to_string(issue)+")");
        error.clear();return true;
    }catch(const std::exception& e){error=e.what();return false;}}
}
