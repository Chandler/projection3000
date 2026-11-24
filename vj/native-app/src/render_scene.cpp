#include "render_scene.hpp"
#include "control_model.hpp"
#include "live_sources.hpp"
#include "vector_catalog.hpp"
#include <algorithm>

namespace vj {
namespace {
void mediaAssets(NativeLayer& layer,const Json& clip){
    layer.subtitle_asset=clip.value("subtitle_asset",std::string{});layer.renditions.clear();
    for(const auto& rendition:clip.value("renditions",Json::array())){NativeLayer::Rendition item;item.path=rendition.value("path",std::string{});item.width=rendition.value("width",0);item.height=rendition.value("height",0);if(!item.path.empty()&&item.width>0&&item.height>0)layer.renditions.push_back(std::move(item));}
}
void expandMedia(NativeBus& bus,const Json& effects){
    std::vector<NativeLayer> expanded;
    for(const auto& layer:bus.layers){
        if(layer.generator!="media_collection"){expanded.push_back(layer);continue;}
        const auto items=layer.params.value("items",Json::array()),resolved=layer.params.value("_resolved_items",Json::array());
        const auto count=bus.collection.empty()?size_t(1):bus.collection.value("faceIds",Json::array()).size();
        for(size_t i=0;i<std::min(items.size(),count);++i){
            auto child=layer;child.generator=items[i]["type"];child.collection_geometry.clear();child.source_id=layer.source_id+":media:"+mediaItemIdentity(items,i);
            child.params=Json::object();for(const auto& spec:effects)if(spec["name"]==child.generator)for(const auto& p:spec["parameters"]){const auto key=p["name"].get<std::string>();child.params[key]=layer.params.value(key,p["default"]);}
            if(items[i].contains("params"))child.params.update(items[i]["params"]);
            child.params["playing"]=layer.params.value("playing",true)&&child.params.value("playing",true);
            child.params["file"]=items[i]["file"];child.resolved_file=i<resolved.size()?resolved[i].value("resolved_file",std::string{}):std::string{};
            if(i<resolved.size())mediaAssets(child,resolved[i]);
            if(!bus.collection.empty()){
                Json vertices=Json::array();const auto faces=bus.collection.value("mediaVertices",Json::array());
                for(size_t face=i;face<count;face+=items.size())if(face<faces.size())for(const auto& vertex:faces[face])vertices.push_back(vertex);
                child.params["_media_vertices"]=vertices;child.params["_media_group"]=layer.source_id;
            }
            expanded.push_back(std::move(child));
        }
    }
    bus.layers=std::move(expanded);
}
}

NativeScene renderScene(const Json& snapshot,const std::vector<std::string>& outputs,double seconds) {
    const auto& grid=snapshot.at("state").at("grid");
    NativeScene scene;
    scene.revision=snapshot.at("revision");
    scene.fps=30;
    auto effects=Model::catalog();for(const auto& effect:snapshot.value("nativeEffects",Json::array()))effects.push_back(effect);
    const auto state=snapshot.at("state"),mix=state.value("mix",Json::object());
    scene.mix.video_master=mix.value("video_master",1.f);scene.mix.video_mute=mix.value("video_mute",false);
    scene.mix.movie_mode=mix.value("movie_mode",false);scene.mix.cast=mix.value("cast",Json()).is_string()?mix["cast"].get<std::string>():"";
    scene.mix.cast_amount=mix.value("cast_amount",1.f);scene.mix.pulse=mix.value("pulse",false);scene.mix.strobe=mix.value("strobe",false);
    scene.mix.flash_at=state.value("flashAt",0.);
    scene.mix.invert=mix.value("invert",false);scene.mix.blackout=mix.value("blackout",false);
    const auto sync=mix.value("sync",Json::object());scene.mix.video_shift_seconds=(sync.value("clock",0.)+sync.value("video",0.))/1000.;
    const auto clock=state.value("clock",Json::object());NativeClock frameClock;
    frameClock.seconds=seconds+scene.mix.video_shift_seconds;frameClock.bpm=clock.value("bpm",120.);
    frameClock.beat=(controlNow()-clock.value("origin",controlNow())+scene.mix.video_shift_seconds)*frameClock.bpm/60.;
    for(const auto& output:outputs) {
        if(!grid["running"].contains(output))continue;
        scene.outputs.push_back(output);
        const auto key=output=="program"?"out1":output;
        if(snapshot.contains("outputs")&&snapshot["outputs"].contains(key)){
            const auto& local=snapshot["outputs"][key]["clock"];frameClock.seconds=local.value("seconds",seconds);frameClock.beat=local.value("beat",0.);frameClock.playing=local.value("playing",true);
            // Snapshot clocks are stamped when captured. Rebuilding from a
            // cached snapshot must not rewind a procedural animation.
            if(frameClock.playing&&local.contains("serverMonotonicNs")){
                const double age=std::max(0.,controlNow()-local["serverMonotonicNs"].get<double>()/1e9);
                frameClock.seconds+=age;frameClock.beat+=age*frameClock.bpm/60.;
            }
            // Media playheads apply their own presentation offset in the graph.
            // Procedural/collection/vector clocks shift here, only while running.
            if(frameClock.playing){frameClock.seconds=std::max(0.,frameClock.seconds+scene.mix.video_shift_seconds);frameClock.beat=std::max(0.,frameClock.beat+scene.mix.video_shift_seconds*frameClock.bpm/60.);}
        }
        for(const auto* bank:{"A","B"}) {
            const std::string key=std::string(bank)=="A"?"selections":"selections_b";
            NativeBus bus;
            bus.bank=true;
            bus.running=grid["running"][output];
            bus.clock=frameClock;
            const auto selections=grid[key].value(output,Json::object());
            int index=0;
            for(const auto& row:grid["rows"]) {
                ++index; // Stable layer slot, including muted and empty rows.
                const auto rid=row["id"].get<std::string>();
                if(!selections.contains(rid))continue;
                const auto column=selections[rid].get<std::string>();
                if(!row["clips"].contains(column))continue;
                const auto& clip=row["clips"][column];
                NativeLayer layer;
                layer.id=index;
                layer.source_id=clip["id"];
                // Source identity belongs to a launched instance, not its saved cell.
                // A/B sharing for the same Out/cell is resolved by the composition API.
                if(snapshot.contains("outputs")&&snapshot["outputs"].contains(output=="program"?"out1":output)){
                    const auto& rendered=snapshot["outputs"][output=="program"?"out1":output];
                    for(const auto& identity:rendered.at("banks").at(bank).at("layers"))if(identity.value("grid_row",std::string{})==rid){layer.id=identity.value("id",index);layer.source_id=identity.value("source_id",layer.source_id);break;}
                }
                layer.generator=clip["gen"];
                for(const auto& spec:effects)if(spec["name"]==layer.generator&&spec.value("collectionGeometry",Json()).is_string())layer.collection_geometry=spec["collectionGeometry"];
                layer.resolved_file=clip.value("resolved_file",std::string{});mediaAssets(layer,clip);
                layer.params=clip["params"];
                if(clip.contains("patchControls"))layer.params["_patch_controls"]=clip["patchControls"];
                if(clip.contains("vector"))layer.vector=clip["vector"];else if(!layer.generator.starts_with("external_"))for(const auto& spec:effects)if(spec["name"]==layer.generator&&spec.value("vector",false))layer.vector=vectorRecipe(layer.generator,layer.params,1920,1080);
                if(layer.generator=="media_collection")layer.params["_resolved_items"]=clip.value("resolvedItems",Json::array());
                if(layer.generator=="ndi"||layer.generator=="syphon"||layer.generator=="usb_webcam")layer.resolved_file=normalizeLiveSelection(layer.generator,layer.params.value(layer.generator=="usb_webcam"?"device":"source",std::string{}));
                layer.opacity=clip.value("opacity",1.f);
                layer.base_opacity=layer.opacity;
                layer.enabled=row.value("enabled",true);
                layer.blend=clip.value("blend",row.value("blend",std::string("normal")));
                bus.layers.push_back(std::move(layer));
            }
            scene.buses[output+bank]=std::move(bus);
        }
        NativeBus mixed;
        mixed.running=grid["running"][output];
        mixed.clock=frameClock;
        if(mixed.running)mixed.layers=scene.buses[output+"A"].layers;
        mixed.crossfade={{"a",output+"A"},{"b",output+"B"},{"value",grid["crossfade"].value(output,0.0)}};
        scene.buses[output]=std::move(mixed);
    }
    if(snapshot.contains("mappings"))for(const auto& mapping:snapshot["mappings"]){
        const auto contexts=mapping.value("collectionContexts",Json::object());
        for(auto it=contexts.begin();it!=contexts.end();++it){const auto source=it.value()["source"].get<std::string>(),out=source=="out1"?"program":source,key=it.key();if(!scene.buses.contains(out))continue;
            for(const auto* bank:{"A","B"}){auto copy=scene.buses[out+bank];copy.collection=it.value()["geometry"];
                if(copy.collection.contains("metaGraph")){copy.layers.erase(std::remove_if(copy.layers.begin(),copy.layers.end(),[](const NativeLayer& l){return l.generator!="patch_collection";}),copy.layers.end());for(auto& layer:copy.layers){layer.opacity*=copy.collection.value("graphOpacity",1.f);layer.base_opacity=layer.opacity;}}
                scene.buses[key+bank]=std::move(copy);}
            auto copy=scene.buses[out];copy.collection=it.value()["geometry"];copy.crossfade["a"]=key+"A";copy.crossfade["b"]=key+"B";scene.buses[key]=std::move(copy);
        }
    }
    for(auto& [name,bus]:scene.buses)expandMedia(bus,effects);
    return scene;
}
}
