#include "../src/rounded_surface.hpp"
#include <cassert>
#include <iostream>
double area(const std::vector<surface_curvature::Point>& p){
    double a=0;for(size_t i=0;i<p.size();i++){const auto& b=p[(i+1)%p.size()];a+=double(p[i][0])*b[1]-double(p[i][1])*b[0];}return std::abs(a)/2;
}
int main(){
    using namespace rounded_surface;
    const std::vector<Point> square{{0,0},{1,0},{1,1},{0,1}};
    const auto p=outline(square,{},.1,2),t=triangles(p);
    const double expected=1-(4-3.141592653589793)*.1*.05;
    assert(std::abs(area(p)-expected)<.00005);
    double covered=0;for(size_t i=0;i<t.size();i+=3)covered+=area({t[i],t[i+1],t[i+2]});
    assert(std::abs(covered-area(p))<.00001);
    assert(outline(square,{},0,2)==square);
    for(double radius:{.001,.05,.5}){
        surface_curvature::Settings curve;curve.top=.2;
        auto warped=outline({{.1,.2},{.8,.1},{.9,.8},{.2,.9}},curve,radius,16.0/9);
        auto mesh=triangles(warped);double sum=0;
        for(size_t i=0;i<mesh.size();i+=3)sum+=area({mesh[i],mesh[i+1],mesh[i+2]});
        assert(std::abs(sum-area(warped))<.00002);
    }
    std::cout<<"Rounded masks preserve aspect, perspective and curved geometry.\n";
}
