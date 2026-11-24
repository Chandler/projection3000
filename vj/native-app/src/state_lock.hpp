#pragma once
#include <filesystem>
#include <stdexcept>
#include <fcntl.h>
#include <sys/file.h>
#include <unistd.h>
namespace vj {
class StateLock {
    int fd_=-1;
public:
    explicit StateLock(const std::filesystem::path& directory){
        std::filesystem::create_directories(directory);
        fd_=::open((directory/"native.lock").c_str(),O_CREAT|O_RDWR,0600);
        if(fd_<0)throw std::runtime_error("Cannot lock state directory");
        if(::flock(fd_,LOCK_EX|LOCK_NB)){::close(fd_);fd_=-1;throw std::runtime_error("State directory is already in use");}
    }
    ~StateLock(){if(fd_>=0)::close(fd_);}
    StateLock(const StateLock&)=delete;
    StateLock& operator=(const StateLock&)=delete;
};
}
