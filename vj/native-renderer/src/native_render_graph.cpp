#include "ndi_input.hpp"
#include "syphon_input.hpp"
#include "native_render_graph.hpp"
#ifdef VJ_MAPPED_METAL
#include "mapped_trace.hpp"
#endif
#include "movie_mode.hpp"
#include "playback.hpp"
#include "static_image.hpp"
#include "static_image_cache.hpp"
#ifdef VJ_MAPPED_METAL
#include "mapped_surface_metal.hpp"
#include "PatchMappedSurface.h"
#endif
#if __has_include("PatchCollection.h")
#include "PatchCollection.h"
#include "patch_particles.hpp"
#include "patch_clouds.hpp"
#include "patch_layers.hpp"
#define VJ_PATCH_COLLECTION 1
#endif

#include <algorithm>
#include <array>
#include <cmath>
#include <fstream>
#include <iomanip>
#include <limits>
#include <set>
#include <sstream>
#include <stdexcept>
#include <utility>

namespace {

using SteadyClock = std::chrono::steady_clock;

GLuint compile(GLenum type, const char *source) {
    const GLuint shader = glCreateShader(type);
    glShaderSource(shader, 1, &source, nullptr);
    glCompileShader(shader);
    GLint ok = 0;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        GLint length = 0;
        glGetShaderiv(shader, GL_INFO_LOG_LENGTH, &length);
        std::string log(static_cast<std::size_t>(std::max(1, length)), '\0');
        glGetShaderInfoLog(shader, length, nullptr, log.data());
        glDeleteShader(shader);
        throw std::runtime_error("native graph shader: " + log);
    }
    return shader;
}

GLuint make_graph_program() {
    constexpr const char *vertex = R"GLSL(
        #version 330 core
        layout(location = 0) in vec2 position;
        layout(location = 1) in vec2 uv;
        out vec2 v_uv;
        void main() {
            v_uv = uv;
            gl_Position = vec4(position, 0.0, 1.0);
        }
    )GLSL";
    constexpr const char *fragment = R"GLSL(
        #version 330 core
        in vec2 v_uv;
        out vec4 color;
        uniform sampler2D source_texture;
        uniform sampler2D bank_b_texture;
        uniform int effect;
        uniform float opacity;
        uniform float beat;
        uniform vec2 resolution;
        uniform vec2 source_size;
        uniform vec4 p0;
        uniform vec4 p1;
        uniform vec4 p2;
        uniform int fit_mode;
        uniform int image_blend;

        vec2 fitted_uv(vec2 uv) {
            if (fit_mode == 0 || source_size.y <= 0.0) return uv;
            float source_aspect = source_size.x / source_size.y;
            float target_aspect = resolution.x / resolution.y;
            vec2 result = uv;
            if (fit_mode == 1) {
                if (source_aspect > target_aspect) {
                    float scale = target_aspect / source_aspect;
                    result.y = (uv.y - 0.5) / scale + 0.5;
                } else {
                    float scale = source_aspect / target_aspect;
                    result.x = (uv.x - 0.5) / scale + 0.5;
                }
                if (any(lessThan(result, vec2(0.0)))
                    || any(greaterThan(result, vec2(1.0)))) return vec2(-2.0);
            } else {
                if (source_aspect > target_aspect) {
                    float scale = target_aspect / source_aspect;
                    result.x = (uv.x - 0.5) * scale + 0.5;
                } else {
                    float scale = source_aspect / target_aspect;
                    result.y = (uv.y - 0.5) * scale + 0.5;
                }
            }
            return result;
        }

        void main() {
            if(effect==31){color=mix(texture(source_texture,v_uv),texture(bank_b_texture,v_uv),opacity);return;}
            vec3 result = vec3(0.0);
            float alpha = opacity;
            if (effect == 0 || effect == 9) {
                vec2 uv = fitted_uv(effect == 9 && p0.y > 0.5
                    ? vec2(1.0) - v_uv : v_uv);
                result = uv.x < -1.0 ? vec3(0.0) : texture(source_texture, uv).rgb;
                if (effect == 9) {
                    result = clamp(result * p0.x, 0.0, 1.0);
                    if (image_blend == 1) result *= alpha;
                    else if (image_blend == 2) result = mix(vec3(1.0), result, alpha);
                }
            } else if (effect == 10) {
                vec2 uv = fitted_uv(p0.y > 0.5 ? vec2(1.0) - v_uv : v_uv);
                vec4 sample_color = p0.w > 0.5 ? vec4(0.0, 0.0, 0.0, 1.0)
                    : uv.x < -1.0 ? vec4(0.0) : texture(source_texture, uv);
                alpha *= sample_color.a;
                result = sample_color.rgb;
                if (p0.z > 0.5 && sample_color.a > 0.0) result /= sample_color.a;
                result = clamp(result * p0.x, 0.0, 1.0);
                if (image_blend == 1) result *= alpha;
                if (image_blend == 2) result = mix(vec3(1.0), result, alpha);
            } else if (effect == 8) {
                vec2 uv = fitted_uv((v_uv - p0.xy) / max(0.01, p0.z) + 0.5);
                vec4 sample_color = vec4(0.0);
                if (all(greaterThanEqual(uv, vec2(0.0)))
                    && all(lessThanEqual(uv, vec2(1.0)))) {
                    sample_color = texture(source_texture, uv);
                }
                alpha *= sample_color.a;
                result = sample_color.a > 0.0
                    ? clamp(sample_color.rgb / sample_color.a * p0.w, 0.0, 1.0)
                    : vec3(0.0);
                // Fixed-function screen/multiply need alpha folded into RGB.
                if (image_blend == 1) result *= alpha;
                if (image_blend == 2) result = mix(vec3(1.0), result, alpha);
            } else if (effect == 11) {
                // Vector textures contain premultiplied color and coverage.
                vec4 sample_color = texture(source_texture, v_uv);
                alpha *= sample_color.a;
                result = sample_color.a > 0.0
                    ? sample_color.rgb / sample_color.a : vec3(0.0);
                if (image_blend == 1) result *= alpha;
                else if (image_blend == 2) result = mix(vec3(1.0), result, alpha);
            } else if (effect == 30) {
                vec4 original = texture(source_texture,v_uv);
                alpha = original.a;
                result = alpha > 0.00001 ? original.rgb/alpha : vec3(0.0);
                if (p0.y > 0.5) result = vec3(1.0)-result;
                float luma = dot(result,vec3(0.299,0.587,0.114));
                result = mix(result,luma*p1.rgb,p1.a);
                result *= p0.x;
                if (p0.z > 0.5) result *= 0.25+0.75*exp(-fract(beat)*5.0);
                if (p0.w > 0.5) result *= mod(beat*2.0,1.0)<0.5 ? 1.0 : 0.0;
                result=mix(result,vec3(1.0),p2.x);alpha=mix(alpha,1.0,p2.x);
            }
            if(effect==30)result *= alpha;
            color = vec4(clamp(result,0.0,1.0), alpha);
        }
    )GLSL";
    const GLuint vs = compile(GL_VERTEX_SHADER, vertex);
    const GLuint fs = compile(GL_FRAGMENT_SHADER, fragment);
    const GLuint program = glCreateProgram();
    glAttachShader(program, vs);
    glAttachShader(program, fs);
    glLinkProgram(program);
    glDeleteShader(vs);
    glDeleteShader(fs);
    GLint ok = 0;
    glGetProgramiv(program, GL_LINK_STATUS, &ok);
    if (!ok) {
        GLint length = 0;
        glGetProgramiv(program, GL_INFO_LOG_LENGTH, &length);
        std::string log(static_cast<std::size_t>(std::max(1, length)), '\0');
        glGetProgramInfoLog(program, length, nullptr, log.data());
        glDeleteProgram(program);
        throw std::runtime_error("native graph program: " + log);
    }
    return program;
}

std::array<float, 3> parse_color(
    const SceneJson &params, const char *name,
    std::array<float, 3> default_value = {1, 1, 1}) {
    const auto item = params.find(name);
    if (item == params.end() || !item->is_string()) return default_value;
    std::string text = item->get<std::string>();
    if (text.size() != 7 || text[0] != '#') return default_value;
    try {
        for (int index = 0; index < 3; ++index) {
            default_value[index] = std::stoi(
                text.substr(1 + index * 2, 2), nullptr, 16) / 255.0f;
        }
    } catch (...) {}
    return default_value;
}

float number(const SceneJson &params, const char *name, float default_value) {
    const auto item = params.find(name);
    if (item == params.end() || !item->is_number()) return default_value;
    const float value = item->get<float>();
    return std::isfinite(value) ? value : default_value;
}

bool json_boolean(const SceneJson &params, const char *name, bool default_value) {
    const auto item = params.find(name);
    return item != params.end() && item->is_boolean()
        ? item->get<bool>() : default_value;
}

std::string text(const SceneJson &params, const char *name,
                 std::string default_value) {
    const auto item = params.find(name);
    return item != params.end() && item->is_string()
        ? item->get<std::string>() : default_value;
}

void set_vec4(GLuint program, const char *name,
              float a, float b, float c, float d) {
    glUniform4f(glGetUniformLocation(program, name), a, b, c, d);
}

}  // namespace

struct NativeRenderGraph::BusTarget {
    std::array<GLuint, 2> textures{};
    std::array<GLuint, 2> framebuffers{};
    GLuint stencil = 0;
    int active = 0;
    int width = 0;
    int height = 0;
    std::uint64_t sequence = 0;
};

struct NativeRenderGraph::SourceNode {
    std::string key;
    std::string source_id;
    std::string timeline_key;
    double known_duration=0;
    std::unique_ptr<MediaDecoder> decoder;
    std::shared_ptr<StaticImageCache::Request> image_request;
    std::string image_path;
    int image_limit=0;
    std::unique_ptr<LiveCapture> camera;
    std::unique_ptr<SyphonInput> syphon;
    std::unique_ptr<NdiInput> ndi;
    NdiSnapshot ndi_state;
    std::string backend;
    GLuint texture = 0;
    int width = 0;
    int height = 0;
    std::uint64_t uploaded_sequence = 0;
    double playhead = 0.0;
    double ping_pong_phase = 0.0;
    bool initialized = false;
    bool playing = true;
    bool audio_enabled = false;
    bool ping_pong = false;
    float speed = 1.0f;
    float loop_start = 0.0f;
    float loop_end = 1.0f;
    float position = 0.0f;
    SteadyClock::time_point updated_at = SteadyClock::now();
    SteadyClock::time_point last_used = SteadyClock::now();
    bool active = false;
};

NativeRenderGraph::NativeRenderGraph(CaptureFactory capture_factory)
    : scene_received_at_(SteadyClock::now()),
      audio_(std::make_unique<NativeAudioEngine>()),
      capture_factory_(capture_factory ? std::move(capture_factory)
          : CaptureFactory{[](const std::string &device) {
                return std::make_unique<LiveCapture>(device);
            }}) {
    ensure_program();
    ensure_geometry();
}

NativeRenderGraph::~NativeRenderGraph() {
    clear_projector_targets();
    if(projector_backdrop_)glDeleteTextures(1,&projector_backdrop_);
    sources_.clear();
    for (auto &[name, target] : buses_) {
        (void)name;
        if(target->stencil)glDeleteRenderbuffers(1,&target->stencil);
        glDeleteFramebuffers(2, target->framebuffers.data());
        glDeleteTextures(2, target->textures.data());
    }
    if (readback_framebuffer_) {
        glDeleteFramebuffers(1, &readback_framebuffer_);
    }
    if (readback_texture_) glDeleteTextures(1, &readback_texture_);
    if (vbo_) glDeleteBuffers(1, &vbo_);
    if (vao_) glDeleteVertexArrays(1, &vao_);
    if (fallback_texture_) glDeleteTextures(1, &fallback_texture_);
    if (program_) glDeleteProgram(program_);
    if (collection_program_) glDeleteProgram(collection_program_);
    if (collection_vao_) glDeleteVertexArrays(1, &collection_vao_);
    if (collection_vbo_) glDeleteBuffers(1, &collection_vbo_);
}

void NativeRenderGraph::ensure_program() {
    if (!program_) program_ = make_graph_program();
    if (!fallback_texture_) {
        // Even procedural branches need a complete sampler on Apple's GL driver.
        const unsigned char black[] = {0, 0, 0, 255};
        glGenTextures(1, &fallback_texture_);
        glBindTexture(GL_TEXTURE_2D, fallback_texture_);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 1, 1, 0, GL_RGBA, GL_UNSIGNED_BYTE, black);
    }
}

void NativeRenderGraph::ensure_geometry() {
    if (vao_) return;
    constexpr std::array<float, 16> vertices{{
        -1, -1, 0, 0, 1, -1, 1, 0,
        -1,  1, 0, 1, 1,  1, 1, 1,
    }};
    glGenVertexArrays(1, &vao_);
    glGenBuffers(1, &vbo_);
    glBindVertexArray(vao_);
    glBindBuffer(GL_ARRAY_BUFFER, vbo_);
    glBufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices.data(),
                 GL_STATIC_DRAW);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float),
                          reinterpret_cast<void *>(0));
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float),
                          reinterpret_cast<void *>(2 * sizeof(float)));
    glEnableVertexAttribArray(1);
}

void NativeRenderGraph::apply_scene(NativeScene scene) {
    processor_errors_.clear();
    clear_projector_targets();
    audio_->apply_scene(scene);
    for(auto it=buses_.begin();it!=buses_.end();){
        if(!scene.buses.contains(it->first)){
            if(it->second->stencil)glDeleteRenderbuffers(1,&it->second->stencil);
            glDeleteFramebuffers(2,it->second->framebuffers.data());glDeleteTextures(2,it->second->textures.data());it=buses_.erase(it);
        }else ++it;
    }
    // Serialized scene inputs can carry media geometry; decode it once.
    for(auto& [name,bus]:scene.buses){
        bus.card_vertices=bus.collection.value("cardVertices",std::vector<float>{});
        for(auto& layer:bus.layers){
        if(auto vertices=layer.params.find("_media_vertices");vertices!=layer.params.end()){
            layer.media_vertices=std::make_shared<const std::vector<float>>(vertices->get<std::vector<float>>());
            layer.params.erase(vertices);
        }
        }
    }
    resolved_patch_dependencies_.clear();photo_geometry_.clear();
    scene_ = std::move(scene);
    scene_received_at_ = SteadyClock::now();
}

void NativeRenderGraph::set_bus_sizes(
    std::map<std::string, std::array<int, 2>> sizes) {
    for(const auto &[name,bus]:scene_.buses){
        if(bus.crossfade.empty() || !sizes.contains(name))continue;
        const auto mix=bus.crossfade.value("value",0.0f);
        if(mix<1) sizes[bus.crossfade.at("a").get<std::string>()]=sizes.at(name);
        if(mix>0) sizes[bus.crossfade.at("b").get<std::string>()]=sizes.at(name);
    }
    // Release targets that no presentation/stream now demands. Scene/audio
    // identities remain present; a later viewer re-creates only its raster target.
    for(auto it=buses_.begin();it!=buses_.end();){if(!sizes.contains(it->first)){if(it->second->stencil)glDeleteRenderbuffers(1,&it->second->stencil);glDeleteFramebuffers(2,it->second->framebuffers.data());glDeleteTextures(2,it->second->textures.data());it=buses_.erase(it);}else ++it;}
    render_sizes_ = std::move(sizes);
}

void NativeRenderGraph::ensure_bus_target(const std::string &bus) {
    auto &slot = buses_[bus];
    if (!slot) slot = std::make_unique<BusTarget>();
    BusTarget &target = *slot;
    const auto requested = render_sizes_.find(bus);
    const int requested_width = requested == render_sizes_.end()
        ? scene_.canvas_width : requested->second[0];
    const int requested_height = requested == render_sizes_.end()
        ? scene_.canvas_height : requested->second[1];
    if (target.width == requested_width
        && target.height == requested_height
        && target.textures[0]) {
        return;
    }
    if (target.textures[0]) {
        if(target.stencil){glDeleteRenderbuffers(1,&target.stencil);target.stencil=0;}
        glDeleteFramebuffers(2, target.framebuffers.data());
        glDeleteTextures(2, target.textures.data());
    }
    target.width = requested_width;
    target.height = requested_height;
    glGenTextures(2, target.textures.data());
    glGenFramebuffers(2, target.framebuffers.data());
    if(bus.starts_with("collection")){
        glGenRenderbuffers(1,&target.stencil);glBindRenderbuffer(GL_RENDERBUFFER,target.stencil);
        glRenderbufferStorage(GL_RENDERBUFFER,GL_DEPTH24_STENCIL8,target.width,target.height);
    }
    for (int index = 0; index < 2; ++index) {
        glBindTexture(GL_TEXTURE_2D, target.textures[index]);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, target.width, target.height,
                     0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
        glBindFramebuffer(GL_FRAMEBUFFER, target.framebuffers[index]);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                               GL_TEXTURE_2D, target.textures[index], 0);
        if(target.stencil)glFramebufferRenderbuffer(GL_FRAMEBUFFER,GL_DEPTH_STENCIL_ATTACHMENT,GL_RENDERBUFFER,target.stencil);
        if (glCheckFramebufferStatus(GL_FRAMEBUFFER)
            != GL_FRAMEBUFFER_COMPLETE) {
            throw std::runtime_error("native bus framebuffer incomplete");
        }
    }
    target.active = 0;
}

