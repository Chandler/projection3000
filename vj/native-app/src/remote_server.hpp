#pragma once
#include "model.hpp"
#include <memory>
namespace vj {
// LAN mapping remote for phones. Serves one page, the live mapping frame and a
// WebSocket canvas driven by the Mapper gesture engine; every request needs the key.
class RemoteServer {
public:
    RemoteServer(Model& model,unsigned short port,std::string key,const std::string& address="0.0.0.0");
    ~RemoteServer();
    unsigned short port() const;
private:
    struct Impl;std::unique_ptr<Impl> impl_;
};
}
