#include "syphon_input.hpp"
#include <chrono>
#include <iostream>
#include <thread>
int main() {
    const auto end = std::chrono::steady_clock::now() + std::chrono::milliseconds(700);
    do {
        syphon_poll();
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    } while (std::chrono::steady_clock::now() < end);
    std::cout << nlohmann::json({{"available", true}, {"sources", syphon_sources()}}).dump() << std::endl;
}