std::string NativeRenderGraph::source_key(const NativeLayer &layer) {
    if (layer.generator == "image") return "image\n"+layer.resolved_file;
    if (layer.generator == "ndi") return "ndi\n" + layer.resolved_file;
    if (layer.generator == "syphon") return "syphon\n" + layer.resolved_file;
    // Live copies share the physical device even when added independently.
    // Fit, opacity and output dimensions must not reopen an exclusive camera.
    if (layer.generator == "usb_webcam") return "camera\n" + layer.resolved_file;
    std::ostringstream key;
    key << layer.source_id << '\n' << layer.generator << '\n' << layer.resolved_file << '\n'
        << layer.subtitle_asset << '\n'
        << text(layer.params, "loop_mode", "forward") << '\n'
        << number(layer.params, "loop_start", 0.0f) << '\n'
        << number(layer.params, "loop_end", 1.0f) << '\n'
        << number(layer.params, "position", 0.0f) << '\n'
        << number(layer.params, "seek_nonce", 0.0f);
    return key.str();
}

NativeRenderGraph::SourceNode *NativeRenderGraph::source_for(
    const NativeLayer &layer) {
    if ((layer.generator != "video" && layer.generator != "text"
         && layer.generator != "image" && layer.generator != "usb_webcam" && layer.generator != "syphon" && layer.generator != "ndi")
        || layer.resolved_file.empty()) {
        return nullptr;
    }
    const auto requirement = source_sizes_.find(source_key(layer));
    const int decode_width = requirement == source_sizes_.end()
        ? scene_.canvas_width : requirement->second[0];
    const int decode_height = requirement == source_sizes_.end()
        ? scene_.canvas_height : requirement->second[1];
    std::string media_path = layer.resolved_file;
    const NativeLayer::Rendition *largest = nullptr;
    for (const auto &rendition : layer.renditions) {
        if (!largest
            || rendition.width * rendition.height
                > largest->width * largest->height) {
            largest = &rendition;
        }
        if (rendition.width >= decode_width
            && rendition.height >= decode_height) {
            media_path = rendition.path;
            break;
        }
    }
    if (media_path == layer.resolved_file && largest) {
        media_path = largest->path;
    }
    int imageLimit=256;while(imageLimit<std::max(decode_width,decode_height)&&imageLimit<8192)imageLimit*=2;
    const std::string key = layer.generator=="image" ? "image\n"+media_path+"\n"+std::to_string(imageLimit) : (layer.generator == "usb_webcam" || layer.generator == "syphon" || layer.generator == "ndi")
        ? source_key(layer) : source_key(layer) + "\n"
        + media_path + "\n"
        + std::to_string(decode_width) + "x"
        + std::to_string(decode_height);
    auto &slot = sources_[key];
    if (!slot) {
        slot = std::make_unique<SourceNode>();
        slot->key = key;
        slot->source_id = layer.source_id;
        if(layer.generator=="video"){
            auto timeline=layer;timeline.subtitle_asset.clear();slot->timeline_key=source_key(timeline);
            // Decode dimensions, cached renditions and prepared subtitles are
            // adapters for the same launch. Preserve its media position while
            // rebuilding that adapter; explicit seek/loop edits remain new keys.
            for(const auto& [previousKey,previous]:sources_)if(previous.get()!=slot.get()&&previous&&previous->decoder&&previous->initialized&&previous->timeline_key==slot->timeline_key){
                slot->playhead=previous->playhead;slot->ping_pong_phase=previous->ping_pong_phase;slot->initialized=true;slot->updated_at=previous->updated_at;
                slot->known_duration=std::max(previous->known_duration,previous->decoder->duration());break;
            }
        }
        slot->playing = json_boolean(layer.params, "playing", true);
        slot->ping_pong =
            text(layer.params, "loop_mode", "forward") == "ping-pong";
        slot->audio_enabled =
            json_boolean(layer.params, "audio_enabled", false)
            && !slot->ping_pong;
        slot->speed = number(layer.params, "speed", 1.0f);
        slot->loop_start = number(layer.params, "loop_start", 0.0f);
        slot->loop_end = number(layer.params, "loop_end", 1.0f);
        slot->position = number(layer.params, "position", 0.0f);
        if(!slot->initialized)slot->updated_at = SteadyClock::now();
        glGenTextures(1, &slot->texture);
        glBindTexture(GL_TEXTURE_2D, slot->texture);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        if (layer.generator == "syphon" || layer.generator == "ndi") {
            const unsigned char black[] = {0, 0, 0, 255};
            glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 1, 1, 0, GL_RGBA, GL_UNSIGNED_BYTE, black);
            slot->width = slot->height = 1;
            if (layer.generator == "syphon") slot->syphon = std::make_unique<SyphonInput>(media_path);
            else slot->ndi = std::make_unique<NdiInput>(media_path);
            slot->backend = layer.generator;
        } else if (layer.generator == "usb_webcam") {
            slot->camera = capture_factory_(media_path);
            slot->backend = LiveCapture::platform_format;
        } else if (layer.generator == "image") {
            const unsigned char empty[]={0,0,0,0};
            glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,1,1,0,GL_RGBA,GL_UNSIGNED_BYTE,empty);
            slot->image_path=media_path;slot->image_limit=imageLimit;
            slot->image_request=StaticImageCache::shared().request(media_path,imageLimit);
            slot->backend="image-loading";
        } else if (layer.generator == "text") {
            if (const auto image = load_static_image(media_path)) {
                glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
                glTexImage2D(
                    GL_TEXTURE_2D, 0, GL_RGBA8,
                    image->width, image->height, 0,
                    GL_RGBA, GL_UNSIGNED_BYTE, image->pixels.data());
                slot->width = image->width;
                slot->height = image->height;
                slot->uploaded_sequence = 1;
                slot->backend = "static-text";
            } else {
                slot->backend = "text-load-failed";
            }
        } else {
            slot->decoder = std::make_unique<MediaDecoder>(
                media_path, decode_width, decode_height,
                layer.subtitle_asset, slot->ping_pong);
            slot->decoder->request(slot->initialized?slot->playhead:0.0);
        }
    }
    // Transport edits keep the decoder and its current timeline. Explicit seek
    // position/nonce and loop changes still identify a new source above.
    slot->playing=json_boolean(layer.params,"playing",true);
    slot->speed=number(layer.params,"speed",1.0f);
    slot->audio_enabled=json_boolean(layer.params,"audio_enabled",false)&&!slot->ping_pong;
    return slot.get();
}

void NativeRenderGraph::update_sources() {
    // Discovery is demand-driven. A plain raster preview must not enumerate
    // Syphon senders merely because the transport is linked into the engine.
    bool needs_syphon=false;
    for(const auto& [name,bus]:scene_.buses){
        if(!render_sizes_.contains(name))continue;
        for(const auto& layer:bus.layers)
            if(layer.enabled&&layer.generator=="syphon"&&!layer.resolved_file.empty()){needs_syphon=true;break;}
        if(needs_syphon)break;
    }
    if(needs_syphon)syphon_poll();
    source_sizes_.clear();
    for (const auto &[bus_name, bus] : scene_.buses) {
        const auto demand = render_sizes_.find(bus_name);
        if (demand == render_sizes_.end()) continue;
        for (const auto &layer : bus.layers) {
            if (!layer.enabled
                || (layer.generator != "video"
                    && layer.generator != "text" && layer.generator != "image"
                    && layer.generator != "usb_webcam" && layer.generator != "syphon" && layer.generator != "ndi")
                || layer.resolved_file.empty()) {
                continue;
            }
            auto &size = source_sizes_[source_key(layer)];
            size[0] = std::max(size[0], demand->second[0]);
            size[1] = std::max(size[1], demand->second[1]);
        }
    }
    std::set<std::string> active;
    if (!calibration_camera_.empty()) {
        NativeLayer camera; camera.generator="usb_webcam"; camera.resolved_file=calibration_camera_; camera.source_id="calibration";
        if (auto *source=source_for(camera)) active.insert(source->key);
    }
    for (const auto &[bus_name, bus] : scene_.buses) {
        if (!render_sizes_.contains(bus_name)) continue;
        for (const auto &layer : bus.layers) {
            if (!layer.enabled
                || (layer.generator != "video"
                    && layer.generator != "text" && layer.generator != "image"
                    && layer.generator != "usb_webcam" && layer.generator != "syphon" && layer.generator != "ndi")) {
                continue;
            }
            if (auto *source = source_for(layer)) {
                active.insert(source->key);
                // Delays NDI playback to smooth uneven frame arrival.
                if (source->ndi) source->ndi->set_buffer_ms(static_cast<int>(number(layer.params, "buffer", 0.0f)));
            }
        }
    }
    const auto now = SteadyClock::now();
    int imageUploads=0;
    for (const auto &key : active) {
        SourceNode &source = *sources_.at(key);
        source.last_used=now;
        if(source.backend=="image-loading"){
            if(!source.image_request)source.image_request=StaticImageCache::shared().request(source.image_path,source.image_limit);
            if(source.image_request&&source.image_request->ready.load()&&imageUploads<2){
                const auto image=source.image_request->image;
                if(image){
                    glBindTexture(GL_TEXTURE_2D,source.texture);glPixelStorei(GL_UNPACK_ALIGNMENT,1);
                    glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,image->width,image->height,0,GL_RGBA,GL_UNSIGNED_BYTE,image->pixels.data());
                    source.width=image->width;source.height=image->height;source.uploaded_sequence=1;source.backend="static-image";++imageUploads;
                }else source.backend="image-load-failed";
                source.image_request.reset();
            }
        }
        if (source.ndi) {
            source.ndi_state = source.ndi->snapshot();
            const auto &frame = source.ndi_state.frame;
            if (frame && frame->sequence != source.uploaded_sequence) {
                glBindTexture(GL_TEXTURE_2D, source.texture);
                glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
                if (source.width != frame->width || source.height != frame->height)
                    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, frame->width, frame->height,
                        0, GL_RGBA, GL_UNSIGNED_BYTE, frame->rgba.data());
                else glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, frame->width, frame->height,
                        GL_RGBA, GL_UNSIGNED_BYTE, frame->rgba.data());
                source.width = frame->width; source.height = frame->height;
                source.uploaded_sequence = frame->sequence;
                ++decoder_uploads_;
            }
            continue;
        }
        if (source.syphon) {
            if (source.syphon->update(source.texture, source.width, source.height))
                ++source.uploaded_sequence;
            continue;
        }
        if (!source.decoder && !source.camera) continue;
        std::optional<DecodedVideoFrame> frame;
        if (source.camera) {
            frame = source.camera->latest();
            if (!frame) source.uploaded_sequence = 0;
        } else {
            const double dt =
                std::chrono::duration<double>(now - source.updated_at).count();
            source.updated_at = now;
            const double decoded_duration=source.decoder->duration();if(decoded_duration>0)source.known_duration=decoded_duration;
            const double duration=source.known_duration;
            if (duration > 0.0 && !source.initialized) {
                const double start = duration * std::clamp(
                    static_cast<double>(source.loop_start), 0.0, 1.0);
                const double end = duration * std::clamp(
                    static_cast<double>(source.loop_end), 0.0, 1.0);
                source.playhead = start + std::clamp(
                    static_cast<double>(source.position), 0.0, 1.0)
                    * std::max(0.0, end - start);
                source.ping_pong_phase = source.playhead - start;
                source.initialized = true;
            }
            const bool audio_master = source.audio_enabled
                && audio_->owns_source(source.source_id);
            if (audio_master) {
                if (const auto audio_playhead =
                        audio_->playhead_for(source.source_id)) {
                    source.playhead = *audio_playhead;
                    source.initialized = true;
                }
            } else if (source.playing && source.initialized) {
                const double start = duration * source.loop_start;
                const double end = duration * source.loop_end;
                const double span = std::max(0.001, end - start);
                if (source.ping_pong) {
                    source.ping_pong_phase += dt * source.speed;
                    source.playhead = ping_pong_position(
                        source.ping_pong_phase, start, end);
                } else {
                    source.playhead += dt * source.speed;
                    if (source.playhead > end) {
                        source.playhead = start
                            + std::fmod(source.playhead - start, span);
                    }
                }
            }
            double presentation_playhead = source.playhead;
            if (duration > 0.0) {
                const double start = duration * source.loop_start;
                const double end = duration * source.loop_end;
                const double span = std::max(0.001, end - start);
                if (source.ping_pong) {
                    presentation_playhead = ping_pong_position(
                        source.ping_pong_phase
                            + scene_.mix.video_shift_seconds,
                        start, end);
                } else {
                    presentation_playhead += scene_.mix.video_shift_seconds;
                    presentation_playhead = start + std::fmod(
                        std::fmod(presentation_playhead - start, span) + span,
                        span);
                }
            }
            source.decoder->request(presentation_playhead);
            frame = source.decoder->latest();
        }
        if (!frame || frame->sequence == source.uploaded_sequence
            || !frame->rgb) {
            continue;
        }
        glBindTexture(GL_TEXTURE_2D, source.texture);
        glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
        if (source.width != frame->width || source.height != frame->height) {
            glTexImage2D(GL_TEXTURE_2D, 0, GL_RGB8,
                         frame->width, frame->height, 0,
                         GL_RGB, GL_UNSIGNED_BYTE, frame->rgb->data());
            source.width = frame->width;
            source.height = frame->height;
        } else {
            glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0,
                            frame->width, frame->height,
                            GL_RGB, GL_UNSIGNED_BYTE, frame->rgb->data());
        }
        source.uploaded_sequence = frame->sequence;
        ++decoder_uploads_;
    }
    std::vector<std::pair<SteadyClock::time_point,std::string>> dormantSyphon;
    for(auto& [key,source]:sources_){source->active=active.contains(key);if(source->syphon&&!source->active)dormantSyphon.emplace_back(source->last_used,key);}
    std::sort(dormantSyphon.rbegin(),dormantSyphon.rend());
    std::set<std::string> warmSyphon;size_t warmBytes=0;
    for(const auto& [used,key]:dormantSyphon){const auto& source=*sources_.at(key);const size_t bytes=size_t(std::max(1,source.width))*std::max(1,source.height)*4;
        if(warmSyphon.size()<32&&warmBytes+bytes<=128*1024*1024){warmSyphon.insert(key);warmBytes+=bytes;}}
    for (auto iterator = sources_.begin(); iterator != sources_.end();) {
        if (active.contains(iterator->first) || warmSyphon.contains(iterator->first)) {
            ++iterator;
            continue;
        }
        if (iterator->second->texture) {
            glDeleteTextures(1, &iterator->second->texture);
        }
        iterator = sources_.erase(iterator);
    }
}

void NativeRenderGraph::draw_layer(
    const NativeLayer &layer, int target_width, int target_height, GLuint input_texture) {
    int effect = -1;
    GLuint texture_id = input_texture ? input_texture : fallback_texture_;
    int source_width = target_width, source_height = target_height;
    bool live_black = false;
    if (!layer.vector.empty() && input_texture) {
        effect = 11;
    } else if (layer.generator == "video" || layer.generator == "usb_webcam" || layer.generator == "syphon" || layer.generator == "ndi") {
        if (auto *source = source_for(layer);
            source && (source->uploaded_sequence > 0 || source->syphon || source->ndi)) {
            const bool online = source->syphon ? source->syphon->connected() : source->ndi_state.connected;
            live_black = (source->syphon || source->ndi) && (source->uploaded_sequence == 0
                || (!online && text(layer.params, "disconnect", "black") != "freeze"));
            effect = (layer.generator == "syphon" || layer.generator == "ndi") ? 10 : layer.generator == "usb_webcam" ? 9 : 0;
            texture_id = source->texture;
            source_width = source->width;
            source_height = source->height;
        }
    } else if (layer.generator == "text" || layer.generator == "image") {
        if (auto *source = source_for(layer);
            source && source->uploaded_sequence > 0) {
            effect = 8; // Still images and text both carry premultiplied RGBA.
            texture_id = source->texture;
            source_width = source->width;
            source_height = source->height;
        }
    }
    if (effect < 0) return;

    glUseProgram(program_);
    glBindVertexArray(vao_);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, texture_id);
    glUniform1i(glGetUniformLocation(program_, "source_texture"), 0);
    glUniform1i(glGetUniformLocation(program_, "effect"), effect);
    glUniform1f(glGetUniformLocation(program_, "opacity"), layer.opacity);
    glUniform2f(glGetUniformLocation(program_, "resolution"),
                static_cast<float>(target_width),
                static_cast<float>(target_height));
    glUniform2f(glGetUniformLocation(program_, "source_size"),
                static_cast<float>(source_width),
                static_cast<float>(source_height));
    set_vec4(program_, "p0", 0, 0, 0, 0);
    set_vec4(program_, "p1", 0, 0, 0, 0);
    set_vec4(program_, "p2", 0, 0, 0, 0);
    glUniform1i(glGetUniformLocation(program_, "fit_mode"), 0);
    glUniform1i(glGetUniformLocation(program_, "image_blend"),
        layer.blend == "screen" ? 1 : layer.blend == "multiply" ? 2 : 0);

    const auto &p = layer.params;
    if (effect == 0 || effect == 8 || effect == 9 || effect == 10) {
        const std::string fit = text(p, "fit", layer.generator == "text" ? "stretch" : effect == 8 ? "contain"
            : (effect == 9 || effect == 10) ? "cover" : "stretch");
        glUniform1i(glGetUniformLocation(program_, "fit_mode"),
                    fit == "contain" ? 1 : fit == "cover" ? 2 : 0);
        if (effect == 9) set_vec4(program_, "p0", number(p, "gain", 1),
            json_boolean(p, "rotate_180", false) ? 1 : 0, 0, 0);
        if (effect == 10) set_vec4(program_, "p0", number(p, "gain", 1),
            json_boolean(p, "rotate_180", false) ? 1 : 0,
            text(p, "alpha", "straight") == "premultiplied" ? 1 : 0, live_black ? 1 : 0);
        if (effect == 8 && layer.generator == "text") {
            // Text placement is already baked into the transparent canvas.
            set_vec4(program_, "p0", .5f, .5f, 1, 1);
        } else if (effect == 8) {
            set_vec4(program_, "p0", number(p, "x", 0.5f),
                number(p, "y", 0.5f), number(p, "scale", 1), number(p, "gain", 1));
        }
    }
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}

