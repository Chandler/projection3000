#pragma once
#include <stdexcept>
namespace vj {
struct ApiError : std::runtime_error {
    int status;
    ApiError(int code,const std::string& message):std::runtime_error(message),status(code){}
};
}
