#include "ndi_output.hpp"
#include "ndi_runtime.hpp"
#include <chrono>
#include <fstream>
#include <iostream>
#include <thread>
#include <unistd.h>
// Explicit, bounded local sender for the Composer's receive/thumbnail check.
int main(int argc,char** argv){
 if(argc!=2){std::cerr<<"Usage: vj-composer-source SELECTION.json\n";return 2;}
 auto runtime=NdiRuntime::get();if(!runtime->api){std::cerr<<runtime->error<<'\n';return 1;}
 const auto name="VJ Composer Check "+std::to_string(getpid());NdiOutput sender(name,192,108,30);
 NDIlib_find_create_t options;options.show_local_sources=true;options.p_extra_ips="127.0.0.1";auto finder=runtime->api->find_create_v2(&options);if(!finder)return 1;
 std::vector<uint8_t> pixels(192*108*3);for(size_t i=0;i<pixels.size();i+=3){pixels[i]=210;pixels[i+1]=50;pixels[i+2]=110;}
 bool found=false;const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(90);
 while(std::chrono::steady_clock::now()<deadline){sender.publish(pixels);if(!found){runtime->api->find_wait_for_sources(finder,30);uint32_t count=0;auto sources=runtime->api->find_get_current_sources(finder,&count);for(uint32_t i=0;i<count;++i)if(sources[i].p_ndi_name&&std::string(sources[i].p_ndi_name).find(name)!=std::string::npos){nlohmann::json selection={{"name",sources[i].p_ndi_name},{"url",sources[i].p_url_address?sources[i].p_url_address:""},{"extra_ips","127.0.0.1"}};std::ofstream file(argv[1]);file<<selection;file.close();std::cout<<selection<<std::endl;found=true;break;}}std::this_thread::sleep_for(std::chrono::milliseconds(30));}
 runtime->api->find_destroy(finder);return found?0:1;
}