void NativeRenderGraph::draw_master(
    const NativeBus &bus, BusTarget &target) {
    NativeLayer master;
    master.generator = "__master";
    master.opacity = 1.0f;
    const int next = 1 - target.active;
    glBindFramebuffer(GL_FRAMEBUFFER, target.framebuffers[next]);
    glViewport(0, 0, target.width, target.height);
    glDisable(GL_BLEND);
    glUseProgram(program_);
    glBindVertexArray(vao_);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, target.textures[target.active]);
    glUniform1i(glGetUniformLocation(program_, "source_texture"), 0);
    glUniform1i(glGetUniformLocation(program_, "effect"), 30);
    glUniform1f(glGetUniformLocation(program_, "opacity"), 1);
    const double elapsed = bus.clock.playing
        ? std::chrono::duration<double>(
            SteadyClock::now() - scene_received_at_).count() : 0.0;
    const double beat = bus.clock.beat
        + elapsed * bus.clock.bpm / 60.0;
    glUniform1f(glGetUniformLocation(program_, "beat"),
                static_cast<float>(beat));
    glUniform2f(glGetUniformLocation(program_, "resolution"),
                static_cast<float>(target.width),
                static_cast<float>(target.height));
    const float gain = scene_.mix.video_mute
        || scene_.mix.blackout ? 0.0f : scene_.mix.video_master;
    set_vec4(program_, "p0", gain, scene_.mix.invert ? 1.0f : 0.0f,
             scene_.mix.pulse ? 1.0f : 0.0f,
             scene_.mix.strobe ? 1.0f : 0.0f);
    const auto cast = parse_color(
        SceneJson{{"cast", scene_.mix.cast}}, "cast", {1, 1, 1});
    set_vec4(program_, "p1", cast[0], cast[1], cast[2],
             scene_.mix.cast.empty() ? 0.0f : scene_.mix.cast_amount);
    const double now=std::chrono::duration<double>(SteadyClock::now().time_since_epoch()).count();
    double flash=scene_.mix.flash_at>0?std::exp(-(now+scene_.mix.video_shift_seconds-scene_.mix.flash_at)*7):0;
    if(flash<.01)flash=0;
    set_vec4(program_, "p2", std::min(1.,flash), 0, 0, 0);
    glUniform1i(glGetUniformLocation(program_, "fit_mode"), 0);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    target.active = next;
}

