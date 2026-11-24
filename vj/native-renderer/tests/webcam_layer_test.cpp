#include "native_render_graph.hpp"
#include <SDL2/SDL.h>
#include <chrono>
#include <cmath>
#include <iostream>
#include <stdexcept>
#include <thread>

using namespace std::chrono_literals;

static void require(bool ok, const char *message) {
    if (!ok) throw std::runtime_error(message);
}

int main() {
    SDL_Window *window = nullptr;
    SDL_GLContext context = nullptr;
    int status = 0;
    try {
        require(SDL_Init(SDL_INIT_VIDEO) == 0, SDL_GetError());
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 3);
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);
        window = SDL_CreateWindow("Webcam layer test", 0, 0, 96, 96,
                                  SDL_WINDOW_OPENGL | SDL_WINDOW_HIDDEN);
        require(window, SDL_GetError());
        context = SDL_GL_CreateContext(window);
        require(context, SDL_GetError());
        int opens = 0;
        NativeRenderGraph graph([&](const std::string &) {
            ++opens;
            return std::make_unique<LiveCapture>(
                "color=red:size=160x90:rate=30,"
                "drawbox=x=0:y=0:w=40:h=30:color=lime:t=fill,realtime", "lavfi");
        });
        graph.set_bus_sizes({{"preview", {96, 96}}, {"program", {96, 96}}});
        NativeScene scene;
        NativeLayer background;
        background.generator = "solid_color";
        background.source_id = "background";
        background.params = {{"color", "#0000ff"}};
        NativeLayer camera;
        camera.generator = "usb_webcam";
        camera.source_id = "camera-one";
        camera.resolved_file = "test-camera";
        camera.opacity = 0.5;
        camera.params = {{"fit", "contain"}, {"gain", 0.5}};
        NativeLayer duplicate = camera;
        duplicate.source_id = "independently-added-camera";
        scene.buses["preview"].layers = {background, camera};
        scene.buses["program"].layers = {background, duplicate};
        graph.apply_scene(scene);
        const auto deadline = std::chrono::steady_clock::now() + 5s;
        std::vector<std::uint8_t> pixels;
        do {
            graph.render();
            pixels = graph.read_bus_rgb("preview", 96, 96);
            if (!pixels.empty() && pixels[(48 * 96 + 48) * 3] > 40) break;
            std::this_thread::sleep_for(10ms);
        } while (std::chrono::steady_clock::now() < deadline);
        require(opens == 1, "Duplicate layers opened camera twice");
        for (const std::string bus : {"preview", "program"}) {
            pixels = graph.read_bus_rgb(bus, 96, 96);
            const int center = (48 * 96 + 48) * 3;
            require(pixels.size() == 96 * 96 * 3, "Missing live bus pixels");
            require(std::abs(pixels[center] - 64) <= 4
                    && std::abs(pixels[center + 2] - 128) <= 4,
                    "Camera brightness/opacity or RGB conversion failed");
            require(pixels[0] < 3, "Camera contain fit did not letterbox");
        }
        // The asymmetric green corner must move from top-left to bottom-right,
        // on both buses, without reopening the capture or mirroring one axis.
        for (const bool rotated : {false, true, false}) {
            for (auto &[name, bus] : scene.buses) {
                bus.layers.back().params["fit"] = "stretch";
                bus.layers.back().params["gain"] = 1;
                bus.layers.back().params["rotate_180"] = rotated;
                bus.layers.back().opacity = 1;
            }
            graph.apply_scene(scene);
            graph.render();
            for (const std::string bus : {"preview", "program"}) {
                pixels = graph.read_bus_rgb(bus, 96, 96);
                const int green = rotated ? (85 * 96 + 85) * 3 : (10 * 96 + 10) * 3;
                const int red = rotated ? (10 * 96 + 10) * 3 : (85 * 96 + 85) * 3;
                require(pixels[green + 1] > 240 && pixels[green] < 10
                        && pixels[red] > 240 && pixels[red + 1] < 10,
                        "Camera 180-degree correction has wrong orientation");
            }
            require(opens == 1, "Camera orientation change reopened capture");
        }
        graph.set_bus_sizes({{"program", {160, 90}}});
        scene.buses["preview"].layers.clear();
        scene.buses["program"].layers.back().params["gain"] = 1;
        graph.apply_scene(scene);
        graph.render();
        require(opens == 1, "Bus resize or gain reopened camera");
        graph.set_calibration_camera("test-camera");
        graph.render();
        require(opens==1,"Calibration opened a second camera");
        const auto raw=graph.calibration_frame();
        require(raw && raw->width==160 && raw->height==90,"Calibration did not get original camera dimensions");
        require((*raw->rgb)[1]>240,"Calibration raw camera orientation changed");
        scene.buses["program"].layers.back().enabled = false;
        graph.apply_scene(scene);
        graph.render();
        require(graph.calibration_frame().has_value(),"Calibration lost capture when Composer disabled layer");
        graph.set_calibration_camera("");
        graph.render();
        require(graph.stats().find("sources 0") != std::string::npos,
                "Disabled last layer retained capture");
        pixels = graph.read_bus_rgb("program", 160, 90);
        require(pixels[0] == 0 && pixels[2] == 255,
                "Disabling webcam did not reveal underlying layer");
        std::cout << "Webcam GPU layers, shared capture, fit, gain, opacity and release passed\n";
    } catch (const std::exception &error) {
        std::cerr << error.what() << '\n';
        status = 1;
    }
    if (context) SDL_GL_DeleteContext(context);
    if (window) SDL_DestroyWindow(window);
    SDL_Quit();
    return status;
}
