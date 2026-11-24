#include "playback.hpp"

#include <cmath>
#include <iostream>
#include <stdexcept>
#include <string>

namespace {

void require_near(
    const std::string &label, double actual, double expected) {
    if (std::abs(actual - expected) <= 0.000001) return;
    throw std::runtime_error(
        label + ": expected " + std::to_string(expected)
        + ", got " + std::to_string(actual));
}

}  // namespace

int main() {
    try {
        require_near("start", ping_pong_position(0.0, 2.0, 4.0), 2.0);
        require_near("forward", ping_pong_position(1.0, 2.0, 4.0), 3.0);
        require_near("end", ping_pong_position(2.0, 2.0, 4.0), 4.0);
        require_near("reverse", ping_pong_position(2.5, 2.0, 4.0), 3.5);
        require_near("cycle", ping_pong_position(4.0, 2.0, 4.0), 2.0);
        require_near("next cycle", ping_pong_position(5.0, 2.0, 4.0), 3.0);
        require_near("negative shift", ping_pong_position(-0.5, 2.0, 4.0), 2.5);
        std::cout << "ping-pong playback math: PASS\n";
        return 0;
    } catch (const std::exception &error) {
        std::cerr << "ping-pong playback math: FAIL: "
                  << error.what() << "\n";
        return 1;
    }
}
