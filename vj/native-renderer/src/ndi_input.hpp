#pragma once
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

struct NdiFrame {
    int width = 0, height = 0;
    double fps = 0;
    std::uint64_t sequence = 0;
    std::vector<std::uint8_t> rgba;
};
struct NdiSnapshot {
    std::shared_ptr<const NdiFrame> frame;
    bool connected = false;
    std::string error;
    int queued_frames = 0;
    int buffer_ms = 0;
};
class NdiInput {
public:
    explicit NdiInput(std::string selection);
    ~NdiInput();
    NdiInput(const NdiInput &) = delete;
    NdiInput &operator=(const NdiInput &) = delete;
    NdiSnapshot snapshot() const;
    void set_buffer_ms(int milliseconds);
private:
    struct State;
    std::shared_ptr<State> state_;
    static void run(const std::shared_ptr<State> &state, const std::string &selection);
};