void NativeRenderGraph::draw_collection(const NativeBus &bus, const NativeLayer &layer,
                                      GLuint texture, int width, int height, bool geometry, double seconds,bool localBackdrop) {
#ifdef VJ_MAPPED_METAL
    if(geometry && layer.collection_geometry=="trace"){
        static const std::vector<float> face={-1,-1,0,0,1,0,1,0, 1,-1,1,0,1,0,1,0, 1,1,1,1,1,0,1,0,
                                             -1,-1,0,0,1,0,1,0, 1,1,1,1,1,0,1,0, -1,1,0,1,1,0,1,0};
        const auto mesh=bus.collection.value("traceVertices",face);
        const double elapsed=bus.clock.playing?std::chrono::duration<double>(SteadyClock::now()-scene_received_at_).count():0.;
        vj::mapped_trace::draw(mapped_metal_,layer.params.value("_patch_recipe",SceneJson::object()),bus.collection,
                               mesh,width,height,layer.blend,layer.opacity,bus.clock.beat+elapsed*bus.clock.bpm/60.);
        return;
    }
#endif
    if (!collection_program_) {
        const char *vs=R"GLSL(#version 330 core
layout(location=0) in vec2 p;layout(location=1) in vec3 uvq;layout(location=2) in vec3 data;
layout(location=3) in vec4 inkClipData;layout(location=4) in vec4 inkColorData;
out vec3 uv;out vec3 graph;out vec4 inkClip;out vec4 inkColor;
void main(){gl_Position=vec4(p,0,1);uv=uvq;graph=data;inkClip=inkClipData;inkColor=inkColorData;})GLSL";
        const char *fs="#version 330 core\n"
#ifdef VJ_MAPPED_METAL
            "#define VJ_MAPPED_METAL 1\n"
#endif
            R"GLSL(
in vec3 uv;in vec3 graph;in vec4 inkClip;in vec4 inkColor;out vec4 color;
uniform sampler2D source;uniform int shape;uniform bool premultiplied,fitClip;
uniform int mediaFit;uniform float mediaSourceAspect;
uniform int gateFit;uniform float gateAspect;uniform vec2 gatePosition;
uniform vec2 contentPositions[128];
uniform vec3 tint;uniform float opacity;uniform int blend;uniform float faceAlpha;
uniform vec4 particleClip;
uniform float inkGlow;uniform bool inkCircles,inkGlass;uniform float glassFrost,glassRefraction;
uniform sampler2D projectorBackdrop;uniform bool hasProjectorBackdrop,hasLocalBackdrop;uniform int projectorRotation;uniform vec2 glassBufferSize;
vec3 glassBackdrop(vec2 p){
    vec4 local=hasLocalBackdrop?texture(source,p):vec4(0);
    if(!hasProjectorBackdrop)return local.rgb;
    // Collection coordinates are logical projector coordinates. The captured
    // framebuffer has bottom-origin pixels after physical output rotation.
    vec2 q=p;
    if(projectorRotation==90)q=vec2(1.0-p.y,p.x);
    else if(projectorRotation==180)q=1.0-p;
    else if(projectorRotation==270)q=vec2(p.y,1.0-p.x);
    q.y=1.0-q.y;
    return local.rgb+texture(projectorBackdrop,q).rgb*(1.0-local.a);
}
uniform float coreWidth,glowRadius,glowAmount,brightness,centerGlow,falloff;
uniform bool pulses;uniform float seconds,pulseSpeed,pulseRate,pulseWidth,pulseAmount,sparkle,routeLength;
uniform int direction;
#ifndef VJ_MAPPED_METAL
uniform int traceKind,traceMode;uniform bool traceReverse,traceSequence,traceSync,traceEnd,traceReflect,traceSingleColor;
uniform float traceWidth,traceOffset,traceBeat,traceSpeed,traceBeatSpeed,traceTail,traceDrag,traceRainbow;
uniform float traceRate,tracePerBeat,traceAttack,traceRelease,traceOnTime,traceFloor,traceCurve,traceSpread,tracePulse,traceBreathe;
uniform float traceStart,traceFinish,traceSeed;
uniform float traceMotionTime,traceMotionDistance,traceMotionJitterDistance,traceMotionRatePhase;
uniform float traceBurst,traceJitter,traceLength,traceCrackle,traceForks,traceSpray;
uniform vec3 traceTint,traceCore,traceGlow;
uniform int tracePaletteCount;uniform vec3 traceColors[256];uniform float traceNodeSeed;
vec3 traceInputColor(float packet){int i=int(mod(packet,float(max(1,tracePaletteCount))));return tracePaletteCount>0?traceColors[i]:traceGlow;}
vec3 tracePalette(float h){return .5+.5*cos(6.2831853*(h-vec3(0,.33333333,.66666667)));}
vec3 traceColor(float x,float identity){
    float env=exp(-3*fract(traceBeat));
    if(traceKind==1)return tracePalette(x*traceSpread+traceBeat*traceSpeed*.25)*brightness*(1-tracePulse*(1-env));
    if(traceKind==2){
        float phase=fract(traceSync?traceBeat*tracePerBeat:traceMotionRatePhase+(seconds-traceMotionTime)*traceRate);
        float scale=traceOnTime/max(1.0,traceAttack+traceRelease);
        float attack=traceAttack*scale,release=traceRelease*scale;
        float a=phase>=traceOnTime?0.0:min(1.0,min(attack>0?phase/attack:1.0,release>0?(traceOnTime-phase)/release:1.0));
        return traceTint*(traceFloor+(1-traceFloor)*pow(a*a*(3-2*a),traceCurve));
    }
    if(traceKind==3)return traceTint*(1-traceBreathe*.6*(1-env));
    if(traceKind==4){
        if(traceRate<=0 && !traceReflect)return vec3(0);
        float start=min(traceStart,traceFinish),end=max(traceStart,traceFinish),span=end-start;
        if(span<.000001 || x<start || x>end)return vec3(0);
        x=traceEnd?end-x:x-start;
        identity=mod(identity+traceNodeSeed,65521.0);
        float speed=max(.001,traceSpeed),w=max(.002,traceLength),latest=floor(seconds*traceRate);
        float count=min(1024.0,ceil((span+w*(1+traceTail*4+.88))/(speed*max(.05,1-traceJitter*.5))*traceRate)+1);
        if(traceReflect)count=1;
        float noise=mod(floor(x*120)*37.0+floor(seconds*30)*17.0+identity*13.0,101.0)/101.0;
        vec3 baseGlow=traceInputColor(latest);
        vec3 glow=traceSingleColor?baseGlow:mix(baseGlow,tracePalette(x+seconds*.09),traceRainbow);
        vec3 coreColor=traceSingleColor?glow:traceCore;
        vec3 result=glow*traceSpray*exp(-x*35)*noise*.25;
        for(int i=0;i<1024;i++){
            float packet=latest-float(i);if(float(i)>=count || packet<0)break;
            float seed=mod(packet*37.0+identity*17.0,1009.0)/1009.0,pos,heading=1;
            if(traceReflect){
                float elapsed=seconds-traceMotionTime;
                float distance=traceMotionDistance+elapsed*speed;
                float jitterDistance=traceMotionJitterDistance+elapsed*speed*traceJitter;
                float travel=(distance+jitterDistance*(mod(identity*17.0,1009.0)/1009.0-.5))/span;
                float phase=mod(travel,2.0);pos=span*(phase<1?phase:2-phase);heading=phase<1?1:-1;
                seed=mod(floor(travel)*37.0+identity*17.0,1009.0)/1009.0;
                baseGlow=traceInputColor(floor(travel));
            }else {pos=(seconds-packet/traceRate)*speed*(1+traceJitter*(seed-.5));baseGlow=traceInputColor(packet);}
            glow=traceSingleColor?baseGlow:mix(baseGlow,tracePalette(x+seconds*.09),traceRainbow);coreColor=traceSingleColor?glow:traceCore;
            float d=(x-pos)*heading,head=exp(-.5*pow(d/(w*.22),2));
            float tail=clamp(1+d/(w*(1+traceTail*4)),0,1)*float(d<=0);
            float flow=(head*.55+tail*.75)*(1-traceCrackle*.9*(1-noise));
            flow+=traceForks*head*pow(sin(x*250+seconds*70+identity*.37),2)*.3;
            result+=(glow*flow+coreColor*head)*(1+traceBurst*seed);
        }
        return clamp(result*brightness,0,1);
    }
    float phase=traceSync?traceBeat*traceBeatSpeed:seconds*traceSpeed;
    float d=fract(phase-x);
    float body=max(clamp(1-d/traceTail,0,1),traceDrag*exp(-d/max(.005,traceTail*(.2+traceDrag))));
    return mix(traceTint,tracePalette(x+seconds*.04),traceRainbow)*body;
}
#endif
uniform float flowSpeed,flowDensity,flowWidth,flowFoam,flowTurbulence;
uniform int sphereTrails;uniform float sphereSpeed,sphereTail,sphereWidth,sphereSpread,sphereFadeStart,sphereFadeAmount;uniform vec3 spherePose,sphereRotate;
vec3 rotateX(vec3 p,float a){float c=cos(a),s=sin(a);return vec3(p.x,c*p.y-s*p.z,s*p.y+c*p.z);}
vec3 rotateY(vec3 p,float a){float c=cos(a),s=sin(a);return vec3(c*p.x+s*p.z,p.y,-s*p.x+c*p.z);}
vec3 rotateZ(vec3 p,float a){float c=cos(a),s=sin(a);return vec3(c*p.x-s*p.y,s*p.x+c*p.y,p.z);}
float pulse(float distance){
    if(!pulses)return 1.0;
    if(distance<0.0)return mix(1.0,.12,pulseAmount);
    bool reverse=direction==1||(direction==2&&mod(floor(seconds/(routeLength/max(.01,pulseSpeed)+1.0/max(.1,pulseRate))),2.0)>0.5);
    if(reverse)distance=routeLength-distance;
    float phase=fract((seconds-distance/max(.01,pulseSpeed))*pulseRate);
    float d=min(phase,1.0-phase)/max(.01,pulseWidth);
    float flicker=fract(sin(floor(seconds*30.0)+floor(distance*80.0)*12.9898)*43758.5453);
    return mix(1.0,.12+.88*exp(-4.0*d*d)*mix(1.0,.2+.8*flicker,sparkle),pulseAmount);
}
// Graph Clouds: mirrors PatchClouds.h and Patch's graphCloudPreview kernel.
uniform vec4 cloudPoints[72];uniform vec4 cloudInfo[24];uniform vec3 cloudColors[24];uniform int cloudCount;
uniform vec4 cloudSky,cloudShape,cloudMotion;
float cloudHash(ivec2 c){uint x=uint(c.x)*73856093u^uint(c.y)*19349663u;x^=x>>16;x*=0x7feb352du;x^=x>>15;x*=0x846ca68bu;x^=x>>16;return float(x%65536u)/65535.0;}
float cloudNoise(vec2 p){vec2 i=floor(p),f=fract(p);f=f*f*(3.0-2.0*f);ivec2 c=ivec2(i);
    float a=cloudHash(c),b=cloudHash(c+ivec2(1,0)),d=cloudHash(c+ivec2(0,1)),e=cloudHash(c+ivec2(1,1));
    return a+(b-a)*f.x+(d-a)*f.y+(a-b-d+e)*f.x*f.y;}
float cloudFbm(vec2 p){float v=0.0,a=.5;for(int i=0;i<4;i++){v+=a*cloudNoise(p);p=p*2.03+vec2(17.1,9.7);a*=.5;}return v/.9375;}
vec4 cloudField(vec2 p,ivec2 pixel){
    float time=cloudMotion.w,sum=0.0,weight=1e-5;vec3 tint=cloudColors[0]*cloudColors[0]*1e-5;
    for(int i=0;i<24;i++){
        if(i>=cloudCount)break;
        vec2 pts[6]=vec2[6](cloudPoints[i*3].xy,cloudPoints[i*3].zw,cloudPoints[i*3+1].xy,cloudPoints[i*3+1].zw,cloudPoints[i*3+2].xy,cloudPoints[i*3+2].zw);
        float nearest=1e9,along=0.0,side=0.0,cum=0.0;
        for(int k=0;k<5;k++){vec2 d=pts[k+1]-pts[k];float l2=dot(d,d),l=sqrt(l2);
            float t=l2>1e-12?clamp(dot(p-pts[k],d)/l2,0.0,1.0):0.0;vec2 r=p-pts[k]-d*t;float dist=length(r);
            if(dist<nearest){nearest=dist;along=cum+t*l;side=l>1e-9?(d.x*r.y-d.y*r.x)/l:0.0;}cum+=l;}
        float a=cum>1e-9?along/cum:0.0,profile=pow(max(0.0,sin(3.14159265*clamp(a*.92+.04,0.0,1.0))),.6);
        float width=cloudInfo[i].x,w=width*(.3+.7*profile),r=nearest/max(w,1e-5);if(r>3.5)continue;
        float n=cloudFbm(vec2(along/(width*4.0)+float(i)*31.7-time*.15,side/(width*.38)+float(i)*7.3));
        float body=exp(-r*r*(2.6-1.7*cloudShape.x))*(1.0-cloudShape.z+cloudShape.z*(.15+1.7*n*n))*cloudInfo[i].y;
        sum=1.0-(1.0-sum)*(1.0-min(1.0,body));float k=body*body;tint+=cloudColors[i]*cloudColors[i]*k;weight+=k;
    }
    vec3 cloud=sqrt(tint/weight);
    float lo=(1.0-cloudShape.y)*.45,hi=lo+.15+.75*cloudShape.x,coverage=smoothstep(0.0,1.0,(sum-lo)/(hi-lo));
    float c=cos(cloudMotion.x),sn=sin(cloudMotion.x);vec2 q=vec2(c*p.x+sn*p.y,-sn*p.x+c*p.y);
    float haze=smoothstep(0.0,1.0,(cloudFbm(vec2(q.x*1.4-time*(.03+cloudMotion.z*.5),q.y*7.0))-.5)/.3)*cloudShape.w*.7;
    // cloudSky.w: 1 paints the sky, 0 leaves it clear so clouds layer over other effects.
    vec3 wisp=cloudColors[0]*cloudColors[0],rgb;float alpha=1.0;
    if(cloudSky.w>.5){rgb=sqrt(mix(cloudSky.rgb*cloudSky.rgb,wisp,haze));rgb=sqrt(mix(rgb*rgb,cloud*cloud,coverage));}
    else{alpha=1.0-(1.0-haze)*(1.0-coverage);rgb=sqrt(mix(wisp,cloud*cloud,coverage/max(alpha,1e-4)));}
    float grain=(cloudHash(pixel+ivec2(int(time*24.0)*131,int(time*24.0)*71))-.5)*cloudMotion.y;
    rgb=clamp(rgb+grain*.28,0.0,1.0);if(cloudSky.w<=.5)alpha=clamp(alpha*(1.0+grain*.9),0.0,1.0);
    return vec4(rgb,alpha);
}
// Separate particle variant; original strip shader above is retained.
uniform vec4 cloudParticleData[384];uniform int cloudDetail;
vec4 cloudParticleField(vec2 p,ivec2 pixel){
    float sum=0.0,weight=0.00001;
    vec3 tint=cloudColors[0]*cloudColors[0]*weight;
    for(int group=0;group<8;group++){
        if(group>=cloudCount)break;
        vec4 bounds=cloudInfo[group];
        if(p.x<bounds.x||p.y<bounds.y||p.x>bounds.z||p.y>bounds.w)continue;
        for(int j=0;j<24;j++){
            if(j>=cloudDetail)break;
            int i=group*cloudDetail+j;
            vec4 a=cloudParticleData[i*2],b=cloudParticleData[i*2+1];
            vec2 delta=p-a.xy;
            vec2 q=vec2(b.x*delta.x+b.y*delta.y,-b.y*delta.x+b.x*delta.y)/a.zw;
            float r2=dot(q,q);if(r2>9.0)continue;
            float t=cloudMotion.w*cloudMotion.z*.1;
            float n=cloudNoise(q*1.4+vec2(b.w-t,b.w*.71))+.5*cloudNoise(q*2.83+vec2(b.w*.31+t,17));
            float body=exp(-r2*(2.6-1.7*cloudShape.x))*(1.0-smoothstep(6.25,9.0,r2))*(1.0-cloudShape.z+cloudShape.z*(.15+1.13*n*n))*b.z;
            sum+=body;tint+=cloudColors[group]*cloudColors[group]*body;weight+=body;
        }
    }
    vec3 cloud=sqrt(tint/weight);
    float coverage=1.0-exp(-sum*(.4+2.0*cloudShape.y));
    float c=cos(cloudMotion.x),sn=sin(cloudMotion.x);vec2 q=vec2(c*p.x+sn*p.y,-sn*p.x+c*p.y);
    float haze=smoothstep(0.0,1.0,(cloudFbm(vec2(q.x*1.4-cloudMotion.w*(cloudMotion.z*.5),q.y*7.0))-.5)/.3)*cloudShape.w*.7;
    vec3 wisp=cloudColors[0]*cloudColors[0],rgb;float alpha=1.0;
    if(cloudSky.w>.5){rgb=sqrt(mix(cloudSky.rgb*cloudSky.rgb,wisp,haze));rgb=sqrt(mix(rgb*rgb,cloud*cloud,coverage));}
    else{alpha=1.0-(1.0-haze)*(1.0-coverage);rgb=sqrt(mix(wisp,cloud*cloud,coverage/max(alpha,1e-4)));}
    float grain=(cloudHash(pixel)-.5)*cloudMotion.y;
    rgb=clamp(rgb+grain*.28,0.0,1.0);if(cloudSky.w<=.5)alpha=clamp(alpha*(1.0+grain*.9),0.0,1.0);
    return vec4(rgb,alpha);
}
uniform bool roundPoints;
void main(){
    vec4 c=vec4(tint,1);
    if(shape==0){
        if(roundPoints && length(uv.xy/uv.z*2.0-1.0)>1.0)discard;
        vec2 st=vec2(uv.x/uv.z,1-uv.y/uv.z);
        if(fitClip && (any(lessThan(st,vec2(0)))||any(greaterThan(st,vec2(1)))))discard;
        int faceFit=int(round(graph.y/uv.z));faceFit=faceFit>0?faceFit-1:mediaFit;
        if(faceFit!=0 && mediaSourceAspect>0.0){
            float faceAspect=max(.0001,graph.x/uv.z);
            if(faceFit==1){
                if(mediaSourceAspect>faceAspect)st.y=(st.y-.5)*mediaSourceAspect/faceAspect+.5;
                else st.x=(st.x-.5)*faceAspect/mediaSourceAspect+.5;
                if(any(lessThan(st,vec2(0)))||any(greaterThan(st,vec2(1))))discard;
            }else{
                vec2 position=contentPositions[clamp(int(round(graph.z/uv.z)),0,127)];
                if(mediaSourceAspect>faceAspect){float scale=faceAspect/mediaSourceAspect;st.x=st.x*scale+(1.-scale)*position.x;}
                else{float scale=mediaSourceAspect/faceAspect;st.y=st.y*scale+(1.-scale)*position.y;}
            }
        }
        c=texture(source,st);
        if(premultiplied&&c.a>0.00001)c.rgb/=c.a;
    }
#ifndef VJ_MAPPED_METAL
    else if(shape==5){
        vec2 p=clamp(uv.xy/uv.z,0,1);
        float along=p.x;
        c.a=1;
        if(traceMode==0){
            vec4 edges=vec4(p.y,1-p.x,1-p.y,p.x);
            float edge=min(min(edges.x,edges.y),min(edges.z,edges.w));
            along=(edge==edges.x?p.x:edge==edges.y?1+p.y:edge==edges.z?3-p.x:4-p.y)/4;
            c.a=1-smoothstep(max(0,traceWidth-fwidth(edge)),traceWidth+fwidth(edge),edge);
        }else if(traceMode==2)along=p.y;
        if(traceSequence)along=(graph.x/uv.z+along)/max(1,graph.y/uv.z);
        if(traceReverse)along=1-along;
        c.rgb=traceColor(traceOffset==0?along:fract(along+traceOffset),mod(traceSeed+(traceSequence?0.0:floor(graph.z/uv.z+.5)),65521.0));
    }
#endif
#ifndef VJ_MAPPED_METAL
    else if(shape==2 || shape==6){
        float endDistance=max(max(-uv.x,uv.x-uv.z),0.0);
        float distance=length(vec2(endDistance,uv.y));
        float core=1.0-smoothstep(max(0.0,coreWidth*.5-.65),coreWidth*.5+.65,distance);
        float halo=glowRadius>0.0?glowAmount*exp(-3.0*distance*distance/(glowRadius*glowRadius)):0.0;
        float along=clamp(uv.x/max(uv.z,.001),0.0,1.0)*graph.z;
        float route=graph.x<0.0?-1.0:min(graph.x+along,graph.y+graph.z-along);
        c.a=shape==6?core*brightness:max(core,halo)*pulse(route);
    }else if(shape==4){
        // Projective interpolation of world coordinates keeps phase continuous
        // across shared edges, including independently rotated boxes.
        vec3 world=vec3(uv.x,graph.x,uv.y)/uv.z;
        float top=clamp(graph.y/uv.z,0.0,1.0);
        float potential=world.y+.24*world.x+.13*world.z;
        float phase=potential+seconds*flowSpeed;
        float bend=sin(world.y*7.0+seconds*1.3)*flowTurbulence*.09;
        float stripes=sin((world.x+world.z*.71+bend)*flowDensity*6.28318);
        float streams=smoothstep(1.0-flowWidth*2.0,1.0,stripes);
        float wave=pow(.5+.5*sin(phase*18.0),5.0);
        float ripples=.5+.5*sin((world.x+world.z)*19.0+phase*8.0);
        float foam=flowFoam*wave*mix(.2,.9,top);
        float water=(.08+streams*(.3+.5*wave)+top*ripples*.15)*brightness;
        c.rgb=mix(tint*water,vec3(brightness),clamp(foam,0.0,1.0));
        c.a=graph.z;
    }else if(shape==9){
        vec3 d=normalize(vec3(uv.xy/uv.z,graph.x/uv.z));
        vec3 angles=spherePose+seconds*sphereRotate;
        d=rotateX(rotateY(rotateZ(d,-angles.z),-angles.y),-angles.x);
        float energy=0.0;
        for(int i=0;i<32;i++){
            if(i>=sphereTrails)break;
            float id=float(i);
            float angle=atan(d.z,d.x);
            float spacing=6.2831853/float(sphereTrails);
            float lane=(fract(sin((id+1.0)*127.1)*43758.5453)*2.0-1.0)*sphereSpread;
            float phase=seconds*sphereSpeed*6.2831853+id*spacing;
            float behind=mod(phase-angle+6.2831853,6.2831853);
            float band=1.0-step(sphereWidth,abs(d.y-lane));
            float tailSpan=max(.001,sphereTail*6.2831853);
            float tailProgress=clamp(behind/tailSpan,0.0,1.0);
            float fade=1.0-clamp((tailProgress-sphereFadeStart)/max(.001,1.0-sphereFadeStart),0.0,1.0);
            float tailMask=1.0-smoothstep(tailSpan-.002,tailSpan+.002,behind);
            float tail=mix(1.0,fade,sphereFadeAmount)*tailMask;
            float head=1.0-step(max(.0005,tailSpan*.01),behind);
            energy=max(energy,band*max(tail,head)*brightness);
        }
        c.rgb=tint*brightness;c.a=clamp(energy,0.0,1.0);
    }
#endif
    else if(shape==12){
        vec2 point=uv.xy/uv.z,faceUV=inkClip.xy+point*inkClip.zw;
        mat2 toPoint=mat2(dFdx(point),dFdy(point));
        if(any(lessThan(faceUV,vec2(0)))||any(greaterThan(faceUV,vec2(1))))discard;
        if(roundPoints && length(faceUV*2.0-1.0)>1.0)discard;
        float r=length(point);
        if(inkGlass){
            // Defocused glass tile refracting the frame beneath it (source = pre-ink copy).
            vec2 q=abs(point)-vec2(.68);float sd=length(max(q,0.0))+min(max(q.x,q.y),0.0)-.17;
            float soft=.03+.22*glassFrost,coverage=(1.0-smoothstep(-soft,soft,sd))*inkColor.a;
            if(coverage<.002)discard;
            // Point units -> framebuffer pixels through the local projective Jacobian.
            if(abs(determinant(toPoint))<1e-12)discard;
            mat2 toPixel=inverse(toPoint);vec2 texel=1.0/glassBufferSize;
            float edge=clamp(1.0+sd/.45,0.0,1.0);
            vec2 bend=-point*glassRefraction*(.12+.55*edge*edge);
            vec2 base=gl_FragCoord.xy*texel+toPixel*bend*texel;
            // Per-pixel spiral rotation trades tap patterns for fine frost grain.
            vec3 sum=vec3(0);float blur=glassFrost*.7,spin=fract(sin(dot(gl_FragCoord.xy,vec2(12.9898,78.233)))*43758.5453)*6.28318;
            for(int i=0;i<12;i++){float a=float(i)*2.39996+spin,rr=sqrt((float(i)+.5)/12.0)*blur;sum+=glassBackdrop(base+toPixel*(vec2(cos(a),sin(a))*rr)*texel);}
            // Glass changes where/how we sample, never the sampled color.
            c=vec4(sum/12.0,coverage);
        }else if(inkCircles){
            float aa=max(.0001,fwidth(r)*.5);
            c=vec4(0,0,0,(1.0-smoothstep(.62-aa,.62+aa,r))*inkColor.a);
        }else{
            float body=1.0-smoothstep(.42,.72,r),rim=exp(-pow((r-.82)*4.5,2.0))*inkGlow;
            float coverage=min(.98,body*.98+rim*.3);
            vec3 tint=mix(vec3(dot(inkColor.rgb,vec3(.2126,.7152,.0722))),inkColor.rgb,.18);
            c=vec4((vec3(.002)*body+tint*rim*.35)/max(coverage,.0001),coverage*inkColor.a);
        }
    }else if(shape==14 || shape==15){
        if(roundPoints && length(uv.xy/uv.z*2.0-1.0)>1.0)discard;
        // Projector space, canvas-height units: strips run across faces and gaps alike.
        vec2 p=gl_FragCoord.xy/glassBufferSize.y;
        c=shape==15?cloudParticleField(p,ivec2(gl_FragCoord.xy*720.0/glassBufferSize.y)):cloudField(p,ivec2(gl_FragCoord.xy*720.0/glassBufferSize.y));c.a*=faceAlpha;
    }else if(shape==11){
        vec2 point=uv.xy/uv.z,faceUV=particleClip.xy+point*particleClip.zw;
        if(any(lessThan(faceUV,vec2(0)))||any(greaterThan(faceUV,vec2(1))))discard;
        if(roundPoints && length(faceUV*2.0-1.0)>1.0)discard;
        float r2=dot(point,point),energy=exp(-r2*2.5);
        c=vec4(mix(graph,vec3(1),.35*exp(-r2*16)),min(1.0,energy*1.15)*faceAlpha);
    }else if(shape==10){
        if(roundPoints && length(uv.xy/uv.z*2.0-1.0)>1.0)discard;
        // Card UVs are already top-origin, matching normalized Syphon textures.
        // Only mediaVertices (shape 0) store an inverted V coordinate.
        vec2 st=uv.xy/uv.z;
        if(gateFit>1 && mediaSourceAspect>0.0){
            float aspect=max(.0001,gateAspect);
            if(gateFit==2){
                if(mediaSourceAspect>aspect)st.y=(st.y-.5)*mediaSourceAspect/aspect+.5;
                else st.x=(st.x-.5)*aspect/mediaSourceAspect+.5;
                if(any(lessThan(st,vec2(0)))||any(greaterThan(st,vec2(1))))discard;
            }else{
                if(mediaSourceAspect>aspect){float scale=aspect/mediaSourceAspect;st.x=st.x*scale+(1.-scale)*gatePosition.x;}
                else{float scale=mediaSourceAspect/aspect;st.y=st.y*scale+(1.-scale)*gatePosition.y;}
            }
        }
        c=texture(source,st)*vec4(graph,1);
    }else if(shape==8){
        if(roundPoints && length(uv.xy/uv.z*2.0-1.0)>1.0)discard;
        c=vec4(graph,faceAlpha);
    }
#ifndef VJ_MAPPED_METAL
    else if(shape==3 || shape==7 || shape==13){
        vec2 p=uv.xy/uv.z*2.0-1.0;
        float center=pow(max(0.0,(1.0-p.x*p.x)*(1.0-p.y*p.y)),falloff);
        if(shape==7 || (shape==13 && roundPoints)){float r2=dot(p,p);if(r2>1.0)discard;center=pow(max(0.0,1.0-r2),falloff);}
        if(shape==13)c.rgb=graph;
        c.a=brightness*mix(1.0,center,centerGlow);
    }
#endif
    c.a*=opacity;
    if(blend==1)c.rgb*=c.a;else if(blend==2)c.rgb=mix(vec3(1),c.rgb,c.a);
    color=c;
})GLSL";
        GLuint v=compile(GL_VERTEX_SHADER,vs),f=compile(GL_FRAGMENT_SHADER,fs);
        collection_program_=glCreateProgram();glAttachShader(collection_program_,v);glAttachShader(collection_program_,f);glLinkProgram(collection_program_);
        glDeleteShader(v);glDeleteShader(f);
        GLint linked=0;glGetProgramiv(collection_program_,GL_LINK_STATUS,&linked);
        if(!linked)throw std::runtime_error("Collection shader link failed");
        glGenVertexArrays(1,&collection_vao_);glGenBuffers(1,&collection_vbo_);
        glBindVertexArray(collection_vao_);glBindBuffer(GL_ARRAY_BUFFER,collection_vbo_);
        glVertexAttribPointer(0,2,GL_FLOAT,GL_FALSE,8*sizeof(float),nullptr);glEnableVertexAttribArray(0);
        glVertexAttribPointer(1,3,GL_FLOAT,GL_FALSE,8*sizeof(float),reinterpret_cast<void*>(2*sizeof(float)));glEnableVertexAttribArray(1);
        glVertexAttribPointer(2,3,GL_FLOAT,GL_FALSE,8*sizeof(float),reinterpret_cast<void*>(5*sizeof(float)));glEnableVertexAttribArray(2);
    }
    SceneJson params = geometry ? layer.params : SceneJson::object();
    const bool patchTrace=layer.generator=="patch_trace";
    const auto recipe=params.value("_patch_recipe",SceneJson::object());
    const auto operation=recipe.value("kind",std::string{});
    const bool mappedSurface=operation=="triangulateFaces"||operation=="boxWaterfall"||operation=="sphereGimbal"||operation=="boxEdges";
    const int traceKind=operation=="traceSnake"?0:operation=="traceRainbow"?1:operation=="tracePulse"?2:operation=="traceSolid"?3:operation=="lightningPulses"?4:-1;
    if(patchTrace){
        if(traceKind<0)return;
        params=recipe.value("params",SceneJson::object());seconds=recipe.value("time",0.);
    }else if(mappedSurface)params=recipe.value("params",SceneJson::object());

    glUseProgram(collection_program_);glBindVertexArray(collection_vao_);glBindBuffer(GL_ARRAY_BUFFER,collection_vbo_);
    glActiveTexture(GL_TEXTURE0);glBindTexture(GL_TEXTURE_2D,texture?texture:fallback_texture_);
    auto scalar=[&](const char *key,float value){glUniform1f(glGetUniformLocation(collection_program_,key),value);};
    glUniform1i(glGetUniformLocation(collection_program_,"source"),0);
    glUniform1i(glGetUniformLocation(collection_program_,"hasProjectorBackdrop"),projector_backdrop_active_);
    glUniform1i(glGetUniformLocation(collection_program_,"hasLocalBackdrop"),localBackdrop);
    glUniform2f(glGetUniformLocation(collection_program_,"glassBufferSize"),width,height);
    glUniform1i(glGetUniformLocation(collection_program_,"projectorRotation"),projector_rotation_);
    glUniform1i(glGetUniformLocation(collection_program_,"projectorBackdrop"),1);
    glActiveTexture(GL_TEXTURE1);glBindTexture(GL_TEXTURE_2D,projector_backdrop_active_?projector_backdrop_:fallback_texture_);glActiveTexture(GL_TEXTURE0);
    const bool round_points=bus.collection.value("kind",std::string{})=="points" && bus.collection.value("pointShape",std::string("circle"))=="circle";
    glUniform1i(glGetUniformLocation(collection_program_,"roundPoints"),round_points);
    glUniform1i(glGetUniformLocation(collection_program_,"fitClip"),bus.collection.value("fit",std::string("stretch"))=="fit");
    glUniform1i(glGetUniformLocation(collection_program_,"premultiplied"),!geometry&&layer.params.value("_premultiplied",false));
    glUniform1i(glGetUniformLocation(collection_program_,"gateFit"),0);
    std::array<float,256> contentPositions;contentPositions.fill(.5f);
    const auto positions=bus.collection.value("faceContentPositions",SceneJson::array());
    for(size_t i=0;i<std::min(size_t(128),positions.size());++i)for(int axis=0;axis<2;++axis)contentPositions[i*2+axis]=positions[i][axis].get<float>();
    glUniform2fv(glGetUniformLocation(collection_program_,"contentPositions[0]"),128,contentPositions.data());
    glUniform2f(glGetUniformLocation(collection_program_,"gatePosition"),.5f,.5f);
    int mediaFit=0;float mediaSourceAspect=float(width)/std::max(1,height);
    if(!geometry&&layer.media_vertices){
        const auto fit=layer.params.value("fit",std::string("stretch"));
        mediaFit=fit=="contain"?1:fit=="cover"?2:0;
        if(const auto* source=source_for(layer);source&&source->width>0&&source->height>0)
            mediaSourceAspect=float(source->width)/source->height;
    }
    glUniform1i(glGetUniformLocation(collection_program_,"mediaFit"),mediaFit);
    scalar("mediaSourceAspect",mediaSourceAspect);
    const auto color=parse_color(params,"color",{1,1,1});
    glUniform3f(glGetUniformLocation(collection_program_,"tint"),color[0],color[1],color[2]);
    scalar("opacity",layer.opacity);scalar("faceAlpha",1);
    glUniform1i(glGetUniformLocation(collection_program_,"blend"),layer.blend=="screen"?1:layer.blend=="multiply"?2:0);
    const float scale=height/1080.0f;
    const float thickness=std::clamp(params.value("thickness",2.0f),.5f,20.0f)*scale;
    const float glow=std::clamp(params.value("glow_radius",16.0f),0.0f,80.0f)*scale;
    scalar("coreWidth",thickness);scalar("glowRadius",glow);
    scalar("glowAmount",std::clamp((layer.collection_geometry=="trace"?.6f:params.value("glow",.6f)),0.0f,1.0f));
    scalar("brightness",std::clamp(params.value("brightness",.7f),0.0f,1.0f));
    scalar("centerGlow",std::clamp(params.value("center_glow",1.0f),0.0f,1.0f));
    scalar("flowSpeed",params.value("speed",.65f));
    scalar("flowDensity",params.value("density",8.0f));
    scalar("flowWidth",params.value("width",.35f));
    scalar("flowFoam",params.value("foam",.6f));
    scalar("flowTurbulence",params.value("turbulence",.35f));
    if(operation=="sphereGimbal"){
        glUniform1i(glGetUniformLocation(collection_program_,"sphereTrails"),std::clamp(int(std::round(params.value("trails",16.0f))),1,32));
        scalar("sphereSpeed",params.value("speed",2.0f));
        scalar("sphereTail",params.value("tail",.10f));
        scalar("sphereFadeStart",params.value("fade_start",0.0f));
        scalar("sphereFadeAmount",params.value("tail_fade",1.0f));
        scalar("sphereSpread",params.value("spread",.035f));
        scalar("sphereWidth",params.value("width",.012f));
        const float radians=3.14159265359f/180.0f;
        auto vec3=[&](const char* key,const char* x,const char* y,const char* z,float scale){
            glUniform3f(glGetUniformLocation(collection_program_,key),
                params.value(x,0.0f)*scale,params.value(y,0.0f)*scale,params.value(z,0.0f)*scale);
        };
        vec3("spherePose","pose_x","pose_y","pose_z",radians);
        vec3("sphereRotate","rotate_x","rotate_y","rotate_z",radians);
    }
    scalar("falloff",std::clamp(params.value("falloff",1.5f),.25f,6.0f));
    glUniform1i(glGetUniformLocation(collection_program_,"pulses"),params.value("pulses",false));
    scalar("seconds",static_cast<float>(seconds));
    scalar("pulseSpeed",params.value("pulse_speed",.6f));scalar("pulseRate",params.value("pulse_rate",1.0f));
    scalar("pulseWidth",params.value("pulse_width",.15f));scalar("pulseAmount",params.value("pulse_amount",1.0f));
    scalar("sparkle",params.value("sparkle",0.0f));
    const auto direction=params.value("pulse_direction",std::string("forward"));
    glUniform1i(glGetUniformLocation(collection_program_,"direction"),direction=="reverse"?1:direction=="bounce"?2:0);
    if(layer.collection_geometry=="trace"){
        const auto route=bus.collection.value("trace",SceneJson::object());
        auto flag=[&](const char* key,bool v){glUniform1i(glGetUniformLocation(collection_program_,key),v);};
        const auto mode=route.value("mode",std::string("perimeter"));
        glUniform1i(glGetUniformLocation(collection_program_,"traceMode"),mode=="horizontal"?1:mode=="vertical"?2:0);
        glUniform1i(glGetUniformLocation(collection_program_,"traceKind"),traceKind);
        flag("traceSequence",route.value("scope",std::string("face"))=="collection");flag("traceReverse",route.value("reverse",false));
        std::vector<float> traceColors;
        if(patchTrace)for(const auto& c:recipe.value("colors",SceneJson::array())){if(traceColors.size()>=256*3)break;traceColors.insert(traceColors.end(),{c.value("r",0.f),c.value("g",0.f),c.value("b",0.f)});}
        glUniform1i(glGetUniformLocation(collection_program_,"tracePaletteCount"),int(traceColors.size()/3));
        if(!traceColors.empty())glUniform3fv(glGetUniformLocation(collection_program_,"traceColors"),int(traceColors.size()/3),traceColors.data());
        scalar("traceNodeSeed",patchTrace?params.value("seed",0.f):0.f);
        flag("traceSingleColor",params.value("single_color",false));
        flag("traceReflect",params.value("reflect",false));
        scalar("traceSeed",bus.collection.value("traceSeed",0.f));
        flag("traceSync",params.value("beat_sync",false));flag("traceEnd",params.value("origin",std::string("start"))=="end");
        scalar("traceWidth",route.value("width",.04f));scalar("traceOffset",route.value("offset",0.f));
        const double elapsed=bus.clock.playing?std::chrono::duration<double>(SteadyClock::now()-scene_received_at_).count():0.;
        scalar("traceBeat",bus.clock.beat+elapsed*bus.clock.bpm/60.);
        scalar("brightness",params.value("brightness",1.f));
        for(const auto &[uniform,key,fallback]:std::vector<std::tuple<const char*,const char*,float>>{
            {"traceMotionTime","_motion_time",0.f},{"traceMotionDistance","_motion_distance",0.f},{"traceMotionJitterDistance","_motion_jitter_distance",0.f},{"traceMotionRatePhase","_motion_rate_phase",0.f},
            {"traceStart","start",0.f},{"traceFinish","end",1.f},{"traceSpeed","speed",.5f},{"traceBeatSpeed","beat_speed",.25f},{"traceTail","tail",.25f},{"traceDrag","drag",.5f},{"traceRainbow","rainbow",0.f},
            {"traceOnTime","on_time",.5f},{"traceRate","rate",.5f},{"tracePerBeat","per_beat",1.f},{"traceAttack","attack",.45f},{"traceRelease","release",.55f},{"traceFloor","floor",0.f},{"traceCurve","curve",1.f},
            {"traceSpread","spread",1.f},{"tracePulse","pulse",0.f},{"traceBreathe","breathe",0.f},{"traceBurst","burst",.45f},{"traceJitter","jitter",.35f},{"traceLength","length",.08f},
            {"traceCrackle","crackle",.38f},{"traceForks","forks",.32f},{"traceSpray","top_spray",.45f}})scalar(uniform,params.value(key,fallback));
        for(const auto &[uniform,key]:std::vector<std::pair<const char*,const char*>>{{"traceTint","tint"},{"traceCore","core"},{"traceGlow","glow"}}){
            const auto c=parse_color(params,key,{1,1,1});glUniform3f(glGetUniformLocation(collection_program_,uniform),c[0],c[1],c[2]);
        }
    }
    glEnable(GL_BLEND);glBlendEquation(GL_FUNC_ADD);
    if(layer.blend=="add")glBlendFuncSeparate(GL_SRC_ALPHA,GL_ONE,GL_ONE,GL_ONE_MINUS_SRC_ALPHA);
    else if(layer.blend=="subtract"){glBlendEquationSeparate(GL_FUNC_REVERSE_SUBTRACT,GL_FUNC_ADD);glBlendFuncSeparate(GL_SRC_ALPHA,GL_ONE,GL_ZERO,GL_ONE);}
    else if(layer.blend=="screen")glBlendFuncSeparate(GL_ONE,GL_ONE_MINUS_SRC_COLOR,GL_ONE,GL_ONE_MINUS_SRC_ALPHA);
    else if(layer.blend=="multiply")glBlendFuncSeparate(GL_DST_COLOR,GL_ZERO,GL_ONE,GL_ONE_MINUS_SRC_ALPHA);
    else glBlendFuncSeparate(GL_SRC_ALPHA,GL_ONE_MINUS_SRC_ALPHA,GL_ONE,GL_ONE_MINUS_SRC_ALPHA);
    float routeSpan=1;
    auto draw=[&](const std::vector<float> &vertices,int shape,int stride=8){
        if(vertices.empty())return;
#ifdef VJ_MAPPED_METAL
        if(mappedSurface && shape!=1){
            const char* function=shape==2?"mappedTriangulate":shape==4?"mappedWaterfall":shape==6?"mappedBoxEdges":"mappedSphere";
            auto constants=vj::mapped_surface::uniforms(params,color,thickness,glow,static_cast<float>(seconds),routeSpan);
            mapped_metal_.draw(patchMappedSurfaceMSL,function,vertices.data(),vertices.size(),&constants,sizeof(constants),
                                  nullptr,0,width,height,layer.blend,layer.opacity);
            return;
        }
#endif
        glUniform1i(glGetUniformLocation(collection_program_,"shape"),shape);
        glBufferData(GL_ARRAY_BUFFER,vertices.size()*sizeof(float),vertices.data(),GL_DYNAMIC_DRAW);
        if(stride==16){
            glVertexAttribPointer(0,2,GL_FLOAT,GL_FALSE,16*sizeof(float),nullptr);
            glVertexAttribPointer(1,3,GL_FLOAT,GL_FALSE,16*sizeof(float),reinterpret_cast<void*>(2*sizeof(float)));
            glVertexAttribPointer(2,3,GL_FLOAT,GL_FALSE,16*sizeof(float),reinterpret_cast<void*>(5*sizeof(float)));
            glEnableVertexAttribArray(3);glEnableVertexAttribArray(4);
            glVertexAttribPointer(3,4,GL_FLOAT,GL_FALSE,16*sizeof(float),reinterpret_cast<void*>(8*sizeof(float)));
            glVertexAttribPointer(4,4,GL_FLOAT,GL_FALSE,16*sizeof(float),reinterpret_cast<void*>(12*sizeof(float)));
        }
        glDrawArrays(GL_TRIANGLES,0,vertices.size()/stride);
        if(stride==16){
            glDisableVertexAttribArray(3);glDisableVertexAttribArray(4);
            glVertexAttribPointer(0,2,GL_FLOAT,GL_FALSE,8*sizeof(float),nullptr);
            glVertexAttribPointer(1,3,GL_FLOAT,GL_FALSE,8*sizeof(float),reinterpret_cast<void*>(2*sizeof(float)));
            glVertexAttribPointer(2,3,GL_FLOAT,GL_FALSE,8*sizeof(float),reinterpret_cast<void*>(5*sizeof(float)));
        }
    };
    glDisable(GL_STENCIL_TEST);
    if(!geometry){
        if(layer.media_vertices){
            draw(*layer.media_vertices,0);return;
        }
        if(bus.collection.value("hasContentFit",false)){draw(bus.collection.at("contentVertices").get<std::vector<float>>(),0);return;}
        const auto raw=bus.collection.at("vertices").get<std::vector<float>>();std::vector<float> vertices;
        for(std::size_t i=0;i+4<raw.size();i+=5){vertices.insert(vertices.end(),raw.begin()+i,raw.begin()+i+5);vertices.insert(vertices.end(),{0,0,0});}
        draw(vertices,0);return;
    }
    if(layer.collection_geometry=="trace"){
        const std::vector<float> face={-1,-1,0,0,1,0,1,0, 1,-1,1,0,1,0,1,0, 1,1,1,1,1,0,1,0,
                                      -1,-1,0,0,1,0,1,0, 1,1,1,1,1,0,1,0, -1,1,0,1,1,0,1,0};
        draw(bus.collection.value("traceVertices",face),5);return;
    }
    if(operation=="boxEdges"){
        std::vector<float> vertices;
        for(const auto &edge:bus.collection.value("boxEdges",SceneJson::array())){
            const float x=edge[0][0].get<float>()*width,y=edge[0][1].get<float>()*height;
            const float xx=edge[1][0].get<float>()*width,yy=edge[1][1].get<float>()*height;
            const float length=std::hypot(xx-x,yy-y);if(length<.001f)continue;
            const float dx=(xx-x)/length,dy=(yy-y)/length,pad=thickness*.5f+1;
            auto vertex=[&](float along,float side){vertices.insert(vertices.end(),{
                2*(x+dx*along-dy*side)/width-1,2*(y+dy*along+dx*side)/height-1,
                along,side,length,0,0,0});};
            vertex(-pad,pad);vertex(-pad,-pad);vertex(length+pad,-pad);
            vertex(-pad,pad);vertex(length+pad,-pad);vertex(length+pad,pad);
        }
        draw(vertices,6);return;
    }
    const auto& cards=bus.card_vertices;
    #ifdef VJ_PATCH_COLLECTION
    if(layer.collection_geometry=="patch"&&!mappedSurface){
        const auto recipe=params.value("_patch_recipe",SceneJson::object());if(recipe.empty())return;
        auto p=recipe.value("params",SceneJson::object());const bool gate=recipe.value("kind",std::string{})=="surfaceGate";
        auto colors=recipe.value("colors",SceneJson::array());if(colors.empty())return;
        if(gate){auto* source=source_for(layer);if(!source||!source->syphon||!source->syphon->connected()||!source->uploaded_sequence)return;glActiveTexture(GL_TEXTURE0);glBindTexture(GL_TEXTURE_2D,source->texture);scalar("mediaSourceAspect",float(source->width)/std::max(1,source->height));}
        if(recipe.value("kind",std::string{})=="graphClouds" || recipe.value("kind",std::string{})=="graphCloudParticles"){
            // Face centers come from the projected cards, so Meta and ordinary
            // graphs share one projector metric (x scaled by aspect).
            const auto faceIndices=bus.collection.value("cardFaceIndices",std::vector<int>{});
            const int count=std::max<int>(1,bus.collection.value("faceIds",SceneJson::array()).size());
            const double aspect=double(width)/std::max(1,height);
            std::vector<double> centers(count*2,0.);std::vector<int> samples(count,0);
            for(size_t card=0;card<cards.size()/48;++card){int face=card<faceIndices.size()?faceIndices[card]:int(card);if(face<0||face>=count)continue;
                for(int v=0;v<6;++v){centers[face*2]+=(cards[card*48+v*8]+1)*.5*aspect;centers[face*2+1]+=(cards[card*48+v*8+1]+1)*.5;}samples[face]+=6;}
            const auto fallback=bus.collection.value("centers",SceneJson::array());const bool meta=bus.collection.contains("metaGraph");
            for(int f=0;f<count;++f){
                if(samples[f]){centers[f*2]/=samples[f];centers[f*2+1]/=samples[f];}
                else if(!meta&&f<int(fallback.size())){centers[f*2]=fallback[f][0].get<double>()*aspect;centers[f*2+1]=fallback[f][1].get<double>();}
                else{centers[f*2]=.5*aspect;centers[f*2+1]=.5;}
            }
            const auto config=patch_clouds::config(p);
            const int traversal=patch_particles::traversal(bus.collection.value("graphTraversal",std::string("loop")));
            if(recipe.value("kind",std::string{})=="graphCloudParticles"){
                const int groups=std::clamp(int(std::round(p.value("clouds",4.))),1,8),detail=std::clamp(int(std::round(p.value("detail",16.))),8,24);
                const double wind=p.value("wind",-8.)*3.141592653589793/180;
                std::vector<float> data,bounds,tints;
                data.reserve(groups*detail*8);
                for(int group=0;group<groups;group++){
                    float x0=1e9,y0=1e9,x1=-1e9,y1=-1e9;
                    for(int i=0;i<detail;i++){
                        auto a=patch_cloud_particle(config,group,i,detail,centers.data(),count,int(colors.size()),seconds,traversal,wind);
                        data.insert(data.end(),{float(a.x),float(a.y),float(a.rx),float(a.ry),float(cos(a.angle)),float(sin(a.angle)),float(a.level),float(a.noise)});
                        const float radius=3*std::max(a.rx,a.ry);x0=std::min(x0,float(a.x)-radius);y0=std::min(y0,float(a.y)-radius);x1=std::max(x1,float(a.x)+radius);y1=std::max(y1,float(a.y)+radius);
                        if(i==0){const auto& rgb=colors[a.color%colors.size()];tints.insert(tints.end(),{rgb.value("r",0.f),rgb.value("g",0.f),rgb.value("b",0.f)});}
                    }
                    bounds.insert(bounds.end(),{x0,y0,x1,y1});
                }
                glUniform4fv(glGetUniformLocation(collection_program_,"cloudParticleData[0]"),int(data.size()/4),data.data());
                glUniform4fv(glGetUniformLocation(collection_program_,"cloudInfo[0]"),groups,bounds.data());
                glUniform3fv(glGetUniformLocation(collection_program_,"cloudColors[0]"),groups,tints.data());
                glUniform1i(glGetUniformLocation(collection_program_,"cloudCount"),groups);glUniform1i(glGetUniformLocation(collection_program_,"cloudDetail"),detail);
                const auto& sky=colors[0];
                glUniform4f(glGetUniformLocation(collection_program_,"cloudSky"),sky.value("r",0.f),sky.value("g",0.f),sky.value("b",0.f),config.sky);
                glUniform4f(glGetUniformLocation(collection_program_,"cloudShape"),p.value("softness",.7f),p.value("density",.55f),p.value("texture",.6f),p.value("haze",.3f));
                glUniform4f(glGetUniformLocation(collection_program_,"cloudMotion"),wind,p.value("grain",.18f),p.value("speed",.12f),float(seconds));
                scalar("faceAlpha",std::clamp(p.value("brightness",1.f),0.f,1.f));draw(cards,15);scalar("faceAlpha",1);return;
            }
            std::vector<float> points,info,tints;
            for(int i=0;i<config.count;++i){auto streak=patch_cloud_streak(config,i,centers.data(),count,int(colors.size()),seconds,traversal);
                for(int k=0;k<PATCH_CLOUD_POINTS;++k){points.push_back(float(streak.x[k]));points.push_back(float(streak.y[k]));}
                info.insert(info.end(),{float(streak.width),float(streak.level),0,0});
                const auto& rgb=colors[streak.color%colors.size()];tints.insert(tints.end(),{rgb.value("r",0.f),rgb.value("g",0.f),rgb.value("b",0.f)});}
            glUniform4fv(glGetUniformLocation(collection_program_,"cloudPoints[0]"),int(points.size()/4),points.data());
            glUniform4fv(glGetUniformLocation(collection_program_,"cloudInfo[0]"),int(info.size()/4),info.data());
            glUniform3fv(glGetUniformLocation(collection_program_,"cloudColors[0]"),int(tints.size()/3),tints.data());
            glUniform1i(glGetUniformLocation(collection_program_,"cloudCount"),config.count);
            const auto& sky=colors[0];
            glUniform4f(glGetUniformLocation(collection_program_,"cloudSky"),sky.value("r",0.f),sky.value("g",0.f),sky.value("b",0.f),config.sky);
            glUniform4f(glGetUniformLocation(collection_program_,"cloudShape"),p.value("softness",.7f),p.value("density",.55f),p.value("texture",.6f),p.value("haze",.3f));
            glUniform4f(glGetUniformLocation(collection_program_,"cloudMotion"),p.value("wind",-8.f)*3.14159265f/180,p.value("grain",.18f),p.value("speed",.12f),float(seconds));
            scalar("faceAlpha",std::clamp(p.value("brightness",1.f),0.f,1.f));draw(cards,14);scalar("faceAlpha",1);return;
        }
        const bool ink=recipe.value("kind",std::string{})=="graphInkFlow";
        if(ink||recipe.value("kind",std::string{})=="graphParticles"){
            const auto charts=bus.collection.value("particleFaces",SceneJson::array()),centers=bus.collection.value("centers",SceneJson::array());
            const auto faceIndices=bus.collection.value("cardFaceIndices",std::vector<int>{});std::set<int> visible(faceIndices.begin(),faceIndices.end());
            int count=bus.collection.value("faceIds",SceneJson::array()).size();auto config=patch_particles::config(p,ink);
            int traversal=patch_particles::traversal(bus.collection.value("graphTraversal",std::string("loop")));
            if(ink&&traversal==2&&bus.collection.value("graphTopology",std::string("ordered"))!="complete")traversal=0;
            auto particles=patch_particles::cloud(config,count,int(colors.size()),seconds,traversal,ink,p.value("turbulence",1.),p.value("pulse",.45),p.value("markStyle",0.)>=.5,p.value("startingFaces",100.),p.value("independentTravel",0.)>=.5);
            scalar("inkGlow",p.value("glow",.18));
            const bool glass=ink&&p.value("markStyle",0.)>=1.5;
            glUniform1i(glGetUniformLocation(collection_program_,"inkCircles"),p.value("markStyle",0.)>=.5&&!glass);
            glUniform1i(glGetUniformLocation(collection_program_,"inkGlass"),glass);
            scalar("glassFrost",p.value("glassFrost",.55));scalar("glassRefraction",p.value("glassRefraction",.5));
            if(bus.collection.value("graphReplace",false)){auto black=cards;for(size_t i=0;i<black.size()/8;++i)for(int c=5;c<8;c++)black[i*8+c]=0;scalar("faceAlpha",1);draw(black,8);}
            std::vector<float> inkVertices;if(ink)inkVertices.reserve(particles.size()*96);
            for(auto particle:particles){int face=particle.face;if(!visible.contains(face)||face<0||face>=int(charts.size()))continue;const auto& chart=charts[face];if(!chart.value("valid",false))continue;
                double aspect=chart.value("aspect",1.),w=aspect>=1?aspect:1,h=aspect>=1?1:1/aspect,dx=particle.stage==1?1:-1,dy=0;
                if(particle.stage&&face<int(centers.size())&&particle.neighbor>=0&&particle.neighbor<int(centers.size())&&chart.contains("basis")){
                    auto basis=chart["basis"];double x=centers[particle.neighbor][0].get<double>()-centers[face][0].get<double>(),y=centers[particle.neighbor][1].get<double>()-centers[face][1].get<double>();
                    // Ordinary collection centers use normalized projector X; Meta centers are already spatial.
                    if(!bus.collection.contains("metaGraph"))x*=16./9.;
                    double ux=basis[0][0],uy=basis[0][1],vx=basis[1][0],vy=basis[1][1],det=ux*vy-uy*vx;
                    if(std::abs(det)>1e-9){dx=(x*vy-y*vx)/det*w;dy=(y*ux-x*uy)/det*h;}
                }
                auto placed=ink?patch_ink_place(particle,aspect,dx,dy,p.value("exploration",1.)):patch_particle_place(particle,aspect,dx,dy);double rx=placed.radius/w,ry=placed.radius/h;
                if(placed.x+rx*3<0||placed.x-rx*3>1||placed.y+ry*3<0||placed.y-ry*3>1)continue;
                auto matrix=chart["uvToProjector"].get<std::array<double,9>>();std::vector<float> vertices;vertices.reserve(48);const int order[6]={0,1,2,0,2,3};const double corners[4][2]={{-3,-3},{3,-3},{3,3},{-3,3}};
                const auto& rgb=colors[placed.color%colors.size()];bool valid=true;
                for(int i:order){double sx=corners[i][0],sy=corners[i][1],u=placed.x+sx*rx,v=placed.y+sy*ry,q=matrix[6]*u+matrix[7]*v+matrix[8];if(std::abs(q)<1e-8){valid=false;break;}
                    double x=(matrix[0]*u+matrix[1]*v+matrix[2])/q,y=(matrix[3]*u+matrix[4]*v+matrix[5])/q;vertices.insert(vertices.end(),{float(x*2-1),float(y*2-1),float(sx/q),float(sy/q),float(1/q),rgb.value("r",0.f),rgb.value("g",0.f),rgb.value("b",0.f)});
                }
                if(!valid)continue;
                if(ink){for(int v=0;v<6;++v){inkVertices.insert(inkVertices.end(),vertices.begin()+v*8,vertices.begin()+(v+1)*8);inkVertices.insert(inkVertices.end(),{float(placed.x),float(placed.y),float(rx),float(ry),rgb.value("r",0.f),rgb.value("g",0.f),rgb.value("b",0.f),float(placed.level*p.value("brightness",1.))});}continue;}
                scalar("faceAlpha",placed.level*p.value("brightness",1.));glUniform4f(glGetUniformLocation(collection_program_,"particleClip"),placed.x,placed.y,rx,ry);draw(vertices,ink?12:11);
            }
            if(ink)draw(inkVertices,12,16);
            scalar("faceAlpha",1);return;
        }
#ifdef VJ_MAPPED_METAL
        if(operation=="glowFaces"||operation=="flashFaces"){
            auto vertices=cards;
            const auto faces=bus.collection.value("cardFaceIndices",std::vector<int>{});
            for(size_t i=0;i<vertices.size()/8;++i)vertices[i*8+5]=float(i/6<faces.size()?faces[i/6]:int(i/6));
            std::vector<std::array<float,4>> palette;palette.reserve(colors.size());
            for(const auto& c:colors)palette.push_back({c.value("r",0.f),c.value("g",0.f),c.value("b",0.f),1});
            const bool glowFace=operation=="glowFaces";
            const std::array<std::array<float,4>,3> fx={{
                {float(seconds),p.value("pattern",0.f),p.value("speed",2.f),p.value("seed",1.f)},
                {glowFace?p.value("center_glow",1.f):p.value("onTime",.8f),glowFace?p.value("falloff",1.5f):p.value("fade",0.f),p.value("brightness",1.f),0},
                {float(bus.collection.value("faceIds",SceneJson::array()).size()),float(palette.size()),round_points?1.f:0.f,
                 bus.collection.contains("metaGraph")&&!bus.collection.value("graphReplace",false)?1.f:0.f}
            }};
            mapped_metal_.draw(patchMappedSurfaceMSL,glowFace?"mappedGlowFaces":"mappedFlashFaces",vertices.data(),vertices.size(),
                                  fx.data(),sizeof(fx),palette.data(),palette.size()*sizeof(palette[0]),width,height,layer.blend,layer.opacity);
            return;
        }
#else
        if(recipe.value("kind",std::string{})=="glowFaces"){
            auto vertices=cards;const auto indices=bus.collection.value("cardFaceIndices",std::vector<int>{});
            for(size_t card=0;card<vertices.size()/48;++card){int face=card<indices.size()?indices[card]:int(card);const auto& rgb=colors[patch_glow_sample(face,int(colors.size()),1).color];
                for(int v=0;v<6;++v)for(int c=0;c<3;++c)vertices[card*48+v*8+5+c]=rgb.value(c==0?"r":c==1?"g":"b",0.f);
            }
            scalar("brightness",std::clamp(p.value("brightness",.7f),0.f,1.f));scalar("centerGlow",std::clamp(p.value("center_glow",1.f),0.f,1.f));scalar("falloff",std::clamp(p.value("falloff",1.5f),.25f,6.f));
            draw(vertices,13);return;
        }
#endif
        PatchCollectionConfig config{int(p.value("pattern",0.)),p.value("speed",2.),p.value("onTime",.8),p.value("fade",0.),p.value("brightness",1.),uint32_t(p.value("seed",1.))};
        auto vertices=cards;const auto faceIndices=bus.collection.value("cardFaceIndices",std::vector<int>{});const int count=bus.collection.value("faceIds",SceneJson::array()).size();
        const bool pulse=recipe.value("kind",std::string{})=="graphPulse",meta=bus.collection.contains("metaGraph");
        const auto traversal=bus.collection.value("graphTraversal",std::string("loop"));
        const bool fitFaces=gate&&bus.collection.value("hasContentFit",false);
        const auto faceFits=bus.collection.value("faceContentFits",std::vector<int>{});
        const auto faceAspects=bus.collection.value("faceAspects",std::vector<float>{});
        size_t faceStart=0;
        for(size_t card=0;card<vertices.size()/48;++card){int face=card<faceIndices.size()?faceIndices[card]:int(card);
            auto s=pulse?patch_graph_sample(face,count,int(colors.size()),seconds,p.value("speed",2.),p.value("trail",1.5),p.value("brightness",1.),traversal=="once"?1:traversal=="wander"?2:0,uint32_t(p.value("seed",1.))):patch_collection_sample(config,face,count,int(colors.size()),seconds);
            const bool transparent=(pulse||meta)&&!bus.collection.value("graphReplace",false)&&!gate;
            for(int v=0;v<6;++v)for(int c=0;c<3;++c){const char* key=c==0?"r":c==1?"g":"b";float a=colors[s.previous].value(key,0.f),b=colors[s.color].value(key,0.f);vertices[card*48+v*8+5+c]=(a+(b-a)*s.blend)*(transparent?1:s.level);}
            if(pulse||meta||fitFaces){
                const bool faceEnd=card+1>=vertices.size()/48||card+1>=faceIndices.size()||faceIndices[card+1]!=face;
                if(faceEnd){if(fitFaces){glUniform1i(glGetUniformLocation(collection_program_,"gateFit"),face<int(faceFits.size())?faceFits[face]:0);scalar("gateAspect",face<int(faceAspects.size())?faceAspects[face]:1.f);glUniform2f(glGetUniformLocation(collection_program_,"gatePosition"),contentPositions[std::clamp(face,0,127)*2],contentPositions[std::clamp(face,0,127)*2+1]);}scalar("faceAlpha",transparent?s.level:1);draw(std::vector<float>(vertices.begin()+faceStart*48,vertices.begin()+(card+1)*48),gate?10:8);faceStart=card+1;}
            }
        }
        if(!pulse&&!meta&&!fitFaces)draw(vertices,gate?10:8);scalar("faceAlpha",1);return;
    }
