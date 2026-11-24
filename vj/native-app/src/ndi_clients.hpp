#pragma once
#include <nlohmann/json.hpp>
#include <filesystem>
#include <functional>
#include <memory>
#include <optional>
#include <atomic>
#include <string>
namespace vj {
class NdiClients {
public:
    using Json=nlohmann::json;
    // Callbacks must obey timeout/cancellation. HTTP returns a validated JSON
    // object or throws. No redirects, environment proxies or shell commands.
    using Http=std::function<Json(const std::string& endpoint,const std::string& method,const std::string& path,const Json& body,int timeoutSeconds,const std::atomic<bool>& cancel)>;
    using Discovery=std::function<Json(int timeoutSeconds,const std::atomic<bool>& cancel)>;
    // enable=true is called only for an explicit assignment. Return null while
    // feed is unready, empty string when disabled, otherwise serialized NDI name
    // selector {name,url:"",extra_ips:""}; never persist a transient NDI port.
    using Source=std::function<std::optional<std::string>(const std::string& projector,bool enable)>;
    explicit NdiClients(std::filesystem::path cacheFile,Http http={},Discovery discovery={});
    ~NdiClients();
    void setSourceProvider(Source source);
    void start();
    void stop();
    Json snapshot() const;
    std::optional<Json> request(const std::string& method,const std::string& path,const Json& body=Json::object());
    // Focused fake-transport checks and externally discovered services may seed
    // endpoints without running multicast discovery. Does not send any request.
    void discovered(const Json& endpoints);
    void poll();
    static Json httpRequest(const std::string&,const std::string&,const std::string&,const Json&,int,const std::atomic<bool>&);
    static Json discover(int timeoutSeconds,const std::atomic<bool>& cancel);
private:
    struct Impl;std::unique_ptr<Impl> impl_;
};
class NetworkDiagnostics {
public:
    using Json=nlohmann::json;
    explicit NetworkDiagnostics(std::filesystem::path stateRoot,NdiClients::Http http={});
    ~NetworkDiagnostics();
    // Config accepts host/port/error; fixtures retain the original wled list.
    // probe=false is local-only and never initiates a network request.
    Json network(const Json& wled,const Json& fixtures,int serverPort,bool probe=true);
    // Explicit, read-only discovery. Does not configure or start LED output.
    Json discoverWled(const Json& configured);
    Json stats(int activeOutputs,const Json& rendererMetrics=Json::object());
private:
    struct Impl;std::unique_ptr<Impl> impl_;
};
}
