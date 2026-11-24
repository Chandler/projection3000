#include "../src/selection_marker.hpp"
#include <cassert>
#include <iostream>
int main(){
    using namespace selection_marker;
    std::vector<surface_curvature::Point> corners{{.1f,.2f},{.3f,.2f},{.3f,.6f},{.1f,.6f}};
    for(int rotation:{0,90,180,270}){
        auto p=square(corners,{},1920,1080,rotation);assert(p.size()==4);
        const int w=rotation%180?1080:1920,h=rotation%180?1920:1080;
        assert(std::abs((p[1][0]-p[0][0])*w-8)<.001);
        assert(std::abs((p[2][1]-p[1][1])*h-8)<.001);
        assert(std::abs((p[0][0]+p[2][0])/2-.2)<.00001);
        assert(std::abs((p[0][1]+p[2][1])/2-.4)<.00001);
    }
    assert(square({}, {},1920,1080,0).empty());
    assert(square({{0,0},{.0001f,0},{.0001f,.0001f},{0,.0001f}}, {},1920,1080,0).empty());
    auto small=square({{0,0},{.01f,0},{.01f,.01f},{0,.01f}}, {},1920,1080,0);
    assert(small.size()==4&&(small[1][0]-small[0][0])*1920<8);
    std::cout<<"Selection squares stay centered, subtle, square under rotation, and proportional on small cards.\n";
}
