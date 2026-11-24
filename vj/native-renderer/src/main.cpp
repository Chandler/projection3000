#include "surface_curvature_json.hpp"
#include "plane_pattern.hpp"
#include "module_fetch.hpp"
#define GL_GLEXT_PROTOTYPES
#include <SDL2/SDL.h>
#include <SDL2/SDL_opengl.h>

#include <boost/asio/connect.hpp>
#include <boost/asio/ip/tcp.hpp>
#include <boost/beast/core.hpp>
#include <boost/beast/http.hpp>
#include <boost/beast/websocket.hpp>
#include <nlohmann/json.hpp>
#include <wasmtime.h>

#include "native_render_graph.hpp"
#include "projector_ndi_output.hpp"
#include "room_preview_target.hpp"
#include "native_scene.hpp"
#include "monitor_frame_publisher.hpp"
#include "mapping_fit.hpp"
#include "surface_curvature.hpp"
#include "rounded_surface.hpp"
#include "selection_marker.hpp"
#include "projector_raster.hpp"
using projector_raster::rotate_output_uv;
using projector_raster::compile_shader;
using projector_raster::make_program;
using projector_raster::solve_linear;
using projector_raster::projective_uvs;
using projector_raster::set_blend;

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>
#include <unistd.h>

namespace asio = boost::asio;
namespace beast = boost::beast;
namespace http = beast::http;
namespace websocket = beast::websocket;
using tcp = asio::ip::tcp;
using json = nlohmann::json;
using Clock = std::chrono::steady_clock;

struct WsUrl {
    std::string host;
    std::string port = "80";
    std::string target = "/";

    std::string authority() const {
        return port == "80" ? host : host + ":" + port;
    }
};

std::optional<WsUrl> parse_ws_url(std::string value) {
    constexpr const char *prefix = "ws://";
    if (!value.starts_with(prefix)) return std::nullopt;
    value.erase(0, std::strlen(prefix));
    const auto slash = value.find('/');
    const std::string authority = value.substr(0, slash);
    const auto colon = authority.rfind(':');
    WsUrl result;
    if (colon != std::string::npos) {
        result.host = authority.substr(0, colon);
        result.port = authority.substr(colon + 1);
    } else {
        result.host = authority;
    }
    result.target = slash == std::string::npos ? "/" : value.substr(slash);
    if (result.host.empty() || result.port.empty()) return std::nullopt;
    return result;
}

struct Rect {
    std::string id;
    std::vector<std::array<float, 2>> corners;
    std::vector<std::array<float, 2>> uvs{{
        {{0.0f, 1.0f}}, {{1.0f, 1.0f}}, {{1.0f, 0.0f}}, {{0.0f, 0.0f}},
    }};
    std::string source = "out1";
    std::string native_bus;
    bool fold = false;
    double corner_radius = 0;
    std::vector<Rect> masks;
    std::vector<Rect> overlay_masks;
    surface_curvature::Settings curvature;
    std::shared_ptr<const surface_curvature::Mesh> curved;
    bool live = true;
    bool wireframe = false;
    bool plane_pattern = false, plane_circle = false;
    std::array<float,2> plane_extent{1,1};
    bool overlay = false;
    std::string blend = "normal";
    std::string fit = "stretch";
};

struct Trace {
    std::string id;
    std::vector<std::array<float, 2>> points;
    int pixels = 60;
    float width = 0.015f;
    float feather = 0.5f;
    float glow = 0.35f;
    std::string blend = "add";
    bool enabled = true;
};

struct VectorMaster {
    float gain = 1.0f;
    bool mute = false;
    bool pulse = false;
    bool strobe = false;
    bool invert = false;
    bool blackout = false;
    std::string cast;
    float cast_amount = 0.0f;
    double global_beat = 0.0;
};

struct VectorRecipe {
    int abi = 1;
    std::string format = "vibe-vector/1";
    std::string module;
    std::string effect;
    std::vector<float> params;
    int canvas_width = 960;
    int canvas_height = 540;
    double seconds = 0.0;
    double beat = 0.0;
    double bpm = 120.0;
    bool playing = true;
    float opacity = 1.0f;
    std::string blend = "normal";
    std::string line_cap = "round";
    std::uint64_t revision = 0;
    VectorMaster master;
    Clock::time_point received_at = Clock::now();
};

std::optional<VectorRecipe> parse_vector_recipe(const json &item) {
    if (!item.is_object()) return std::nullopt;
    const std::string format = item.value("format", "");
    const int abi = item.value("abi", 0);
    if (!((format == "vibe-vector/1" && abi == 1)
          || (format == "vibe-graphics/2" && abi == 2))) {
        return std::nullopt;
    }
    VectorRecipe recipe;
    recipe.abi = abi;
    recipe.format = format;
    recipe.module = item.value("module", "");
    recipe.effect = item.value("effect", "");
    recipe.revision = item.value("revision", std::uint64_t{0});
    recipe.opacity = item.value("opacity", 1.0f);
    recipe.blend = item.value("blend", "normal");
    recipe.line_cap = item.value("lineCap", "round");
    if (recipe.line_cap != "butt") recipe.line_cap = "round";
    if (recipe.module.empty()
        || !recipe.module.starts_with("/vector/modules/")
        || recipe.module.find("..") != std::string::npos) {
        return std::nullopt;
    }
    if (const auto params = item.find("paramValues");
        params != item.end() && params->is_array()) {
        for (const auto &param : *params) {
            if (!param.is_number() || recipe.params.size() >= 64) break;
            const float number = param.get<float>();
            recipe.params.push_back(std::isfinite(number) ? number : 0.0f);
        }
    }
    if (const auto canvas = item.find("canvas");
        canvas != item.end() && canvas->is_array()
        && canvas->size() >= 2) {
        recipe.canvas_width = std::max(1, (*canvas)[0].get<int>());
        recipe.canvas_height = std::max(1, (*canvas)[1].get<int>());
    }
    if (const auto clock = item.find("clock");
        clock != item.end() && clock->is_object()) {
        recipe.seconds = clock->value("seconds", 0.0);
        recipe.beat = clock->value("beat", 0.0);
        recipe.bpm = clock->value("bpm", 120.0);
        recipe.playing = clock->value("playing", true);
    }
    if (const auto master = item.find("master");
        master != item.end() && master->is_object()) {
        recipe.master.gain = master->value("gain", 1.0f);
        recipe.master.mute = master->value("mute", false);
        recipe.master.pulse = master->value("pulse", false);
        recipe.master.strobe = master->value("strobe", false);
        recipe.master.invert = master->value("invert", false);
        recipe.master.blackout = master->value("blackout", false);
        if (const auto cast = master->find("cast");
            cast != master->end() && cast->is_string()) {
            recipe.master.cast = cast->get<std::string>();
        }
        recipe.master.cast_amount = master->value("castAmount", 0.0f);
        recipe.master.global_beat =
            master->value("globalBeat", recipe.beat);
    }
    recipe.received_at = Clock::now();
    return recipe;
}

struct Project {
    std::vector<Rect> rects;
    std::vector<Trace> traces;
    std::set<std::string> selected_rect_ids;
    std::uint64_t selection_revision = 0;
    bool enabled = true;
    int rotation = 0;
    bool bounds_grid = false;
    std::uint64_t generation = 0;
    std::array<std::optional<VectorRecipe>, kMaxOutputs> vectors;
};


bool mapping_allows_movie_mode(const Project &project) {
    if (!project.enabled || project.bounds_grid) return false;
    if (std::any_of(
            project.traces.begin(), project.traces.end(),
            [](const Trace &trace) { return trace.enabled; })) {
        return false;
    }
    const Rect *visible = nullptr;
    for (const auto &rect : project.rects) {
        if (!rect.live || rect.source == "none") continue;
        if (visible) return false;
        visible = &rect;
    }
    return visible && visible->source == "out1"
        && visible->blend == "normal";
}

std::optional<SDL_DisplayMode> cinema_display_mode(
    int display, const SDL_Rect &desktop_bounds) {
    std::optional<SDL_DisplayMode> selected;
    const int modes = SDL_GetNumDisplayModes(display);
    for (int index = 0; index < modes; ++index) {
        SDL_DisplayMode mode{};
        if (SDL_GetDisplayMode(display, index, &mode) != 0
            || mode.w != desktop_bounds.w || mode.h != desktop_bounds.h
            || mode.refresh_rate != 24) {
            continue;
        }
        if (!selected || mode.format == SDL_PIXELFORMAT_RGB888) {
            selected = mode;
        }
    }
    return selected;
}

bool enter_movie_display_mode(
    SDL_Window *window, const SDL_DisplayMode &mode) {
    if (SDL_SetWindowFullscreen(window, 0) != 0) return false;
    if (SDL_SetWindowDisplayMode(window, &mode) != 0
        || SDL_SetWindowFullscreen(window, SDL_WINDOW_FULLSCREEN) != 0) {
        SDL_SetWindowDisplayMode(window, nullptr);
        SDL_SetWindowFullscreen(window, SDL_WINDOW_FULLSCREEN_DESKTOP);
        return false;
    }
    SDL_GL_SetSwapInterval(1);
    return true;
}

bool leave_movie_display_mode(
    SDL_Window *window, const SDL_Rect &desktop_bounds) {
    bool okay = SDL_SetWindowFullscreen(window, 0) == 0;
    okay = SDL_SetWindowDisplayMode(window, nullptr) == 0 && okay;
    SDL_SetWindowPosition(window, desktop_bounds.x, desktop_bounds.y);
    SDL_SetWindowSize(window, desktop_bounds.w, desktop_bounds.h);
    okay = SDL_SetWindowFullscreen(
        window, SDL_WINDOW_FULLSCREEN_DESKTOP) == 0 && okay;
    SDL_GL_SetSwapInterval(1);
    return okay;
}

bool finite_pair(const json &value) {
    return value.is_array() && value.size() >= 2 && value[0].is_number()
        && value[1].is_number() && std::isfinite(value[0].get<double>())
        && std::isfinite(value[1].get<double>());
}

std::optional<Project> parse_project(const json &message, std::uint64_t generation) {
    if (!message.is_object()) return std::nullopt;
    const std::string type = message.value("type", "");
    if (type != "mapping_snapshot" && type != "mapping_preview") return std::nullopt;
    const auto project_it = message.find("project");
    if (project_it == message.end() || !project_it->is_object()) return std::nullopt;
    const json &value = *project_it;

    Project project;
    project.generation = generation;
    if(message.contains("selectedRectIds"))project.selected_rect_ids=message.at("selectedRectIds").get<std::set<std::string>>();
    project.selection_revision=message.value("selectionRevision",std::uint64_t{0});
    if (const auto output = value.find("output"); output != value.end() && output->is_object()) {
        const bool legacy_rotate_180 = output->value("rotate180", false)
            || output->value("flipVertical", false);
        project.rotation = output->value("rotation", legacy_rotate_180 ? 180 : 0);
        if (project.rotation != 0 && project.rotation != 90
            && project.rotation != 180 && project.rotation != 270) {
            project.rotation = 0;
        }
        project.bounds_grid = output->value("boundsGrid", false);
        project.enabled = output->value("enabled", true);
    }
    if (const auto buses = message.find("vectorBuses");
        buses != message.end() && buses->is_object()) {
        for (int index = 0; index < kMaxOutputs; ++index) {
            const std::string source = "out" + std::to_string(index + 1);
            const auto item = buses->find(source);
            if (item == buses->end() || !item->is_object()) {
                continue;
            }
            project.vectors[index] = parse_vector_recipe(*item);
        }
    }
    if (const auto traces = value.find("traces");
        traces != value.end() && traces->is_array()) {
        for (const auto &item : *traces) {
            if (!item.is_object()) continue;
            Trace trace;
            trace.id = item.value("id", "");
            trace.pixels = std::clamp(item.value("pixels", 60), 2, 2000);
            trace.width =
                std::clamp(item.value("width", 0.015f), 0.001f, 0.2f);
            trace.feather =
                std::clamp(item.value("feather", 0.5f), 0.0f, 1.0f);
            trace.glow =
                std::clamp(item.value("glow", 0.35f), 0.0f, 1.0f);
            trace.blend = item.value("blend", "add");
            if (trace.blend != "add" && trace.blend != "screen"
                && trace.blend != "normal") {
                trace.blend = "add";
            }
            trace.enabled = item.value("enabled", true);
            if (const auto points = item.find("points");
                points != item.end() && points->is_array()) {
                for (const auto &point : *points) {
                    if (!finite_pair(point)) continue;
                    trace.points.push_back({
                        std::clamp(point[0].get<float>(), 0.0f, 1.0f),
                        std::clamp(point[1].get<float>(), 0.0f, 1.0f),
                    });
                }
            }
            if (!trace.id.empty() && trace.points.size() >= 2) {
                project.traces.push_back(std::move(trace));
            }
        }
    }
    const auto rects = value.find(value.contains("renderRects") ? "renderRects" : "rects");
    if (rects == value.end() || !rects->is_array()) return project;
    for (const auto &item : *rects) {
        if (!item.is_object()) continue;
        const auto corners = item.find("corners");
        if (corners == item.end() || !corners->is_array()
            || corners->size() < 4 || corners->size() > 64) {
            continue;
        }
        Rect rect;
        rect.id=item.value("id",std::string{});
        rect.corners.clear();
        bool valid = true;
        for (const auto &point : *corners) {
            if (!finite_pair(point)) {
                valid = false;
                break;
            }
            rect.corners.push_back(
                {point[0].get<float>(), point[1].get<float>()});
        }
        if (!valid) continue;
        if (const auto uvs = item.find("uvs");
            uvs != item.end() && uvs->is_array()
            && uvs->size() == rect.corners.size()) {
            rect.uvs.clear();
            for (const auto &point : *uvs) {
                if (!finite_pair(point)) {
                    valid = false;
                    break;
                }
                rect.uvs.push_back(
                    {point[0].get<float>(), point[1].get<float>()});
            }
        } else if (rect.corners.size() != 4) {
            valid = false;
        }
        if (!valid) continue;
        rect.fold = item.value("fold", false) && rect.corners.size()==6;
        rect.corner_radius=std::clamp(item.value("cornerRadius",0.0),0.0,.5);
        for(const auto* field:{"maskSurfaces","overlaySurfaces"})if(const auto masks=item.find(field);masks!=item.end()&&masks->is_array()){
            for(const auto& raw:*masks){
                Rect mask;mask.corner_radius=raw.value("cornerRadius",0.0);
                for(const auto& p:raw.at("corners"))mask.corners.push_back({p[0].get<float>(),p[1].get<float>()});
                mask.curvature=surface_curvature::from_json(raw.value("curvature",json()));
                if(mask.curvature.active()){
                    auto mesh=surface_curvature::build(mask.corners,{{0,0},{1,0},{1,1},{0,1}},mask.curvature);
                    if(mesh)mask.curved=std::make_shared<const surface_curvature::Mesh>(std::move(*mesh));
                }
                (std::string(field)=="overlaySurfaces"?rect.overlay_masks:rect.masks).push_back(std::move(mask));
            }
        }
        if(const auto c=item.find("curvature");c!=item.end()&&c->is_object()){
            rect.curvature={c->value("top",0.0),c->value("right",0.0),c->value("bottom",0.0),c->value("left",0.0),c->value("wrapX",0.0),c->value("wrapY",0.0)};
            rect.curvature.spacing_x=c->value("spacingX",0.0);rect.curvature.spacing_y=c->value("spacingY",0.0);
            const std::array<std::string,4> sides{"top","right","bottom","left"};
            for(int i=0;i<4;i++){
                rect.curvature.skew[i]=c->value(sides[i]+"Skew",0.0);
                rect.curvature.shape[i]=c->value(sides[i]+"Shape",0.0);
            }
            if(const auto pins=c->find("pins");pins!=c->end()&&pins->is_object()){
                rect.curvature.pins_enabled=pins->value("enabled",true);
                rect.curvature.local_pins=pins->value("method",std::string("fit"))=="local";
                if(const auto points=pins->find("points");points!=pins->end()&&points->is_array())for(const auto& p:*points){
                    const auto side=std::find(sides.begin(),sides.end(),p.value("side",std::string()));
                    if(side==sides.end()||!p.contains("target")||!finite_pair(p["target"]))continue;
                    rect.curvature.pins.push_back({int(side-sides.begin()),p.value("t",.5),{p["target"][0].get<double>(),p["target"][1].get<double>()},p.value("enabled",true)});
                }
                surface_curvature::prepare_pins(rect.curvature);
            }
            if(rect.curvature.active()){
                if(rect.fold)continue;
                auto mesh=surface_curvature::build(rect.corners,rect.uvs,rect.curvature);
                if(!mesh)continue;
                rect.curved=std::make_shared<const surface_curvature::Mesh>(std::move(*mesh));
            }
        }
        rect.source = item.value("source", "out1");
        rect.native_bus = item.value("nativeBus", "");
        if (output_source_index(rect.source) < 0 && rect.source != "none") rect.source = "out1";
        if(const auto extent=item.find("planePattern");extent!=item.end() && finite_pair(*extent)){
            rect.plane_pattern=true;rect.plane_extent={(*extent)[0].get<float>(),(*extent)[1].get<float>()};
            rect.plane_circle=item.value("pointShape",std::string{})=="circle";
        }
        rect.live = item.value("mode", "live") != "grid";
        rect.wireframe = item.value("graphic",std::string("grid"))=="wireframe";
        rect.overlay = item.value("kind", "surface") == "overlay";
        rect.blend = item.value("blend", "normal");
        rect.fit = item.value("fit", "stretch");
        project.rects.push_back(rect);
    }
    return project;
}

