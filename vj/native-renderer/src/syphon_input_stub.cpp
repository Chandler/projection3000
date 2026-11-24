#include "syphon_input.hpp"
struct SyphonInput::State {};
void syphon_poll() {}
nlohmann::json syphon_sources() { return nlohmann::json::array(); }
SyphonInput::SyphonInput(const std::string &) : state_(std::make_unique<State>()) {}
SyphonInput::~SyphonInput() = default;
bool SyphonInput::update(unsigned int, int &, int &) { return false; }
bool SyphonInput::connected() const { return false; }
std::string SyphonInput::error() const { return "Syphon requires macOS"; }
