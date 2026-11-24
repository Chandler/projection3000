#pragma once
#include "model.hpp"
#include <memory>
namespace vj {
class ApiServer {
public:
    ApiServer(Model& model,unsigned short port,const std::string& address="127.0.0.1");
    // Stops network handling and joins all background requests. The supplied
    // Model must remain alive through destruction; no detached work survives it.
    ~ApiServer();
    unsigned short port() const;
private:
    struct Impl;std::unique_ptr<Impl> impl_;
};
}
