#include "monitor_frame_publisher.hpp"

#include <atomic>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <stdexcept>
#include <system_error>

#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

namespace {

#pragma pack(push, 1)
struct MonitorFrameHeader {
    char magic[8];
    std::uint32_t version;
    std::uint32_t header_size;
    std::uint32_t width;
    std::uint32_t height;
    std::uint32_t stride;
    std::uint32_t pixel_format;
    std::uint32_t slot_count;
    std::uint32_t active_slot;
    std::uint64_t sequence;
    std::uint64_t timestamp_ns;
    std::uint64_t reserved;
};
#pragma pack(pop)
static_assert(sizeof(MonitorFrameHeader) == 64);

constexpr std::uint32_t kSlots = 3;

std::string monitor_root() {
    if (const char *configured = std::getenv("VIBE_MONITOR_FRAME_ROOT");
        configured && *configured) {
        return configured;
    }
#if defined(__APPLE__)
    return "/tmp";
#else
    return "/dev/shm";
#endif
}

std::uint64_t monotonic_ns() {
    return static_cast<std::uint64_t>(
        std::chrono::duration_cast<std::chrono::nanoseconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count());
}

}  // namespace

MonitorFramePublisher::MonitorFramePublisher(std::string bus)
    : bus_(std::move(bus)) {
    auto root = monitor_root();
    while (root.size() > 1 && root.back() == '/') root.pop_back();
    path_ = root + "/vibe-vj-" + std::to_string(::getuid())
        + "-" + bus_ + ".rgb";
}

MonitorFramePublisher::~MonitorFramePublisher() {
    close_mapping();
}

void MonitorFramePublisher::close_mapping() {
    if (mapped_) {
        ::munmap(mapped_, mapped_size_);
        mapped_ = nullptr;
    }
    if (fd_ >= 0) {
        ::close(fd_);
        fd_ = -1;
    }
    mapped_size_ = 0;
    width_ = 0;
    height_ = 0;
}

void MonitorFramePublisher::ensure_mapping(int width, int height) {
    if (mapped_ && width_ == width && height_ == height) return;
    close_mapping();
    const std::size_t frame_bytes =
        static_cast<std::size_t>(width) * height * 3;
    mapped_size_ = sizeof(MonitorFrameHeader) + kSlots * frame_bytes;

    const auto root = std::filesystem::path(path_).parent_path();
    std::error_code filesystem_error;
    std::filesystem::create_directories(root, filesystem_error);
    const std::string temporary = path_ + ".tmp-"
        + std::to_string(::getpid()) + "-" + std::to_string(monotonic_ns());
    fd_ = ::open(temporary.c_str(), O_CREAT | O_EXCL | O_RDWR, 0600);
    if (fd_ < 0 || ::ftruncate(fd_, static_cast<off_t>(mapped_size_)) != 0) {
        if (fd_ >= 0) ::close(fd_);
        fd_ = -1;
        ::unlink(temporary.c_str());
        throw std::runtime_error("cannot create native monitor shared frame");
    }
    mapped_ = ::mmap(
        nullptr, mapped_size_, PROT_READ | PROT_WRITE, MAP_SHARED, fd_, 0);
    if (mapped_ == MAP_FAILED) {
        mapped_ = nullptr;
        ::close(fd_);
        fd_ = -1;
        ::unlink(temporary.c_str());
        throw std::runtime_error("cannot mmap native monitor shared frame");
    }
    width_ = width;
    height_ = height;
    active_slot_ = 0;
    sequence_ = 0;
    MonitorFrameHeader header{};
    std::memcpy(header.magic, "VIBERGB1", 8);
    header.version = 1;
    header.header_size = sizeof(MonitorFrameHeader);
    header.width = static_cast<std::uint32_t>(width);
    header.height = static_cast<std::uint32_t>(height);
    header.stride = static_cast<std::uint32_t>(width * 3);
    header.pixel_format = 1;
    header.slot_count = kSlots;
    std::memcpy(mapped_, &header, sizeof(header));
    if (::rename(temporary.c_str(), path_.c_str()) != 0) {
        close_mapping();
        ::unlink(temporary.c_str());
        throw std::runtime_error("cannot publish native monitor shared frame");
    }
}

void MonitorFramePublisher::publish(
    const std::vector<std::uint8_t> &rgb, int width, int height) {
    if (width < 1 || height < 1
        || rgb.size() != static_cast<std::size_t>(width) * height * 3) {
        throw std::runtime_error("invalid native monitor RGB frame");
    }
    ensure_mapping(width, height);
    const std::size_t frame_bytes = rgb.size();
    const std::uint32_t next = (active_slot_ + 1) % kSlots;
    auto *base = static_cast<std::uint8_t *>(mapped_);
    std::memcpy(
        base + sizeof(MonitorFrameHeader)
            + static_cast<std::size_t>(next) * frame_bytes,
        rgb.data(), frame_bytes);
    std::atomic_thread_fence(std::memory_order_release);

    MonitorFrameHeader header{};
    std::memcpy(header.magic, "VIBERGB1", 8);
    header.version = 1;
    header.header_size = sizeof(MonitorFrameHeader);
    header.width = static_cast<std::uint32_t>(width);
    header.height = static_cast<std::uint32_t>(height);
    header.stride = static_cast<std::uint32_t>(width * 3);
    header.pixel_format = 1;
    header.slot_count = kSlots;
    header.active_slot = next;
    header.sequence = ++sequence_;
    header.timestamp_ns = monotonic_ns();
    std::memcpy(mapped_, &header, sizeof(header));
    active_slot_ = next;
}
