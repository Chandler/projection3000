#pragma once
#include <nlohmann/json.hpp>
#include <chrono>
#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <vector>
namespace vj {
struct FrameImage {
    int width=0,height=0;
    std::uint64_t sequence=0;
    std::chrono::steady_clock::time_point captured;
    std::shared_ptr<const std::vector<std::uint8_t>> rgb;
    int channels=3; // RGB8 or RGBA8, top-to-bottom. Room PNG preserves alpha.
};
struct FrameEncoding { int width=0,height=0,quality=72;bool png=false; };
struct EncodedFrame {
    std::shared_ptr<const std::vector<std::uint8_t>> bytes;
    std::string contentType="image/jpeg";
    int width=0,height=0;
    std::uint64_t sequence=0;
    std::chrono::steady_clock::time_point captured;
};
struct FrameDemand {int width=0,height=0;double fps=0;std::string mappingId,transport;};
struct FrameStreamRoute {std::string channel,profile="auto";};
// nullopt for unrelated routes; recognized invalid/inactive routes throw ApiError.
std::optional<FrameStreamRoute> frameStreamRoute(const std::string& path,
    const nlohmann::json& query,int activeOutputs);
std::optional<std::string> mappingFrameRoute(const std::string& path);
// Core-only, latest-only queues. No graphics calls, devices, sockets, or mmap.
// One encoder worker; destruction joins it. Encoder must finish in bounded time.
class FrameTransport {
public:
    using Encoder=std::function<std::vector<std::uint8_t>(const FrameImage&,const FrameEncoding&)>;
    using Client=std::uint64_t;
    FrameTransport();~FrameTransport();
    FrameTransport(const FrameTransport&)=delete;FrameTransport& operator=(const FrameTransport&)=delete;
    void configure(int width,int height,int fps,int quality,int activeOutputs,bool streamHD=false);
    void setEncoder(Encoder encoder);
    void setActiveOutputs(int count);
    void setStreamHD(bool enabled);
    // Synchronous CPU encoding for explicit HTTP camera requests; no store mutation.
    std::vector<std::uint8_t> encodeImage(const FrameImage& image,const FrameEncoding& encoding)const;
    int activeOutputs()const;
    Client subscribeLeds();
    void unsubscribeLeds(Client client);
    std::shared_ptr<const std::string> takeLeds(Client client);
    bool publishLedFrames(const std::map<std::string,std::vector<std::uint8_t>>& frames,bool virtualActive);
    Client subscribe(const FrameStreamRoute& route);
    void unsubscribe(Client client);
    bool connected(Client client)const;
    // Removes one client's newest packet. Slow writes cannot queue other frames.
    std::optional<EncodedFrame> take(Client client);
    std::map<std::string,FrameDemand> demand()const;
    bool due(const std::string& channel)const;
    // Packed, top-to-bottom RGB8. Rejects invalid/unrequested/oversized frames.
    bool publish(const std::string& channel,int width,int height,std::vector<std::uint8_t> rgb,int channels=3);
    bool publishRGBA(const std::string& channel,int width,int height,std::vector<std::uint8_t> rgba){return publish(channel,width,height,std::move(rgba),4);}
    // Latest raw frame, for diagnostics/internal consumers; stale after 2 seconds.
    std::optional<FrameImage> latest(const std::string& channel)const;
    // Reads cache and requests a two-second readback lease; never enables output.
    // Normal prefers physical, then NDI. Room exclusively uses room PNG.
    std::optional<EncodedFrame> mappingFrame(const std::string& mappingId,bool room);
    nlohmann::json diagnostics()const;
private:
    struct Impl;std::unique_ptr<Impl> impl_;
};
}
