#include "mapping_fit.hpp"

#include <iostream>
#include <stdexcept>

void require(bool condition, const char *message) {
    if (!condition) throw std::runtime_error(message);
}

int main() {
    try {
        // A wide composition on a tall projector rect, with and without an
        // open Composer monitor. Monitor demand must not change the crop.
        for (const auto demand : {std::array<int, 2>{160, 210},
                                  std::array<int, 2>{640, 360}}) {
            const auto size = mapping_bus_size(demand, 960, 540);
            require(size[0] >= demand[0] && size[1] >= demand[1],
                    "mapping resolution undersamples demand");
            const float aspect = static_cast<float>(size[0]) / size[1];
            require(std::abs(aspect - 16.0f / 9) < 0.005f,
                    "tall rect distorted the composition before mapping");
            const auto crop = mapping_content_scale("fill", aspect, 160, 210);
            require(crop[0] > 2.3f && crop[1] == 1,
                    "wide video must crop its sides on a tall rect");
            // The shader samples the central 1/scale part of the source.
            require(std::abs(aspect / crop[0] - 160.0f / 210) < 0.001f,
                    "cropped video has the wrong visible proportions");
            const auto fit = mapping_content_scale("fit", aspect, 160, 210);
            require(fit[0] == 1 && fit[1] < 0.44f,
                    "fit must letterbox the wide video");
            require(mapping_content_scale("stretch", aspect, 160, 210)
                        == std::array<float, 2>{1, 1},
                    "warp must retain the full source");
        }
        const auto portrait = mapping_bus_size({640, 360}, 540, 960);
        const float aspect = static_cast<float>(portrait[0]) / portrait[1];
        const auto crop = mapping_content_scale("fill", aspect, 640, 360);
        require(crop[0] == 1 && crop[1] > 3.1f,
                "portrait composition must crop top and bottom on a wide rect");
        const auto full = mapping_bus_size({1280, 720}, 960, 540);
        require(full == std::array<int, 2>{1280, 720},
                "matching aspect should retain requested resolution");
        std::cout << "Mapping crop, fit, warp, and monitor demand passed\n";
    } catch (const std::exception &error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
