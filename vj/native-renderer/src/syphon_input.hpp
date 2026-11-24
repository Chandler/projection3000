#pragma once
#include <memory>
#include <string>
#include <nlohmann/json.hpp>

// Call on the renderer's main thread with its GL context current.
// Discovery owns no capture connection. Frames stay GPU-resident.
void syphon_poll();
nlohmann::json syphon_sources();
class SyphonInput {
public:
    explicit SyphonInput(const std::string &selection);
    ~SyphonInput();
    SyphonInput(const SyphonInput &) = delete;
    SyphonInput &operator=(const SyphonInput &) = delete;
    bool update(unsigned int destination, int &width, int &height);
    bool connected() const;
    std::string error() const;
private:
    struct State;
    std::unique_ptr<State> state_;
};
