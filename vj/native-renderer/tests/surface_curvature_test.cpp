#include "../src/surface_curvature.hpp"
#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
using namespace surface_curvature;
int main(){
    const std::vector<Point> corners{{.2f,.3f},{.8f,.3f},{.8f,.7f},{.2f,.7f}};
    const std::vector<Point> uvs{{0,1},{1,1},{1,0},{0,0}};
    const Settings c{.2,0,-.1,0,150,0};
    const auto m=build(corners,uvs,c);assert(m);
    assert(m->points.size()==1089&&m->indices.size()==6144);
    assert(std::abs(m->points[16][1]-.22)<1e-6);
    assert(std::abs(m->points[1072][1]-.66)<1e-6);
    for(int row=0;row<=32;row++)for(int col=0;col<=32;col++){
        const auto &q=m->uvqs[row*33+col];
        assert(std::abs(q[0]/q[2]-col/32.f)<1e-6);
        assert(std::abs(q[1]/q[2]-(1-row/32.f))<1e-6);
    }
    const auto quarter=point(.25,0,Settings{.1,0,-.1,0,120,0});
    assert(std::abs(quarter[0]-(.5-.5/std::sqrt(3.)))<1e-9);
    assert(std::abs(quarter[1]+.1*(std::sqrt(3.)-1))<1e-9);
    assert(!build(corners,uvs,Settings{-.45,0,0,-.45,0,0}));
    const auto flat=build(corners,uvs,Settings{});assert(flat);
    for(int row=0;row<=32;row++)for(int col=0;col<=32;col++){
        const auto p=flat->points[row*33+col];
        assert(std::abs(p[0]-(.2+.6*col/32))<1e-6);
        assert(std::abs(p[1]-(.3+.4*row/32))<1e-6);
    }
    Settings shaped=c;shaped.top=-.65;shaped.skew[0]=.4;shaped.shape[0]=-.2;
    assert(std::abs(point(.5,0,shaped)[1]-.65)<1e-9);
    assert(point(.75,0,shaped)[1]>point(.25,0,shaped)[1]);
    const auto initial=build(corners,uvs,shaped);assert(initial);
    shaped.spacing_x=1.2;shaped.spacing_y=-.7;
    const auto biased=build(corners,uvs,shaped);assert(biased);
    assert(biased->points==initial->points);
    assert(biased->uvqs!=initial->uvqs);
    for(int row=0;row<=32;row++)for(int col=0;col<=32;col++){
        const auto &q=biased->uvqs[row*33+col];
        const auto v=source_point(q[0]/q[2],1-q[1]/q[2],shaped);
        assert(std::abs(biased->points[row*33+col][0]-(.2+.6*v[0]))<1e-6);
        assert(std::abs(biased->points[row*33+col][1]-(.3+.4*v[1]))<1e-6);
    }
    for(const double bias:{-3.,-1.,0.,1.,3.})for(int i=0;i<=100;i++){
        assert(std::abs(inverse_spacing(spacing_parameter(i/100.,bias),bias)-i/100.)<1e-9);
    }

}
