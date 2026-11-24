#pragma once

#include <nlohmann/json.hpp>
#include "output_limits.hpp"

#include <algorithm>
#include <cstdint>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <vector>

using SceneJson = nlohmann::json;

struct NativeClock {
    double seconds = 0.0;
    double beat = 0.0;
    double bpm = 120.0;
    bool playing = true;
};

struct NativeLayer {
    struct Rendition {
        std::string path;
        int width = 0;
        int height = 0;
    };
    int id = 0;
    std::string source_id;
    std::string generator;
    std::string collection_geometry;
    std::string collection_layout = "repeat"; // repeat, span or inherit
    std::string resolved_file;
    std::string subtitle_asset;
    std::vector<Rendition> renditions;
    SceneJson params = SceneJson::object();
    SceneJson vector = SceneJson::object();
    // Immutable face geometry is shared by scratch/mapped layer copies.
    std::shared_ptr<const std::vector<float>> media_vertices;
    float opacity = 1.0f;
    float base_opacity = 1.0f;
    std::string blend = "normal";
    bool enabled = true;
};

struct NativeBus {
    NativeClock clock;
    std::vector<NativeLayer> layers;
    SceneJson collection = SceneJson::object();
    bool running = true;
    bool bank = false;
    SceneJson crossfade = SceneJson::object();
    // Decoded once when the render graph receives the scene.
    std::vector<float> card_vertices;
};

struct NativeMonitorDemand {
    double fps = 0.0;
    int width = 0;
    int height = 0;
};

struct NativeMix {
    float video_master = 1.0f;
    bool video_mute = false;
    bool movie_mode = false;
    double video_shift_seconds = 0.0;
    double flash_at = 0.0;
    std::string cast;
    float cast_amount = 1.0f;
    bool pulse = false;
    bool strobe = false;
    bool invert = false;
    bool blackout = false;
};

struct NativeNdiProjector {
    std::string name;
    int width=1280, height=720, fps=30;
};

struct NativeScene {
    std::uint64_t revision = 0;
    int fps = 30;
    int canvas_width = 960;
    int canvas_height = 540;
    std::map<std::string, NativeBus> buses;
    std::vector<std::string> outputs;
    std::map<std::string, NativeMonitorDemand> monitor_demand;
    NativeMix mix;
    std::map<std::string, NativeNdiProjector> ndi_projectors;
    std::map<std::string, std::array<int,2>> room_projectors;
};