#endif
    if(operation=="boxWaterfall"){
        draw(bus.collection.value("flowVertices",std::vector<float>{}),4);return;
    }
    if(operation=="sphereGimbal"){
        draw(bus.collection.value("sphereVertices",std::vector<float>{}),9);return;
    }
    if(operation!="triangulateFaces"||!params.value("lines",true))return;
    // Clip the entire soft line footprint, not just its center path, against
    // the union of face polygons. Lines and halos never jump inside cards.
    // Box faces meet without gaps: their topology links must run on the
    // surfaces, rather than being erased by the planar card exclusion mask.
    const bool clip=bus.collection.value("kind",std::string("planar"))=="planar"
        &&params.value("line_ends",std::string("edges"))=="edges";
    if(clip){
        auto mask=cards;
        const float margin=std::clamp(number(params,"edge_margin",0),0.0f,80.0f)*scale;
        if(margin>0){
            // Dilate the face mask in projector pixels. Round joins keep acute
            // corners from creating long spikes; internal triangle edges stay
            // inside the union of the dilated face polygons.
            auto point=[&](float x,float y){mask.insert(mask.end(),{2*x/width-1,2*y/height-1,0,0,1,0,0,0});};
            for(std::size_t i=0;i+23<cards.size();i+=24){
                for(int corner=0;corner<3;++corner){
                    const auto a=i+corner*8,b=i+((corner+1)%3)*8;
                    const float x=(cards[a]+1)*width*.5f,y=(cards[a+1]+1)*height*.5f;
                    const float xx=(cards[b]+1)*width*.5f,yy=(cards[b+1]+1)*height*.5f;
                    const float length=std::hypot(xx-x,yy-y);
                    if(length>.001f){
                        const float nx=-(yy-y)/length*margin,ny=(xx-x)/length*margin;
                        point(x+nx,y+ny);point(x-nx,y-ny);point(xx-nx,yy-ny);
                        point(x+nx,y+ny);point(xx-nx,yy-ny);point(xx+nx,yy+ny);
                    }
                    for(int step=0;step<24;++step){
                        const float a0=step*6.283185307f/24,a1=(step+1)*6.283185307f/24;
                        point(x,y);point(x+margin*std::cos(a0),y+margin*std::sin(a0));point(x+margin*std::cos(a1),y+margin*std::sin(a1));
                    }
                }
            }
        }
        glEnable(GL_STENCIL_TEST);glStencilMask(0xff);glClearStencil(0);glClear(GL_STENCIL_BUFFER_BIT);
        glStencilFunc(GL_ALWAYS,1,0xff);glStencilOp(GL_KEEP,GL_KEEP,GL_REPLACE);
        glColorMask(GL_FALSE,GL_FALSE,GL_FALSE,GL_FALSE);draw(mask,1);glColorMask(GL_TRUE,GL_TRUE,GL_TRUE,GL_TRUE);
        glStencilMask(0);glStencilFunc(GL_EQUAL,0,0xff);glStencilOp(GL_KEEP,GL_KEEP,GL_KEEP);
    }
    const auto centers=bus.collection.at("centers").get<std::vector<std::array<float,2>>>();
    const auto lengths=bus.collection.value("edgeLengths",std::vector<float>{});
    const int count=static_cast<int>(centers.size());if(!count){glDisable(GL_STENCIL_TEST);glStencilMask(0xff);return;}
    std::vector<std::vector<std::pair<int,float>>> adjacency(count);
    int edge_index=0;
    for(const auto &edge:bus.collection.at("edges")){
        int a=edge[0].get<int>(),b=edge[1].get<int>();
        float length=edge_index<static_cast<int>(lengths.size())?lengths[edge_index]:1.0f;++edge_index;
        adjacency.at(a).push_back({b,length});adjacency.at(b).push_back({a,length});
    }
    int root=std::clamp(bus.collection.value("pulseRoot",0),0,count-1);
    const auto epoch=static_cast<std::uint64_t>(std::max(0.0,seconds)/(4.0/std::max(.05f,params.value("pulse_speed",.6f))+1.0/std::max(.1f,params.value("pulse_rate",1.0f))));
    auto choose=[&](const std::string &mode,const char *field,int fallback,int salt){
        if(mode=="first")return 0;if(mode=="last")return count-1;
        if(mode=="random")return static_cast<int>((epoch*1664525+1013904223+salt*69069)%count);
        if(mode=="face"){
            const auto name=params.value(field,std::string(""));
            const auto names=bus.collection.value("faceNames",std::vector<std::string>{});
            const auto ids=bus.collection.value("faceIds",std::vector<std::string>{});
            for(int i=0;i<count;++i)if((i<static_cast<int>(ids.size())&&ids[i]==name)||(i<static_cast<int>(names.size())&&names[i]==name))return i;
        }
        return fallback;
    };
    root=choose(params.value("pulse_start",std::string("center")),"start_face",root,0);
    std::vector<float> distances(count,std::numeric_limits<float>::infinity());
    std::vector<int> previous(count,-1);std::vector<bool> visited(count,false);distances[root]=0;
    for(int step=0;step<count;++step){
        int node=-1;for(int i=0;i<count;++i)if(!visited[i]&&(node<0||distances[i]<distances[node]))node=i;
        if(node<0||!std::isfinite(distances[node]))break;visited[node]=true;
        for(const auto &[next,length]:adjacency[node])if(distances[node]+length<distances[next]){distances[next]=distances[node]+length;previous[next]=node;}
    }
    int farthest=root;for(int i=0;i<count;++i)if(std::isfinite(distances[i])&&distances[i]>distances[farthest])farthest=i;
    int destination=choose(params.value("pulse_end",std::string("farthest")),"end_face",farthest,1);
    if(!std::isfinite(distances[destination]))destination=farthest;
    const bool route_only=params.value("pulse_mode",std::string("wave"))=="route";
    std::set<std::pair<int,int>> route;
    for(int node=destination;previous[node]>=0;node=previous[node])route.insert(std::minmax(node,previous[node]));
    routeSpan=std::max(.001f,distances[route_only?destination:farthest]);scalar("routeLength",routeSpan);
    std::vector<float> vertices;std::size_t index=0;
    for(const auto &edge:bus.collection.at("edges")){
        int ia=edge[0].get<int>(),ib=edge[1].get<int>();auto a=centers.at(ia),b=centers.at(ib);
        float x=a[0]*width,y=a[1]*height,xx=b[0]*width,yy=b[1]*height;
        float length=std::hypot(xx-x,yy-y);float routeLength=index<lengths.size()?lengths[index]:length/std::max(width,height);++index;
        if(length<.001f)continue;
        float dx=(xx-x)/length,dy=(yy-y)/length,pad=std::max(thickness*.5f+1,glow*1.75f);
        const bool traversed=(!route_only||route.contains(std::minmax(ia,ib)))&&std::isfinite(distances.at(ia))&&std::isfinite(distances.at(ib));
        auto vertex=[&](float along,float side){
            vertices.insert(vertices.end(),{2*(x+dx*along-dy*side)/width-1,2*(y+dy*along+dx*side)/height-1,
                along,side,length,traversed?distances.at(ia):-1.0f,traversed?distances.at(ib):0.0f,routeLength});
        };
        vertex(-pad,pad);vertex(-pad,-pad);vertex(length+pad,-pad);
        vertex(-pad,pad);vertex(length+pad,-pad);vertex(length+pad,pad);
    }
    draw(vertices,2);glDisable(GL_STENCIL_TEST);glStencilMask(0xff);
}

