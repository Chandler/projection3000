#include "render_host.hpp"
#include "render_scene.hpp"
#include "render_demand.hpp"
#include "mapping_compat.hpp"
#include "native_render_graph.hpp"
#include "mapped_outputs.hpp"
#include "mapping_render_pass.hpp"
#include "vector_host.hpp"
#include "fixture_output.hpp"
#include "frame_publisher.hpp"
#include "frame_codec.hpp"
#include "calibration_capture.hpp"
#include <SDL2/SDL.h>
#include <chrono>
#include <limits>

namespace vj {
struct RenderHost::Impl {
    Model& model;
    MappingPreviewCache mappingPreviews;
    RenderHostOptions options;
    SDL_Window* window=nullptr;
    SDL_GLContext context=nullptr;
    bool initialized=false,checking=false;
    std::unique_ptr<NativeRenderGraph> graph;
    std::unique_ptr<MappedOutputs> outputs;
    std::unique_ptr<VectorHost> vectors;
    std::unique_ptr<FixtureOutputRuntime> fixtures;
    LedSampler leds;
    std::unique_ptr<FramePublisher> publisher;
    std::chrono::steady_clock::time_point reported;
    std::uint64_t revision=std::numeric_limits<std::uint64_t>::max();
    std::uint64_t frames=0,clockRevision=0,mediaRevision=0,previewRevision=0;
    std::vector<std::string> activeOutputs;
    std::string calibrationCamera,demandKey;
    std::chrono::steady_clock::time_point started=std::chrono::steady_clock::now();
    Impl(Model& m,RenderHostOptions o):model(m),options(std::move(o)){}
    ~Impl(){
        if(context)SDL_GL_MakeCurrent(window,context);
        fixtures.reset();publisher.reset();outputs.reset();graph.reset();vectors.reset();
        if(context)SDL_GL_DeleteContext(context);
        if(window)SDL_DestroyWindow(window);
        if(initialized)SDL_QuitSubSystem(SDL_INIT_VIDEO|SDL_INIT_EVENTS);
    }
    void initialize(){
        if(options.width<16||options.width>7680||options.height<16||options.height>4320||options.fps<1||options.fps>120)
            throw std::runtime_error("Render size must be 16..7680 × 16..4320; fps must be 1..120");
        if(SDL_InitSubSystem(SDL_INIT_VIDEO|SDL_INIT_EVENTS)!=0)throw std::runtime_error(std::string("SDL video: ")+SDL_GetError());
        initialized=true;
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION,3);
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION,3);
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK,SDL_GL_CONTEXT_PROFILE_CORE);
        SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER,0);
        SDL_GL_SetAttribute(SDL_GL_STENCIL_SIZE,8);
        window=SDL_CreateWindow("VJ Render Service",SDL_WINDOWPOS_UNDEFINED,SDL_WINDOWPOS_UNDEFINED,options.width,options.height,SDL_WINDOW_OPENGL|SDL_WINDOW_HIDDEN);
        if(!window)throw std::runtime_error(std::string("SDL render window: ")+SDL_GetError());
        context=SDL_GL_CreateContext(window);
        if(!context)throw std::runtime_error(std::string("OpenGL context: ")+SDL_GetError());
        if(SDL_GL_MakeCurrent(window,context)!=0)throw std::runtime_error(std::string("OpenGL current context: ")+SDL_GetError());
        SDL_GL_SetSwapInterval(0);
        graph=std::make_unique<NativeRenderGraph>();
        graph->set_processor_encoder(options.processorEncoder);
        publisher=std::make_unique<FramePublisher>();model.frames().setEncoder(encodeFrameImage);
        vectors=std::make_unique<VectorHost>(model.stateRoot()/"vector-modules");vectors->install(*graph);
        outputs=std::make_unique<MappedOutputs>();
        if(options.publishOutputs){fixtures=std::make_unique<FixtureOutputRuntime>(FixtureOutputCallbacks{[this]{return model.fixtureSnapshot();},[this](const std::string& kind,const Json& status){model.setControlRuntime(kind,status);}});fixtures->start();}
    }
    bool tick(){
        SDL_Event event;
        while(SDL_PollEvent(&event))if(event.type==SDL_QUIT)return false;
        auto snapshot=model.renderSnapshot();mappingPreviews.apply(snapshot);
        auto camera=snapshot.value("calibration",Json::object()).value("camera",std::string{});if(camera!=calibrationCamera){if(camera.empty())stopCalibrationCamera();calibrationCamera=camera;}
        const auto streams=model.frames().demand();Json requested={{"check",checking}};
        for(const auto& [bus,demand]:streams)requested[bus]={demand.width,demand.height};
        const auto requestedKey=requested.dump();
        if(demandKey!=requestedKey){snapshot=model.snapshot();mappingPreviews.apply(snapshot);}
        const auto nextRevision=snapshot.at("revision").get<std::uint64_t>();
        if(previewRevision!=snapshot.value("scenePreviewRevision",uint64_t(0))||nextRevision!=revision||clockRevision!=snapshot.value("clockRevision",uint64_t(0))||demandKey!=requestedKey||mediaRevision!=snapshot.value("mediaRevision",uint64_t(0))){
            outputs->configure(snapshot,options.publishOutputs);
            model.frames().configure(options.width,options.height,options.fps,72,snapshot["state"]["grid"]["running"].size(),snapshot["state"].value("stream_hd",false));
            activeOutputs.clear();const auto& running=snapshot.at("state").at("grid").at("running");
            for(const auto& output:kOutputBuses)if(running.contains(output))activeOutputs.push_back(output);
            for(const auto& output:options.outputs)if(!running.contains(output))throw std::runtime_error("Unknown render output: "+output);
            auto scene=renderScene(snapshot,activeOutputs,std::chrono::duration<double>(std::chrono::steady_clock::now()-started).count());
            scene.fps=options.fps;scene.canvas_width=options.width;scene.canvas_height=options.height;
            std::vector<RenderViewDemand> views;
            for(const auto& output:checking?activeOutputs:options.outputs)views.push_back({output,"",options.width,options.height});
            if(checking)for(auto it=snapshot["mappings"].begin();it!=snapshot["mappings"].end();++it)views.push_back({"",it.key(),320,180});
            auto sizes=renderDemand(snapshot,scene,options.width,options.height,views,streams,options.publishOutputs);
            LedSampler::prepareScene(snapshot,scene,sizes);leds.configure(scene);
            model.setPatchReferences(patchDemand(snapshot,scene,sizes));
            graph->apply_scene(std::move(scene));graph->set_bus_sizes(std::move(sizes));revision=nextRevision;previewRevision=snapshot.value("scenePreviewRevision",uint64_t(0));mediaRevision=snapshot.value("mediaRevision",uint64_t(0));demandKey=requestedKey;clockRevision=snapshot.value("clockRevision",uint64_t(0));
        }
        graph->set_palette_sources(model.paletteSources());graph->set_patch_outputs(model.patchOutputs());vectors->beginFrame(nextRevision);graph->render(true);vectors->endFrame();if(this->frames%6==0)model.setPlaybackRuntime(graph->diagnostics()["sources"]);auto frames=leds.render(snapshot,*graph);bool virtualActive=false;for(const auto& fixture:snapshot["state"].value("fixtures",Json::array()))virtualActive|=fixture.value("enabled",false)&&fixture.value("kind",std::string{})=="virtual";model.frames().publishLedFrames(frames,virtualActive);if(fixtures)fixtures->submitFrames(frames);outputs->render(snapshot,*graph,frames,[&](const std::string& mid,uint64_t revision){model.calibration().acknowledgeTarget(mid,revision);});publisher->publish(model.frames(),snapshot,*graph,frames);glFlush();model.calibration().acknowledge(snapshot.value("calibration",Json::object()).value("revision",uint64_t(0)));++this->frames;
        const auto now=std::chrono::steady_clock::now();if(now-reported>=std::chrono::seconds(1)){model.setOutputRuntime(outputs->runtime());model.setControlRuntime("vectors",vectors->diagnostics());model.setControlRuntime("renderer",{{"sequence",this->frames},{"engine",graph->diagnostics()},{"size",{options.width,options.height}},{"targetFps",options.fps}});reported=now;}
        return true;
    }
};
RenderHost::RenderHost(Model& model,RenderHostOptions options):impl_(std::make_unique<Impl>(model,std::move(options))){impl_->initialize();}
RenderHost::~RenderHost()=default;
bool RenderHost::tick(){return impl_->tick();}
Json RenderHost::diagnostics()const{
    const auto* version=glGetString(GL_VERSION);
    const auto output=impl_->outputs->runtime();bool active=false;for(const auto& p:output["projectors"])active=active||p["ndi"].value("active",false);
    return {{"vectors",impl_->vectors->diagnostics()},{"engine",impl_->graph->diagnostics()},{"frames",impl_->frames},{"outputs",impl_->activeOutputs},{"size",{impl_->options.width,impl_->options.height}},{"fps",impl_->options.fps},{"openGL",version?reinterpret_cast<const char*>(version):""},{"physicalOutputs",false},{"ndiOutputs",active},{"outputStatus",output},{"audioOutputPolicy","enabled-clips"}};
}
Json RenderHost::checkRendering(){
    impl_->checking=true;struct ResetCheck{bool& value;~ResetCheck(){value=false;}} reset{impl_->checking};
    if(!tick())throw std::runtime_error("Render service received quit before its first frame");
    Json checks=Json::array();
    for(const auto& output:impl_->activeOutputs){
        auto texture=impl_->graph->bus_texture(output);
        const auto rgb=impl_->graph->read_bus_rgb(output,16,9);
        if(!texture.texture||rgb.size()!=16*9*3)throw std::runtime_error("Render readback failed for "+output);
        checks.push_back({{"output",output},{"size",{16,9}},{"firstPixel",{rgb[0],rgb[1],rgb[2]}}});
    }
    Json mapped=Json::array();GLuint fbo=0,texture=0,stencil=0;glGenFramebuffers(1,&fbo);glGenTextures(1,&texture);glGenRenderbuffers(1,&stencil);
    glBindTexture(GL_TEXTURE_2D,texture);glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,320,180,0,GL_RGBA,GL_UNSIGNED_BYTE,nullptr);
    glBindFramebuffer(GL_FRAMEBUFFER,fbo);glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,texture,0);
    glBindRenderbuffer(GL_RENDERBUFFER,stencil);glRenderbufferStorage(GL_RENDERBUFFER,GL_STENCIL_INDEX8,320,180);glFramebufferRenderbuffer(GL_FRAMEBUFFER,GL_STENCIL_ATTACHMENT,GL_RENDERBUFFER,stencil);
    {MappingRenderPass pass;const auto snapshot=impl_->model.snapshot();const auto frames=impl_->leds.render(snapshot,*impl_->graph);
        for(auto it=snapshot["mappings"].begin();it!=snapshot["mappings"].end();++it){
            glBindFramebuffer(GL_FRAMEBUFFER,fbo);pass.render(it.value(),320,180,[&](const std::string& out){return impl_->graph->bus_texture(out);},[&](const std::string& id){auto found=frames.find(id);return found==frames.end()?std::vector<uint8_t>{}:found->second;},nullptr,false,impl_->graph.get());
            Json samples=Json::array();for(int x:{80,160,240}){std::array<uint8_t,3> pixel{};glReadPixels(x,90,1,1,GL_RGB,GL_UNSIGNED_BYTE,pixel.data());samples.push_back(pixel);}mapped.push_back({{"mappingId",it.key()},{"samples",samples}});
        }
    }
    glBindFramebuffer(GL_FRAMEBUFFER,0);glDeleteFramebuffers(1,&fbo);glDeleteTextures(1,&texture);glDeleteRenderbuffers(1,&stencil);
    const auto error=glGetError();
    if(error!=GL_NO_ERROR)throw std::runtime_error("OpenGL error "+std::to_string(error));
    return {{"readback",checks},{"mappedReadback",mapped},{"render",diagnostics()}};
}
}
