#pragma once

#define GL_GLEXT_PROTOTYPES
#include <SDL2/SDL_opengl.h>

#include "media_decoder.hpp"
#include "live_capture.hpp"
#include <functional>
#include "native_audio.hpp"
#include "native_scene.hpp"

#include <array>
#include <chrono>
#include <cstdint>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <vector>

struct NativeBusTexture {
    GLuint texture = 0;
    int width = 0;
    int height = 0;
    std::uint64_t sequence = 0;
    // The topmost cell on this Out asks collections that follow it to span.
    bool span = false;
};

class NativeRenderGraph {
public:
    using CaptureFactory = std::function<std::unique_ptr<LiveCapture>(const std::string &)>;
    explicit NativeRenderGraph(CaptureFactory capture_factory = {});
    ~NativeRenderGraph();

    NativeRenderGraph(const NativeRenderGraph &) = delete;
    NativeRenderGraph &operator=(const NativeRenderGraph &) = delete;

    void apply_scene(NativeScene scene);
    void set_bus_sizes(std::map<std::string, std::array<int, 2>> sizes);
    void set_patch_outputs(SceneJson sources) { patch_outputs_ = std::move(sources); }
    const SceneJson& patch_outputs() const { return patch_outputs_; }
    void set_palette_sources(SceneJson sources) { palette_sources_ = std::move(sources); }
    void render(bool deferProjectorGlass=false);
    using BusRenderer = std::function<bool(const std::string &, int, int)>;
    void set_vector_renderer(BusRenderer renderer) { vector_renderer_ = std::move(renderer); }
    using VectorLayerRenderer = std::function<bool(const NativeLayer &, double, double, int, int)>;
    void set_vector_layer_renderer(VectorLayerRenderer renderer) { vector_layer_renderer_ = std::move(renderer); }
    void set_calibration_camera(std::string device) { calibration_camera_ = std::move(device); }
    std::optional<DecodedVideoFrame> calibration_frame();
    std::string calibration_camera_error();
    void suspend_media_clock();
    void resume_media_clock();
    NativeBusTexture bus_texture(const std::string &bus) const;
    bool bus_span(const std::string &bus) const;
    // Called while the projector framebuffer contains the layers below this
    // Meta overlay. Returns empty when the overlay does not need a backdrop.
    NativeBusTexture projector_overlay(const std::string& bus,int width,int height,int rotation);
    std::optional<double> movie_frame_rate() const;
    std::vector<std::uint8_t> read_bus_rgb(
        const std::string &bus, int width, int height);
    std::string stats() const;
    SceneJson diagnostics() const;
    bool static_images_pending() const;

private:
    struct BusTarget;
    struct SourceNode;

    void ensure_geometry();
    void ensure_program();
    void ensure_bus_target(const std::string &bus);
    SourceNode *source_for(const NativeLayer &layer);
    void update_sources();
    void render_bus(const std::string &name, const NativeBus &bus);
    void draw_layer(const NativeLayer &layer, double seconds, double beat,
                    int target_width, int target_height,
                    GLuint input_texture = 0);
    void draw_master(const NativeBus &bus, BusTarget &target);
    void draw_collection(const NativeBus &bus, const NativeLayer &layer,
                         GLuint texture, int width, int height, bool geometry, double seconds,bool localBackdrop=true);
    GLuint collection_program_ = 0, collection_vao_ = 0, collection_vbo_ = 0;
    static std::string source_key(const NativeLayer &layer);

    BusRenderer vector_renderer_;
    VectorLayerRenderer vector_layer_renderer_;
    std::string calibration_camera_;
    SceneJson palette_sources_ = SceneJson::array();
    SceneJson patch_outputs_ = SceneJson::array();
    std::map<std::string,std::map<std::string,SceneJson>> resolved_patch_dependencies_;
    std::map<std::string,std::map<std::pair<size_t,size_t>,std::shared_ptr<const std::vector<float>>>> photo_geometry_;
    std::uint64_t patch_resolution_hits_=0,patch_resolution_rebuilds_=0;
    void resolve_patch_outputs();
    NativeScene scene_;
    std::chrono::steady_clock::time_point scene_received_at_;
    std::map<std::string, std::unique_ptr<BusTarget>> buses_;
    std::map<std::string, std::unique_ptr<BusTarget>> projector_buses_;
    void clear_projector_targets();
    bool projector_overlay_layers(const std::string& bus,std::vector<std::string>& names) const;
    GLuint projector_backdrop_=0;
    int projector_width_=0,projector_height_=0,projector_rotation_=0;
    bool projector_backdrop_active_=false;
    std::uint64_t projector_backdrop_copies_=0;
    std::map<std::string, std::unique_ptr<SourceNode>> sources_;
    std::map<std::string, std::array<int, 2>> render_sizes_;
    std::map<std::string, std::array<int, 2>> source_sizes_;
    std::unique_ptr<NativeAudioEngine> audio_;
    CaptureFactory capture_factory_;
    GLuint program_ = 0;
    GLuint fallback_texture_ = 0;
    GLuint vao_ = 0;
    GLuint vbo_ = 0;
    GLuint readback_texture_ = 0;
    GLuint readback_framebuffer_ = 0;
    int readback_width_ = 0;
    int readback_height_ = 0;
    std::uint64_t rendered_frames_ = 0;
    std::uint64_t decoder_uploads_ = 0;
    std::uint64_t monitor_readbacks_ = 0;
    double render_ms_ema_ = 0.0;
    double render_ms_max_ = 0.0;
    std::uint64_t missed_deadlines_ = 0;
};