void NativeRenderGraph::render_bus(
    const std::string &name, const NativeBus &bus) {
    ensure_bus_target(name);
    BusTarget &target = *buses_.at(name);
    target.active = 0;
    glBindFramebuffer(GL_FRAMEBUFFER, target.framebuffers[target.active]);
    glViewport(0, 0, target.width, target.height);
    glDisable(GL_BLEND);
    glClearColor(0, 0, 0, bus.collection.empty() ? 1 : 0);
    glClear(GL_COLOR_BUFFER_BIT);

    if (!bus.running) {
        ++target.sequence;
        return;
    }

    if(!bus.crossfade.empty()){
        const auto a=bus_texture(bus.crossfade.at("a").get<std::string>());
        const auto b=bus_texture(bus.crossfade.at("b").get<std::string>());
        glUseProgram(program_);glBindVertexArray(vao_);
        glActiveTexture(GL_TEXTURE0);glBindTexture(GL_TEXTURE_2D,a.texture?a.texture:b.texture);
        glUniform1i(glGetUniformLocation(program_,"source_texture"),0);
        glActiveTexture(GL_TEXTURE1);glBindTexture(GL_TEXTURE_2D,b.texture?b.texture:a.texture);
        glUniform1i(glGetUniformLocation(program_,"bank_b_texture"),1);
        glUniform1i(glGetUniformLocation(program_,"effect"),31);
        glUniform1f(glGetUniformLocation(program_,"opacity"),bus.crossfade.value("value",0.0f));
        glDrawArrays(GL_TRIANGLE_STRIP,0,4);
        glUniform1i(glGetUniformLocation(program_,"bank_b_texture"),0);glActiveTexture(GL_TEXTURE0);
        draw_master(bus,target);++target.sequence;return;
    }

    const NativeLayer *direct_vector = nullptr;
    int enabled_layers = 0;
    for (const auto &layer : bus.layers) {
        if (!layer.enabled) continue;
        ++enabled_layers;
        if (!layer.vector.empty()) direct_vector = &layer;
    }
    if (!bus.bank && bus.collection.empty() && enabled_layers == 1 && direct_vector && vector_renderer_
        && vector_renderer_(name, target.width, target.height)) {
        ++target.sequence;
        return; // Vector recipe already applies the master mix.
    }

    const double elapsed = bus.clock.playing
        ? std::chrono::duration<double>(
            SteadyClock::now() - scene_received_at_).count() : 0.0;
    const double seconds = bus.clock.seconds + elapsed;
    const double beat = bus.clock.beat
        + elapsed * bus.clock.bpm / 60.0;
    bool has_base = false;
    std::string base_media_group;
    for (const auto &layer : bus.layers) {
        if (!layer.enabled) continue;
        if(layer.generator=="patch_adjustment"){
            if(!has_base || layer.opacity<=0)continue;
            const auto source=layer.params.value("source",std::string{});
            const auto context=name+"/"+layer.source_id+"/"+std::to_string(layer.id);
            std::string error;
            if(source.empty())error="Adjustment source is missing";
#ifdef VJ_MAPPED_METAL
            else if(!processor_encoder_)error="No Patch processor host is connected";
            else {
                const int next=1-target.active;
                if(mapped_metal_.process(processor_encoder_,source,context,seconds,target.framebuffers[target.active],
                                         target.framebuffers[next],target.width,target.height,layer.blend,layer.opacity,error)){
                    target.active=next;++processor_frames_;processor_errors_.erase(context);
                }
            }
#else
            else error="Patch adjustments require the Metal processor backend";
#endif
            if(!error.empty())processor_errors_[context]=error;
            continue;
        }
        // Mixed Patch outputs carry video as a surfaceGate leaf. Without
        // collection geometry it remains an ordinary video layer, so free
        // mapped surfaces and the Out preview still receive the video.
        const bool videoFallback = layer.collection_geometry=="patch"
            && layer.generator=="syphon"
            && layer.params.value("_patch_recipe",SceneJson::object()).value("kind",std::string{})=="surfaceGate"
            && (bus.collection.empty() || bus.collection.value("traceOnly",false));
        const bool typed = !layer.collection_geometry.empty() && !videoFallback;
        const bool trace=layer.collection_geometry=="trace";
        if (typed && ((!trace && (bus.collection.empty() || bus.collection.value("traceOnly",false))) || layer.opacity <= 0.0f)) continue;
        if(trace && bus.collection.empty()){
            glBindFramebuffer(GL_FRAMEBUFFER,target.framebuffers[target.active]);
            glViewport(0,0,target.width,target.height);
            draw_collection(bus,layer,0,target.width,target.height,true,seconds);
            has_base=true;continue;
        }
        if (has_base && layer.opacity <= 0.0f) continue;
        if (!bus.collection.empty()) {
            const auto& recipe=layer.params.value("_patch_recipe",SceneJson::object());
            const bool glass=typed && recipe.value("kind",std::string{})=="graphInkFlow"
                && recipe.value("params",SceneJson::object()).value("markStyle",0.)>=1.5;
            if(glass&&projector_backdrop_active_&&!has_base){
                // Nothing local lies beneath this glass: sample the captured
                // projector directly, without another ping-pong copy.
                glBindFramebuffer(GL_FRAMEBUFFER,target.framebuffers[target.active]);
                glViewport(0,0,target.width,target.height);
                draw_collection(bus,layer,0,target.width,target.height,true,seconds,false);
            } else if (glass) {
                // Glass marks refract the frame beneath them: copy it to the
                // other buffer, draw there while sampling the untouched copy.
                const int next = 1 - target.active;
                glBindFramebuffer(GL_READ_FRAMEBUFFER, target.framebuffers[target.active]);
                glBindFramebuffer(GL_DRAW_FRAMEBUFFER, target.framebuffers[next]);
                glBlitFramebuffer(0,0,target.width,target.height,0,0,target.width,target.height,GL_COLOR_BUFFER_BIT,GL_NEAREST);
                glBindFramebuffer(GL_FRAMEBUFFER, target.framebuffers[next]);
                glViewport(0,0,target.width,target.height);
                draw_collection(bus, layer, target.textures[target.active], target.width, target.height, true, seconds);
                target.active = next;
            } else if (typed) {
                glBindFramebuffer(GL_FRAMEBUFFER, target.framebuffers[target.active]);
                glViewport(0,0,target.width,target.height);
                draw_collection(bus, layer, 0, target.width, target.height, true, seconds);
            } else {
                const int scratch = 1 - target.active;
                glBindFramebuffer(GL_FRAMEBUFFER, target.framebuffers[scratch]);
                glViewport(0,0,target.width,target.height);
                glDisable(GL_BLEND);glClearColor(0,0,0,0);glClear(GL_COLOR_BUFFER_BIT);
                auto isolated=layer;isolated.opacity=1;isolated.blend="normal";
                // Keep the complete image in the scratch texture. Crop/contain
                // at the destination face, whose aspect may differ per item.
                if(layer.media_vertices)isolated.params["fit"]="stretch";
                if (!layer.vector.empty()) {
                    if (!vector_layer_renderer_ || !vector_layer_renderer_(isolated,seconds,beat,target.width,target.height)) continue;
                } else draw_layer(isolated,target.width,target.height);
                glBindFramebuffer(GL_FRAMEBUFFER,target.framebuffers[target.active]);
                glViewport(0,0,target.width,target.height);
                auto mapped=layer;
                const auto media_group=layer.params.value("_media_group",std::string{});
                if(!has_base && !media_group.empty())base_media_group=media_group;
                if(!has_base || (!media_group.empty() && media_group==base_media_group)){
                    mapped.opacity=layer.base_opacity;mapped.blend="normal";
                }
                // Vector scratch frames are premultiplied; raster scratch frames are straight.
                mapped.params["_premultiplied"] = !layer.vector.empty();
                draw_collection(bus,mapped,target.textures[scratch],target.width,target.height,false,seconds);
            }
            has_base=true;
            continue;
        }
        GLuint vector_texture = 0;
        if (!layer.vector.empty()) {
            if (!vector_layer_renderer_) continue;
            const int scratch = 1 - target.active;
            glBindFramebuffer(GL_FRAMEBUFFER, target.framebuffers[scratch]);
            glViewport(0, 0, target.width, target.height);
            glDisable(GL_BLEND);
            glClearColor(0, 0, 0, 0);
            glClear(GL_COLOR_BUFFER_BIT);
            if (!vector_layer_renderer_(layer, seconds, beat, target.width, target.height)) continue;
            vector_texture = target.textures[scratch];
        }
        glBindFramebuffer(GL_FRAMEBUFFER, target.framebuffers[target.active]);
        glViewport(0, 0, target.width, target.height);
        if (!has_base) {
            // Layer strength blends against content, never the cleared bus.
            // Keep source alpha (text/images), but ignore the base's fader
            // and blend mode until there is another layer underneath it.
            auto base = layer;
            base.opacity = layer.base_opacity;
            base.blend = "normal";
            glEnable(GL_BLEND);
            glBlendEquation(GL_FUNC_ADD);
            glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
            draw_layer(base, target.width, target.height, vector_texture);
            has_base = true;
            continue;
        }
        glEnable(GL_BLEND);
        glBlendEquation(GL_FUNC_ADD);
        if (layer.blend == "add") {
            glBlendFunc(GL_SRC_ALPHA, GL_ONE);
        } else if (layer.blend == "subtract") {
            glBlendEquationSeparate(GL_FUNC_REVERSE_SUBTRACT, GL_FUNC_ADD);
            glBlendFuncSeparate(GL_SRC_ALPHA, GL_ONE, GL_ZERO, GL_ONE);
        } else if (layer.blend == "screen") {
            glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_COLOR);
        } else if (layer.blend == "multiply") {
            glBlendFunc(GL_DST_COLOR, GL_ZERO);
        } else {
            glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
        }
        draw_layer(layer,  target.width, target.height, vector_texture);
    }
    if (name != "preview" && !bus.bank) draw_master(bus, target);
    ++target.sequence;
}