struct Runtime {
    std::string server;
    int mapping = 1;
    std::atomic<bool> running{true};
    std::mutex project_mutex;
    Project project;
    std::mutex led_mutex;
    std::map<std::string, std::vector<std::uint8_t>> led_frames;
    std::atomic<std::uint64_t> state_messages{0};
    std::atomic<std::uint64_t> led_messages{0};
    std::mutex native_scene_mutex;
    NativeScene native_scene;
    std::atomic<std::uint64_t> native_scene_messages{0};
};

int source_index(const std::string &source) {
    return std::max(0, output_source_index(source));
}

template <typename Handler>
void read_websocket(const WsUrl &url, Handler handler) {
    asio::io_context io;
    tcp::resolver resolver(io);
    websocket::stream<beast::tcp_stream> ws(io);
    const auto endpoints = resolver.resolve(url.host, url.port);
    beast::get_lowest_layer(ws).connect(endpoints);
    ws.set_option(websocket::stream_base::timeout::suggested(beast::role_type::client));
    ws.read_message_max(32 * 1024 * 1024);
    ws.handshake(url.authority(), url.target);
    beast::flat_buffer buffer;
    while (handler(ws, buffer)) {
        buffer.consume(buffer.size());
        ws.read(buffer);
    }
    beast::error_code ignored;
    ws.close(websocket::close_code::normal, ignored);
}

struct ModulePending : std::runtime_error {
    ModulePending() : std::runtime_error("Loading vector module") {}
};

std::vector<std::uint8_t> read_http_bytes(
    const std::string &server, const std::string &target) {
    struct Entry {
        std::mutex mutex;
        bool loading = true;
        std::vector<std::uint8_t> bytes;
        std::string error;
        Clock::time_point retry{};
    };
    // Accessed by the render thread; each entry's result is shared with one
    // detached worker. Bounded cache and deadlines bound outstanding work.
    static std::map<std::string, std::shared_ptr<Entry>> cache;
    const auto key = server + target;
    auto it = cache.find(key);
    if (it == cache.end()) {
        if (cache.size() >= 32) {
            for (auto old = cache.begin(); old != cache.end(); ++old) {
                auto candidate = old->second;
                std::lock_guard lock(candidate->mutex);
                if (!candidate->loading) { cache.erase(old); break; }
            }
            if (cache.size() >= 32) throw ModulePending();
        }
        it = cache.emplace(key, std::make_shared<Entry>()).first;
        auto entry = it->second;
        std::thread([entry, server, target] {
            try {
                const auto url = parse_ws_url("ws://" + server + target);
                if (!url) throw std::runtime_error("Invalid vector module URL");
                auto bytes = fetch_module(url->host, url->port, url->authority(), url->target);
                std::lock_guard lock(entry->mutex);
                entry->bytes = std::move(bytes);
                entry->loading = false;
            } catch (const std::exception &error) {
                std::lock_guard lock(entry->mutex);
                entry->error = error.what();
                entry->retry = Clock::now() + std::chrono::seconds(3);
                entry->loading = false;
            }
        }).detach();
    }
    auto entry = it->second;
    std::lock_guard lock(entry->mutex);
    if (entry->loading) throw ModulePending();
    if (!entry->error.empty()) {
        if (Clock::now() >= entry->retry) cache.erase(it);
        // Retrying must not permanently disable this recipe revision.
        throw ModulePending();
    }
    return entry->bytes;
}

#include "calibration_control.hpp"

void state_worker(Runtime *runtime) {
    std::uint64_t generation = 0;
    while (runtime->running.load()) {
        const auto url = parse_ws_url(
            "ws://" + runtime->server + "/ws/state?mapping="
            + std::to_string(runtime->mapping) + "&role=render");
        if (!url) return;
        try {
            bool first = true;
            {std::lock_guard lock(runtime->project_mutex);runtime->project.selected_rect_ids.clear();runtime->project.selection_revision=0;}
            read_websocket(*url, [&](auto &ws, beast::flat_buffer &buffer) {
                if (first) {
                    first = false;
                    ws.read(buffer);
                }
                if (!ws.got_text()) return runtime->running.load();
                const std::string text = beast::buffers_to_string(buffer.data());
                try {
                    const auto message = json::parse(text);
                    if(message.value("type",std::string{})=="mapping_selection"){
                        std::lock_guard lock(runtime->project_mutex);
                        const auto revision=message.value("selectionRevision",std::uint64_t{0});
                        if(revision>=runtime->project.selection_revision){
                            runtime->project.selected_rect_ids=message.at("selectedRectIds").get<std::set<std::string>>();
                            runtime->project.selection_revision=revision;
                        }
                    }
                    if (auto project = parse_project(message, ++generation)) {
                        {
                            std::lock_guard lock(runtime->project_mutex);
                            if (!message.contains("vectorBuses")) {
                                project->vectors = runtime->project.vectors;
                            }
                            if(!message.contains("selectedRectIds")||project->selection_revision<runtime->project.selection_revision){
                                project->selected_rect_ids=runtime->project.selected_rect_ids;
                                project->selection_revision=runtime->project.selection_revision;
                            }
                            runtime->project = *project;
                        }
                        runtime->state_messages.fetch_add(1);
                    }
                } catch (const std::exception &error) {
                    std::cerr << "Mapping JSON ignored: " << error.what() << "\n";
                }
                return runtime->running.load();
            });
        } catch (const std::exception &error) {
            std::cerr << "Mapping socket reconnecting: " << error.what() << "\n";
            std::lock_guard lock(runtime->project_mutex);runtime->project.selected_rect_ids.clear();
        }
        std::this_thread::sleep_for(std::chrono::seconds(1));
    }
}

void renderer_state_worker(Runtime *runtime) {
    while (runtime->running.load()) {
        const auto url =
            parse_ws_url("ws://" + runtime->server + "/ws/renderer");
        if (!url) return;
        try {
            bool first = true;
            read_websocket(*url, [&](auto &ws, beast::flat_buffer &buffer) {
                if (first) {
                    first = false;
                    ws.read(buffer);
                }
                if (!ws.got_text()) return runtime->running.load();
                try {
                    const auto message = json::parse(
                        beast::buffers_to_string(buffer.data()));
                    if (auto scene = parse_native_scene(message)) {
                        {
                            std::lock_guard lock(runtime->native_scene_mutex);
                            runtime->native_scene = std::move(*scene);
                        }
                        runtime->native_scene_messages.fetch_add(1);
                    }
                } catch (const std::exception &error) {
                    std::cerr << "Renderer JSON ignored: "
                              << error.what() << "\n";
                }
                return runtime->running.load();
            });
        } catch (const std::exception &error) {
            if (runtime->running.load()) {
                std::cerr << "Renderer socket reconnecting: "
                          << error.what() << "\n";
            }
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(500));
    }
}

std::vector<std::uint8_t> decode_base64(const std::string &text) {
    static constexpr std::array<std::int8_t, 256> table = [] {
        std::array<std::int8_t, 256> result{};
        result.fill(-1);
        constexpr char alphabet[] =
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        for (int i = 0; i < 64; ++i) {
            result[static_cast<unsigned char>(alphabet[i])] =
                static_cast<std::int8_t>(i);
        }
        return result;
    }();
    std::vector<std::uint8_t> bytes;
    bytes.reserve(text.size() * 3 / 4);
    std::uint32_t bits = 0;
    int count = 0;
    for (const unsigned char character : text) {
        if (character == '=') break;
        const int value = table[character];
        if (value < 0) continue;
        bits = (bits << 6) | static_cast<std::uint32_t>(value);
        count += 6;
        if (count >= 8) {
            count -= 8;
            bytes.push_back(static_cast<std::uint8_t>(
                (bits >> count) & 0xff));
        }
    }
    return bytes;
}

void led_worker(Runtime *runtime) {
    while (runtime->running.load()) {
        const auto url =
            parse_ws_url("ws://" + runtime->server + "/ws/leds");
        if (!url) return;
        try {
            bool first = true;
            read_websocket(*url, [&](auto &ws, beast::flat_buffer &buffer) {
                if (first) {
                    first = false;
                    ws.read(buffer);
                }
                if (!ws.got_text()) return runtime->running.load();
                try {
                    const auto message = json::parse(
                        beast::buffers_to_string(buffer.data()));
                    if (message.value("type", "") != "led_frames") {
                        return runtime->running.load();
                    }
                    const auto frames = message.find("frames");
                    if (frames == message.end() || !frames->is_object()) {
                        return runtime->running.load();
                    }
                    std::lock_guard lock(runtime->led_mutex);
                    for (auto item = frames->begin(); item != frames->end();
                         ++item) {
                        if (!item.value().is_string()) continue;
                        runtime->led_frames[item.key()] =
                            decode_base64(item.value().get<std::string>());
                    }
                    runtime->led_messages.fetch_add(1);
                } catch (const std::exception &error) {
                    std::cerr << "LED JSON ignored: " << error.what() << "\n";
                }
                return runtime->running.load();
            });
        } catch (const std::exception &error) {
            if (runtime->running.load()) {
                std::cerr << "LED socket reconnecting: "
                          << error.what() << "\n";
            }
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(500));
    }
}

struct VectorPoint {
    float x = 0.0f;
    float y = 0.0f;
};

struct VectorStyle {
    std::array<float, 4> core{{1, 1, 1, 1}};
    std::array<float, 4> glow{{1, 1, 1, 0}};
    float core_width = 0.004f;
    float glow_width = 0.02f;
};

struct VectorSegment {
    VectorPoint a;
    VectorPoint b;
    VectorStyle style_a;
    VectorStyle style_b;
    bool path_start = true;
    bool path_end = true;
};

struct VectorSplat {
    VectorPoint point;
    VectorStyle style;
};

struct VectorScene {
    std::vector<VectorSegment> segments;
    std::vector<VectorSplat> splats;
};

// Calibration annotations live in projector space, so fitting the surface
// cannot move its target markers. Draw with the surface's layer order.
VectorScene make_pin_scene(const Rect &rect, int width, int height, int rotation) {
    VectorScene scene;
    if (rect.live || rect.overlay || rect.fold || rect.curvature.pins.empty()) return scene;
    const auto matrix = surface_curvature::quad_matrix(rect.corners);
    if (!matrix) return scene;
    const auto &h = *matrix;
    const float w = (rotation == 90 || rotation == 270) ? height : width;
    const float v = (rotation == 90 || rotation == 270) ? width : height;
    auto project = [&](const std::array<double,2> &p) {
        const double q = h[6]*p[0]+h[7]*p[1]+h[8];
        return VectorPoint{float((h[0]*p[0]+h[1]*p[1]+h[2])/q)*w,
                           float((h[3]*p[0]+h[4]*p[1]+h[5])/q)*v};
    };
    const auto center = project({.5,.5});
    const std::array<std::array<float,4>,4> colors{{
        {{.396f,.843f,1,1}}, {{1,.749f,.412f,1}},
        {{.769f,.627f,1,1}}, {{.486f,.867f,.659f,1}}
    }};
    // Seven-segment numerals stay legible as plain line primitives.
    const unsigned digits[] = {0x3f,0x06,0x5b,0x4f,0x66,0x6d,0x7d,0x07,0x7f,0x6f};
    const float strokes[7][4] = {{0,0,6,0},{6,0,6,6},{6,6,6,12},
        {0,12,6,12},{0,6,0,12},{0,0,0,6},{0,6,6,6}};
    for (std::size_t i=0; i<rect.curvature.pins.size(); ++i) {
        const auto &pin = rect.curvature.pins[i];
        const auto target = project(pin.target);
        const auto uv = surface_curvature::pin_uv(pin.side,pin.t);
        const auto actual = project(surface_curvature::point(uv[0],uv[1],rect.curvature));
        if (!std::isfinite(target.x) || !std::isfinite(target.y)
            || !std::isfinite(actual.x) || !std::isfinite(actual.y)) continue;
        const bool enabled = rect.curvature.pins_enabled && pin.enabled;
        VectorStyle style;
        style.core = enabled ? colors[pin.side] : std::array<float,4>{.48f,.5f,.54f,1};
        style.core_width = 2.0f/height;
        style.glow_width = 0;
        auto line = [&](float x1,float y1,float x2,float y2) {
            scene.segments.push_back({{x1/w,y1/v},{x2/w,y2/v},style,style});
        };
        const float dx=actual.x-target.x, dy=actual.y-target.y;
        const float distance=std::hypot(dx,dy);
        for(float d=0; d<distance; d+=9) {
            const float end=std::min(d+5,distance);
            line(target.x+dx*d/distance,target.y+dy*d/distance,
                 target.x+dx*end/distance,target.y+dy*end/distance);
        }
        if(distance>3) {
            line(actual.x-3,actual.y-3,actual.x+3,actual.y+3);
            line(actual.x-3,actual.y+3,actual.x+3,actual.y-3);
        }
        for(int s=0;s<24;++s) {
            if(!enabled && s%3==2)continue;
            const float a=s*6.2831853f/24, b=(s+1)*6.2831853f/24;
            line(target.x+8*std::cos(a),target.y+8*std::sin(a),
                 target.x+8*std::cos(b),target.y+8*std::sin(b));
        }
        line(target.x-4,target.y,target.x+4,target.y);
        line(target.x,target.y-4,target.x,target.y+4);
        const auto label=std::to_string(i+1);
        const float inward=std::max(1.0f,std::hypot(center.x-target.x,center.y-target.y));
        const float x=target.x+22*(center.x-target.x)/inward-(label.size()*10-4)/2;
        const float y=target.y+22*(center.y-target.y)/inward-6;
        for(std::size_t n=0;n<label.size();++n)
            for(int s=0;s<7;++s)if(digits[label[n]-'0']&(1<<s))
                line(x+n*10+strokes[s][0],y+strokes[s][1],
                     x+n*10+strokes[s][2],y+strokes[s][3]);
    }
    return scene;
}

