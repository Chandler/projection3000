#include "ndi_runtime.hpp"
#include <nlohmann/json.hpp>
#include <chrono>
#include <cstdlib>
#include <iostream>
int main(int argc, char **argv) {
    auto runtime = NdiRuntime::get();
    using Json = nlohmann::json;
    if (!runtime->api) {
        std::cout << Json({{"available",false},{"sources",Json::array()},{"error",runtime->error}}).dump() << '\n';
        return 0;
    }
    const auto *env = std::getenv("VIBE_NDI_EXTRA_IPS");
    const std::string extra = argc > 1 ? argv[1] : env ? env : "";
    NDIlib_find_create_t settings;
    settings.show_local_sources = true;
    settings.p_extra_ips = extra.empty() ? nullptr : extra.c_str();
    auto finder = runtime->api->find_create_v2(&settings);
    if (!finder) {
        std::cout << Json({{"available",false},{"sources",Json::array()},{"error","NDI discovery unavailable"}}).dump() << '\n';
        return 0;
    }
    const auto end = std::chrono::steady_clock::now()+std::chrono::milliseconds(1600);
    while (std::chrono::steady_clock::now()<end) runtime->api->find_wait_for_sources(finder,100);
    uint32_t count=0;
    const auto *sources=runtime->api->find_get_current_sources(finder,&count);
    Json list=Json::array();
    for(uint32_t i=0;i<count;++i) {
        const std::string name=sources[i].p_ndi_name?sources[i].p_ndi_name:"";
        const std::string url=sources[i].p_url_address?sources[i].p_url_address:"";
        list.push_back({{"name",name},{"label",name},{"url",url},
            {"selection",Json({{"name",name},{"url",url},{"extra_ips",extra}}).dump()}});
    }
    runtime->api->find_destroy(finder);
    std::cout<<Json({{"available",true},{"sources",list},{"version",runtime->version}}).dump()<<'\n';
}
