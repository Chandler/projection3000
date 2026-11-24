#pragma once

#include <cstdint>
#include <string>
#include <vector>

class MonitorFramePublisher {
public:
    explicit MonitorFramePublisher(std::string bus);
    ~MonitorFramePublisher();

    MonitorFramePublisher(const MonitorFramePublisher &) = delete;
    MonitorFramePublisher &operator=(const MonitorFramePublisher &) = delete;

    void publish(const std::vector<std::uint8_t> &rgb,
                 int width, int height);
    const std::string &path() const { return path_; }

private:
    void ensure_mapping(int width, int height);
    void close_mapping();

    std::string bus_;
    std::string path_;
    int fd_ = -1;
    void *mapped_ = nullptr;
    std::size_t mapped_size_ = 0;
    int width_ = 0;
    int height_ = 0;
    std::uint32_t active_slot_ = 0;
    std::uint64_t sequence_ = 0;
};