VectorScene make_trace_scene(
    const Trace &trace, const std::vector<std::uint8_t> &rgb) {
    VectorScene scene;
    if (trace.points.size() < 2) return scene;

    std::vector<float> cumulative(trace.points.size(), 0.0f);
    for (std::size_t i = 1; i < trace.points.size(); ++i) {
        cumulative[i] = cumulative[i - 1] + std::hypot(
            trace.points[i][0] - trace.points[i - 1][0],
            trace.points[i][1] - trace.points[i - 1][1]);
    }
    const float total = cumulative.back();
    if (total <= 0.000001f) return scene;

    auto point_at = [&](float fraction) {
        const float distance = std::clamp(fraction, 0.0f, 1.0f) * total;
        const auto upper = std::upper_bound(
            cumulative.begin(), cumulative.end(), distance);
        const std::size_t end = std::clamp<std::size_t>(
            static_cast<std::size_t>(upper - cumulative.begin()),
            1, trace.points.size() - 1);
        const std::size_t start = end - 1;
        const float span = cumulative[end] - cumulative[start];
        const float amount =
            span > 0.000001f ? (distance - cumulative[start]) / span : 0.0f;
        return VectorPoint{
            trace.points[start][0]
                + (trace.points[end][0] - trace.points[start][0]) * amount,
            trace.points[start][1]
                + (trace.points[end][1] - trace.points[start][1]) * amount,
        };
    };

    const int pixels = std::max(2, trace.pixels);
    scene.segments.reserve(pixels);
    for (int i = 0; i < pixels; ++i) {
        const std::size_t offset = static_cast<std::size_t>(i) * 3;
        const float red = offset + 2 < rgb.size() ? rgb[offset] / 255.0f : 0.0f;
        const float green =
            offset + 2 < rgb.size() ? rgb[offset + 1] / 255.0f : 0.0f;
        const float blue =
            offset + 2 < rgb.size() ? rgb[offset + 2] / 255.0f : 0.0f;
        const float brightness = std::max({red, green, blue});
        if (brightness <= 0.001f) continue;

        VectorStyle style;
        // Colors are premultiplied because the analytic vector shader uses
        // premultiplied-alpha blending for both the crisp core and halo.
        style.core = {red, green, blue, brightness};
        style.glow = {
            red * trace.glow, green * trace.glow, blue * trace.glow,
            brightness * trace.glow,
        };
        style.core_width = trace.width;
        // The browser's trace ribbon is three core widths wide. Keep the
        // analytic halo inside the same footprint; feather changes edge
        // softness there, not the geometry's overall size.
        style.glow_width =
            trace.width * (0.25f + trace.glow * 0.75f);
        scene.segments.push_back({
            point_at(static_cast<float>(i) / pixels),
            point_at(static_cast<float>(i + 1) / pixels),
            style, style, true, true,
        });
    }
    return scene;
}

std::string wasmtime_error_text(wasmtime_error_t *error) {
    if (!error) return "";
    wasm_name_t message;
    wasmtime_error_message(error, &message);
    std::string text(message.data, message.size);
    wasm_name_delete(&message);
    wasmtime_error_delete(error);
    return text;
}

std::string wasmtime_trap_text(wasm_trap_t *trap) {
    if (!trap) return "";
    wasm_message_t message;
    wasm_trap_message(trap, &message);
    std::string text(message.data, message.size);
    wasm_byte_vec_delete(&message);
    wasm_trap_delete(trap);
    return text;
}

wasm_trap_t *vector_abort(
    void *, wasmtime_caller_t *, const wasmtime_val_t *,
    std::size_t, wasmtime_val_t *, std::size_t) {
    // AssemblyScript follows this import with `unreachable`, which turns the
    // guest failure into a Wasmtime trap. No host state is exposed.
    return nullptr;
}

wasm_engine_t *vector_wasm_engine() {
    static wasm_engine_t *engine = [] {
        wasm_config_t *config = wasm_config_new();
        wasmtime_config_consume_fuel_set(config, true);
        return wasm_engine_new_with_config(config);
    }();
    return engine;
}

class VectorWasmEffect {
public:
    VectorWasmEffect(
        const std::string &server, std::string module_path, int expected_abi)
        : module_path_(std::move(module_path)) {
        const auto bytes = read_http_bytes(server, module_path_);
        store_ = wasmtime_store_new(vector_wasm_engine(), nullptr, nullptr);
        if (!store_) throw std::runtime_error("could not create Wasmtime store");
        wasmtime_store_limiter(store_, 64 * 1024 * 1024, 10000, 1, 1, 1);
        context_ = wasmtime_store_context(store_);
        if (auto *error = wasmtime_context_set_fuel(context_, 5'000'000)) {
            throw std::runtime_error(
                "could not initialize vector WASM fuel: "
                + wasmtime_error_text(error));
        }

        wasmtime_module_t *module = nullptr;
        if (auto *error = wasmtime_module_new(
                vector_wasm_engine(), bytes.data(), bytes.size(), &module)) {
            throw std::runtime_error(
                "WASM compile failed: " + wasmtime_error_text(error));
        }

        wasm_valtype_vec_t abort_params;
        wasm_valtype_vec_new_uninitialized(&abort_params, 4);
        for (std::size_t i = 0; i < abort_params.size; ++i) {
            abort_params.data[i] = wasm_valtype_new_i32();
        }
        wasm_valtype_vec_t abort_results;
        wasm_valtype_vec_new_empty(&abort_results);
        wasm_functype_t *abort_type =
            wasm_functype_new(&abort_params, &abort_results);
        wasmtime_func_t abort_func;
        wasmtime_func_new(
            context_, abort_type, vector_abort, nullptr, nullptr, &abort_func);
        wasm_functype_delete(abort_type);
        wasmtime_extern_t imports[1]{};
        imports[0].kind = WASMTIME_EXTERN_FUNC;
        imports[0].of.func = abort_func;

        wasm_trap_t *trap = nullptr;
        wasmtime_error_t *error = wasmtime_instance_new(
            context_, module, imports, 1, &instance_, &trap);
        wasmtime_module_delete(module);
        if (error || trap) {
            throw std::runtime_error(
                "WASM instantiate failed: " + wasmtime_error_text(error)
                + wasmtime_trap_text(trap));
        }

        memory_ = exported("memory", WASMTIME_EXTERN_MEMORY).of.memory;
        abi_version_ = exported("abi_version", WASMTIME_EXTERN_FUNC).of.func;
        params_ptr_ = exported("params_ptr", WASMTIME_EXTERN_FUNC).of.func;
        params_capacity_ =
            exported("params_capacity", WASMTIME_EXTERN_FUNC).of.func;
        commands_ptr_ = exported("commands_ptr", WASMTIME_EXTERN_FUNC).of.func;
        commands_capacity_ =
            exported("commands_capacity", WASMTIME_EXTERN_FUNC).of.func;
        render_ = exported("render", WASMTIME_EXTERN_FUNC).of.func;

        abi_ = call_i32(abi_version_);
        if (abi_ != 1 && abi_ != 2) {
            throw std::runtime_error("unsupported vector WASM ABI");
        }
        if (abi_ != expected_abi) {
            throw std::runtime_error(
                "graphics recipe/module ABI mismatch");
        }
        param_offset_ = static_cast<std::uint32_t>(call_i32(params_ptr_));
        param_capacity_count_ = call_i32(params_capacity_);
        command_offset_ = static_cast<std::uint32_t>(call_i32(commands_ptr_));
        command_capacity_count_ = call_i32(commands_capacity_);
        if (param_capacity_count_ <= 0 || param_capacity_count_ > 32768
            || command_capacity_count_ <= 0
            || command_capacity_count_ > 1'000'000) {
            throw std::runtime_error("invalid vector WASM buffer capacity");
        }
        validate_memory(
            param_offset_, static_cast<std::size_t>(param_capacity_count_)
                               * sizeof(float));
        validate_memory(
            command_offset_, static_cast<std::size_t>(command_capacity_count_)
                                 * sizeof(float));
        std::cerr << "Vector WASM loaded: " << module_path_ << "\n";
    }

    ~VectorWasmEffect() {
        if (store_) wasmtime_store_delete(store_);
    }

    VectorWasmEffect(const VectorWasmEffect &) = delete;
    VectorWasmEffect &operator=(const VectorWasmEffect &) = delete;

    const std::string &module_path() const { return module_path_; }
    int abi() const { return abi_; }

    VectorScene evaluate(
        const std::vector<float> &params, double seconds, double beat) {
        if (params.size() > static_cast<std::size_t>(param_capacity_count_)) {
            throw std::runtime_error("vector recipe exceeds parameter capacity");
        }
        auto *memory = wasmtime_memory_data(context_, &memory_);
        auto *param_data = reinterpret_cast<float *>(memory + param_offset_);
        std::fill(
            param_data, param_data + param_capacity_count_, 0.0f);
        std::copy(params.begin(), params.end(), param_data);

        if (auto *error = wasmtime_context_set_fuel(context_, 5'000'000)) {
            throw std::runtime_error(
                "could not set vector WASM fuel: "
                + wasmtime_error_text(error));
        }
        wasmtime_val_t args[2]{};
        args[0].kind = WASMTIME_F64;
        args[0].of.f64 = seconds;
        args[1].kind = WASMTIME_F64;
        args[1].of.f64 = beat;
        wasmtime_val_t result{};
        result.kind = WASMTIME_I32;
        wasm_trap_t *trap = nullptr;
        wasmtime_error_t *error = wasmtime_func_call(
            context_, &render_, args, 2, &result, 1, &trap);
        if (error || trap) {
            throw std::runtime_error(
                "vector WASM render failed: " + wasmtime_error_text(error)
                + wasmtime_trap_text(trap));
        }
        const int used = result.of.i32;
        if (used < 0 || used > command_capacity_count_) {
            throw std::runtime_error("vector WASM returned invalid command size");
        }
        memory = wasmtime_memory_data(context_, &memory_);
        const auto *commands =
            reinterpret_cast<const float *>(memory + command_offset_);
        return parse_commands(
            commands, static_cast<std::size_t>(used), abi_);
    }

private:
    wasmtime_extern_t exported(
        const char *name, wasmtime_extern_kind_t expected) {
        wasmtime_extern_t item{};
        if (!wasmtime_instance_export_get(
                context_, &instance_, name, std::strlen(name), &item)
            || item.kind != expected) {
            throw std::runtime_error(
                "vector WASM missing export " + std::string(name));
        }
        return item;
    }

    int call_i32(const wasmtime_func_t &function) {
        if (auto *error = wasmtime_context_set_fuel(context_, 100'000)) {
            throw std::runtime_error(wasmtime_error_text(error));
        }
        wasmtime_val_t result{};
        result.kind = WASMTIME_I32;
        wasm_trap_t *trap = nullptr;
        wasmtime_error_t *error = wasmtime_func_call(
            context_, &function, nullptr, 0, &result, 1, &trap);
        if (error || trap) {
            throw std::runtime_error(
                wasmtime_error_text(error) + wasmtime_trap_text(trap));
        }
        return result.of.i32;
    }

    void validate_memory(std::uint32_t offset, std::size_t bytes) const {
        const std::size_t memory_size =
            wasmtime_memory_data_size(context_, &memory_);
        if (static_cast<std::size_t>(offset) + bytes > memory_size) {
            throw std::runtime_error("vector WASM buffer exceeds memory");
        }
    }

    static VectorScene parse_commands(
        const float *commands, std::size_t count, int abi) {
        VectorScene scene;
        VectorStyle style;
        VectorPoint current{}, start{};
        VectorStyle rich_style;
        VectorPoint rich_current{};
        bool have_rich_current = false;
        bool have_current = false;
        bool path_has_segment = false;
        std::size_t path_first_segment = 0;
        std::size_t cursor = 0;
        auto require = [&](std::size_t amount) {
            if (cursor + amount > count) {
                throw std::runtime_error("truncated vector command");
            }
        };
        auto value = [&]() {
            const float next = commands[cursor++];
            return std::isfinite(next) ? next : 0.0f;
        };
        auto read_style = [&]() {
            VectorStyle next;
            for (float &channel : next.core) channel = value();
            for (float &channel : next.glow) channel = value();
            next.core_width = std::max(0.0f, value());
            next.glow_width = std::max(0.0f, value());
            return next;
        };
        auto read_vertex = [&]() {
            const VectorPoint point{value(), value()};
            return std::pair{point, read_style()};
        };
        auto mix_value = [](float a, float b, float amount) {
            return a + (b - a) * amount;
        };
        auto mix_style = [&](const VectorStyle &a, const VectorStyle &b,
                             float amount) {
            VectorStyle mixed;
            for (int i = 0; i < 4; ++i) {
                mixed.core[i] = mix_value(a.core[i], b.core[i], amount);
                mixed.glow[i] = mix_value(a.glow[i], b.glow[i], amount);
            }
            mixed.core_width =
                mix_value(a.core_width, b.core_width, amount);
            mixed.glow_width =
                mix_value(a.glow_width, b.glow_width, amount);
            return mixed;
        };
        auto append_segment = [&](VectorPoint a, VectorPoint b,
                                  const VectorStyle &style_a,
                                  const VectorStyle &style_b) {
            if (path_has_segment) {
                scene.segments.back().path_end = false;
            }
            scene.segments.push_back({
                a, b, style_a, style_b, !path_has_segment, true});
            path_has_segment = true;
        };
        while (cursor < count) {
            const int op = static_cast<int>(value());
            if (op == 1) {
                require(10);
                for (float &channel : style.core) channel = value();
                for (float &channel : style.glow) channel = value();
                style.core_width = std::max(0.0f, value());
                style.glow_width = std::max(0.0f, value());
                have_current = false;
                have_rich_current = false;
                path_has_segment = false;
            } else if (op == 2) {
                require(2);
                current = {value(), value()};
                start = current;
                have_current = true;
                path_has_segment = false;
                path_first_segment = scene.segments.size();
            } else if (op == 3) {
                require(2);
                const VectorPoint next{value(), value()};
                if (have_current) {
                    append_segment(current, next, style, style);
                }
                current = next;
                have_current = true;
            } else if (op == 4) {
                if (have_current
                    && (current.x != start.x || current.y != start.y)) {
                    if (path_has_segment) {
                        scene.segments.back().path_end = false;
                        scene.segments[path_first_segment].path_start = false;
                    }
                    scene.segments.push_back({
                        current, start, style, style,
                        !path_has_segment, false});
                }
                current = start;
                path_has_segment = false;
            } else if (abi >= 2 && op == 5) {
                require(12);
                const auto vertex = read_vertex();
                rich_current = vertex.first;
                rich_style = vertex.second;
                have_rich_current = true;
                path_has_segment = false;
                path_first_segment = scene.segments.size();
            } else if (abi >= 2 && op == 6) {
                require(12);
                const auto vertex = read_vertex();
                if (have_rich_current) {
                    append_segment(
                        rich_current, vertex.first, rich_style, vertex.second);
                }
                rich_current = vertex.first;
                rich_style = vertex.second;
                have_rich_current = true;
            } else if (abi >= 2 && op == 7) {
                require(16);
                const VectorPoint control1{value(), value()};
                const VectorPoint control2{value(), value()};
                const auto vertex = read_vertex();
                if (have_rich_current) {
                    const VectorPoint curve_start = rich_current;
                    const VectorStyle curve_style = rich_style;
                    VectorPoint previous = curve_start;
                    VectorStyle previous_style = curve_style;
                    constexpr int pieces = 24;
                    for (int piece = 1; piece <= pieces; ++piece) {
                        const float t =
                            static_cast<float>(piece) / pieces;
                        const float u = 1.0f - t;
                        const VectorPoint point{
                            u * u * u * curve_start.x
                                + 3 * u * u * t * control1.x
                                + 3 * u * t * t * control2.x
                                + t * t * t * vertex.first.x,
                            u * u * u * curve_start.y
                                + 3 * u * u * t * control1.y
                                + 3 * u * t * t * control2.y
                                + t * t * t * vertex.first.y,
                        };
                        const VectorStyle sample_style =
                            mix_style(curve_style, vertex.second, t);
                        append_segment(
                            previous, point, previous_style, sample_style);
                        previous = point;
                        previous_style = sample_style;
                    }
                }
                rich_current = vertex.first;
                rich_style = vertex.second;
                have_rich_current = true;
            } else if (abi >= 2 && op == 8) {
                require(12);
                const auto vertex = read_vertex();
                scene.splats.push_back({vertex.first, vertex.second});
            } else {
                throw std::runtime_error(
                    "unknown vector opcode " + std::to_string(op));
            }
            if (scene.segments.size() + scene.splats.size() > 100'000) {
                throw std::runtime_error("vector scene segment limit exceeded");
            }
        }
        return scene;
    }

    std::string module_path_;
    wasmtime_store_t *store_ = nullptr;
    wasmtime_context_t *context_ = nullptr;
    wasmtime_instance_t instance_{};
    wasmtime_memory_t memory_{};
    wasmtime_func_t abi_version_{};
    wasmtime_func_t params_ptr_{};
    wasmtime_func_t params_capacity_{};
    wasmtime_func_t commands_ptr_{};
    wasmtime_func_t commands_capacity_{};
    wasmtime_func_t render_{};
    std::uint32_t param_offset_ = 0;
    std::uint32_t command_offset_ = 0;
    int param_capacity_count_ = 0;
    int command_capacity_count_ = 0;
    int abi_ = 1;
};


GLuint make_vector_program() {
    constexpr const char *vertex = R"GLSL(
        #version 330 core
        layout(location = 0) in vec2 position;
        layout(location = 1) in vec3 line_local;
        layout(location = 2) in vec4 core_color;
        layout(location = 3) in vec4 glow_color;
        layout(location = 4) in vec4 widths;
        out vec3 v_line_local;
        out vec4 v_core;
        out vec4 v_glow;
        out vec4 v_widths;
        void main() {
            gl_Position = vec4(position, 0.0, 1.0);
            v_line_local = line_local;
            v_core = core_color;
            v_glow = glow_color;
            v_widths = widths;
        }
    )GLSL";
    constexpr const char *fragment = R"GLSL(
        #version 330 core
        in vec3 v_line_local; // along, across, segment length in pixels
        in vec4 v_core;
        in vec4 v_glow;
        in vec4 v_widths;     // core diameter, glow radius, butt start/end
        uniform int vector_pass; // 0 = glow field, 1 = crisp core
        out vec4 color;
        void main() {
            float along = v_line_local.x;
            float across = v_line_local.y;
            float length_px = v_line_local.z;
            float cap = max(max(-along, along - length_px), 0.0);
            float distance_px = length(vec2(cap, across));
            float core_radius = max(v_widths.x * 0.5, 0.3);
            float aa = max(fwidth(distance_px), 0.7);
            float cap_mask = 1.0;
            if (v_widths.z > 0.5) {
                cap_mask *= smoothstep(-aa, aa, along);
            }
            if (v_widths.w > 0.5) {
                cap_mask *= smoothstep(-aa, aa, length_px - along);
            }
            float core = (1.0 - smoothstep(
                core_radius - aa, core_radius + aa, distance_px))
                * v_core.a * cap_mask;
            if (vector_pass == 0) {
                if (v_widths.y <= 0.0 || v_glow.a <= 0.0) discard;
                // Canvas2D's shadowBlur is substantially tighter than a
                // Gaussian whose sigma equals the UI radius. Model its wide
                // glow stroke plus an approximately half-radius blur.
                float glow_sigma = max(v_widths.y * 0.5, 0.001);
                float glow_stroke_radius =
                    core_radius + v_widths.y * 0.275;
                float glow_distance =
                    max(distance_px - glow_stroke_radius, 0.0);
                float halo = exp(
                    -0.5 * pow(glow_distance / glow_sigma, 2.0))
                    * v_glow.a * cap_mask;
                if (halo < 0.003) discard;
                color = vec4(v_glow.rgb * halo, halo);
                return;
            }
            if (core < 0.001) discard;
            color = vec4(v_core.rgb * core, core);
        }
    )GLSL";
    const GLuint vs = compile_shader(GL_VERTEX_SHADER, vertex);
    const GLuint fs = compile_shader(GL_FRAGMENT_SHADER, fragment);
    const GLuint program = glCreateProgram();
    glAttachShader(program, vs);
    glAttachShader(program, fs);
    glLinkProgram(program);
    glDeleteShader(vs);
    glDeleteShader(fs);
    GLint ok = GL_FALSE;
    glGetProgramiv(program, GL_LINK_STATUS, &ok);
    if (!ok) {
        GLint length = 0;
        glGetProgramiv(program, GL_INFO_LOG_LENGTH, &length);
        std::string log(static_cast<std::size_t>(std::max(length, 1)), '\0');
        glGetProgramInfoLog(program, length, nullptr, log.data());
        throw std::runtime_error("Vector shader link failed: " + log);
    }
    return program;
}


