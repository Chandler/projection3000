#pragma once
// Shared raster projector behavior: extracted unchanged from main.cpp so editor
// previews and the standalone renderer use identical shaders and transforms.
#ifndef GL_GLEXT_PROTOTYPES
#define GL_GLEXT_PROTOTYPES
#endif
#include <SDL2/SDL_opengl.h>
#include "plane_pattern.hpp"
#include <algorithm>
#include <array>
#include <cmath>
#include <optional>
#include <stdexcept>
#include <string>
namespace projector_raster {
inline std::array<float, 2> rotate_output_uv(std::array<float, 2> point, int rotation) {
    const float x = point[0], y = point[1];
    switch ((rotation % 360 + 360) % 360) {
        case 90: return {1.0f - y, x};
        case 180: return {1.0f - x, 1.0f - y};
        case 270: return {y, 1.0f - x};
        default: return point;
    }
}

inline GLuint compile_shader(GLenum type, const char *source) {
    const GLuint shader = glCreateShader(type);
    glShaderSource(shader, 1, &source, nullptr);
    glCompileShader(shader);
    GLint ok = GL_FALSE;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        GLint length = 0;
        glGetShaderiv(shader, GL_INFO_LOG_LENGTH, &length);
        std::string log(static_cast<std::size_t>(std::max(length, 1)), '\0');
        glGetShaderInfoLog(shader, length, nullptr, log.data());
        throw std::runtime_error("OpenGL shader compile failed: " + log);
    }
    return shader;
}

