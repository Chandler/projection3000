#include "mapped_outputs.hpp"
#include "mapping_render_pass.hpp"
#include "projector_ndi_output.hpp"
#include <map>
namespace vj {
struct MappedOutputs::Impl {
    std::map<std::string,std::unique_ptr<ProjectorNdiOutput>> senders;
    MappingRenderPass mapping;
    std::map<std::string,std::pair<uint64_t,uint64_t>> pendingPresentation;
    Json errors=Json::object();
    bool permitted=false;
};
MappedOutputs::MappedOutputs():impl_(std::make_unique<Impl>()){}
MappedOutputs::~MappedOutputs()=default;
void MappedOutputs::configure(const Json& snapshot,bool permitted){
    impl_->permitted=permitted;const auto configs=snapshot.at("state").value("ndi_projectors",Json::object());
    for(auto it=impl_->senders.begin();it!=impl_->senders.end();){auto config=configs.value(it->first,Json::object());if(!permitted||!config.value("enabled",false)||config.value("name",std::string{})!=it->second->output.name)it=impl_->senders.erase(it);else ++it;}
    impl_->errors=Json::object();if(!permitted)return;
    for(auto it=configs.begin();it!=configs.end();++it){if(!it.value().value("enabled",false))continue;
        try{NativeNdiProjector config;config.name=it.value().at("name");config.width=it.value().at("width");config.height=it.value().at("height");config.fps=it.value().at("fps");
            auto& sender=impl_->senders[it.key()];if(!sender)sender=std::make_unique<ProjectorNdiOutput>(config);else sender->configure(config);
        }catch(const std::exception& error){impl_->senders.erase(it.key());impl_->errors[it.key()]=error.what();}
    }
}
void MappedOutputs::render(const Json& snapshot,NativeRenderGraph& graph,const LedSampler::Frames& traces,const std::function<void(const std::string&,uint64_t)>& presented){
    for(auto& [mid,sender]:impl_->senders){
        if(auto pending=impl_->pendingPresentation.find(mid);pending!=impl_->pendingPresentation.end()&&sender->output.diagnostics().value("sentSequence",uint64_t(0))>=pending->second.first){if(presented)presented(mid,pending->second.second);impl_->pendingPresentation.erase(pending);}
        if(!sender->output.due())continue;
        try{auto sequence=sender->render([&](const SDL_Rect& viewport){impl_->mapping.render(snapshot.at("mappings").at(mid),viewport.w,viewport.h,[&](const std::string& bus){return graph.bus_texture(bus);},[&](const std::string& fixture){auto frame=traces.find(fixture);return frame==traces.end()?std::vector<uint8_t>{}:frame->second;},snapshot.value("calibration",Json::object()).value("outputs",Json::object()).value(mid,Json()),false,&graph);});if(sequence)impl_->pendingPresentation[mid]={sequence,snapshot.value("calibration",Json::object()).value("revision",uint64_t(0))};impl_->errors.erase(mid);}
        catch(const std::exception& error){impl_->errors[mid]=error.what();}
    }
}
Json MappedOutputs::runtime()const{
    Json result={{"ndiAvailable",true},{"rendererConnected",true},{"projectors",Json::object()}};
    for(int i=1;i<=4;++i){const auto mid=std::to_string(i);Json status={{"active",false},{"error",""}};
        if(auto sender=impl_->senders.find(mid);sender!=impl_->senders.end()){status=sender->second->output.diagnostics();status["active"]=status.value("ready",false)&&status.value("sent",uint64_t(0))>0&&status.value("error",std::string{}).empty();}
        if(impl_->errors.contains(mid)){status["active"]=false;status["error"]=impl_->errors[mid];}
        if(!impl_->permitted)status["error"]="Network outputs suppressed by host";
        result["projectors"][mid]["ndi"]=status;
    }return result;
}
std::array<int,2> MappedOutputs::size()const{std::array<int,2> result{0,0};for(const auto& [mid,sender]:impl_->senders){(void)mid;result[0]=std::max(result[0],sender->output.width);result[1]=std::max(result[1],sender->output.height);}return result;}
}
