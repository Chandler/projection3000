#include "frame_publisher.hpp"
#include "mapping_render_pass.hpp"
#include <algorithm>
#include <map>
namespace vj {
struct FramePublisher::Impl {
    struct Target {
        GLuint fbo=0,texture=0,depth=0;int width=0,height=0;
        ~Target(){if(depth)glDeleteRenderbuffers(1,&depth);if(texture)glDeleteTextures(1,&texture);if(fbo)glDeleteFramebuffers(1,&fbo);}
        void bind(int w,int h){
            if(!fbo){glGenFramebuffers(1,&fbo);glGenTextures(1,&texture);glGenRenderbuffers(1,&depth);}
            glBindFramebuffer(GL_FRAMEBUFFER,fbo);
            if(w!=width||h!=height){width=w;height=h;glBindTexture(GL_TEXTURE_2D,texture);
                glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
                glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);
                glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,w,h,0,GL_RGBA,GL_UNSIGNED_BYTE,nullptr);glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,texture,0);
                glBindRenderbuffer(GL_RENDERBUFFER,depth);glRenderbufferStorage(GL_RENDERBUFFER,GL_DEPTH24_STENCIL8,w,h);glFramebufferRenderbuffer(GL_FRAMEBUFFER,GL_DEPTH_STENCIL_ATTACHMENT,GL_RENDERBUFFER,depth);
                if(glCheckFramebufferStatus(GL_FRAMEBUFFER)!=GL_FRAMEBUFFER_COMPLETE)throw std::runtime_error("Mapped preview framebuffer incomplete");
            }
        }
    };
    MappingRenderPass pass;
    std::map<std::string,std::unique_ptr<Target>> targets;
    uint64_t sequence=0;
};
FramePublisher::FramePublisher():impl_(std::make_unique<Impl>()){}
FramePublisher::~FramePublisher()=default;
NativeBusTexture FramePublisher::mappingTexture(const nlohmann::json& snapshot,NativeRenderGraph& graph,const LedSampler::Frames& traces,const std::string& mid,int width,int height){
    if(!snapshot.at("mappings").contains(mid)||width<1||height<1||width>4096||height>4096)return {};
    GLint old=0;glGetIntegerv(GL_FRAMEBUFFER_BINDING,&old);
    auto& target=impl_->targets[mid];if(!target)target=std::make_unique<Impl::Target>();target->bind(width,height);
    impl_->pass.render(snapshot["mappings"][mid],width,height,[&](const std::string& bus){return graph.bus_texture(bus);},[&](const std::string& id){auto i=traces.find(id);return i==traces.end()?std::vector<uint8_t>{}:i->second;},snapshot.value("calibration",nlohmann::json::object()).value("outputs",nlohmann::json::object()).value(mid,nlohmann::json()),false,&graph);
    glBindFramebuffer(GL_FRAMEBUFFER,old);return {target->texture,width,height,++impl_->sequence};
}
void FramePublisher::publish(FrameTransport& transport,const nlohmann::json& snapshot,NativeRenderGraph& graph,const LedSampler::Frames& traces){
    const auto statuses=snapshot.at("state").value("output_status",nlohmann::json::object()).value("projectors",nlohmann::json::object());
    for(const auto& [channel,demand]:transport.demand()){
        if(!transport.due(channel))continue;
        if(demand.mappingId.empty()){auto rgb=graph.read_bus_rgb(channel,demand.width,demand.height);if(!rgb.empty())transport.publish(channel,demand.width,demand.height,std::move(rgb));continue;}
        auto status=statuses.value(demand.mappingId,nlohmann::json::object());
        if(demand.transport!="room"&&!status.value(demand.transport=="physical"?"display":"ndi",nlohmann::json::object()).value("active",false))continue;
        int width=demand.width,height=demand.height;
        if(demand.transport=="room"){
            const auto scene=snapshot.value("room",nlohmann::json::object()).value("scene",nlohmann::json::object());
            for(const auto& projector:scene.value("projectors",nlohmann::json::array()))if(projector.value("id",std::string{})==demand.mappingId)height=std::max(1,int(width/projector.value("aspect",16./9.)));
        }else if(demand.transport=="ndi"){
            const auto config=snapshot["state"].value("ndi_projectors",nlohmann::json::object()).value(demand.mappingId,nlohmann::json::object());
            height=std::max(1,int(double(width)*config.value("height",540)/config.value("width",960)));
        }else{
            const auto did=status.value("display",nlohmann::json::object()).value("displayId",std::string{});
            for(const auto& display:snapshot["state"]["output_status"].value("displays",nlohmann::json::array()))if(display.value("displayId",std::string{})==did)height=std::max(1,int(double(width)*display.value("height",540)/display.value("width",960)));
        }
        const auto texture=mappingTexture(snapshot,graph,traces,demand.mappingId,width,height);if(!texture.texture)continue;
        GLint previous=0;glGetIntegerv(GL_FRAMEBUFFER_BINDING,&previous);glBindFramebuffer(GL_FRAMEBUFFER,impl_->targets[demand.mappingId]->fbo);glPixelStorei(GL_PACK_ALIGNMENT,1);
        std::vector<uint8_t> raw(size_t(width)*height*3),rgb(raw.size());glReadPixels(0,0,width,height,GL_RGB,GL_UNSIGNED_BYTE,raw.data());
        const size_t stride=size_t(width)*3;for(int y=0;y<height;++y)std::copy_n(raw.data()+size_t(y)*stride,stride,rgb.data()+size_t(height-1-y)*stride);
        glBindFramebuffer(GL_FRAMEBUFFER,previous);transport.publish(channel,width,height,std::move(rgb));
    }
}
}
