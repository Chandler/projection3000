#pragma once
#include "model.hpp"

namespace vj {
struct LibraryOutputRequest {
    bool duplicate;
    std::string templateID,outputID,inputSource;
};
using StageLibraryOutput=std::function<Reply(const LibraryOutputRequest&)>;
using FinishLibraryOutput=std::function<Reply(const std::string& instance,bool commit)>;
Reply placeLibrarySubpatch(Model& model,const Json& command,const StageLibraryOutput& stage,const FinishLibraryOutput& finish);
}
