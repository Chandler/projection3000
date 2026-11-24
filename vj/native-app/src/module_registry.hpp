#pragma once
#include <filesystem>
#include <functional>
#include <mutex>
#include <nlohmann/json.hpp>
#include <optional>
#include <string>
#include <vector>
namespace vj {
using VectorModuleValidator=std::function<void(const std::vector<uint8_t>&,const nlohmann::json&)>;
void installVectorModuleValidator(VectorModuleValidator validator);
void installWasmtimeModuleValidator(); // Optional Wasmtime implementation in vector_host.cpp.
bool vectorModuleValidatorAvailable();
struct RegistryReply {int status=200;nlohmann::json body;std::string changedEffect;};
class ModuleRegistry {
public:
    using Json=nlohmann::json;
    explicit ModuleRegistry(std::filesystem::path root);
    void reloadFromDisk(); // Caller serializes store mutations during import.
    Json catalog() const;
    Json history() const;
    Json diagnostics() const;
    Json normalize(const std::string& effect,const Json& params) const;
    Json recipe(const std::string& effect,const Json& params,int width,int height) const;
    std::filesystem::path modulePath(const std::string& id,const std::string& version="") const;
    std::optional<RegistryReply> request(const std::string& method,const std::string& path,const Json& body);
    RegistryReply importLocal(const std::filesystem::path& file,const Json& manifest,const std::string& id="",std::optional<uint64_t> revision=std::nullopt);
    static Json checkedManifest(const Json& raw);
    static Json normalizeParameters(const Json& manifest,const Json& values);
private:
    std::filesystem::path root_;
    mutable std::mutex mutex_;
    Json entries_=Json::object(),warnings_=Json::array();
    RegistryReply upload(std::vector<uint8_t> bytes,const Json& manifest,const std::string& id,std::optional<uint64_t> revision);
    std::filesystem::path modulePathUnlocked(const Json& entry,const std::string& version="") const;
};
}