inline GLuint make_program() {
    constexpr const char *vertex = R"GLSL(
        #version 330 core
        layout(location = 0) in vec2 position;
        layout(location = 1) in vec3 uvq;
        out vec3 projected_uv;
        void main() {
            projected_uv = uvq;
            gl_Position = vec4(position, 0.0, 1.0);
        }
    )GLSL";
    constexpr const char *fragment = R"GLSL(
        #version 330 core
        uniform sampler2D frame_texture;
        uniform vec2 destination_scale;
        uniform int use_texture;
        uniform int overlay_grid;
        uniform vec2 plane_extent;
        uniform bool plane_circle;
        in vec3 projected_uv;
        out vec4 color;

    )GLSL" VJ_PLANE_PATTERN_GLSL R"GLSL(
        float grid_line(vec2 uv) {
            vec2 every = abs(fract(uv * 10.0 + 0.5) - 0.5) / fwidth(uv * 10.0);
            float interior = 1.0 - min(min(every.x, every.y), 1.0);
            vec2 edge_distance = min(uv, 1.0 - uv) / fwidth(uv);
            float edge = 1.0 - min(min(edge_distance.x, edge_distance.y), 1.0);
            vec2 center_distance = abs(uv - 0.5) / fwidth(uv);
            float center = 1.0 - min(min(center_distance.x, center_distance.y), 1.0);
            return max(max(interior, edge), center);
        }

        void main() {
            float q = abs(projected_uv.z) < 0.000001
                ? (projected_uv.z < 0.0 ? -0.000001 : 0.000001)
                : projected_uv.z;
            vec2 uv = projected_uv.xy / q;
            if (overlay_grid == 3) {color=planePattern(uv,plane_extent,plane_circle);return;}
            if (overlay_grid == 2) {
                vec2 distance=min(uv,1.0-uv)/max(fwidth(uv),vec2(.000001));
                float line=1.0-smoothstep(1.0,2.5,min(distance.x,distance.y));
                color=vec4(vec3(0.0,1.0,.4)*line,1.0);return;
            }
            if (overlay_grid != 0) {
                float line = grid_line(uv);
                if (line < 0.01) discard;
                color = vec4(vec3(1.0), line);
                return;
            }
            if (use_texture == 0) {
                float line = grid_line(uv);
                color = vec4(
                    mix(vec3(0.01, 0.025, 0.01),
                        vec3(0.08, 1.0, 0.24), line),
                    1.0);
                return;
            }
            vec2 source_uv = (uv - (vec2(1.0) - destination_scale) * 0.5)
                / destination_scale;
            if (any(lessThan(source_uv, vec2(0.0)))
                || any(greaterThan(source_uv, vec2(1.0)))) {
                color = vec4(0.0, 0.0, 0.0, 1.0);
                return;
            }
            // JPEG scanlines arrive top-to-bottom, while OpenGL texture V
            // increases bottom-to-top. Flip only the sampled frame; mapping
            // geometry and its calibration grids already use screen-space Y.
            source_uv.y = 1.0 - source_uv.y;
            color = texture(frame_texture, source_uv);
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
    if (!ok) throw std::runtime_error("OpenGL shader link failed");
    return program;
}

inline bool solve_linear(std::array<std::array<double, 9>, 8> &rows,
                  std::array<double, 8> &result) {
    for (int column = 0; column < 8; ++column) {
        int pivot = column;
        for (int row = column + 1; row < 8; ++row) {
            if (std::abs(rows[row][column]) > std::abs(rows[pivot][column])) pivot = row;
        }
        if (std::abs(rows[pivot][column]) < 1e-10) return false;
        std::swap(rows[column], rows[pivot]);
        const double divisor = rows[column][column];
        for (int j = column; j <= 8; ++j) rows[column][j] /= divisor;
        for (int row = 0; row < 8; ++row) {
            if (row == column) continue;
            const double factor = rows[row][column];
            for (int j = column; j <= 8; ++j) rows[row][j] -= factor * rows[column][j];
        }
    }
    for (int row = 0; row < 8; ++row) result[row] = rows[row][8];
    return true;
}

template<class Surface>
std::optional<std::array<std::array<float, 3>, 4>> projective_uvs(const Surface &rect) {
    if (rect.corners.size() != 4 || rect.uvs.size() != 4) {
        return std::nullopt;
    }
    std::array<std::array<double, 9>, 8> rows{};
    for (int i = 0; i < 4; ++i) {
        const double x = rect.corners[i][0], y = rect.corners[i][1];
        const double u = rect.uvs[i][0], v = rect.uvs[i][1];
        rows[i * 2] = {x, y, 1, 0, 0, 0, -u * x, -u * y, u};
        rows[i * 2 + 1] = {0, 0, 0, x, y, 1, -v * x, -v * y, v};
    }
    std::array<double, 8> h{};
    if (!solve_linear(rows, h)) return std::nullopt;
    std::array<std::array<float, 3>, 4> result{};
    double max_q = 1e-8;
    int sign = 0;
    for (int i = 0; i < 4; ++i) {
        const double q = h[6] * rect.corners[i][0] + h[7] * rect.corners[i][1] + 1;
        if (!std::isfinite(q) || std::abs(q) < 1e-8) return std::nullopt;
        const int next_sign = q < 0 ? -1 : 1;
        if (sign && sign != next_sign) return std::nullopt;
        sign = next_sign;
        result[i] = {
            static_cast<float>(rect.uvs[i][0] * q),
            static_cast<float>(rect.uvs[i][1] * q),
            static_cast<float>(q),
        };
        max_q = std::max(max_q, std::abs(q));
    }
    for (auto &value : result) {
        for (float &component : value) component /= static_cast<float>(max_q);
    }
    return result;
}

inline void set_blend(const std::string &blend) {
    glEnable(GL_BLEND);
    glBlendEquation(GL_FUNC_ADD);
    if (blend == "premultiplied") {
        glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
    } else if (blend == "add") {
        glBlendFunc(GL_ONE, GL_ONE);
    } else if (blend == "subtract") {
        glBlendEquationSeparate(GL_FUNC_REVERSE_SUBTRACT, GL_FUNC_ADD);
        glBlendFuncSeparate(GL_SRC_ALPHA, GL_ONE, GL_ZERO, GL_ONE);
    } else if (blend == "screen") {
        glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_COLOR);
    } else if (blend == "multiply") {
        glBlendFunc(GL_DST_COLOR, GL_ZERO);
    } else {
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    }
}

}
