#pragma once
#include <chrono>
#include <memory>
#include <string>
#include <vector>
#include <cstdint>
#include <nlohmann/json.hpp>

// Latest-frame mailbox: network compression never runs on the GL thread.
class NdiOutput {
public:
    NdiOutput(std::string name, int width, int height, int fps);
    ~NdiOutput();
    bool due();
    void configure(int w, int h, int rate);
    std::uint64_t publish(std::vector<std::uint8_t> rgb);
    nlohmann::json diagnostics() const;
    const std::string name;
    int width, height, fps;
private:
    struct State;
    std::shared_ptr<State> state_;
    std::chrono::steady_clock::time_point next_{};
};