using Homography = std::array<double, 9>;

std::optional<Homography> solve_homography(
    const std::array<std::array<float, 2>, 4> &from,
    const std::array<std::array<float, 2>, 4> &to) {
    std::array<std::array<double, 9>, 8> rows{};
    for (int i = 0; i < 4; ++i) {
        const double x = from[i][0], y = from[i][1];
        const double u = to[i][0], v = to[i][1];
        rows[i * 2] = {x, y, 1, 0, 0, 0, -u * x, -u * y, u};
        rows[i * 2 + 1] = {0, 0, 0, x, y, 1, -v * x, -v * y, v};
    }
    std::array<double, 8> solved{};
    if (!solve_linear(rows, solved)) return std::nullopt;
    return Homography{
        solved[0], solved[1], solved[2],
        solved[3], solved[4], solved[5],
        solved[6], solved[7], 1.0,
    };
}

std::optional<VectorPoint> apply_homography(
    const Homography &h, VectorPoint point) {
    const double q = h[6] * point.x + h[7] * point.y + h[8];
    if (!std::isfinite(q) || std::abs(q) < 1e-9) return std::nullopt;
    const double x = (h[0] * point.x + h[1] * point.y + h[2]) / q;
    const double y = (h[3] * point.x + h[4] * point.y + h[5]) / q;
    if (!std::isfinite(x) || !std::isfinite(y)) return std::nullopt;
    return VectorPoint{static_cast<float>(x), static_cast<float>(y)};
}

bool clip_to_uv_quad(
    VectorPoint &a, VectorPoint &b,
    const std::array<std::array<float, 2>, 4> &polygon) {
    double area = 0.0;
    for (int i = 0; i < 4; ++i) {
        const auto &p = polygon[i];
        const auto &q = polygon[(i + 1) % 4];
        area += p[0] * q[1] - q[0] * p[1];
    }
    if (std::abs(area) < 1e-9) return false;
    const double sign = area > 0 ? 1.0 : -1.0;
    double low = 0.0, high = 1.0;
    const VectorPoint delta{b.x - a.x, b.y - a.y};
    for (int i = 0; i < 4; ++i) {
        const auto &p = polygon[i];
        const auto &q = polygon[(i + 1) % 4];
        const double ex = q[0] - p[0], ey = q[1] - p[1];
        auto inside = [&](VectorPoint point) {
            return sign * (ex * (point.y - p[1])
                           - ey * (point.x - p[0]));
        };
        const double fa = inside(a);
        const double fb = inside(b);
        if (fa < 0 && fb < 0) return false;
        if ((fa < 0) != (fb < 0)) {
            const double t = fa / (fa - fb);
            if (fa < 0) low = std::max(low, t);
            else high = std::min(high, t);
        }
    }
    if (low > high) return false;
    b = {a.x + delta.x * static_cast<float>(high),
         a.y + delta.y * static_cast<float>(high)};
    a = {a.x + delta.x * static_cast<float>(low),
         a.y + delta.y * static_cast<float>(low)};
    return true;
}

struct VectorGpuVertex {
    float position[2];
    float line_local[3];
    float core[4];
    float glow[4];
    float widths[4];
};

std::array<float, 3> parse_hex_color(const std::string &text) {
    if (text.size() != 7 || text[0] != '#') return {1, 1, 1};
    try {
        return {
            static_cast<float>(std::stoi(text.substr(1, 2), nullptr, 16)) / 255,
            static_cast<float>(std::stoi(text.substr(3, 2), nullptr, 16)) / 255,
            static_cast<float>(std::stoi(text.substr(5, 2), nullptr, 16)) / 255,
        };
    } catch (...) {
        return {1, 1, 1};
    }
}

void apply_master_color(
    std::array<float, 4> &color, const VectorMaster &master) {
    if (master.invert) {
        for (int i = 0; i < 3; ++i) color[i] = 1.0f - color[i];
    }
    if (!master.cast.empty() && master.cast_amount > 0) {
        const auto cast = parse_hex_color(master.cast);
        const float luminance =
            color[0] * 0.299f + color[1] * 0.587f + color[2] * 0.114f;
        for (int i = 0; i < 3; ++i) {
            color[i] +=
                (luminance * cast[i] - color[i]) * master.cast_amount;
        }
    }
}

float vector_master_gain(
    const VectorRecipe &recipe, Clock::time_point now) {
    if (recipe.master.mute || recipe.master.blackout) return 0.0f;
    const double elapsed = recipe.playing
        ? std::chrono::duration<double>(now - recipe.received_at).count() : 0.0;
    const double beat =
        recipe.master.global_beat + elapsed * recipe.bpm / 60.0;
    float gain = std::clamp(recipe.master.gain, 0.0f, 1.0f);
    if (recipe.master.pulse) {
        gain *= 0.25f + 0.75f
            * std::exp(-static_cast<float>(
                beat - std::floor(beat)) * 5.0f);
    }
    if (recipe.master.strobe
        && std::fmod(beat * 2.0, 1.0) >= 0.5) {
        gain = 0.0f;
    }
    return gain;
}

void append_vector_rect(
    const VectorScene &scene, const VectorRecipe &recipe, const Rect &rect,
    int drawable_width, int drawable_height, int rotation,
    std::vector<VectorGpuVertex> &vertices,
    std::vector<std::uint32_t> &indices) {
    if(rect.fold && rect.corners.size()==6 && rect.uvs.size()==6){
        for(const auto &panel : std::array<std::array<int,4>,2>{{{{0,1,4,5}},{{1,2,3,4}}}}){
            Rect part=rect;part.fold=false;part.corners.clear();part.uvs.clear();
            for(int i:panel){part.corners.push_back(rect.corners[i]);part.uvs.push_back(rect.uvs[i]);}
            append_vector_rect(scene,recipe,part,drawable_width,drawable_height,rotation,vertices,indices);
        }
        return;
    }
    if (rect.corners.size() != 4 || rect.uvs.size() != 4) return;
    std::array<std::array<float, 2>, 4> corners{};
    std::array<std::array<float, 2>, 4> uvs{};
    std::copy_n(rect.corners.begin(), 4, corners.begin());
    std::copy_n(rect.uvs.begin(), 4, uvs.begin());
    const auto homography = solve_homography(uvs, corners);
    if (!homography) return;
    const std::array<std::array<float,2>,4> unit{{{{0,0}},{{1,0}},{{1,1}},{{0,1}}}};
    const auto to_unit=solve_homography(uvs,unit),to_screen=solve_homography(unit,corners);
    auto map_point=[&](VectorPoint p)->std::optional<VectorPoint>{
        if(!rect.curved)return apply_homography(*homography,p);
        if(!to_unit||!to_screen)return std::nullopt;
        const auto local=apply_homography(*to_unit,p);if(!local)return std::nullopt;
        const auto bent=surface_curvature::source_point(local->x,local->y,rect.curvature);
        return apply_homography(*to_screen,{float(bent[0]),float(bent[1])});
    };
    auto mix_style=[](const VectorStyle& a,const VectorStyle& b,float t){
        VectorStyle result;
        for(int i=0;i<4;i++){result.core[i]=a.core[i]+(b.core[i]-a.core[i])*t;result.glow[i]=a.glow[i]+(b.glow[i]-a.glow[i])*t;}
        result.core_width=a.core_width+(b.core_width-a.core_width)*t;
        result.glow_width=a.glow_width+(b.glow_width-a.glow_width)*t;
        return result;
    };

    float scale_x = 1.0f, scale_y = 1.0f;
    if (rect.fit != "stretch") {
        float min_x = 1, max_x = 0, min_y = 1, max_y = 0;
        for (const auto &corner : rect.corners) {
            min_x = std::min(min_x, corner[0]);
            max_x = std::max(max_x, corner[0]);
            min_y = std::min(min_y, corner[1]);
            max_y = std::max(max_y, corner[1]);
        }
        const float box_w =
            std::max((max_x - min_x) * drawable_width, 0.001f);
        const float box_h =
            std::max((max_y - min_y) * drawable_height, 0.001f);
        const float ratio =
            (static_cast<float>(recipe.canvas_width) / recipe.canvas_height)
            * (box_h / box_w);
        if (rect.fit == "fit") {
            if (ratio >= 1) scale_y = 1.0f / ratio;
            else scale_x = ratio;
        } else if (rect.fit == "fill") {
            if (ratio >= 1) scale_x = ratio;
            else scale_y = 1.0f / ratio;
        }
    }

    const float gain =
        vector_master_gain(recipe, Clock::now()) * recipe.opacity;
    if (gain <= 0.0001f) return;

    for (const auto &source_segment : scene.segments) {
        VectorPoint a{
            source_segment.a.x * scale_x + (1 - scale_x) * 0.5f,
            (1 - source_segment.a.y) * scale_y + (1 - scale_y) * 0.5f,
        };
        VectorPoint b{
            source_segment.b.x * scale_x + (1 - scale_x) * 0.5f,
            (1 - source_segment.b.y) * scale_y + (1 - scale_y) * 0.5f,
        };
        if (!clip_to_uv_quad(a, b, uvs)) continue;
        int pieces=1;
        if(rect.curved&&to_unit){
            const auto la=apply_homography(*to_unit,a),lb=apply_homography(*to_unit,b);
            if(!la||!lb)continue;
            pieces=std::clamp(int(std::ceil(std::max(std::abs(lb->x-la->x),std::abs(lb->y-la->y))*surface_curvature::steps)),1,64);
        }
        for(int piece=0;piece<pieces;piece++){
        const float t0=float(piece)/pieces,t1=float(piece+1)/pieces;
        auto segment=source_segment;
        segment.style_a=mix_style(source_segment.style_a,source_segment.style_b,t0);
        segment.style_b=mix_style(source_segment.style_a,source_segment.style_b,t1);
        segment.path_start=source_segment.path_start&&piece==0;
        segment.path_end=source_segment.path_end&&piece==pieces-1;
        auto mapped_a = map_point({a.x+(b.x-a.x)*t0,a.y+(b.y-a.y)*t0});
        auto mapped_b = map_point({a.x+(b.x-a.x)*t1,a.y+(b.y-a.y)*t1});
        if (!mapped_a || !mapped_b) continue;
        const auto rotated_a = rotate_output_uv({mapped_a->x, mapped_a->y}, rotation);
        const auto rotated_b = rotate_output_uv({mapped_b->x, mapped_b->y}, rotation);
        mapped_a->x = rotated_a[0]; mapped_a->y = rotated_a[1];
        mapped_b->x = rotated_b[0]; mapped_b->y = rotated_b[1];
        const float ax = mapped_a->x * drawable_width;
        const float ay = mapped_a->y * drawable_height;
        const float bx = mapped_b->x * drawable_width;
        const float by = mapped_b->y * drawable_height;
        const float dx = bx - ax, dy = by - ay;
        const float length = std::hypot(dx, dy);
        if (length < 0.01f) continue;
        const float tx = dx / length, ty = dy / length;
        const float nx = -ty, ny = tx;
        const float core_width_a =
            std::max(0.6f, segment.style_a.core_width * drawable_height);
        const float core_width_b =
            std::max(0.6f, segment.style_b.core_width * drawable_height);
        const float glow_width_a =
            std::max(0.0f, segment.style_a.glow_width * drawable_height);
        const float glow_width_b =
            std::max(0.0f, segment.style_b.glow_width * drawable_height);
        const float max_core_width =
            std::max(core_width_a, core_width_b);
        const float max_glow_width =
            std::max(glow_width_a, glow_width_b);
        const float outer =
            std::max(max_core_width * 0.5f + 1.5f,
                     max_core_width * 0.5f + max_glow_width * 1.85f);
        const float start_outer =
            recipe.line_cap == "butt" && segment.path_start ? 1.5f : outer;
        const float end_outer =
            recipe.line_cap == "butt" && segment.path_end ? 1.5f : outer;
        std::array<float, 4> core_a = segment.style_a.core;
        std::array<float, 4> core_b = segment.style_b.core;
        std::array<float, 4> glow_a = segment.style_a.glow;
        std::array<float, 4> glow_b = segment.style_b.glow;
        apply_master_color(core_a, recipe.master);
        apply_master_color(core_b, recipe.master);
        apply_master_color(glow_a, recipe.master);
        apply_master_color(glow_b, recipe.master);
        core_a[3] *= gain;
        core_b[3] *= gain;
        glow_a[3] *= gain;
        glow_b[3] *= gain;

        const std::uint32_t first =
            static_cast<std::uint32_t>(vertices.size());
        const std::array<std::array<float, 4>, 4> corners{{
            {{ax - tx * start_outer + nx * outer,
              ay - ty * start_outer + ny * outer, -start_outer, outer}},
            {{ax - tx * start_outer - nx * outer,
              ay - ty * start_outer - ny * outer, -start_outer, -outer}},
            {{bx + tx * end_outer + nx * outer,
              by + ty * end_outer + ny * outer, length + end_outer, outer}},
            {{bx + tx * end_outer - nx * outer,
              by + ty * end_outer - ny * outer, length + end_outer, -outer}},
        }};
        for (std::size_t corner_index = 0;
             corner_index < corners.size(); ++corner_index) {
            const auto &corner = corners[corner_index];
            const bool at_end = corner_index >= 2;
            const auto &core = at_end ? core_b : core_a;
            const auto &glow = at_end ? glow_b : glow_a;
            VectorGpuVertex vertex{};
            vertex.position[0] = corner[0] / drawable_width * 2 - 1;
            vertex.position[1] = -(corner[1] / drawable_height * 2 - 1);
            vertex.line_local[0] = corner[2];
            vertex.line_local[1] = corner[3];
            vertex.line_local[2] = length;
            std::copy(core.begin(), core.end(), vertex.core);
            std::copy(glow.begin(), glow.end(), vertex.glow);
            vertex.widths[0] =
                at_end ? core_width_b : core_width_a;
            vertex.widths[1] =
                at_end ? glow_width_b : glow_width_a;
            vertex.widths[2] =
                recipe.line_cap == "butt" && segment.path_start ? 1.0f : 0.0f;
            vertex.widths[3] =
                recipe.line_cap == "butt" && segment.path_end ? 1.0f : 0.0f;
            vertices.push_back(vertex);
        }
        indices.insert(indices.end(), {
            first, first + 1, first + 2,
            first + 1, first + 3, first + 2,
        });
    }

    } // segment subdivisions

    for (const auto &splat : scene.splats) {
        VectorPoint point{
            splat.point.x * scale_x + (1 - scale_x) * 0.5f,
            (1 - splat.point.y) * scale_y + (1 - scale_y) * 0.5f,
        };
        VectorPoint clipped = point;
        if (!clip_to_uv_quad(point, clipped, uvs)) continue;
        auto mapped = map_point(point);
        if (!mapped) continue;
        const auto rotated = rotate_output_uv({mapped->x, mapped->y}, rotation);
        mapped->x = rotated[0]; mapped->y = rotated[1];
        const float center_x = mapped->x * drawable_width;
        const float center_y = mapped->y * drawable_height;
        const float core_width =
            std::max(0.6f, splat.style.core_width * drawable_height);
        const float glow_width =
            std::max(0.0f, splat.style.glow_width * drawable_height);
        const float outer =
            std::max(core_width * 0.5f + 1.5f,
                     core_width * 0.5f + glow_width * 1.85f);
        std::array<float, 4> core = splat.style.core;
        std::array<float, 4> glow = splat.style.glow;
        apply_master_color(core, recipe.master);
        apply_master_color(glow, recipe.master);
        core[3] *= gain;
        glow[3] *= gain;

        const std::uint32_t first =
            static_cast<std::uint32_t>(vertices.size());
        const std::array<std::array<float, 4>, 4> corners{{
            {{center_x - outer, center_y - outer, -outer, -outer}},
            {{center_x - outer, center_y + outer, -outer, outer}},
            {{center_x + outer, center_y - outer, outer, -outer}},
            {{center_x + outer, center_y + outer, outer, outer}},
        }};
        for (const auto &corner : corners) {
            VectorGpuVertex vertex{};
            vertex.position[0] = corner[0] / drawable_width * 2 - 1;
            vertex.position[1] = -(corner[1] / drawable_height * 2 - 1);
            vertex.line_local[0] = corner[2];
            vertex.line_local[1] = corner[3];
            vertex.line_local[2] = 0;
            std::copy(core.begin(), core.end(), vertex.core);
            std::copy(glow.begin(), glow.end(), vertex.glow);
            vertex.widths[0] = core_width;
            vertex.widths[1] = glow_width;
            vertex.widths[2] = 0;
            vertex.widths[3] = 0;
            vertices.push_back(vertex);
        }
        indices.insert(indices.end(), {
            first, first + 1, first + 2,
            first + 1, first + 3, first + 2,
        });
    }
}

