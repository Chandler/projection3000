#include "native_render_graph.hpp"
#include "static_image.hpp"
#include <SDL2/SDL.h>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <unistd.h>

void require(bool value, const char *message) {
    if (!value) throw std::runtime_error(message);
}

int main(int argc, char **argv) {
    const bool collection_only=argc>1 && std::string(argv[1])=="--media-collection";
    // Three columns: transparent red, half-transparent red, opaque red.
    constexpr unsigned char png[] = {137,80,78,71,13,10,26,10,0,0,0,13,73,72,68,82,0,0,0,3,0,0,0,3,8,6,0,0,0,86,40,181,191,0,0,0,30,73,68,65,84,8,29,29,193,1,13,0,0,8,3,32,158,252,54,215,77,200,122,131,102,189,65,179,222,160,7,123,0,5,254,42,165,175,43,0,0,0,0,73,69,78,68,174,66,96,130};
    const auto path = std::filesystem::temp_directory_path()
        / ("vibe-image-test-" + std::to_string(getpid()) + ".png");
    { std::ofstream file(path, std::ios::binary);
      file.write(reinterpret_cast<const char *>(png), sizeof(png)); }
    int status = 0;
    SDL_Window *window = nullptr;
    SDL_GLContext context = nullptr;
    try {
        const auto decoded = load_static_image(path.string());
        require(decoded && decoded->width == 3, "PNG decode failed");
        require(decoded->pixels[0] == 0 && decoded->pixels[4] == 128
                && decoded->pixels[7] == 128, "PNG alpha was lost");
        require(!load_static_image(path.string() + ".missing"), "missing image accepted");
        require(SDL_Init(SDL_INIT_VIDEO) == 0, SDL_GetError());
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 3);
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);
        window = SDL_CreateWindow("Image layer test", 0, 0, 96, 96,
                                  SDL_WINDOW_OPENGL | SDL_WINDOW_HIDDEN);
        require(window, SDL_GetError());
        context = SDL_GL_CreateContext(window);
        require(context, SDL_GetError());
        NativeRenderGraph graph;
        graph.set_bus_sizes({{"preview", {3, 3}}, {"program", {3, 3}}});
        NativeScene scene;
        NativeLayer background;
        background.generator = "solid_color";
        background.source_id = "background";
        background.params = {{"color", "#336699"}};
        NativeLayer image;
        image.generator = "image";
        image.source_id = "image";
        image.resolved_file = path.string();
        image.params = {{"fit", "stretch"}};
        const float dst[] = {0.2f, 0.4f, 0.6f};
        std::vector<unsigned char> pixels;
        if(!collection_only){
        for (const std::string blend : {"normal", "add", "screen", "multiply", "subtract"}) {
            for (float opacity : {1.0f, 0.5f}) {
                image.blend = blend;
                image.opacity = opacity;
                scene.buses["preview"].layers = {background, image};
                scene.buses["program"] = scene.buses["preview"];
                graph.apply_scene(scene);
                graph.render();
                for (const std::string bus : {"preview", "program"}) {
                    const auto pixels = graph.read_bus_rgb(bus, 3, 3);
                    require(pixels.size() == 27, "empty GPU output");
                    for (int x = 0; x < 3; ++x) for (int c = 0; c < 3; ++c) {
                        const float src = c == 0 ? 1 : 0;
                        const float alpha = (x == 0 ? 0 : x == 1 ? 128 / 255.0f : 1) * opacity;
                        const float mixed = blend == "add" ? dst[c] + src
                            : blend == "screen" ? 1 - (1 - dst[c]) * (1 - src)
                            : blend == "subtract" ? dst[c] - src
                            : blend == "multiply" ? dst[c] * src : src;
                        const float expected = std::clamp(dst[c] + (mixed - dst[c]) * alpha, 0.0f, 1.0f);
                        require(std::abs(pixels[x * 3 + c] / 255.0f - expected) < 0.015f,
                                "GPU alpha blend mismatch");
                    }
                }
            }
        }
        image.blend = "normal";
        image.opacity = 1;
        image.params = {{"fit", "contain"}, {"scale", 0.5}, {"x", 0.25}, {"y", 0.25}};
        graph.set_bus_sizes({{"preview", {96, 96}}});
        NativeLayer adjustment;
        adjustment.generator = "color_adjust";
        adjustment.source_id = "filter";
        adjustment.params = {{"saturation", 0}};
        scene.buses["preview"].layers = {background, image, adjustment};
        graph.apply_scene(scene);
        graph.render();
        pixels = graph.read_bus_rgb("preview", 96, 96);
        const int title_pixel = (24 * 96 + 40) * 3;
        require(std::abs(pixels[title_pixel] - pixels[title_pixel + 1]) <= 1,
                "filter above image did not affect title");
        scene.buses["preview"].layers = {background, adjustment, image};
        graph.apply_scene(scene);
        graph.render();
        pixels = graph.read_bus_rgb("preview", 96, 96);
        require(pixels[title_pixel] > 240 && pixels[title_pixel + 1] < 10,
                "image placement or layer ordering failed");
        }
        graph.set_bus_sizes({{"preview", {96, 96}}});
        // Expanded media items must draw only their assigned faces, sampling
        // the full item on each face and preserving first-layer opacity rules.
        auto face=[](float left,float right){
            return std::vector<float>{left,-1,0,1,1,0,0,0, right,-1,1,1,1,0,0,0,
                right,1,1,0,1,0,0,0, left,-1,0,1,1,0,0,0,
                right,1,1,0,1,0,0,0, left,1,0,0,1,0,0,0};
        };
        image.params={{"fit","stretch"},{"_media_vertices",face(-1,0)},{"_media_group","collection"}};
        image.opacity=.2f;image.base_opacity=.6f;
        auto second=background;second.params={{"color","#00ff00"},{"_media_vertices",face(0,1)},{"_media_group","collection"}};
        second.opacity=.2f;second.base_opacity=.6f;
        scene.buses["preview"].collection={{"kind","planar"}};
        scene.buses["preview"].layers={image,second};
        graph.apply_scene(scene);graph.render();
        pixels=graph.read_bus_rgb("preview",96,96);
        const int left_pixel=(48*96+42)*3,right_pixel=(48*96+72)*3;
        require(pixels[left_pixel]>140 && pixels[left_pixel]<165 && pixels[left_pixel+1]<5,
                "first media item did not fill its face");
        require(pixels[right_pixel]<5 && pixels[right_pixel+1]>140 && pixels[right_pixel+1]<165,
                "second media item leaked or lost collection opacity");
        // Rotate the mapped media quads, retaining their UV associations.
        // The asymmetric image and independent second face must rotate with them.
        auto rotated=[](std::vector<float> vertices){for(std::size_t i=0;i<vertices.size();i+=8){const float x=vertices[i];vertices[i]=-vertices[i+1];vertices[i+1]=x;}return vertices;};
        image.params["_media_vertices"]=rotated(face(-1,0));second.params["_media_vertices"]=rotated(face(0,1));
        scene.buses["preview"].layers={image,second};graph.apply_scene(scene);graph.render();
        auto turned=graph.read_bus_rgb("preview",96,96);
        for(int channel=0;channel<3;++channel){
            require(std::abs(int(turned[(42*96+47)*3+channel])-int(pixels[left_pixel+channel]))<=2,"media UV orientation did not follow its plane");
            require(std::abs(int(turned[(72*96+47)*3+channel])-int(pixels[right_pixel+channel]))<=2,"second plane orientation did not follow geometry");
        }
        // Two mapped faces must receive independent flat colors, with the
        // same path handling box, planar, and round point destinations.
        auto cards=face(-1,0);auto right=face(0,1);cards.insert(cards.end(),right.begin(),right.end());
        NativeLayer flash;flash.generator="flash_faces";flash.source_id="flash";flash.collection_geometry="faces";
        flash.params={{"theme","custom"},{"colors",2},{"color_a","#ff0000"},{"color_b","#00ff00"},{"speed",2},{"on_time",1}};
        auto &bus=scene.buses["preview"];bus.clock.playing=false;bus.clock.seconds=0;
        for(const std::string kind:{"planar","boxes","points"}){
            bus.collection={{"kind",kind},{"pointShape","circle"},{"cardVertices",cards},{"faceIds",{"left","right"}},{"cardFaceIndices",{0,1}}};
            bus.layers={flash};graph.apply_scene(scene);graph.render();
            pixels=graph.read_bus_rgb("preview",96,96);
            require(pixels[(48*96+24)*3]>245 && pixels[(48*96+24)*3+1]<5,"left face color lost");
            require(pixels[right_pixel]<5 && pixels[right_pixel+1]>245,"right face color lost");
            if(kind=="points")require(pixels[0]<5,"round point coverage lost");
        }
        bus.collection["kind"]="boxes";bus.clock.seconds=.5;
        graph.apply_scene(scene);graph.render();pixels=graph.read_bus_rgb("preview",96,96);
        require(pixels[(48*96+24)*3+1]>245 && pixels[right_pixel]>245,"colors did not alternate");
        bus.layers[0].params["on_time"]=.5;bus.clock.seconds=.375;
        graph.apply_scene(scene);graph.render();pixels=graph.read_bus_rgb("preview",96,96);
        require(pixels[right_pixel]<5 && pixels[right_pixel+1]<5,"off interval is not black on GPU");
        scene.buses["preview"].collection=SceneJson::object();
        image.opacity=1;
        if (argc > 1 && !collection_only) {
            image.resolved_file = argv[1];
            require(load_static_image(image.resolved_file).has_value(), "title PNG decode failed");
            image.params = {{"fit", "contain"}};
            scene.buses["preview"].layers = {background, image};
            graph.set_bus_sizes({{"preview", {960, 540}}});
            graph.apply_scene(scene);
            graph.render();
            pixels = graph.read_bus_rgb("preview", 960, 540);
            require(pixels[0] == 51 && pixels[1] == 102 && pixels[2] == 153,
                    "title background lost transparency");
            if (argc > 2) {
                std::ofstream output(argv[2], std::ios::binary);
                output << "P6\n960 540\n255\n";
                output.write(reinterpret_cast<const char *>(pixels.data()), pixels.size());
            }
        }
        std::cout << "Image decode, GPU alpha blends, placement, filters, and outputs passed\n";
    } catch (const std::exception &error) {
        std::cerr << error.what() << '\n';
        status = 1;
    }
    if (context) SDL_GL_DeleteContext(context);
    if (window) SDL_DestroyWindow(window);
    SDL_Quit();
    std::filesystem::remove(path);
    return status;
}
