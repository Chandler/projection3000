// ABI execution and analytic GPU strokes ported from native-renderer/src/main.cpp.
// Keep parser/shader behavior aligned with that renderer until shared extraction.
#include "vector_host.hpp"
#include "module_registry.hpp"
#include "projector_raster.hpp"
#include "surface_curvature.hpp"
#include <wasmtime.h>
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <iostream>
#include <map>
#include <set>
#include <stdexcept>
#include <vector>
namespace vj {
namespace {
using json=nlohmann::json;
using Clock=std::chrono::steady_clock;
using projector_raster::compile_shader;
using projector_raster::solve_linear;
using projector_raster::rotate_output_uv;
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
        if(params->size()>32768)throw std::runtime_error("Vector parameter limit exceeded");
        for (const auto &param : *params) {
            if (!param.is_number())throw std::runtime_error("Vector parameters must be numeric");
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
        const std::vector<uint8_t>& bytes, std::string module_path, int expected_abi, uint64_t render_fuel=5'000'000)
        : module_path_(std::move(module_path)),render_fuel_(render_fuel) {
        store_ = wasmtime_store_new(vector_wasm_engine(), nullptr, nullptr);
        if (!store_) throw std::runtime_error("could not create Wasmtime store");
        try {
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

        wasm_importtype_vec_t declared_imports;
        wasmtime_module_imports(module, &declared_imports);
        auto named = [](const wasm_name_t* name, const char* expected) {
            return name->size == std::strlen(expected)
                && std::memcmp(name->data, expected, name->size) == 0;
        };
        const bool allowed_imports = declared_imports.size == 1
            && named(wasm_importtype_module(declared_imports.data[0]), "env")
            && named(wasm_importtype_name(declared_imports.data[0]), "abort");
        wasm_importtype_vec_delete(&declared_imports);
        if (!allowed_imports) {
            wasmtime_module_delete(module);
            throw std::runtime_error("Module must import only env.abort(i32,i32,i32,i32)");
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
        if (param_offset_%alignof(float) || command_offset_%alignof(float)
            || param_capacity_count_ <= 0 || param_capacity_count_ > 32768
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
        } catch (...) { wasmtime_store_delete(store_);store_=nullptr;throw; }
    }

    ~VectorWasmEffect() {
        if (store_) wasmtime_store_delete(store_);
    }

    VectorWasmEffect(const VectorWasmEffect &) = delete;
    VectorWasmEffect &operator=(const VectorWasmEffect &) = delete;

    const std::string &module_path() const { return module_path_; }
    int abi() const { return abi_; }

    void validateUploadCapacity(std::size_t count) const {
        if (param_capacity_count_ > 1024 || count > static_cast<std::size_t>(param_capacity_count_))
            throw std::runtime_error("Invalid exported parameter capacity");
    }

    VectorScene evaluate(
        const std::vector<float> &params, double seconds, double beat, bool validate_only=false) {
        if (params.size() > static_cast<std::size_t>(param_capacity_count_)) {
            throw std::runtime_error("vector recipe exceeds parameter capacity");
        }
        auto *memory = wasmtime_memory_data(context_, &memory_);
        auto *param_data = reinterpret_cast<float *>(memory + param_offset_);
        std::fill(
            param_data, param_data + param_capacity_count_, 0.0f);
        std::copy(params.begin(), params.end(), param_data);

        if (auto *error = wasmtime_context_set_fuel(context_, render_fuel_)) {
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
        if(result.kind!=WASMTIME_I32) throw std::runtime_error("Vector render must return i32");
        const int used = result.of.i32;
        if (used < 0 || used > command_capacity_count_) {
            throw std::runtime_error("vector WASM returned invalid command size");
        }
        memory = wasmtime_memory_data(context_, &memory_);
        const auto *commands =
            reinterpret_cast<const float *>(memory + command_offset_);
        if (validate_only) {
            // Validate the ABI stream itself without GPU tessellation or its scene budget.
            for (int i=0;i<used;++i)
                if (!std::isfinite(commands[i])) throw std::runtime_error("Nonfinite vector command");
            std::size_t cursor=0;
            constexpr std::size_t sizes[]={0,10,2,2,0,12,12,16,12};
            while (cursor<static_cast<std::size_t>(used)) {
                const float op=commands[cursor];
                if (op<1 || op>(abi_==1?4:8) || std::floor(op)!=op)
                    throw std::runtime_error("Malformed vector command stream");
                cursor+=1+sizes[static_cast<int>(op)];
                if(cursor>static_cast<std::size_t>(used))
                    throw std::runtime_error("Malformed vector command stream");
            }
            return {};
        }
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
        if(result.kind!=WASMTIME_I32) throw std::runtime_error("Vector buffer export must return i32");
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
    uint64_t render_fuel_;
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


}
struct VectorHost::Impl {
    std::filesystem::path uploaded;
    GLuint program=0,vao=0,vbo=0,ebo=0;GLint pass=-1;
    struct Cache {std::unique_ptr<VectorWasmEffect> effect;std::string signature,error;uint64_t errorRevision=0;size_t segments=0,splats=0;};
    std::map<std::string,Cache> layers;std::set<std::string> used;uint64_t revision=0;
    Impl(std::filesystem::path external):uploaded(std::move(external)){
        program=make_vector_program();pass=glGetUniformLocation(program,"vector_pass");glGenVertexArrays(1,&vao);glGenBuffers(1,&vbo);glGenBuffers(1,&ebo);glBindVertexArray(vao);glBindBuffer(GL_ARRAY_BUFFER,vbo);
        const size_t offsets[]={offsetof(VectorGpuVertex,position),offsetof(VectorGpuVertex,line_local),offsetof(VectorGpuVertex,core),offsetof(VectorGpuVertex,glow),offsetof(VectorGpuVertex,widths)};const GLint sizes[]={2,3,4,4,4};
        for(GLuint i=0;i<5;++i){glVertexAttribPointer(i,sizes[i],GL_FLOAT,GL_FALSE,sizeof(VectorGpuVertex),reinterpret_cast<void*>(offsets[i]));glEnableVertexAttribArray(i);}glBindBuffer(GL_ELEMENT_ARRAY_BUFFER,ebo);
    }
    ~Impl(){layers.clear();if(ebo)glDeleteBuffers(1,&ebo);if(vbo)glDeleteBuffers(1,&vbo);if(vao)glDeleteVertexArrays(1,&vao);if(program)glDeleteProgram(program);}
    std::filesystem::path modulePath(const std::string& module)const{
        namespace fs=std::filesystem;constexpr std::string_view prefix="/vector/modules/external/";
        if(!module.starts_with(prefix))throw std::runtime_error("Invalid vector module path");
        auto relative=module.substr(prefix.size());auto root=uploaded;
        if(root.empty()||relative.empty()||fs::path(relative).is_absolute()||fs::path(relative).extension()!=".wasm")throw std::runtime_error("Vector module root or path is unavailable");
        root=fs::weakly_canonical(root);auto path=fs::weakly_canonical(root/relative);auto a=root.begin(),b=path.begin();for(;a!=root.end();++a,++b)if(b==path.end()||*a!=*b)throw std::runtime_error("Vector module escapes module root");
        if(!fs::is_regular_file(path))throw std::runtime_error("Vector module is missing");const auto size=fs::file_size(path);if(size<8||size>2*1024*1024)throw std::runtime_error("Vector module size is invalid");return path;
    }
    bool render(const NativeLayer& layer,double seconds,double beat,int width,int height){
        used.insert(layer.source_id);auto& cache=layers[layer.source_id];if(!cache.error.empty()&&cache.errorRevision==revision)return false;
        try{
            auto recipe=parse_vector_recipe(layer.vector);if(!recipe)throw std::runtime_error("Invalid vector recipe");const auto path=modulePath(recipe->module);
            const auto signature=path.string()+":"+std::to_string(std::filesystem::file_size(path))+":"+std::to_string(static_cast<long long>(std::filesystem::last_write_time(path).time_since_epoch().count()))+":"+std::to_string(recipe->abi);
            if(!cache.effect||cache.signature!=signature){std::ifstream input(path,std::ios::binary);std::vector<uint8_t> bytes(std::istreambuf_iterator<char>(input),{});cache.effect=std::make_unique<VectorWasmEffect>(bytes,recipe->module,recipe->abi,5'000'000);cache.signature=signature;cache.segments=0;cache.splats=0;}
            const auto picture=cache.effect->evaluate(recipe->params,seconds,beat);cache.segments=picture.segments.size();cache.splats=picture.splats.size();
            Rect rect;rect.corners={{{0,0}},{{1,0}},{{1,1}},{{0,1}}};rect.fit="stretch";
            // Compositor applies layer opacity/blend/master after this transparent source.
            recipe->opacity=1;recipe->master=VectorMaster{};
            std::vector<VectorGpuVertex> vertices;std::vector<uint32_t> indices;append_vector_rect(picture,*recipe,rect,width,height,0,vertices,indices);for(auto& vertex:vertices)vertex.position[1]=-vertex.position[1];
            if(!indices.empty()){
                glDisable(GL_STENCIL_TEST);glUseProgram(program);glBindVertexArray(vao);glBindBuffer(GL_ARRAY_BUFFER,vbo);glBufferData(GL_ARRAY_BUFFER,vertices.size()*sizeof(VectorGpuVertex),vertices.data(),GL_DYNAMIC_DRAW);glBindBuffer(GL_ELEMENT_ARRAY_BUFFER,ebo);glBufferData(GL_ELEMENT_ARRAY_BUFFER,indices.size()*sizeof(uint32_t),indices.data(),GL_DYNAMIC_DRAW);
                glUniform1i(pass,0);set_vector_blend("normal",true);glDrawElements(GL_TRIANGLES,static_cast<GLsizei>(indices.size()),GL_UNSIGNED_INT,nullptr);glUniform1i(pass,1);set_vector_blend("normal",false);glDrawElements(GL_TRIANGLES,static_cast<GLsizei>(indices.size()),GL_UNSIGNED_INT,nullptr);
            }
            cache.error.clear();return true;
        }catch(const std::exception& error){cache.effect.reset();cache.signature.clear();cache.error=error.what();cache.errorRevision=revision;return false;}
    }
};
void installWasmtimeModuleValidator() {
    installVectorModuleValidator([](const std::vector<uint8_t>& bytes,const json& manifest) {
        VectorWasmEffect effect(bytes,"uploaded animation",manifest.at("abi").get<int>());
        effect.validateUploadCapacity(manifest.at("parameters").size());
        std::vector<float> defaults;
        for(const auto& parameter:manifest.at("parameters")) defaults.push_back(parameter.at("default").get<float>());
        for(double seconds:{0.0,0.5,10.0}) effect.evaluate(defaults,seconds,seconds*2,true);
    });
}
VectorHost::VectorHost(std::filesystem::path uploaded):impl_(std::make_shared<Impl>(std::move(uploaded))){}
VectorHost::~VectorHost()=default;
void VectorHost::install(NativeRenderGraph& graph){std::weak_ptr<Impl> weak=impl_;graph.set_vector_layer_renderer([weak](const NativeLayer& layer,double seconds,double beat,int width,int height){if(auto owner=weak.lock())return owner->render(layer,seconds,beat,width,height);return false;});}
void VectorHost::beginFrame(uint64_t revision){impl_->revision=revision;impl_->used.clear();}
void VectorHost::endFrame(){for(auto it=impl_->layers.begin();it!=impl_->layers.end();)if(!impl_->used.contains(it->first))it=impl_->layers.erase(it);else++it;}
nlohmann::json VectorHost::diagnostics()const{json result=json::array();for(const auto& [id,cache]:impl_->layers)result.push_back({{"sourceId",id},{"module",cache.effect?cache.effect->module_path():""},{"error",cache.error},{"segments",cache.segments},{"splats",cache.splats}});return {{"available",true},{"abiVersions",{1,2}},{"sources",result}};}
}