void set_vector_blend(const std::string &blend, bool glow_pass) {
    glEnable(GL_BLEND);
    // Merge connected segment halos with MAX so a cube corner is one coherent
    // light field rather than three order-dependent translucent end caps.
    glBlendEquation(
        glow_pass && blend == "normal" ? GL_MAX : GL_FUNC_ADD);
    if (blend == "add") {
        glBlendFunc(GL_ONE, GL_ONE);
    } else if (blend == "subtract") {
        glBlendEquationSeparate(GL_FUNC_REVERSE_SUBTRACT, GL_FUNC_ADD);
        glBlendFuncSeparate(GL_ONE, GL_ONE, GL_ZERO, GL_ONE);
    } else if (blend == "screen") {
        glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_COLOR);
    } else if (blend == "multiply") {
        glBlendFunc(GL_DST_COLOR, GL_ZERO);
    } else {
        glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
    }
}

struct GpuFrame {
    GLuint texture = 0;
    int width = 0;
    int height = 0;
};

struct Options {
    bool list_displays = false;
    std::string server = "127.0.0.1:9100";
    int mapping = 1;
    int display = 0;
    int display2 = 1;
    std::vector<int> display_ids;
    bool swap_mappings = false;
    bool windowed = false;
    int width = 1280;
    int height = 720;
};

void usage(const char *name) {
    std::cerr << "Usage: " << name
              << " [--server HOST:PORT] [--mapping 1|2|3|4] [--display N]"
                 " [--mapping 0 --display N --display2 N] [--displays 0,1,2,3] [--swap-mappings]"
                 " [--windowed WIDTHxHEIGHT] [--list-displays]\n";
}

std::optional<Options> parse_options(int argc, char **argv) {
    Options options;
    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        if (arg == "--list-displays") {
            options.list_displays = true;
        } else if (arg == "--server" && i + 1 < argc) {
            options.server = argv[++i];
        } else if (arg == "--mapping" && i + 1 < argc) {
            options.mapping = std::stoi(argv[++i]);
        } else if (arg == "--display" && i + 1 < argc) {
            options.display = std::stoi(argv[++i]);
        } else if (arg == "--display2" && i + 1 < argc) {
            options.display2 = std::stoi(argv[++i]);
        } else if (arg == "--displays" && i + 1 < argc) {
            std::stringstream list(argv[++i]);std::string item;
            while(std::getline(list,item,',')) {
                const auto value=std::stoi(item);
                if(value<0 || std::find(options.display_ids.begin(),options.display_ids.end(),value)!=options.display_ids.end()) return std::nullopt;
                options.display_ids.push_back(value);
            }
            if(options.display_ids.empty() || options.display_ids.size()>4)return std::nullopt;
            options.display=options.display_ids[0];
            if(options.display_ids.size()>1){options.mapping=0;options.display2=options.display_ids[1];}
        } else if (arg == "--swap-mappings") {
            options.swap_mappings = true;
        } else if (arg == "--windowed" && i + 1 < argc) {
            options.windowed = true;
            const std::string size = argv[++i];
            const auto x = size.find('x');
            if (x == std::string::npos) return std::nullopt;
            options.width = std::stoi(size.substr(0, x));
            options.height = std::stoi(size.substr(x + 1));
        } else if (arg == "--help" || arg == "-h") {
            usage(argv[0]);
            std::exit(0);
        } else {
            return std::nullopt;
        }
    }
    if (options.mapping < 0 || options.mapping > 4 || options.display < 0
        || options.display2 < 0
        || options.width < 64 || options.height < 64) {
        return std::nullopt;
    }
    return options;
}


