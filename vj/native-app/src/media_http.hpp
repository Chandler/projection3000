#pragma once
#include "media_library.hpp"
#include <boost/asio/thread_pool.hpp>
#include <boost/beast.hpp>
#include <functional>
#include <memory>
namespace vj {
constexpr std::uint64_t mediaUploadLimit=4ull*1024*1024*1024;
constexpr std::uint64_t mediaUploadBodyLimit=mediaUploadLimit+1024*1024;
// Incremental multipart parser/file publisher. Feed bounded decoded HTTP chunks
// on a disk worker; destructor removes incomplete hidden .part files.
class MediaUploadWriter {
public:
    MediaUploadWriter(std::filesystem::path nativeMediaRoot,std::string contentType);
    ~MediaUploadWriter();
    void append(const char* bytes,std::size_t size);
    nlohmann::json finish();
private:
    struct Impl;std::unique_ptr<Impl> impl_;
};
struct MediaHttpAsset {
    std::filesystem::path path;
    std::string contentType,cacheControl="private, max-age=300";
};
// path/query are already URL-decoded by the control server. Resolves only
// supported library/native/removable media, including cached video posters.
std::optional<MediaHttpAsset> resolveMediaHttpAsset(const MediaLibrary& library,
    const std::string& path,const nlohmann::json& query);
// Each handoff owns its connection and response. Call after header read, before
// body consumption. Caller reserves one bounded worker slot until finished().
void serveMediaUpload(boost::beast::tcp_stream&& stream,
    boost::beast::flat_buffer&& buffered,
    boost::beast::http::request_parser<boost::beast::http::string_body>&& headers,
    const std::filesystem::path& nativeMediaRoot,boost::asio::thread_pool& workers,
    std::function<void()> finished);
// Range/conditional GET/HEAD, bounded pread worker chunks; no full file string.
void serveMediaAsset(boost::beast::tcp_stream&& stream,
    boost::beast::http::request<boost::beast::http::string_body>&& request,
    MediaHttpAsset asset,boost::asio::thread_pool& workers,std::function<void()> finished);
}