void NativeRenderGraph::resolve_patch_outputs(){
 static const SceneJson missing;
 std::map<std::string,const SceneJson*> outputs;
 for(const auto& item:patch_outputs_)if(item.value("available",false))outputs[item.value("id",std::string{})]=&item;
 const auto find=[&](const std::string& id)->const SceneJson*{auto it=outputs.find(id);return it==outputs.end()?nullptr:it->second;};
 for(auto& [name,bus]:scene_.buses){
  if(!render_sizes_.contains(name))continue;
  // Only the outputs used by this bus invalidate its expansion. Video frames
  // change inside Syphon without changing recipes or connection identities.
  std::set<std::string> dependencies;
  std::function<void(const SceneJson&,int)> visitRecipe;
  auto depend=[&](const std::string& id){dependencies.insert(id);};
  visitRecipe=[&](const SceneJson& recipe,int depth){
   if(!recipe.is_object()||depth>16)return;
   if(auto source=recipe.find("videoSource");source!=recipe.end()&&source->is_string())depend(source->get<std::string>());
   if(auto videos=recipe.find("videos");videos!=recipe.end()&&videos->is_array())for(const auto& source:*videos)if(source.is_string())depend(source.get<std::string>());
   if(auto layers=recipe.find("layers");layers!=recipe.end()&&layers->is_array())for(const auto& layer:*layers)if(auto child=layer.find("recipe");child!=layer.end())visitRecipe(*child,depth+1);
  };
  for(const auto& layer:bus.layers){
   if(layer.params.value("_mux_leaf",false))continue;
   if(layer.params.contains("_patch_type")||layer.generator=="patch_video"||layer.generator=="patch_collection"||layer.generator=="patch_trace"){
    const auto id=layer.params.value("source",std::string{});depend(id);
    if(auto output=find(id))if(auto recipe=output->find("recipe");recipe!=output->end())visitRecipe(*recipe,0);
   }
   if(auto controls=layer.params.find("_patch_controls");controls!=layer.params.end())for(const auto& binding:*controls)depend(binding.value("source",std::string{}));
  }
  auto cached=resolved_patch_dependencies_.find(name);
  bool unchanged=cached!=resolved_patch_dependencies_.end()&&cached->second.size()==dependencies.size();
  if(unchanged)for(const auto& id:dependencies){auto previous=cached->second.find(id);const auto* output=find(id);if(previous==cached->second.end()||previous->second!=(output?*output:missing)){unchanged=false;break;}}
  if(unchanged){++patch_resolution_hits_;continue;}
  ++patch_resolution_rebuilds_;
  auto& saved=resolved_patch_dependencies_[name];saved.clear();
  for(const auto& id:dependencies){const auto* output=find(id);saved[id]=output?*output:missing;}
  // Changed faders/recipes rebuild only lightweight layer state. Immutable
  // photo geometry survives these rebuilds until the scene changes.
  std::erase_if(bus.layers,[](const NativeLayer& layer){return layer.params.value("_mux_leaf",false);});
  for(auto& layer:bus.layers)if(layer.params.contains("_mux_opacity")){layer.opacity=layer.params["_mux_opacity"];layer.base_opacity=layer.params["_mux_base_opacity"];layer.params.erase("_mux_opacity");layer.params.erase("_mux_base_opacity");}
  for(auto& layer:bus.layers){
  if(layer.params.contains("_patch_controls")){if(!layer.params.contains("_patch_control_base")){layer.params["_patch_control_base"]=SceneJson::object();for(auto it=layer.params["_patch_controls"].begin();it!=layer.params["_patch_controls"].end();++it)layer.params["_patch_control_base"][it.key()]=layer.params.value(it.key(),SceneJson(0.));}for(auto it=layer.params["_patch_control_base"].begin();it!=layer.params["_patch_control_base"].end();++it)layer.params[it.key()]=it.value();}
  if(layer.params.contains("_patch_controls"))for(auto it=layer.params["_patch_controls"].begin();it!=layer.params["_patch_controls"].end();++it){const auto& b=it.value();if(auto output=find(b.value("source",std::string{}));output&&output->value("type",std::string{})=="control")layer.params[it.key()]=b.value("min",0.)+(b.value("max",1.)-b.value("min",0.))*std::clamp(output->value("value",0.),0.,1.);}
  if(layer.generator=="patch_video"||layer.generator=="patch_collection"||layer.generator=="patch_trace")layer.params["_patch_type"]=layer.generator;
  if(!layer.params.contains("_patch_type"))continue;
  const auto id=layer.params.value("source",std::string{});auto output=find(id);
  const bool collection=layer.params["_patch_type"]=="patch_collection",trace=layer.params["_patch_type"]=="patch_trace";
  layer.generator=trace?"patch_trace":collection?"patch_collection":"syphon";layer.resolved_file.clear();layer.params.erase("_patch_recipe");
  if(!output)continue;
  if(trace){if(output->value("type",std::string{})=="trace")layer.params["_patch_recipe"]=output->value("recipe",SceneJson::object());continue;}
  if(!collection){layer.resolved_file=output->value("selection",std::string{});continue;}
  auto recipe=output->value("recipe",SceneJson::object());layer.params["_patch_recipe"]=recipe;
  if(recipe.value("kind",std::string{})=="surfaceGate")if(auto video=find(recipe.value("videoSource",std::string{}))){layer.generator="syphon";layer.resolved_file=video->value("selection",std::string{});}
 }
 #ifdef VJ_PATCH_COLLECTION
  std::vector<NativeLayer> expanded;
  for(auto& original:bus.layers){auto layer=std::move(original);auto recipe=layer.params.value("_patch_recipe",SceneJson::object());
   const auto kind=recipe.value("kind",std::string{});
   if(kind!="layerMux"&&kind!="videoCollection"){expanded.push_back(std::move(layer));continue;}
   const float opacity=layer.opacity,base=layer.base_opacity;layer.params["_mux_opacity"]=opacity;layer.params["_mux_base_opacity"]=base;layer.opacity=layer.base_opacity=0;expanded.push_back(layer);
   int index=0;for(const auto& leaf:patch_layers::flatten(recipe)){auto child=layer;child.params.erase("_mux_opacity");child.params.erase("_mux_base_opacity");child.params["_mux_leaf"]=true;child.params["_patch_recipe"]=leaf.recipe;child.opacity=opacity*leaf.opacity;child.base_opacity=base*leaf.opacity;child.source_id+="/layer/"+std::to_string(index++);child.generator="patch_collection";child.resolved_file.clear();if(leaf.additive)child.blend="add";
    if(leaf.recipe.value("kind",std::string{})=="videoCollection"){
     const auto videos=leaf.recipe.value("videos",SceneJson::array());
     const auto faceData=bus.collection.find("mediaVertices");
     const auto faceIDs=bus.collection.find("faceIds");
     const size_t count=bus.collection.empty()?1:faceIDs==bus.collection.end()?0:faceIDs->size();
     for(size_t i=0;i<std::min({videos.size(),count,size_t(8)});++i){
      if(!videos[i].is_string())continue;
      const auto source=videos[i].get<std::string>();const auto* video=find(source);
      if(!video||video->value("type",std::string{})!="video")continue;
      auto item=child;item.generator="syphon";item.collection_geometry.clear();item.resolved_file=video->value("selection",std::string{});
      item.source_id+="/video/"+source;item.params.erase("_patch_recipe");
      item.params["fit"]=leaf.recipe.value("fit",std::string("contain"));
      item.params["gain"]=leaf.recipe.value("brightness",1.);
      if(!bus.collection.empty()){
       auto& geometry=photo_geometry_[name][{videos.size(),i}];
       if(!geometry){
        auto vertices=std::make_shared<std::vector<float>>();
        if(faceData!=bus.collection.end())for(size_t face=i;face<count;face+=videos.size())if(face<faceData->size())for(const auto& vertex:(*faceData)[face])vertices->push_back(vertex.get<float>());
        geometry=std::move(vertices);
       }
       item.media_vertices=geometry;item.params["_media_group"]=child.source_id;
      }
      expanded.push_back(std::move(item));
     }
     continue;
    }
    if(leaf.recipe.value("kind",std::string{})=="surfaceGate")if(auto video=find(leaf.recipe.value("videoSource",std::string{}))){child.generator="syphon";child.resolved_file=video->value("selection",std::string{});}
    expanded.push_back(std::move(child));
   }
  }bus.layers=std::move(expanded);
 #endif
 }
}
void NativeRenderGraph::clear_projector_targets(){
    for(auto& [name,target]:projector_buses_)if(target){
        if(target->stencil)glDeleteRenderbuffers(1,&target->stencil);
        glDeleteFramebuffers(2,target->framebuffers.data());glDeleteTextures(2,target->textures.data());
    }
    projector_buses_.clear();
}

