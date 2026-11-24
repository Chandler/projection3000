#pragma once
#include <array>
#include <string>

inline constexpr int kMaxOutputs = 20;
inline int output_source_index(const std::string &source) {
    for (int i = 0; i < kMaxOutputs; ++i)
        if (source == "out" + std::to_string(i + 1)) return i;
    return -1;
}
inline const std::array<std::string, kMaxOutputs> kOutputBuses = [] {
    std::array<std::string, kMaxOutputs> buses{};
    buses[0] = "program";
    for (int i = 1; i < kMaxOutputs; ++i) buses[i] = "out" + std::to_string(i + 1);
    return buses;
}();