inline std::optional<NativeScene> parse_native_scene(const SceneJson &message) {
    if (!message.is_object()
        || message.value("type", "") != "renderer_state") {
        return std::nullopt;
    }
    NativeScene scene;
    scene.revision = message.value("revision", std::uint64_t{0});
    scene.fps = std::clamp(message.value("fps", 30), 1, 120);
    if (const auto canvas = message.find("canvas");
        canvas != message.end() && canvas->is_array()
        && canvas->size() >= 2) {
        scene.canvas_width = std::clamp((*canvas)[0].get<int>(), 64, 7680);
        scene.canvas_height = std::clamp((*canvas)[1].get<int>(), 64, 4320);
    }
    if (const auto outputs = message.find("outputs");
        outputs != message.end() && outputs->is_array()) {
        for (const auto &output : *outputs) {
            if (!output.is_string()) continue;
            const std::string name = output.get<std::string>();
            if (name == "program" || output_source_index(name) >= 1) {
                scene.outputs.push_back(name);
            }
        }
    }
    if(const auto demand=message.find("roomProjectors");demand!=message.end()&&demand->is_object()){
        for(auto it=demand->begin();it!=demand->end();++it){
            if((it.key()!="1"&&it.key()!="2"&&it.key()!="3"&&it.key()!="4")||!it.value().is_object())continue;
            scene.room_projectors[it.key()]={std::clamp(it.value().value("width",640),64,960),std::clamp(it.value().value("height",360),64,1280)};
        }
    }
    if (const auto outputs = message.find("ndiProjectors"); outputs != message.end() && outputs->is_object()) {
        for (auto it=outputs->begin();it!=outputs->end();++it) {
            if (scene.ndi_projectors.size()>=4) break;
            if ((it.key()!="1" && it.key()!="2" && it.key()!="3" && it.key()!="4")
                || !it.value().is_object() || !it.value().value("enabled",false)) continue;
            NativeNdiProjector output;
            output.name=it.value().value("name", "Vibe Projector " + it.key());
            output.width=std::clamp(it.value().value("width",1280),64,1920);
            output.height=std::clamp(it.value().value("height",720),64,1080);
            output.fps=std::clamp(it.value().value("fps",30),1,60);
            scene.ndi_projectors[it.key()]=output;
        }
    }
    if (const auto buses = message.find("buses");
        buses != message.end() && buses->is_object()) {
        for (auto item = buses->begin(); item != buses->end(); ++item) {
            if (!item.value().is_object()) continue;
            NativeBus bus;
            bus.running = item.value().value("running", true);
            bus.bank = item.value().value("bank", false);
            bus.crossfade = item.value().value("crossfade", SceneJson::object());
            bus.collection = item.value().value("collection", SceneJson::object());
            if (const auto clock = item.value().find("clock");
                clock != item.value().end() && clock->is_object()) {
                bus.clock.seconds = clock->value("seconds", 0.0);
                bus.clock.beat = clock->value("beat", 0.0);
                bus.clock.bpm = clock->value("bpm", 120.0);
                bus.clock.playing = clock->value("playing", true);
            }
            if (const auto layers = item.value().find("layers");
                layers != item.value().end() && layers->is_array()) {
                for (const auto &value : *layers) {
                    if (!value.is_object()) continue;
                    NativeLayer layer;
                    layer.id = value.value("id", 0);
                    layer.source_id = value.value("source_id", "");
                    layer.generator = value.value("gen", "");
                    layer.collection_geometry = value.value("collection_effect", "");
                    layer.collection_layout = value.value("collection_layout", "repeat");
                    layer.resolved_file = value.value("resolved_file", "");
                    layer.subtitle_asset = value.value("subtitle_asset", "");
                    if (const auto renditions = value.find("renditions");
                        renditions != value.end() && renditions->is_array()) {
                        for (const auto &rendition : *renditions) {
                            if (!rendition.is_object()) continue;
                            NativeLayer::Rendition parsed;
                            parsed.path = rendition.value("path", "");
                            parsed.width = rendition.value("width", 0);
                            parsed.height = rendition.value("height", 0);
                            if (!parsed.path.empty()
                                && parsed.width > 0 && parsed.height > 0) {
                                layer.renditions.push_back(std::move(parsed));
                            }
                        }
                    }
                    layer.opacity =
                        std::clamp(value.value("opacity", 1.0f), 0.0f, 1.0f);
                    layer.base_opacity = std::clamp(value.value("base_opacity", 1.0f), 0.0f, 1.0f);
                    layer.blend = value.value("blend", "normal");
                    layer.enabled = value.value("enabled", true);
                    if (const auto vector = value.find("vector");
                        vector != value.end() && vector->is_object()) {
                        layer.vector = *vector;
                    }
                    if (const auto params = value.find("params");
                        params != value.end() && params->is_object()) {
                        layer.params = *params;
                    }
                    if (!layer.generator.empty() && !layer.source_id.empty()) {
                        bus.layers.push_back(std::move(layer));
                    }
                }
            }
            scene.buses[item.key()] = std::move(bus);
        }
    }
    if (const auto demand = message.find("monitorDemand");
        demand != message.end() && demand->is_object()) {
        for (auto item = demand->begin(); item != demand->end(); ++item) {
            if (!item.value().is_object()) continue;
            NativeMonitorDemand value;
            value.fps = std::clamp(
                item.value().value("fps", 0.0), 0.0, 120.0);
            value.width = std::clamp(
                item.value().value("width", 0), 0, 7680);
            value.height = std::clamp(
                item.value().value("height", 0), 0, 4320);
            scene.monitor_demand[item.key()] = value;
        }
    }
    if (const auto mix = message.find("mix");
        mix != message.end() && mix->is_object()) {
        scene.mix.video_master =
            std::clamp(mix->value("video_master", 1.0f), 0.0f, 1.0f);
        scene.mix.video_mute = mix->value("video_mute", false);
        scene.mix.movie_mode = mix->value("movie_mode", false);
        if (const auto sync = mix->find("sync");
            sync != mix->end() && sync->is_object()) {
            const double clock_ms = sync->value("clock", 0.0);
            const double video_ms = sync->value("video", 0.0);
            scene.mix.video_shift_seconds = std::clamp(
                (clock_ms + video_ms) / 1000.0, -2.0, 2.0);
        }
        if (const auto cast = mix->find("cast");
            cast != mix->end() && cast->is_string()) {
            scene.mix.cast = cast->get<std::string>();
        }
        scene.mix.cast_amount =
            std::clamp(mix->value("cast_amount", 1.0f), 0.0f, 1.0f);
        scene.mix.pulse = mix->value("pulse", false);
        scene.mix.strobe = mix->value("strobe", false);
        scene.mix.invert = mix->value("invert", false);
        scene.mix.blackout = mix->value("blackout", false);
    }
    return scene;
}