int main(int argc, char **argv) {
    // The VJ app owns these windows; standalone renderer invocations remain independent.
    const char* launcher_env = std::getenv("VIBE_LAUNCHER_PID");
    const pid_t launcher_pid = launcher_env ? static_cast<pid_t>(std::atoi(launcher_env)) : 0;
    const auto parsed = parse_options(argc, argv);
    if (!parsed) {
        usage(argv[0]);
        return 2;
    }
    const Options options = *parsed;

    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS
                 | (options.list_displays ? 0 : SDL_INIT_AUDIO)) != 0) {
        std::cerr << "SDL initialization failed: " << SDL_GetError() << "\n";
        return 1;
    }
    if (options.list_displays) {
        json items = json::array();
        for (int i = 0; i < SDL_GetNumVideoDisplays(); ++i) {
            SDL_Rect bounds{};
            SDL_GetDisplayBounds(i, &bounds);
            const char *name = SDL_GetDisplayName(i);
            items.push_back({{"id", i}, {"name", name ? name : "Display"},
                             {"width", bounds.w}, {"height", bounds.h}});
        }
        std::cout << items.dump() << "\n";
        SDL_Quit();
        return 0;
    }
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);
    SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
    SDL_GL_SetAttribute(SDL_GL_STENCIL_SIZE, 8);

    const int displays = SDL_GetNumVideoDisplays();
    const std::vector<int> physical_displays = !options.display_ids.empty() ? options.display_ids
        : options.mapping==0 ? std::vector<int>{options.display,options.display2} : std::vector<int>{options.display};
    std::vector<int> physical_mappings;
    for(std::size_t i=0;i<physical_displays.size();++i)
        physical_mappings.push_back(options.mapping==0 ? (options.swap_mappings && i<2 ? 2-static_cast<int>(i) : static_cast<int>(i)+1) : options.mapping);
    for(const auto display:physical_displays)if(display>=displays){std::cerr<<"Display unavailable: "<<display<<"\n";return 1;}
    if (options.display >= displays
        || (options.mapping == 0 && options.display2 >= displays)) {
        std::cerr << "Display " << options.display << " unavailable; SDL found "
                  << displays << " display(s).\n";
        return 1;
    }
    for (int i = 0; i < displays; ++i) {
        SDL_Rect bounds{};
        SDL_GetDisplayBounds(i, &bounds);
        const char *display_name = SDL_GetDisplayName(i);
        std::cerr << "SDL display " << i << ": " << (display_name ? display_name : "Unavailable")
                  << " " << bounds.w << "x" << bounds.h << " at "
                  << bounds.x << "," << bounds.y << "\n";
    }

    SDL_Rect bounds{};
    SDL_GetDisplayBounds(options.display, &bounds);
    SDL_Rect bounds2{};
    if (options.mapping == 0) {
        SDL_GetDisplayBounds(options.display2, &bounds2);
    }
    std::vector<SDL_Rect> physical_bounds;
    int union_left=bounds.x,union_top=bounds.y,union_right=bounds.x+bounds.w,union_bottom=bounds.y+bounds.h;
    for(const auto display:physical_displays) {
        SDL_Rect area{};SDL_GetDisplayBounds(display,&area);physical_bounds.push_back(area);
        union_left=std::min(union_left,area.x);union_top=std::min(union_top,area.y);
        union_right=std::max(union_right,area.x+area.w);union_bottom=std::max(union_bottom,area.y+area.h);
    }
    const int width = options.windowed ? options.width*physical_displays.size() : union_right-union_left;
    const int height = options.windowed
        ? options.height : union_bottom - union_top;
    const int x = options.windowed ? SDL_WINDOWPOS_CENTERED : union_left;
    const int y = options.windowed ? SDL_WINDOWPOS_CENTERED : union_top;
    const std::string title = options.mapping == 0
        ? "Vibe Native Render Projectors"
        : "Vibe Native Render " + std::to_string(options.mapping);
    Uint32 flags = SDL_WINDOW_OPENGL | SDL_WINDOW_SHOWN | SDL_WINDOW_ALLOW_HIGHDPI;
    if (!options.windowed) flags |= SDL_WINDOW_BORDERLESS;
    SDL_Window *window = SDL_CreateWindow(
        title.c_str(), x, y, width, height, flags);
    if (!window) {
        std::cerr << "Window creation failed: " << SDL_GetError() << "\n";
        return 1;
    }
    if (!options.windowed && options.mapping != 0) {
        SDL_SetWindowFullscreen(window, SDL_WINDOW_FULLSCREEN_DESKTOP);
    }
    SDL_GLContext context = SDL_GL_CreateContext(window);
    if (!context) {
        std::cerr << "OpenGL context failed: " << SDL_GetError() << "\n";
        return 1;
    }
    SDL_GL_MakeCurrent(window, context);
    SDL_GL_SetSwapInterval(1);
    SDL_ShowCursor(options.windowed ? SDL_ENABLE : SDL_DISABLE);
    std::optional<SDL_DisplayMode> movie_display_mode;
    if (!options.windowed && options.mapping != 0) {
        movie_display_mode = cinema_display_mode(options.display, bounds);
        if (movie_display_mode) {
            std::cerr << "Movie mode available: "
                      << movie_display_mode->w << "x"
                      << movie_display_mode->h << "@"
                      << movie_display_mode->refresh_rate << "Hz\n";
        } else {
            std::cerr << "Movie mode unavailable: display "
                      << options.display
                      << " has no native-resolution 24Hz mode\n";
        }
    }

    GLuint program = 0;
    GLuint vector_program = 0;
    try {
        program = make_program();
        vector_program = make_vector_program();
    } catch (const std::exception &error) {
        std::cerr << error.what() << "\n";
        return 1;
    }
    GLuint vao = 0, vbo = 0, ebo = 0;
    glGenVertexArrays(1, &vao);
    glGenBuffers(1, &vbo);
    glGenBuffers(1, &ebo);
    glBindVertexArray(vao);
    glBindBuffer(GL_ARRAY_BUFFER, vbo);
    glBufferData(GL_ARRAY_BUFFER, sizeof(float) * 20, nullptr, GL_DYNAMIC_DRAW);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, sizeof(float) * 5,
                          reinterpret_cast<void *>(0));
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, sizeof(float) * 5,
                          reinterpret_cast<void *>(sizeof(float) * 2));
    glEnableVertexAttribArray(1);
    constexpr std::array<unsigned int, 6> indices{{0, 1, 2, 0, 2, 3}};
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, ebo);
    glBufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof(indices), indices.data(), GL_STATIC_DRAW);

    GLuint vector_vao = 0, vector_vbo = 0, vector_ebo = 0;
    glGenVertexArrays(1, &vector_vao);
    glGenBuffers(1, &vector_vbo);
    glGenBuffers(1, &vector_ebo);
    glBindVertexArray(vector_vao);
    glBindBuffer(GL_ARRAY_BUFFER, vector_vbo);
    glVertexAttribPointer(
        0, 2, GL_FLOAT, GL_FALSE, sizeof(VectorGpuVertex),
        reinterpret_cast<void *>(offsetof(VectorGpuVertex, position)));
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(
        1, 3, GL_FLOAT, GL_FALSE, sizeof(VectorGpuVertex),
        reinterpret_cast<void *>(offsetof(VectorGpuVertex, line_local)));
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(
        2, 4, GL_FLOAT, GL_FALSE, sizeof(VectorGpuVertex),
        reinterpret_cast<void *>(offsetof(VectorGpuVertex, core)));
    glEnableVertexAttribArray(2);
    glVertexAttribPointer(
        3, 4, GL_FLOAT, GL_FALSE, sizeof(VectorGpuVertex),
        reinterpret_cast<void *>(offsetof(VectorGpuVertex, glow)));
    glEnableVertexAttribArray(3);
    glVertexAttribPointer(
        4, 4, GL_FLOAT, GL_FALSE, sizeof(VectorGpuVertex),
        reinterpret_cast<void *>(offsetof(VectorGpuVertex, widths)));
    glEnableVertexAttribArray(4);
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, vector_ebo);

    Runtime *runtime = new Runtime;
    runtime->server = options.server;
    runtime->mapping = options.mapping == 0
        ? (options.swap_mappings ? 2 : 1) : options.mapping;
    std::thread(state_worker, runtime).detach();
    Runtime *secondary_runtime = nullptr;
    if (options.mapping == 0) {
        secondary_runtime = new Runtime;
        secondary_runtime->server = options.server;
        secondary_runtime->mapping = options.swap_mappings ? 1 : 2;
        std::thread(state_worker, secondary_runtime).detach();
    }
    std::thread(led_worker, runtime).detach();
    std::thread(renderer_state_worker, runtime).detach();
    auto *calibration=new CalibrationControl;
    std::thread(calibration_worker,runtime,calibration).detach();
    MonitorFramePublisher calibration_camera("calibration-camera");
    std::map<std::string,std::unique_ptr<MonitorFramePublisher>> mapping_monitors;
    std::map<std::string,Clock::time_point> mapping_monitor_times;
    auto publish_mapping=[&](const Project &project,int mid,const SDL_Rect &viewport,const std::string &transport){
        if(transport!="room"&&!std::any_of(project.rects.begin(),project.rects.end(),[](const Rect &r){return !r.native_bus.empty();}))return;
        const auto name="mapping-"+std::to_string(mid)+"-"+transport;
        const auto now=Clock::now();if(now<mapping_monitor_times[name])return;
        mapping_monitor_times[name]=now+std::chrono::milliseconds(100);
        auto &publisher=mapping_monitors[name];if(!publisher)publisher=std::make_unique<MonitorFramePublisher>(name);
        std::vector<std::uint8_t> pixels(viewport.w*viewport.h*3),rgb(pixels.size());
        GLint pack=0;glGetIntegerv(GL_PIXEL_PACK_BUFFER_BINDING,&pack);glBindBuffer(GL_PIXEL_PACK_BUFFER,0);glPixelStorei(GL_PACK_ALIGNMENT,1);
        glReadPixels(viewport.x,viewport.y,viewport.w,viewport.h,GL_RGB,GL_UNSIGNED_BYTE,pixels.data());
        glBindBuffer(GL_PIXEL_PACK_BUFFER,pack);
        const auto stride=static_cast<std::size_t>(viewport.w)*3;
        for(int y=0;y<viewport.h;++y)std::copy_n(pixels.data()+y*stride,stride,rgb.data()+(viewport.h-1-y)*stride);
        publisher->publish(rgb,viewport.w,viewport.h);
    };
    std::uint64_t calibration_sequence=0;
    std::string calibration_device;
    const auto calibration_instance=std::to_string(Clock::now().time_since_epoch().count());

    std::array<GpuFrame, kMaxOutputs> gpu_frames{};
    for (auto &gpu : gpu_frames) {
        glGenTextures(1, &gpu.texture);
        glBindTexture(GL_TEXTURE_2D, gpu.texture);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    }

    const bool publish_projectors=options.mapping==0 || options.mapping==1;
    std::array<Runtime*,4> projector_runtimes{};
    projector_runtimes[runtime->mapping-1]=runtime;
    if(secondary_runtime)projector_runtimes[secondary_runtime->mapping-1]=secondary_runtime;
    if(publish_projectors) for(int i=0;i<4;++i) if(!projector_runtimes[i]) {
        auto *subscriber=new Runtime;
        subscriber->server=options.server;subscriber->mapping=i+1;
        projector_runtimes[i]=subscriber;
        std::thread(state_worker,subscriber).detach();
    }
    std::map<std::string,std::unique_ptr<ProjectorNdiOutput>> ndi_projectors;
    std::map<std::string,std::unique_ptr<RoomPreviewTarget>> room_targets;
    auto native_graph = std::make_unique<NativeRenderGraph>();
    std::uint64_t applied_native_scene = 0;
    std::map<std::string, std::unique_ptr<MonitorFramePublisher>> monitor_publishers;
    std::map<std::string, Clock::time_point> next_monitor_frame;
    std::cerr << "Native FFmpeg/OpenGL render graph active\n";

    glUseProgram(program);
    glUniform1i(glGetUniformLocation(program, "frame_texture"), 0);
    const GLint scale_location = glGetUniformLocation(program, "destination_scale");
    const GLint texture_location = glGetUniformLocation(program, "use_texture");
    const GLint overlay_location = glGetUniformLocation(program, "overlay_grid");
    const GLint plane_extent_location=glGetUniformLocation(program,"plane_extent");
    const GLint plane_circle_location=glGetUniformLocation(program,"plane_circle");
    const GLint vector_pass_location =
        glGetUniformLocation(vector_program, "vector_pass");

    struct LayerVectorState {
        std::unique_ptr<VectorWasmEffect> effect;
        std::string error;
        std::uint64_t error_revision = 0;
    };
    std::map<std::string, LayerVectorState> layer_vectors;
    std::array<std::unique_ptr<VectorWasmEffect>, kMaxOutputs> vector_effects{};
    std::array<std::optional<VectorScene>, kMaxOutputs> vector_scenes{};
    std::array<std::string, kMaxOutputs> vector_errors{};
    std::array<std::string, kMaxOutputs> vector_error_keys{};
    std::array<std::uint64_t, kMaxOutputs> vector_frames{};
    std::array<std::uint64_t, kMaxOutputs> vector_at{};

    bool running = true;
    const auto startup_at = Clock::now();
    auto stats_at = Clock::now();
    auto next_present_frame = Clock::now();
    double scene_present_fps = 30.0;
    bool movie_mode_active = false;
    double movie_source_fps = 0.0;
    std::optional<double> pending_movie_fps;
    std::optional<Clock::time_point> movie_candidate_at;
    std::uint64_t presented = 0;
    json renderer_metrics = json::object();
    std::uint64_t metrics_sequence = 0;
    std::uint64_t led_at = 0;

    while (running) {
        if (launcher_pid > 0 && getppid() != launcher_pid) {
            std::cerr << "Launcher exited; stopping renderer.\n";
            break;
        }
        SDL_Event event{};
        while (SDL_PollEvent(&event)) {
            if (event.type == SDL_QUIT
                || (event.type == SDL_KEYDOWN && event.key.keysym.sym == SDLK_ESCAPE)) {
                running = false;
            }
        }

        Project primary_project;
        {
            std::lock_guard lock(runtime->project_mutex);
            primary_project = runtime->project;
        }
        Project secondary_project;
        if (secondary_runtime) {
            std::lock_guard lock(secondary_runtime->project_mutex);
            secondary_project = secondary_runtime->project;
        }
        std::vector<Project> render_projects;
        for(const auto id:physical_mappings) {
            const auto subscriber=projector_runtimes.at(id-1);
            std::lock_guard lock(subscriber->project_mutex);render_projects.push_back(subscriber->project);
        }
        const auto mode_now = Clock::now();
        std::optional<double> requested_movie_fps;
        if (movie_display_mode
            && mapping_allows_movie_mode(primary_project)) {
            requested_movie_fps = native_graph->movie_frame_rate();
        }
        if (requested_movie_fps) {
            if (!pending_movie_fps
                || std::abs(*pending_movie_fps - *requested_movie_fps)
                    > 0.001) {
                pending_movie_fps = requested_movie_fps;
                movie_candidate_at = mode_now;
            }
            if (!movie_mode_active && movie_candidate_at
                && mode_now - startup_at >= std::chrono::seconds(6)
                && mode_now - *movie_candidate_at
                    >= std::chrono::milliseconds(1500)) {
                native_graph->suspend_media_clock();
                if (enter_movie_display_mode(window, *movie_display_mode)) {
                    movie_mode_active = true;
                    movie_source_fps = *requested_movie_fps;
                    next_present_frame = Clock::now();
                    std::cerr << "Movie mode active: source "
                              << std::fixed << std::setprecision(3)
                              << movie_source_fps << "fps -> display "
                              << movie_display_mode->w << "x"
                              << movie_display_mode->h << "@"
                              << movie_display_mode->refresh_rate << "Hz\n";
                } else {
                    std::cerr << "Movie mode disabled: "
                              << SDL_GetError() << "\n";
                    movie_display_mode.reset();
                }
                native_graph->resume_media_clock();
            } else if (movie_mode_active) {
                movie_source_fps = *requested_movie_fps;
            }
        } else {
            pending_movie_fps.reset();
            movie_candidate_at.reset();
            if (movie_mode_active) {
                native_graph->suspend_media_clock();
                if (!leave_movie_display_mode(window, bounds)) {
                    std::cerr << "Movie mode restore warning: "
                              << SDL_GetError() << "\n";
                }
                movie_mode_active = false;
                movie_source_fps = 0.0;
                next_present_frame = Clock::now();
                std::cerr << "Movie mode inactive: desktop refresh restored\n";
                native_graph->resume_media_clock();
            }
        }
        int full_drawable_w = 1, full_drawable_h = 1;
        SDL_GL_GetDrawableSize(window, &full_drawable_w, &full_drawable_h);
        const int render_count = static_cast<int>(physical_displays.size());
        std::vector<SDL_Rect> target_viewports(render_count);
        if (render_count == 1) {
            target_viewports[0] = {0, 0, full_drawable_w, full_drawable_h};
        } else if (options.windowed) {
            for(int target=0;target<render_count;++target) {
                const int left=full_drawable_w*target/render_count;
                target_viewports[target]={left,0,full_drawable_w*(target+1)/render_count-left,full_drawable_h};
            }
        } else {
            const double scale_x =
                static_cast<double>(full_drawable_w) / width;
            const double scale_y =
                static_cast<double>(full_drawable_h) / height;
            for (int target = 0; target < render_count; ++target) {
                const auto &display = physical_bounds[target];
                const int viewport_x = static_cast<int>(std::lround(
                    (display.x - union_left) * scale_x));
                const int viewport_top = static_cast<int>(std::lround(
                    (display.y - union_top) * scale_y));
                const int viewport_w = static_cast<int>(std::lround(
                    display.w * scale_x));
                const int viewport_h = static_cast<int>(std::lround(
                    display.h * scale_y));
                target_viewports[target] = {
                    viewport_x,
                    full_drawable_h - viewport_top - viewport_h,
                    viewport_w, viewport_h,
                };
            }
        }
        NativeScene network_scene;
        {std::lock_guard lock(runtime->native_scene_mutex);network_scene=runtime->native_scene;}
        struct NetworkPass {std::string id; Project project; SDL_Rect viewport; bool due; bool room=false;};
        std::vector<NetworkPass> network_passes;
        for(auto it=ndi_projectors.begin();it!=ndi_projectors.end();) {
            const auto cfg=network_scene.ndi_projectors.find(it->first);
            if(!publish_projectors || cfg==network_scene.ndi_projectors.end() || cfg->second.name!=it->second->output.name)
                it=ndi_projectors.erase(it);
            else ++it;
        }
        if(publish_projectors) for(const auto &[id,cfg]:network_scene.ndi_projectors) {
            auto &sender=ndi_projectors[id];
            if(!sender)sender=std::make_unique<ProjectorNdiOutput>(cfg);
            else sender->configure(cfg);
            const bool due=sender->output.due();
            const auto subscriber=projector_runtimes.at(std::stoi(id)-1);
            Project project;{std::lock_guard lock(subscriber->project_mutex);project=subscriber->project;}
            // Keep source demand stable between transmission frames.
            network_passes.push_back({id,std::move(project),{0,0,cfg.width,cfg.height},due});
        }
        for(auto it=room_targets.begin();it!=room_targets.end();){
            if(!publish_projectors||!network_scene.room_projectors.contains(it->first))it=room_targets.erase(it);else ++it;
        }
        if(publish_projectors)for(const auto &[id,size]:network_scene.room_projectors){
            auto &target=room_targets[id];if(!target)target=std::make_unique<RoomPreviewTarget>();
            target->width=size[0];target->height=size[1];
            const bool due=Clock::now()>=target->next;
            if(due)target->next=Clock::now()+std::chrono::milliseconds(100);
            const auto subscriber=projector_runtimes.at(std::stoi(id)-1);
            Project project;{std::lock_guard lock(subscriber->project_mutex);project=subscriber->project;}
            network_passes.push_back({id,std::move(project),{0,0,size[0],size[1]},due,true});
        }
        std::map<std::string, std::array<int, 2>> bus_sizes;
        const auto &sized_buses = kOutputBuses;
        for (int target = 0; target < render_count + static_cast<int>(network_passes.size()); ++target) {
            const auto &target_project = target<render_count ? render_projects[target] : network_passes[target-render_count].project;
            const auto &viewport = target<render_count ? target_viewports[target] : network_passes[target-render_count].viewport;
            for (const auto &rect : target_project.rects) {
                const int source = source_index(rect.source);
                if(!rect.native_bus.empty()){
                    auto &size=bus_sizes[rect.native_bus];size[0]=std::max(size[0],viewport.w);size[1]=std::max(size[1],viewport.h);continue;
                }
                if (!rect.live || rect.source == "none" || target_project.vectors[source]) continue;
                float min_x = 1.0f, min_y = 1.0f;
                float max_x = 0.0f, max_y = 0.0f;
                for (const auto &corner : rect.corners) {
                    min_x = std::min(min_x, corner[0]);
                    min_y = std::min(min_y, corner[1]);
                    max_x = std::max(max_x, corner[0]);
                    max_y = std::max(max_y, corner[1]);
                }
                const int width = std::clamp(
                    static_cast<int>(std::ceil(
                        (max_x - min_x) * viewport.w)), 64, viewport.w);
                const int height = std::clamp(
                    static_cast<int>(std::ceil(
                        (max_y - min_y) * viewport.h)),
                    64, viewport.h);
                auto &size = bus_sizes[sized_buses[source]];
                size[0] = std::max(size[0], width);
                size[1] = std::max(size[1], height);
            }
        }

        const auto frame_now = Clock::now();
        for (int i = 0; i < kMaxOutputs; ++i) {
            const auto &recipe = primary_project.vectors[i];
            if (!recipe) {
                vector_scenes[i].reset();
                vector_errors[i].clear();
                vector_error_keys[i].clear();
                continue;
            }
            const std::string recipe_key = recipe->module + ":"
                + std::to_string(recipe->abi) + ":"
                + std::to_string(recipe->revision);
            if (!vector_error_keys[i].empty()
                && vector_error_keys[i] == recipe_key) {
                vector_scenes[i].reset();
                continue;
            }
            try {
                if (!vector_effects[i]
                    || vector_effects[i]->module_path() != recipe->module
                    || vector_effects[i]->abi() != recipe->abi) {
                    vector_effects[i] = std::make_unique<VectorWasmEffect>(
                        options.server, recipe->module, recipe->abi);
                    vector_errors[i].clear();
                    vector_error_keys[i].clear();
                }
                const double elapsed = recipe->playing
                    ? std::chrono::duration<double>(
                        frame_now - recipe->received_at).count()
                    : 0.0;
                vector_scenes[i] = vector_effects[i]->evaluate(
                    recipe->params,
                    recipe->seconds + elapsed,
                    recipe->beat + elapsed * recipe->bpm / 60.0);
                ++vector_frames[i];
            } catch (const ModulePending &) {
                vector_scenes[i].reset();
                vector_errors[i] = "Vector module loading / reconnecting";
            } catch (const std::exception &error) {
                const std::string message = error.what();
                if (message != vector_errors[i]) {
                    std::cerr << "Vector out" << i + 1
                              << " disabled: " << message << "\n";
                    vector_errors[i] = message;
                }
                vector_error_keys[i] = recipe_key;
                vector_scenes[i].reset();
            }
        }

        json calibration_command;
        { std::lock_guard lock(calibration->mutex);
          if(Clock::now()-calibration->received<std::chrono::seconds(3)) calibration_command=calibration->command;
        }
        if(!calibration_command.is_object())calibration_command=json::object();
        const auto camera_device=calibration_command.value("camera","");
        if(camera_device!=calibration_device){calibration_sequence=0;calibration_device=camera_device;}
        native_graph->set_calibration_camera(camera_device);
        const auto messages = runtime->native_scene_messages.load();
        if (messages != applied_native_scene) {
            NativeScene scene;
            {
                std::lock_guard lock(runtime->native_scene_mutex);
                scene = runtime->native_scene;
            }
            native_graph->apply_scene(std::move(scene));
            applied_native_scene = messages;
            {
                std::lock_guard lock(runtime->native_scene_mutex);
                scene_present_fps = std::max(1, runtime->native_scene.fps);
            }
        }
        const auto graph_now = Clock::now();
        if (applied_native_scene) {
            NativeScene scene;
            {
                std::lock_guard lock(runtime->native_scene_mutex);
                scene = runtime->native_scene;
            }
            for (const auto &[bus, demand] : scene.monitor_demand) {
                if (demand.fps <= 0.0
                    || demand.width < 1 || demand.height < 1) {
                    continue;
                }
                auto &size = bus_sizes[bus];
                size[0] = std::max(size[0], demand.width);
                size[1] = std::max(size[1], demand.height);
            }
            for (auto &[bus, size] : bus_sizes) {
                if(!bus.starts_with("collection") && !bus.starts_with("led-"))size = mapping_bus_size(
                    size, scene.canvas_width, scene.canvas_height);
            }
            native_graph->set_bus_sizes(bus_sizes);
            native_graph->set_vector_renderer([&](const std::string &bus, int width, int height) {
                const auto found=std::find(kOutputBuses.begin(),kOutputBuses.end(),bus);
                if(found==kOutputBuses.end())return false;
                const auto index=std::distance(kOutputBuses.begin(),found);
                const auto &recipe=primary_project.vectors[index];
                if(!recipe)return false;
                if(!vector_scenes[index])return true;
                Rect rect;rect.corners={{{0,0}},{{1,0}},{{1,1}},{{0,1}}};
                std::vector<VectorGpuVertex> vertices;std::vector<std::uint32_t> indices;
                append_vector_rect(*vector_scenes[index],*recipe,rect,width,height,false,vertices,indices);
                // Projector geometry is bottom-origin GL; bus pixels are top-origin.
                for(auto &vertex:vertices)vertex.position[1]=-vertex.position[1];
                if(indices.empty())return true;
                glDisable(GL_STENCIL_TEST);
                glUseProgram(vector_program);glBindVertexArray(vector_vao);
                glBindBuffer(GL_ARRAY_BUFFER,vector_vbo);
                glBufferData(GL_ARRAY_BUFFER,vertices.size()*sizeof(VectorGpuVertex),vertices.data(),GL_DYNAMIC_DRAW);
                glBindBuffer(GL_ELEMENT_ARRAY_BUFFER,vector_ebo);
                glBufferData(GL_ELEMENT_ARRAY_BUFFER,indices.size()*sizeof(std::uint32_t),indices.data(),GL_DYNAMIC_DRAW);
                glUniform1i(vector_pass_location,0);set_vector_blend("normal",true);
                glDrawElements(GL_TRIANGLES,indices.size(),GL_UNSIGNED_INT,nullptr);
                glUniform1i(vector_pass_location,1);set_vector_blend("normal",false);
                glDrawElements(GL_TRIANGLES,indices.size(),GL_UNSIGNED_INT,nullptr);
                return true;
            });
            std::set<std::string> used_vector_layers;
            native_graph->set_vector_layer_renderer([&](const NativeLayer &layer,
                double seconds, double beat, int width, int height) {
                used_vector_layers.insert(layer.source_id);
                auto &cached = layer_vectors[layer.source_id];
                if (!cached.error.empty() && cached.error_revision == scene.revision) return false;
                try {
                    auto recipe = parse_vector_recipe(layer.vector);
                    if (!recipe) throw std::runtime_error("Invalid vector layer recipe");
                    if (!cached.effect || cached.effect->module_path() != recipe->module
                        || cached.effect->abi() != recipe->abi) {
                        cached.effect = std::make_unique<VectorWasmEffect>(
                            options.server, recipe->module, recipe->abi);
                    }
                    const auto picture = cached.effect->evaluate(recipe->params, seconds, beat);
                    // Transparent source at full strength; the compositor owns
                    // layer opacity, blend mode and the Out's master controls.
                    Rect rect; rect.corners = {{{0,0}},{{1,0}},{{1,1}},{{0,1}}};
                    rect.fit = "stretch";
                    std::vector<VectorGpuVertex> vertices;
                    std::vector<std::uint32_t> indices;
                    append_vector_rect(picture, *recipe, rect, width, height, false, vertices, indices);
                    for (auto &vertex : vertices) vertex.position[1] = -vertex.position[1];
                    if (!indices.empty()) {
                        glDisable(GL_STENCIL_TEST);
                        glUseProgram(vector_program); glBindVertexArray(vector_vao);
                        glBindBuffer(GL_ARRAY_BUFFER, vector_vbo);
                        glBufferData(GL_ARRAY_BUFFER, vertices.size()*sizeof(VectorGpuVertex), vertices.data(), GL_DYNAMIC_DRAW);
                        glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, vector_ebo);
                        glBufferData(GL_ELEMENT_ARRAY_BUFFER, indices.size()*sizeof(std::uint32_t), indices.data(), GL_DYNAMIC_DRAW);
                        glUniform1i(vector_pass_location, 0); set_vector_blend("normal", true);
                        glDrawElements(GL_TRIANGLES, indices.size(), GL_UNSIGNED_INT, nullptr);
                        glUniform1i(vector_pass_location, 1); set_vector_blend("normal", false);
                        glDrawElements(GL_TRIANGLES, indices.size(), GL_UNSIGNED_INT, nullptr);
                    }
                    cached.error.clear();
                    return true;
                } catch (const ModulePending &) {
                    return false;
                } catch (const std::exception &error) {
                    if (cached.error != error.what())
                        std::cerr << "Vector layer " << layer.id << ": " << error.what() << "\n";
                    cached.error = error.what();
                    cached.error_revision = scene.revision;
                    return false;
                }
            });
            native_graph->render();
            native_graph->set_vector_renderer({});
            native_graph->set_vector_layer_renderer({});
            for (auto it = layer_vectors.begin(); it != layer_vectors.end();) {
                if (!used_vector_layers.contains(it->first)) it = layer_vectors.erase(it);
                else ++it;
            }
            const auto &graph_buses = kOutputBuses;
            for (int i = 0; i < kMaxOutputs; ++i) {
                const auto texture =
                    native_graph->bus_texture(graph_buses[i]);
                if (!texture.texture) continue;
                gpu_frames[i].texture = texture.texture;
                gpu_frames[i].width = texture.width;
                gpu_frames[i].height = texture.height;
            }
            if (options.mapping == 0 || options.mapping == 1) {
                for (auto it = monitor_publishers.begin(); it != monitor_publishers.end();) {
                    if (!scene.monitor_demand.contains(it->first)) {
                        next_monitor_frame.erase(it->first);
                        it = monitor_publishers.erase(it);
                    } else ++it;
                }
                for (const auto &[bus, demand] : scene.monitor_demand) {
                    if (demand.fps <= 0.0 || demand.width < 1 || demand.height < 1
                        || graph_now < next_monitor_frame[bus]) continue;
                    auto rgb = native_graph->read_bus_rgb(bus, demand.width, demand.height);
                    if (!rgb.empty()) {
                        auto &publisher = monitor_publishers[bus];
                        if (!publisher) publisher = std::make_unique<MonitorFramePublisher>("monitor-" + bus);
                        publisher->publish(rgb, demand.width, demand.height);
                    }
                    next_monitor_frame[bus] = graph_now + std::chrono::microseconds(
                        static_cast<long long>(1'000'000.0 / demand.fps));
                }
            }
        }

        if(!camera_device.empty()) {
            if(const auto frame=native_graph->calibration_frame();frame && frame->sequence!=calibration_sequence) {
                calibration_camera.publish(*frame->rgb,frame->width,frame->height);calibration_sequence=frame->sequence;
            }
        }
        glClearColor(0, 0, 0, 1);
        glClear(GL_COLOR_BUFFER_BIT);
        int rendered_traces = 0;
        auto render_projector = [&](Project project, int mapping_id, const SDL_Rect &viewport) {
        const auto outputs=calibration_command.value("outputs",json::object());
        if(outputs.contains(std::to_string(mapping_id))) {
            const auto &pattern=outputs.at(std::to_string(mapping_id));
            if(pattern.value("kind","")=="grid")project=calibration_grid(pattern,viewport);
            else {calibration_pattern(pattern,viewport);return;}
        }
        // The framebuffer was cleared to black. A hidden output draws nothing,
        // including traces and the full-projector grid. Calibration can override it.
        if (!project.enabled) return;
        const int drawable_w = viewport.w;
        const int drawable_h = viewport.h;
        glViewport(
            viewport.x, viewport.y, viewport.w, viewport.h);
        glUseProgram(program);
        glBindVertexArray(vao);
        glActiveTexture(GL_TEXTURE0);

        // Rect list order is layer order, for both raster and vector content.
        // Overlay coverage is the union of earlier ordinary surfaces, intersected
        // with the overlay polygon. Muting content does not erase mask geometry.
        std::function<void(const Rect&)> stencil_polygon = [&](const Rect &shape) {
            if(!shape.masks.empty()){
                for(const auto& mask:shape.masks)stencil_polygon(mask);
                return;
            }
            std::vector<float> vertices;
            std::vector<std::array<float,2>> coverage=shape.corners;
            const bool rounded=shape.corner_radius>0&&shape.corners.size()==4&&!shape.fold;
            if(rounded){
                const double aspect=(project.rotation==90||project.rotation==270)?double(drawable_h)/drawable_w:double(drawable_w)/drawable_h;
                coverage=rounded_surface::triangles(rounded_surface::outline(shape.corners,shape.curvature,shape.corner_radius,aspect));
            } else if(shape.curved){
                coverage.clear();
                for(auto index:shape.curved->indices)coverage.push_back(shape.curved->points[index]);
            } else if(shape.fold && shape.corners.size()==6){
                coverage.clear();
                for(int i:{0,1,4,0,4,5,1,2,3,1,3,4})coverage.push_back(shape.corners[i]);
            }
            for (const auto &corner : coverage) {
                const auto rotated = rotate_output_uv(corner, project.rotation);
                float x = rotated[0] * 2.0f - 1.0f;
                float y = 1.0f - rotated[1] * 2.0f;
                vertices.insert(vertices.end(), {x, y, 0.5f, 0.5f, 1.0f});
            }
            glBindBuffer(GL_ARRAY_BUFFER, vbo);
            glBufferData(GL_ARRAY_BUFFER, vertices.size() * sizeof(float), vertices.data(), GL_DYNAMIC_DRAW);
            glDrawArrays((rounded || shape.fold || shape.curved) ? GL_TRIANGLES : GL_TRIANGLE_FAN, 0, static_cast<GLsizei>(coverage.size()));
        };
        for (std::size_t rect_index = 0; rect_index < project.rects.size(); ++rect_index) {
            const auto &rect = project.rects[rect_index];
            glDisable(GL_STENCIL_TEST);
            if (rect.source == "none") continue;
            if (rect.overlay || rect.corner_radius>0 || !rect.masks.empty()) {
                glUseProgram(program);
                glBindVertexArray(vao);
                glUniform1i(texture_location, 0);
                glUniform1i(overlay_location, 0);
                glEnable(GL_STENCIL_TEST);
                glStencilMask(0xff);
                glClearStencil(0);
                glClear(GL_STENCIL_BUFFER_BIT);
                glColorMask(GL_FALSE, GL_FALSE, GL_FALSE, GL_FALSE);
                glStencilFunc(GL_ALWAYS, 1, 0xff);
                glStencilOp(GL_KEEP, GL_KEEP, GL_REPLACE);
                if(rect.overlay){
                    for (std::size_t lower = 0; lower < rect_index; ++lower)
                        if (!project.rects[lower].overlay){
                            const auto& below=project.rects[lower];
                            if(below.overlay_masks.empty())stencil_polygon(below);
                            else for(const auto& mask:below.overlay_masks)stencil_polygon(mask);
                        }
                    glStencilFunc(GL_EQUAL, 1, 0xff);
                    glStencilOp(GL_KEEP, GL_KEEP, GL_INCR);
                }
                stencil_polygon(rect);
                glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
                glStencilMask(0);
                glStencilFunc(GL_EQUAL, rect.overlay?2:1, 0xff);
                glStencilOp(GL_KEEP, GL_KEEP, GL_KEEP);
            }
            const int index = source_index(rect.source);
            const bool is_vector = rect.native_bus.empty() && rect.live && project.vectors[index] && vector_scenes[index];
            if (is_vector) {
                std::vector<VectorGpuVertex> vector_vertices;
                std::vector<std::uint32_t> vector_indices;
                append_vector_rect(
                    *vector_scenes[index], *project.vectors[index], rect,
                    drawable_w, drawable_h, project.rotation,
                    vector_vertices, vector_indices);
                if (!vector_indices.empty()) {
                    glUseProgram(vector_program);
                    glBindVertexArray(vector_vao);
                    glBindBuffer(GL_ARRAY_BUFFER, vector_vbo);
                    glBufferData(
                        GL_ARRAY_BUFFER,
                        static_cast<GLsizeiptr>(
                            vector_vertices.size() * sizeof(VectorGpuVertex)),
                        vector_vertices.data(), GL_DYNAMIC_DRAW);
                    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, vector_ebo);
                    glBufferData(
                        GL_ELEMENT_ARRAY_BUFFER,
                        static_cast<GLsizeiptr>(
                            vector_indices.size() * sizeof(std::uint32_t)),
                        vector_indices.data(), GL_DYNAMIC_DRAW);
                    glUniform1i(vector_pass_location, 0);
                    set_vector_blend(rect.blend, true);
                    glDrawElements(
                        GL_TRIANGLES,
                        static_cast<GLsizei>(vector_indices.size()),
                        GL_UNSIGNED_INT, nullptr);
                    glUniform1i(vector_pass_location, 1);
                    set_vector_blend(rect.blend, false);
                    glDrawElements(
                        GL_TRIANGLES,
                        static_cast<GLsizei>(vector_indices.size()),
                        GL_UNSIGNED_INT, nullptr);
                }
                continue;
            }

            glUseProgram(program);
            glBindVertexArray(vao);
            const auto uvq = projective_uvs(rect);
            std::vector<float> vertices;
            std::vector<unsigned int> mapping_indices;
            auto append_vertex = [&](const std::array<float, 2> &point,
                                     float u, float v, float q) {
                const auto rotated = rotate_output_uv(point, project.rotation);
                float px = rotated[0] * 2.0f - 1.0f;
                float py = 1.0f - rotated[1] * 2.0f;
                vertices.insert(vertices.end(), {px, py, u, v, q});
            };
            if(rect.curved){
                for(std::size_t i=0;i<rect.curved->points.size();i++){
                    const auto &uv=rect.curved->uvqs[i];append_vertex(rect.curved->points[i],uv[0],uv[1],uv[2]);
                }
                mapping_indices=rect.curved->indices;
            } else if(rect.fold && rect.corners.size()==6 && rect.uvs.size()==6){
                for(const auto &panel : std::array<std::array<int,4>,2>{{{{0,1,4,5}},{{1,2,3,4}}}}){
                    Rect part=rect;part.fold=false;part.corners.clear();part.uvs.clear();
                    for(int i:panel){part.corners.push_back(rect.corners[i]);part.uvs.push_back(rect.uvs[i]);}
                    const auto pq=projective_uvs(part);
                    if(!pq)continue;
                    const unsigned int offset=vertices.size()/5;
                    for(int i=0;i<4;++i)append_vertex(part.corners[i],(*pq)[i][0],(*pq)[i][1],(*pq)[i][2]);
                    for(unsigned int i:{0u,1u,2u,0u,2u,3u})mapping_indices.push_back(offset+i);
                }
            } else if (uvq) {
                for (int i = 0; i < 4; ++i) {
                    append_vertex(
                        rect.corners[i], (*uvq)[i][0],
                        (*uvq)[i][1], (*uvq)[i][2]);
                }
                mapping_indices = {0, 1, 2, 0, 2, 3};
            } else if (rect.corners.size() == rect.uvs.size()
                       && rect.corners.size() >= 4) {
                std::array<float, 2> center{0, 0};
                std::array<float, 2> center_uv{0, 0};
                for (std::size_t i = 0; i < rect.corners.size(); ++i) {
                    center[0] += rect.corners[i][0];
                    center[1] += rect.corners[i][1];
                    center_uv[0] += rect.uvs[i][0];
                    center_uv[1] += rect.uvs[i][1];
                }
                const float divisor =
                    static_cast<float>(rect.corners.size());
                center[0] /= divisor;
                center[1] /= divisor;
                center_uv[0] /= divisor;
                center_uv[1] /= divisor;
                append_vertex(center, center_uv[0], center_uv[1], 1.0f);
                for (std::size_t i = 0; i < rect.corners.size(); ++i) {
                    append_vertex(
                        rect.corners[i], rect.uvs[i][0],
                        rect.uvs[i][1], 1.0f);
                    mapping_indices.insert(mapping_indices.end(), {
                        0,
                        static_cast<unsigned int>(i + 1),
                        static_cast<unsigned int>(
                            (i + 1) % rect.corners.size() + 1),
                    });
                }
            } else {
                continue;
            }
            glBindBuffer(GL_ARRAY_BUFFER, vbo);
            glBufferData(
                GL_ARRAY_BUFFER,
                static_cast<GLsizeiptr>(vertices.size() * sizeof(float)),
                vertices.data(), GL_DYNAMIC_DRAW);
            glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, ebo);
            glBufferData(
                GL_ELEMENT_ARRAY_BUFFER,
                static_cast<GLsizeiptr>(
                    mapping_indices.size() * sizeof(unsigned int)),
                mapping_indices.data(), GL_DYNAMIC_DRAW);

            auto gpu = gpu_frames[index];
            if(!rect.native_bus.empty()){
                const auto resolved=native_graph->bus_texture(rect.native_bus);
                gpu.texture=resolved.texture;gpu.width=resolved.width;gpu.height=resolved.height;
            }
            const bool textured = rect.live && gpu.width > 0;
            glUniform1i(texture_location, textured ? 1 : 0);
            glUniform1i(overlay_location, !rect.live && rect.plane_pattern ? 3 : !rect.live && rect.wireframe ? 2 : 0);
            glUniform2f(plane_extent_location,rect.plane_extent[0],rect.plane_extent[1]);
            glUniform1i(plane_circle_location,rect.plane_circle);
            glBindTexture(GL_TEXTURE_2D, gpu.texture);

            float scale_x = 1.0f, scale_y = 1.0f;
            if (textured && rect.fit != "stretch") {
                float min_x = 1, max_x = 0, min_y = 1, max_y = 0;
                for (const auto &corner : rect.corners) {
                    min_x = std::min(min_x, corner[0]);
                    max_x = std::max(max_x, corner[0]);
                    min_y = std::min(min_y, corner[1]);
                    max_y = std::max(max_y, corner[1]);
                }
                const float box_w = std::max((max_x - min_x) * drawable_w, 0.001f);
                const float box_h = std::max((max_y - min_y) * drawable_h, 0.001f);
                const auto scale = mapping_content_scale(
                    rect.fit, static_cast<float>(gpu.width) / gpu.height,
                    box_w, box_h);
                scale_x = scale[0];
                scale_y = scale[1];
            }
            glUniform2f(scale_location, scale_x, scale_y);
            set_blend(rect.blend);
            if(!rect.native_bus.empty())glBlendFunc(GL_ONE,GL_ONE_MINUS_SRC_ALPHA);
            glDrawElements(
                GL_TRIANGLES,
                static_cast<GLsizei>(mapping_indices.size()),
                GL_UNSIGNED_INT, nullptr);
            if (!rect.live && !rect.overlay && !rect.curvature.pins.empty()) {
                const auto markers = make_pin_scene(rect, drawable_w, drawable_h, project.rotation);
                Rect canvas;
                canvas.corners = {{0,0},{1,0},{1,1},{0,1}};
                VectorRecipe recipe;
                std::vector<VectorGpuVertex> pin_vertices;
                std::vector<std::uint32_t> pin_indices;
                append_vector_rect(markers, recipe, canvas, drawable_w, drawable_h,
                                   project.rotation, pin_vertices, pin_indices);
                glUseProgram(vector_program);
                glBindVertexArray(vector_vao);
                glBindBuffer(GL_ARRAY_BUFFER, vector_vbo);
                glBufferData(GL_ARRAY_BUFFER, pin_vertices.size()*sizeof(VectorGpuVertex),
                             pin_vertices.data(), GL_DYNAMIC_DRAW);
                glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, vector_ebo);
                glBufferData(GL_ELEMENT_ARRAY_BUFFER, pin_indices.size()*sizeof(std::uint32_t),
                             pin_indices.data(), GL_DYNAMIC_DRAW);
                glUniform1i(vector_pass_location, 1);
                set_vector_blend("normal", false);
                glDrawElements(GL_TRIANGLES, static_cast<GLsizei>(pin_indices.size()),
                               GL_UNSIGNED_INT, nullptr);
            }
        }
        glDisable(GL_STENCIL_TEST);
        glStencilMask(0xff);

        // Projected LED traces are a full-canvas light layer. Their RGB cells
        // arrive on the lightweight LED feed and use the same analytic GPU
        // line/glow renderer as vector effects.
        if (!project.traces.empty()) {
            std::map<std::string, std::vector<std::uint8_t>> led_frames;
            {
                std::lock_guard lock(runtime->led_mutex);
                led_frames = runtime->led_frames;
            }
            Rect full;
            full.corners = {{
                {{0, 0}}, {{1, 0}}, {{1, 1}}, {{0, 1}},
            }};
            VectorRecipe trace_recipe;
            trace_recipe.canvas_width = drawable_w;
            trace_recipe.canvas_height = drawable_h;
            trace_recipe.line_cap = "butt";
            for (const auto &trace : project.traces) {
                if (!trace.enabled) continue;
                const std::string fixture =
                    (mapping_id == 1
                        ? "map-" : "map" + std::to_string(mapping_id) + "-")
                    + trace.id;
                const auto frame = led_frames.find(fixture);
                if (frame == led_frames.end()) continue;
                const auto scene = make_trace_scene(trace, frame->second);
                std::vector<VectorGpuVertex> trace_vertices;
                std::vector<std::uint32_t> trace_indices;
                append_vector_rect(
                    scene, trace_recipe, full, drawable_w, drawable_h,
                    project.rotation, trace_vertices, trace_indices);
                if (trace_indices.empty()) continue;
                ++rendered_traces;

                glUseProgram(vector_program);
                glBindVertexArray(vector_vao);
                glBindBuffer(GL_ARRAY_BUFFER, vector_vbo);
                glBufferData(
                    GL_ARRAY_BUFFER,
                    static_cast<GLsizeiptr>(
                        trace_vertices.size() * sizeof(VectorGpuVertex)),
                    trace_vertices.data(), GL_DYNAMIC_DRAW);
                glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, vector_ebo);
                glBufferData(
                    GL_ELEMENT_ARRAY_BUFFER,
                    static_cast<GLsizeiptr>(
                        trace_indices.size() * sizeof(std::uint32_t)),
                    trace_indices.data(), GL_DYNAMIC_DRAW);
                glUniform1i(vector_pass_location, 0);
                set_vector_blend(trace.blend, true);
                glDrawElements(
                    GL_TRIANGLES, static_cast<GLsizei>(trace_indices.size()),
                    GL_UNSIGNED_INT, nullptr);
                glUniform1i(vector_pass_location, 1);
                set_vector_blend(trace.blend, false);
                glDrawElements(
                    GL_TRIANGLES, static_cast<GLsizei>(trace_indices.size()),
                    GL_UNSIGNED_INT, nullptr);
            }
        }

        if (project.bounds_grid) {
            glUseProgram(program);
            glBindVertexArray(vao);
            Rect full;
            full.corners = {{
                {{0, 0}}, {{1, 0}}, {{1, 1}}, {{0, 1}},
            }};
            const auto uvq = projective_uvs(full);
            std::array<float, 20> vertices{};
            for (int i = 0; i < 4; ++i) {
                const auto rotated = rotate_output_uv(full.corners[i], project.rotation);
                float px = rotated[0] * 2.0f - 1.0f;
                float py = 1.0f - rotated[1] * 2.0f;
                vertices[i * 5] = px;
                vertices[i * 5 + 1] = py;
                vertices[i * 5 + 2] = (*uvq)[i][0];
                vertices[i * 5 + 3] = (*uvq)[i][1];
                vertices[i * 5 + 4] = (*uvq)[i][2];
            }
            glBindBuffer(GL_ARRAY_BUFFER, vbo);
            // A preceding polygon may have resized/replaced these buffers.
            // Bounds grids must also work after an empty or entirely muted mapping.
            glBufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices.data(), GL_DYNAMIC_DRAW);
            glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, ebo);
            glBufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof(indices), indices.data(), GL_DYNAMIC_DRAW);
            glUniform1i(texture_location, 0);
            glUniform1i(overlay_location, 1);
            glUniform2f(scale_location, 1, 1);
            glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
            glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_INT, nullptr);
        }
        // Selection annotations are transient and never appear on live surfaces.
        VectorScene markers;
        for(const auto& rect:project.rects){
            if(rect.live||rect.source=="none"||!project.selected_rect_ids.contains(rect.id))continue;
            const auto points=selection_marker::square(rect.corners,rect.curvature,drawable_w,drawable_h,project.rotation);
            VectorStyle style;style.core={.08f,.65f,.18f,.65f};style.core_width=1.0f/drawable_h;style.glow_width=0;
            for(size_t i=0;i<points.size();i++){
                const auto a=points[i],b=points[(i+1)%points.size()];
                markers.segments.push_back({{a[0],a[1]},{b[0],b[1]},style,style});
            }
        }
        if(!markers.segments.empty()){
            Rect canvas;canvas.corners={{0,0},{1,0},{1,1},{0,1}};
            VectorRecipe recipe;std::vector<VectorGpuVertex> vertices;std::vector<std::uint32_t> marker_indices;
            append_vector_rect(markers,recipe,canvas,drawable_w,drawable_h,project.rotation,vertices,marker_indices);
            glDisable(GL_STENCIL_TEST);glUseProgram(vector_program);glBindVertexArray(vector_vao);
            glBindBuffer(GL_ARRAY_BUFFER,vector_vbo);glBufferData(GL_ARRAY_BUFFER,vertices.size()*sizeof(VectorGpuVertex),vertices.data(),GL_DYNAMIC_DRAW);
            glBindBuffer(GL_ELEMENT_ARRAY_BUFFER,vector_ebo);glBufferData(GL_ELEMENT_ARRAY_BUFFER,marker_indices.size()*sizeof(std::uint32_t),marker_indices.data(),GL_DYNAMIC_DRAW);
            glUniform1i(vector_pass_location,1);set_vector_blend("normal",false);
            glDrawElements(GL_TRIANGLES,marker_indices.size(),GL_UNSIGNED_INT,nullptr);
        }
        };
        for(int target=0;target<render_count;++target) {
            render_projector(render_projects[target],physical_mappings[target],target_viewports[target]);
            publish_mapping(render_projects[target],physical_mappings[target],target_viewports[target],"physical");
        }
        for(const auto &pass:network_passes) {
            if(!pass.due)continue;
            if(pass.room){
                room_targets.at(pass.id)->render([&](const SDL_Rect &viewport){
                    render_projector(pass.project,std::stoi(pass.id),viewport);
                    publish_mapping(pass.project,std::stoi(pass.id),viewport,"room");
                });
                continue;
            }
            ndi_projectors.at(pass.id)->render([&](const SDL_Rect &viewport) {
                render_projector(pass.project,std::stoi(pass.id),viewport);
                publish_mapping(pass.project,std::stoi(pass.id),viewport,"ndi");
            });
        }

        SDL_GL_SwapWindow(window);
        json calibration_displays=json::array();
        std::vector<int> connected_mappings;
        for(int target=0;target<render_count;++target) {
            const int physical=physical_displays[target];
            const int mid=physical_mappings[target];
            const auto &v=target_viewports[target];
            // SDL display indices can disappear during hot-plug. A null C
            // string crashes JSON's string constructor before it can throw.
            const char *display_name=SDL_GetDisplayName(physical);
            if(!display_name)continue;
            connected_mappings.push_back(mid);
            calibration_displays.push_back({{"id",mid},{"physical",physical},{"name",display_name},
                {"width",v.w},{"height",v.h},{"x",v.x},{"y",v.y},{"active",true},{"instance",calibration_instance}});
        }
        for(const auto &[id,sender]:ndi_projectors) {
            const int mid=std::stoi(id);
            if(std::find(connected_mappings.begin(),connected_mappings.end(),mid)!=connected_mappings.end())continue;
            calibration_displays.push_back({{"id",mid},{"physical",-1},{"name",sender->output.name},
                {"width",sender->output.width},{"height",sender->output.height},{"x",0},{"y",0},
                {"active",true},{"transport","ndi"},{"instance",calibration_instance}});
        }
        { std::lock_guard lock(calibration->mutex);
          json vector_status=json::object();
          for(int i=0;i<kMaxOutputs;++i) vector_status["out"+std::to_string(i+1)] = {
            {"ready",bool(vector_scenes[i])},{"error",vector_errors[i]},
            {"module",primary_project.vectors[i]?primary_project.vectors[i]->module:""}};
          calibration->status={{"metrics",renderer_metrics},{"vectors",vector_status},{"instance",calibration_instance},{"displays",calibration_displays},
            {"applied",calibration_command.value("revision",0)},{"cameraError",native_graph->calibration_camera_error()}};
        }
        ++presented;

        const auto now = Clock::now();
        const double seconds = std::chrono::duration<double>(now - stats_at).count();
        if (seconds >= 2.0) {
            json ndi_status=json::object();
            for(const auto &[id,sender]:ndi_projectors)ndi_status[id]=sender->output.diagnostics();
            renderer_metrics = {{"ndiProjectors",ndi_status},{"sequence", ++metrics_sequence}, {"sampleSeconds", seconds},
                {"presentFps", presented / seconds}, {"targetFps", movie_mode_active ? movie_source_fps : scene_present_fps},
                {"movieMode", movie_mode_active}, {"graph", native_graph->diagnostics()}};
            std::ostringstream stats;
            stats << "native mapping " << options.mapping
                  << " present " << std::lround(presented / seconds) << " fps";
            for (int i = 0; i < kMaxOutputs; ++i) {
                if (primary_project.vectors[i]) {
                    stats << " | out" << i + 1;
                    stats << " vec "
                          << std::lround(
                              (vector_frames[i] - vector_at[i]) / seconds);
                }
                vector_at[i] = vector_frames[i];
            }
            if (!primary_project.traces.empty()
                || (secondary_runtime && !secondary_project.traces.empty())) {
                const auto led = runtime->led_messages.load();
                stats << " | traces "
                      << primary_project.traces.size()
                            + secondary_project.traces.size()
                      << "/" << rendered_traces
                      << " led " << std::lround((led - led_at) / seconds);
                led_at = led;
            }
            stats << " | " << native_graph->stats();
            if (movie_mode_active) {
                stats << " | movie " << std::fixed << std::setprecision(3)
                      << movie_source_fps << "fps/24Hz";
            }
            std::cerr << stats.str() << "\n";
            SDL_SetWindowTitle(window, stats.str().c_str());
            stats_at = now;
            presented = 0;
        }
        const double target_present_fps = movie_mode_active
            ? movie_source_fps : scene_present_fps;
        next_present_frame += std::chrono::duration_cast<Clock::duration>(
            std::chrono::duration<double>(
                1.0 / std::max(1.0, target_present_fps)));
        const auto sleep_now = Clock::now();
        if (next_present_frame > sleep_now) {
            std::this_thread::sleep_until(next_present_frame);
        } else {
            next_present_frame = sleep_now;
        }
    }

    runtime->running.store(false);
    if (movie_mode_active) leave_movie_display_mode(window, bounds);
    SDL_GL_DeleteContext(context);
    SDL_DestroyWindow(window);
    SDL_Quit();
    // Network workers use blocking reads and are intentionally process-scoped.
    // The experiment exits immediately rather than delaying kiosk recovery.
    std::_Exit(0);
}