bool NativeRenderGraph::projector_overlay_layers(const std::string& name,std::vector<std::string>& names)const{
    std::function<bool(const std::string&)> gather=[&](const std::string& key){
        auto it=scene_.buses.find(key);if(it==scene_.buses.end()||!it->second.running)return false;
        const auto& bus=it->second;bool glass=false;
        if(!bus.crossfade.empty()){
            const double mix=bus.crossfade.value("value",0.);
            if(mix<1)glass|=gather(bus.crossfade.at("a").get<std::string>());
            if(mix>0)glass|=gather(bus.crossfade.at("b").get<std::string>());
        }else for(const auto& layer:bus.layers){
            if(!layer.enabled||layer.opacity<=0)continue;
            auto recipe=layer.params.find("_patch_recipe");
            glass|=recipe!=layer.params.end()&&recipe->value("kind",std::string{})=="graphInkFlow"
                &&recipe->value("params",SceneJson::object()).value("markStyle",0.)>=1.5;
        }
        names.push_back(key);return glass;
    };
    return gather(name);
}

NativeBusTexture NativeRenderGraph::projector_overlay(const std::string& name,int width,int height,int rotation){
    auto found=scene_.buses.find(name);
    if(found==scene_.buses.end()||!found->second.collection.contains("metaGraph")||width<1||height<1)return {};
    std::vector<std::string> names;if(!projector_overlay_layers(name,names))return {};
    std::string resultName=name;
    const auto& mix=scene_.mix;const auto& crossfade=found->second.crossfade;
    // At a settled endpoint with a neutral master, the bank texture is already
    // the final overlay. Avoid clearing/copying it through two full-screen passes.
    if(!crossfade.empty()&&mix.video_master==1&&!mix.video_mute&&!mix.blackout&&!mix.invert&&!mix.pulse&&!mix.strobe
        &&(mix.cast.empty()||mix.cast_amount==0)&&mix.flash_at==0){
        const double amount=crossfade.value("value",0.);
        if(amount==0||amount==1){resultName=crossfade.at(amount==0?"a":"b").get<std::string>();names.pop_back();}
    }
    GLint draw=0,read=0,readBuffer=0;glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING,&draw);glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING,&read);glGetIntegerv(GL_READ_BUFFER,&readBuffer);
    glActiveTexture(GL_TEXTURE0);
    if(!projector_backdrop_){glGenTextures(1,&projector_backdrop_);glBindTexture(GL_TEXTURE_2D,projector_backdrop_);
        glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);
    }else glBindTexture(GL_TEXTURE_2D,projector_backdrop_);
    if(width!=projector_width_||height!=projector_height_){glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,width,height,0,GL_RGBA,GL_UNSIGNED_BYTE,nullptr);projector_width_=width;projector_height_=height;}
    glBindFramebuffer(GL_READ_FRAMEBUFFER,draw);glReadBuffer(draw?GL_COLOR_ATTACHMENT0:GL_BACK);
    glCopyTexSubImage2D(GL_TEXTURE_2D,0,0,0,0,0,width,height);++projector_backdrop_copies_;
    // Separate targets keep projector-specific pixels out of Out previews and
    // other projectors. Each visible overlay is rendered against its own stack.
    for(const auto& key:names)buses_[key].swap(projector_buses_[key]);
    projector_rotation_=(rotation%360+360)%360;projector_backdrop_active_=true;
    auto restore=[&]{
        projector_backdrop_active_=false;
        for(const auto& key:names){buses_[key].swap(projector_buses_[key]);if(!buses_[key])buses_.erase(key);}
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER,draw);glBindFramebuffer(GL_READ_FRAMEBUFFER,read);glReadBuffer(readBuffer);
        glViewport(0,0,width,height);glActiveTexture(GL_TEXTURE0);
    };
    try{
        for(const auto& key:names)render_bus(key,scene_.buses.at(key));
        auto result=bus_texture(resultName);restore();return result;
    }catch(...){restore();throw;}
}

void NativeRenderGraph::render(bool deferProjectorGlass) {
    const auto started = SteadyClock::now();
    resolve_patch_outputs();
    update_sources();
    std::set<std::string> deferred;
    if(deferProjectorGlass)for(const auto& [name,bus]:scene_.buses){
        if(!render_sizes_.contains(name)||!bus.collection.contains("metaGraph"))continue;
        std::vector<std::string> names;
        if(projector_overlay_layers(name,names))deferred.insert(names.begin(),names.end());
    }
    for (const auto &[name, bus] : scene_.buses) {
        if (!render_sizes_.contains(name) || !bus.crossfade.empty() || deferred.contains(name)) continue;
        render_bus(name, bus);
    }
    for (const auto &[name,bus]:scene_.buses) {
        if(render_sizes_.contains(name) && !bus.crossfade.empty() && !deferred.contains(name))render_bus(name,bus);
    }
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    ++rendered_frames_;
    const double elapsed_ms = std::chrono::duration<double, std::milli>(
        SteadyClock::now() - started).count();
    render_ms_ema_ = rendered_frames_ == 1
        ? elapsed_ms : render_ms_ema_ * 0.95 + elapsed_ms * 0.05;
    render_ms_max_ = std::max(render_ms_max_, elapsed_ms);
    if (elapsed_ms > 1000.0 / std::max(1, scene_.fps)) {
        ++missed_deadlines_;
    }
}

void NativeRenderGraph::suspend_media_clock() {
    audio_->suspend_output();
}

void NativeRenderGraph::resume_media_clock() {
    audio_->resume_output();
}

NativeBusTexture NativeRenderGraph::bus_texture(
    const std::string &bus) const {
    const auto item = buses_.find(bus);
    if (item == buses_.end() || !item->second) return {};
    const BusTarget &target = *item->second;
    return {
        target.textures[target.active],
        target.width, target.height, target.sequence, bus_span(bus),
    };
}

bool NativeRenderGraph::bus_span(const std::string &bus) const {
    const auto item = scene_.buses.find(bus);
    if (item == scene_.buses.end()) return false;
    const auto &crossfade = item->second.crossfade;
    if (!crossfade.empty()) {
        // A crossfade switches layout halfway through.
        return bus_span(crossfade.value("value", 0.0) < 0.5
            ? crossfade.value("a", std::string{}) : crossfade.value("b", std::string{}));
    }
    // Layers draw bottom to top; adjustments inherit from the layer below.
    const auto &layers = item->second.layers;
    for (auto layer = layers.rbegin(); layer != layers.rend(); ++layer) {
        if (!layer->enabled || layer->collection_layout == "inherit") continue;
        return layer->collection_layout == "span";
    }
    return false;
}

std::optional<double> NativeRenderGraph::movie_frame_rate() const {
    const auto source_id = movie_mode_source(scene_);
    if (!source_id || !audio_->owns_source(*source_id)
        || !audio_->playhead_for(*source_id)) {
        return std::nullopt;
    }
    for (const auto &[key, source] : sources_) {
        (void)key;
        if (!source || source->source_id != *source_id || !source->decoder) {
            continue;
        }
        const double fps = source->decoder->frame_rate();
        if (cinema_frame_rate(fps)) return fps;
    }
    return std::nullopt;
}

std::vector<std::uint8_t> NativeRenderGraph::read_bus_rgb(
    const std::string &bus, int width, int height) {
    const auto item = buses_.find(bus);
    if (item == buses_.end() || !item->second || width < 1 || height < 1) {
        return {};
    }
    BusTarget &source = *item->second;
    if (!readback_framebuffer_) {
        glGenFramebuffers(1, &readback_framebuffer_);
        glGenTextures(1, &readback_texture_);
    }
    if (readback_width_ != width || readback_height_ != height) {
        readback_width_ = width;
        readback_height_ = height;
        glBindTexture(GL_TEXTURE_2D, readback_texture_);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glTexImage2D(
            GL_TEXTURE_2D, 0, GL_RGB8, width, height, 0,
            GL_RGB, GL_UNSIGNED_BYTE, nullptr);
        glBindFramebuffer(GL_FRAMEBUFFER, readback_framebuffer_);
        glFramebufferTexture2D(
            GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
            GL_TEXTURE_2D, readback_texture_, 0);
        if (glCheckFramebufferStatus(GL_FRAMEBUFFER)
            != GL_FRAMEBUFFER_COMPLETE) {
            throw std::runtime_error("native monitor framebuffer incomplete");
        }
    }
    glBindFramebuffer(
        GL_READ_FRAMEBUFFER, source.framebuffers[source.active]);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, readback_framebuffer_);
    glBlitFramebuffer(
        0, 0, source.width, source.height,
        0, 0, width, height, GL_COLOR_BUFFER_BIT, GL_LINEAR);
    glBindFramebuffer(GL_FRAMEBUFFER, readback_framebuffer_);
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    std::vector<std::uint8_t> display_order(
        static_cast<std::size_t>(width) * height * 3);
    glReadPixels(
        0, 0, width, height, GL_RGB, GL_UNSIGNED_BYTE,
        display_order.data());
    // Bus textures use v=0 as logical display top. The projector mapping
    // shader applies the matching top-origin UV conversion when sampling the
    // texture, so the y=0 row returned first by glReadPixels is already the
    // first row Composer must display. Reversing it here flips only monitor
    // consumers while leaving projection correct.
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    ++monitor_readbacks_;
    return display_order;
}

bool NativeRenderGraph::static_images_pending() const {
    for(const auto& [key,source]:sources_)if(source->backend=="image-loading")return true;
    return false;
}

SceneJson NativeRenderGraph::diagnostics() const {
    SceneJson sources = SceneJson::array();
    for (const auto &[key, source] : sources_) {
        SceneJson item = {{"sourceId", source->source_id}, {"id", key}, {"backend", source->decoder ? source->decoder->backend() : source->backend},
            {"width", source->width}, {"height", source->height}, {"error", ""}};
        if (source->ndi) {
            item["error"] = source->ndi_state.error;
            item["connected"] = source->ndi_state.connected;
            if (source->ndi_state.frame) item["sourceFps"] = source->ndi_state.frame->fps;
        }
        if (source->syphon) {
            item["error"] = source->syphon->error();
            item["connected"] = source->syphon->connected();
            item["active"] = source->active;
        }
        if (source->camera) item["error"] = source->camera->error();
        if (source->decoder) {
            item["playheadSeconds"] = source->playhead;
            item["durationSeconds"] = source->known_duration;
            item["playing"] = source->playing;
            item["loopStartSeconds"] = source->known_duration * source->loop_start;
            item["loopEndSeconds"] = source->known_duration * source->loop_end;
            const double span=source->known_duration*(source->loop_end-source->loop_start);
            item["loopPosition"] = span>0?std::clamp((source->playhead-source->known_duration*source->loop_start)/span,0.,1.):0.;
            item["speed"] = source->speed;
            item["error"] = source->decoder->error();
            if (const auto frame = source->decoder->latest()) {
                item["decodedSeconds"] = frame->seconds;
                item["decodeLagSeconds"] = source->playhead - frame->seconds;
            }
        }
        sources.push_back(std::move(item));
    }
    return {
#ifdef VJ_MAPPED_METAL
        {"mappedMetalDraws",mapped_metal_.draws()},{"mappedMetalError",mapped_metal_.lastError()},
#endif
        {"processorFrames",processor_frames_},{"processorErrors",processor_errors_},
        {"frames", rendered_frames_}, {"sourceCount", sources_.size()},
        {"warmSourceCount",std::count_if(sources_.begin(),sources_.end(),[](const auto& entry){return entry.second->syphon&&!entry.second->active;})},
        {"projectorBackdropCopies",projector_backdrop_copies_},{"patchResolutionCacheHits",patch_resolution_hits_},{"patchResolutionRebuilds",patch_resolution_rebuilds_},
        {"decoderUploads", decoder_uploads_}, {"monitorReadbacks", monitor_readbacks_},
        {"renderMsEma", render_ms_ema_}, {"renderMsMax", render_ms_max_},
        {"missedDeadlines", missed_deadlines_}, {"renderSizes", render_sizes_}, {"sources", sources}};
}

std::string NativeRenderGraph::stats() const {
    std::ostringstream text;
    text << "graph frames " << rendered_frames_
         << " | sources " << sources_.size()
         << " | uploads " << decoder_uploads_
         << " | monitors " << monitor_readbacks_
         << " | render " << std::fixed << std::setprecision(2)
         << render_ms_ema_ << "ms avg " << render_ms_max_
         << "ms max miss " << missed_deadlines_;
    for (const auto &[name, size] : render_sizes_) {
        text << " | " << name << " "
             << size[0] << "x" << size[1];
    }
    for (const auto &[key, source] : sources_) {
        (void)key;
        text << " | " << (
            source->decoder ? source->decoder->backend() : source->backend);
        if (source->width > 0 && source->height > 0) {
            text << " " << source->width << "x" << source->height;
        }
        if (source->camera) {
            if (const auto error = source->camera->error(); !error.empty())
                text << " error=" << error;
        }
        if (source->decoder) {
            text << " clock " << source->playhead;
            if (const auto frame = source->decoder->latest()) {
                text << "/" << frame->seconds;
            }
            text << " x" << source->speed;
            if (source->ping_pong) text << " ping-pong";
            if (const auto error = source->decoder->error(); !error.empty()) {
                text << " error=" << error;
            }
        }
    }
    text << " | " << audio_->stats();
    return text.str();
}

std::optional<DecodedVideoFrame> NativeRenderGraph::calibration_frame() {
    const auto found=sources_.find("camera\n"+calibration_camera_);
    if(found==sources_.end() || !found->second->camera) return std::nullopt;
    return found->second->camera->latest();
}
std::string NativeRenderGraph::calibration_camera_error() {
    const auto found=sources_.find("camera\n"+calibration_camera_);
    if(found==sources_.end() || !found->second->camera) return "Camera not open";
    return found->second->camera->error();
}
