#include "movie_mode.hpp"

#include <cmath>
#include <iostream>
#include <stdexcept>

namespace {

NativeScene movie_scene() {
    NativeScene scene;
    scene.mix.movie_mode = true;
    scene.outputs = {"program"};
    NativeLayer layer;
    layer.id = 1;
    layer.source_id = "movie";
    layer.generator = "video";
    layer.resolved_file = "/movie.mp4";
    layer.params = {{"audio_enabled", true}, {"speed", 1.0}};
    scene.buses["program"].layers.push_back(std::move(layer));
    return scene;
}

void require(bool condition, const char *message) {
    if (!condition) throw std::runtime_error(message);
}

}  // namespace

int main() {
    try {
        require(kMaxOutputs == 20, "output capacity must be twenty");
        require(output_source_index("out10") == 9, "double-digit routing failed");
        require(output_source_index("out20") == 19, "last output routing failed");
        require(output_source_index("out21") == -1, "out-of-range routing accepted");
        require(output_source_index("out02") == -1, "noncanonical output accepted");
        const auto expanded = parse_native_scene({{"type", "renderer_state"},
            {"outputs", {"program", "out9", "out10", "out20", "out21"}}});
        require(expanded && expanded->outputs.size() == 4 && expanded->outputs.back() == "out20",
            "renderer scene rejected high output buses");
        require(cinema_frame_rate(24000.0 / 1001.0), "23.976 rejected");
        require(cinema_frame_rate(24.0), "24 rejected");
        require(!cinema_frame_rate(25.0), "25 accepted");
        require(!cinema_frame_rate(30.0), "30 accepted");

        NativeScene scene = movie_scene();
        require(movie_mode_source(scene) == "movie", "movie rejected");

        scene.mix.movie_mode = false;
        require(!movie_mode_source(scene), "disabled mode accepted");
        scene.mix.movie_mode = true;

        NativeLayer overlay;
        overlay.id = 2;
        overlay.source_id = "overlay";
        overlay.generator = "solid";
        scene.buses["program"].layers.push_back(overlay);
        require(!movie_mode_source(scene), "visible overlay accepted");
        scene.buses["program"].layers.back().enabled = false;
        require(movie_mode_source(scene) == "movie", "disabled overlay rejected");

        auto &movie = scene.buses["program"].layers.front();
        movie.params["speed"] = 1.25;
        require(!movie_mode_source(scene), "non-1x movie accepted");
        movie.params["speed"] = 1.0;
        movie.params["loop_mode"] = "ping-pong";
        require(!movie_mode_source(scene), "ping-pong movie accepted");
        movie.params["loop_mode"] = "forward";
        movie.params["audio_enabled"] = false;
        require(!movie_mode_source(scene), "silent movie accepted");
        movie.params["audio_enabled"] = true;
        scene.outputs.push_back("out2");
        require(!movie_mode_source(scene), "multiple outputs accepted");
    } catch (const std::exception &error) {
        std::cerr << error.what() << "\n";
        return 1;
    }
    return 0;
}
