#include "render_demand.hpp"
#include "mapping_fit.hpp"
#include <algorithm>
#include <cmath>
#include <set>
namespace vj {
std::map<std::string,std::array<int,2>> renderDemand(const SceneJson& snapshot,const NativeScene& scene,
    int canvasWidth,int canvasHeight,const std::vector<RenderViewDemand>& views,const std::map<std::string,FrameDemand>& streams,bool ndiPermitted){
    using J=SceneJson;std::map<std::string,std::array<int,2>> sizes;
    auto bus=[&](const std::string& key,int width,int height){if(!scene.buses.contains(key)||width<1||height<1)return;auto& size=sizes[key];size[0]=std::max(size[0],std::min(width,7680));size[1]=std::max(size[1],std::min(height,4320));};
    const J empty=J::object();const auto& mappings=snapshot.contains("mappings")?snapshot.at("mappings"):empty;const auto& state=snapshot.contains("state")?snapshot.at("state"):empty;
    auto mapping=[&](const std::string& id,int width,int height,const J& override=J()){
        if(!override.is_object()&&!mappings.contains(id))return;const auto& entry=override.is_object()?override:mappings.at(id);const auto& project=entry.at("project");
        for(const auto& rect:project.value("renderRects",project.value("rects",J::array()))){
            // The original collection compositor uses projector-space geometry.
            auto native=rect.value("nativeBus",std::string{});if(!native.empty()){bus(native,width,height);continue;}
            auto source=rect.value("source",std::string("none"));if(rect.value("mode",std::string{})!="live"||source=="none")continue;if(source=="out1")source="program";
            double lowX=1,lowY=1,highX=0,highY=0;for(const auto& corner:rect.value("corners",J::array())){lowX=std::min(lowX,corner[0].get<double>());highX=std::max(highX,corner[0].get<double>());lowY=std::min(lowY,corner[1].get<double>());highY=std::max(highY,corner[1].get<double>());}
            bus(source,std::clamp(int(std::ceil((highX-lowX)*width)),std::min(64,width),width),std::clamp(int(std::ceil((highY-lowY)*height)),std::min(64,height),height));
        }
    };
    for(const auto& view:views){if(!view.mappingId.empty()||view.mappingOverride.is_object())mapping(view.mappingId,view.width,view.height,view.mappingOverride);else{bus(view.bus,view.width,view.height);bus(view.bus+"A",view.width,view.height);bus(view.bus+"B",view.width,view.height);}}
    const auto outputs=state.value("ndi_projectors",J::object());if(ndiPermitted)for(auto it=outputs.begin();it!=outputs.end();++it)if(it.value().value("enabled",false))mapping(it.key(),it.value().value("width",1280),it.value().value("height",720));
    const auto status=state.value("output_status",J::object()),projectors=status.value("projectors",J::object());
    for(const auto& [channel,demand]:streams){if(demand.mappingId.empty()){bus(channel,demand.width,demand.height);continue;}
        int width=demand.width,height=demand.height;auto output=projectors.value(demand.mappingId,J::object());
        if(demand.transport=="room"){for(const auto& projector:snapshot.value("room",J::object()).value("scene",J::object()).value("projectors",J::array()))if(projector.value("id",std::string{})==demand.mappingId)height=std::max(1,int(width/projector.value("aspect",16./9.)));}
        else if(demand.transport=="ndi"){if(!output.value("ndi",J::object()).value("active",false))continue;auto config=outputs.value(demand.mappingId,J::object());height=std::max(1,int(double(width)*config.value("height",540)/config.value("width",960)));}
        else{auto display=output.value("display",J::object());if(!display.value("active",false))continue;for(const auto& item:status.value("displays",J::array()))if(item.value("displayId",std::string{})==display.value("displayId",std::string{}))height=std::max(1,int(double(width)*item.value("height",540)/item.value("width",960)));}
        mapping(demand.mappingId,width,height);
    }
    for(auto& [key,size]:sizes)if(scene.buses.at(key).collection.empty()){
        size=mapping_bus_size(size,canvasWidth,canvasHeight);
        const double scale=std::min({1.,7680./size[0],4320./size[1]});size={std::max(1,int(size[0]*scale)),std::max(1,int(size[1]*scale))};
    }
    return sizes;
}
SceneJson patchDemand(const SceneJson& snapshot,const NativeScene& scene,const std::map<std::string,std::array<int,2>>& sizes){
    using J=SceneJson;std::set<std::string> buses,ids;
    // Match the renderer's A/B demand. Both banks may also be visible as previews.
    const auto requireBus=[&](const auto& self,const std::string& name)->void{
        auto it=scene.buses.find(name);if(it==scene.buses.end()||!it->second.running||!buses.insert(name).second)return;
        const auto& crossfade=it->second.crossfade;if(!crossfade.empty()){const auto mix=crossfade.value("value",0.0);if(mix<1)self(self,crossfade.at("a").get<std::string>());if(mix>0)self(self,crossfade.at("b").get<std::string>());}
    };
    for(const auto& [name,size]:sizes)requireBus(requireBus,name);
    std::set<std::string> fixtures;
    for(const auto& fixture:snapshot.at("state").value("fixtures",J::array()))if(fixture.value("enabled",false)){
        fixtures.insert(fixture.value("id",std::string{}));auto out=fixture.value("route",J::object()).value("out",std::string("none"));
        requireBus(requireBus,out=="out1"?"program":out);
    }
    for(const auto& graph:snapshot.value("metaMapping",J::object()).value("resolvedGraphs",J::array()))if(graph.value("active",false)&&graph.value("opacity",1.)>0){
        bool led=false;for(const auto& member:graph["members"])if(member.value("kind",std::string{})=="led"&&fixtures.contains(member.value("id",std::string{})))led=true;
        if(led){auto out=graph.value("out",std::string("none"));requireBus(requireBus,out=="out1"?"program":out);}
    }
    const auto visit=[&](const auto& self,const J& value)->void{
        if(value.is_string()){auto id=value.get<std::string>();if(id.starts_with("patch:"))ids.insert(id);}
        else if(value.is_structured())for(const auto& child:value)self(self,child);
    };
    for(const auto& name:buses)for(const auto& layer:scene.buses.at(name).layers)if(layer.enabled&&layer.opacity>0)visit(visit,layer.params);
    return ids;
}
}
