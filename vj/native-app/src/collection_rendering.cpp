#include "collection_rendering.hpp"
#include "collection_effect_catalog.hpp"
#include "../../native-renderer/src/surface_curvature_json.hpp"
#include <boost/uuid/detail/sha1.hpp>
#include <algorithm>
#include <array>
#include <bit>
#include <cmath>
#include <cstdint>
#include <deque>
#include <iomanip>
#include <limits>
#include <mutex>
#include <optional>
#include <queue>
#include <sstream>
#include <vector>

namespace vj {
namespace {
using J=nlohmann::json;using P=std::array<double,2>;using V=std::array<double,3>;using H=std::array<double,9>;
const J local={{0,0},{1,0},{1,1},{0,1}},flipped={{0,1},{1,1},{1,0},{0,0}};
constexpr std::array<int,6> triangles={0,1,2,0,2,3};
std::optional<H> homography(const J& from,const J& to){
    if(from.size()!=4||to.size()!=4)return {};
    std::array<std::array<double,9>,8> rows{};
    for(int i=0;i<4;i++){
        // Match cv2.getPerspectiveTransform's float32 point inputs.
        const double x=from[i][0].get<float>(),y=from[i][1].get<float>(),u=to[i][0].get<float>(),v=to[i][1].get<float>();
        rows[i*2]={x,y,1,0,0,0,-u*x,-u*y,u};rows[i*2+1]={0,0,0,x,y,1,-v*x,-v*y,v};
    }
    for(int col=0;col<8;col++){
        int pivot=col;for(int row=col+1;row<8;row++)if(std::abs(rows[row][col])>std::abs(rows[pivot][col]))pivot=row;
        if(std::abs(rows[pivot][col])<1e-14)return {};std::swap(rows[col],rows[pivot]);
        const auto divisor=rows[col][col];for(int j=col;j<9;j++)rows[col][j]/=divisor;
        for(int row=0;row<8;row++)if(row!=col){auto factor=rows[row][col];for(int j=col;j<9;j++)rows[row][j]-=factor*rows[col][j];}
    }
    H result{};for(int i=0;i<8;i++)result[i]=rows[i][8];result[8]=1;return result;
}
P center(const J& points){
    if(auto h=homography(local,points)){const auto& m=*h;double q=m[6]*.5+m[7]*.5+1;P result={(m[0]*.5+m[1]*.5+m[2])/q,(m[3]*.5+m[4]*.5+m[5])/q};if(std::abs(q)>1e-9&&std::isfinite(result[0])&&std::isfinite(result[1]))return result;}
    P result{};for(const auto& p:points){result[0]+=p[0].get<double>()/points.size();result[1]+=p[1].get<double>()/points.size();}return result;
}
double distance(V a,V b){double sum=0;for(int k=0;k<3;k++)sum+=(a[k]-b[k])*(a[k]-b[k]);return std::sqrt(sum);}
V vector(const J& a){V v{};for(size_t i=0;i<std::min(size_t(3),a.size());i++)v[i]=a[i];return v;}
// SHA-256's first word is the original trace instance seed. No platform crypto
// framework is required by the portable application core.
std::uint32_t instanceSeed(const std::string& text){
    constexpr std::array<std::uint32_t,64> k={0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2};
    std::array<std::uint32_t,8> hash={0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19};
    std::vector<unsigned char> bytes(text.begin(),text.end());bytes.push_back(0x80);while(bytes.size()%64!=56)bytes.push_back(0);
    const std::uint64_t bits=text.size()*8;for(int i=7;i>=0;--i)bytes.push_back(static_cast<unsigned char>(bits>>(i*8)));
    for(size_t offset=0;offset<bytes.size();offset+=64){
        std::array<std::uint32_t,64> w{};for(int i=0;i<16;i++)for(int j=0;j<4;j++)w[i]=(w[i]<<8)|bytes[offset+i*4+j];
        for(int i=16;i<64;i++){const auto a=w[i-15],b=w[i-2];w[i]=w[i-16]+(std::rotr(a,7)^std::rotr(a,18)^(a>>3))+w[i-7]+(std::rotr(b,17)^std::rotr(b,19)^(b>>10));}
        auto v=hash;for(int i=0;i<64;i++){auto t1=v[7]+(std::rotr(v[4],6)^std::rotr(v[4],11)^std::rotr(v[4],25))+((v[4]&v[5])^(~v[4]&v[6]))+k[i]+w[i];auto t2=(std::rotr(v[0],2)^std::rotr(v[0],13)^std::rotr(v[0],22))+((v[0]&v[1])^(v[0]&v[2])^(v[1]&v[2]));v={t1+t2,v[0],v[1],v[2],v[3]+t1,v[4],v[5],v[6]};}
        for(int i=0;i<8;i++)hash[i]+=v[i];
    }return hash[0]%65521;
}
J traceOptions(const J& input){
    J result={{"mode","perimeter"},{"scope","face"},{"width",.04},{"offset",0.},{"reverse",false}};
    if(input.is_object())for(auto& [key,value]:result.items())if(input.contains(key))value=input[key];return result;
}
using Edge=std::pair<int,int>;
Edge edge(int a,int b){return {std::min(a,b),std::max(a,b)};}
double cross(P a,P b,P c){return (b[0]-a[0])*(c[1]-a[1])-(b[1]-a[1])*(c[0]-a[0]);}
std::set<Edge> delaunay(const std::vector<V>& plane,double extent){
    V low=plane.front();for(const auto& p:plane)for(int axis=0;axis<3;axis++)low[axis]=std::min(low[axis],p[axis]);
    std::vector<P> points;std::vector<int> original;
    for(size_t i=0;i<plane.size();i++){
        P p={(plane[i][0]-low[0])/extent*10000+10,(plane[i][1]-low[1])/extent*10000+10};
        if(std::none_of(points.begin(),points.end(),[&](P q){return std::hypot(p[0]-q[0],p[1]-q[1])<=.01;})){points.push_back(p);original.push_back(i);}
    }
    std::set<Edge> result;const int count=points.size();
    if(count>=3){
        // Incremental Bowyer-Watson; points have the same normalization and
        // duplicate tolerance as the reference OpenCV subdivision.
        points.insert(points.end(),{{-100000,-100000},{200000,-100000},{-100000,200000}});
        std::vector<std::array<int,3>> tris={{{count,count+1,count+2}}};
        for(int inserted=0;inserted<count;inserted++){
            const auto p=points[inserted];std::map<Edge,int> boundary;std::vector<std::array<int,3>> retained;
            for(auto t:tris){
                const auto a=points[t[0]],b=points[t[1]],c=points[t[2]];
                double ax=a[0]-p[0],ay=a[1]-p[1],bx=b[0]-p[0],by=b[1]-p[1],cx=c[0]-p[0],cy=c[1]-p[1];
                double det=(ax*ax+ay*ay)*(bx*cy-by*cx)-(bx*bx+by*by)*(ax*cy-ay*cx)+(cx*cx+cy*cy)*(ax*by-ay*bx);
                if(det*cross(a,b,c)>1e-8){for(int i=0;i<3;i++)++boundary[edge(t[i],t[(i+1)%3])];}
                else retained.push_back(t);
            }
            for(auto [e,occurrences]:boundary)if(occurrences==1&&std::abs(cross(points[e.first],points[e.second],p))>1e-9)retained.push_back({e.first,e.second,inserted});
            tris=std::move(retained);
        }
        for(auto t:tris)if(t[0]<count&&t[1]<count&&t[2]<count)for(int i=0;i<3;i++)result.insert(edge(original[t[i]],original[t[(i+1)%3]]));
    }
    if(result.empty()&&count>1){std::sort(original.begin(),original.end(),[&](int a,int b){return plane[a][0]!=plane[b][0]?plane[a][0]<plane[b][0]:plane[a][1]<plane[b][1];});for(int i=1;i<count;i++)result.insert({original[i-1],original[i]});}
    return result;
}
J geometry(const J& data){
    const auto& faces=data.at("faces");if(faces.empty())throw std::invalid_argument("Collection geometry requires faces");
    std::map<std::string,J> rects;for(const auto& r:data.at("rects"))rects[r.at("id")]=r;
    const auto mesh=data.value("mesh",J());const bool hasMesh=mesh.is_object();const auto kind=data.value("kind",std::string("planar"));
    const int turns=data.value("contentRotation",0)/90;auto cardUVs=local;
    for(int turn=0;turn<turns;++turn)for(auto& uv:cardUVs){double u=uv[0],v=uv[1];uv={v,1-u};}

    std::vector<V> plane;J centers=J::array();
    for(const auto& face:faces){if(hasMesh)plane.push_back(vector(mesh.at("faces").at(face.at("meshFaceId").get<std::string>()).at("center")));else{auto p=center(face.at("planeCorners"));plane.push_back({p[0],p[1],0});}centers.push_back(center(rects.at(face.at("rectId")).at("corners")));}
    if(kind=="points"){plane.clear();centers=J::array();for(const auto& p:data.at("points")){plane.push_back(vector(p.at("position")));centers.push_back(p.at("position"));}}
    if(plane.size()!=faces.size())throw std::invalid_argument("Collection point count differs from face count");
    V low=plane.front(),high=low,mean{};for(const auto& p:plane)for(int axis=0;axis<3;axis++){low[axis]=std::min(low[axis],p[axis]);high[axis]=std::max(high[axis],p[axis]);mean[axis]+=p[axis];}
    for(auto& value:mean)value/=plane.size();
    const double extent=std::max({high[0]-low[0],high[1]-low[1],high[2]-low[2],1e-9});
    std::set<Edge> edges;
    if(!hasMesh)edges=delaunay(plane,extent);
    else{
        std::map<std::string,int> indices;for(size_t i=0;i<faces.size();i++)indices[faces[i]["meshFaceId"]]=i;
        for(const auto& [fid,index]:indices){
            std::vector<std::string> pending;for(const auto& n:mesh["faces"][fid]["neighbors"])pending.push_back(n["face"]);std::set<std::string> seen={fid};
            while(!pending.empty()){auto other=pending.back();pending.pop_back();if(!seen.insert(other).second)continue;if(indices.contains(other))edges.insert(edge(index,indices[other]));else for(const auto& n:mesh["faces"][other]["neighbors"])pending.push_back(n["face"]);}
        }
    }
    std::vector<std::vector<std::pair<int,double>>> adjacency(faces.size());J lengths=J::array(),edgeList=J::array();
    for(auto [a,b]:edges){double length=distance(plane[a],plane[b])/extent;adjacency[a].push_back({b,length});adjacency[b].push_back({a,length});edgeList.push_back({a,b});lengths.push_back(length);}
    int root=0;for(size_t i=1;i<plane.size();i++)if(distance(plane[i],mean)<distance(plane[root],mean))root=i;
    std::vector<double> distances(faces.size(),INFINITY);std::vector<int> seeds={root};for(size_t i=0;i<faces.size();i++)seeds.push_back(i);
    for(auto seed:seeds){if(std::isfinite(distances[seed]))continue;distances[seed]=0;std::priority_queue<std::pair<double,int>,std::vector<std::pair<double,int>>,std::greater<>> queue;queue.push({0,seed});while(!queue.empty()){auto [d,node]=queue.top();queue.pop();if(d>distances[node])continue;for(auto [other,length]:adjacency[node])if(d+length<distances[other]){distances[other]=d+length;queue.push({distances[other],other});}}}
    std::set<std::string> wet;
    if(hasMesh){
        std::set<std::string> remaining;for(auto it=mesh["faces"].begin();it!=mesh["faces"].end();++it)remaining.insert(it.key());
        while(!remaining.empty()){
            auto seed=*remaining.begin();for(const auto& fid:remaining)if(mesh["faces"][fid]["center"][1].get<double>()>mesh["faces"][seed]["center"][1].get<double>())seed=fid;
            std::set<std::string> component;std::vector<std::string> queue={seed};
            while(!queue.empty()){auto fid=queue.back();queue.pop_back();if(!component.insert(fid).second)continue;remaining.erase(fid);for(const auto& n:mesh["faces"][fid]["neighbors"])queue.push_back(n["face"]);}
            queue={seed};while(!queue.empty()){auto fid=queue.back();queue.pop_back();if(!wet.insert(fid).second)continue;const auto& face=mesh["faces"][fid];for(const auto& n:face["neighbors"])if(mesh["faces"][n["face"].get<std::string>()]["center"][1].get<double>()<=face["center"][1].get<double>()+1e-5)queue.push_back(n["face"]);}
        }
    }
    J boxEdges=J::array();std::set<std::pair<std::string,std::string>> seenEdges;std::map<std::string,J> boxes;
    if(data.contains("boxes")&&data["boxes"].is_array())for(const auto& box:data["boxes"])boxes[box["id"]]=box;
    if(hasMesh)for(const auto& face:faces){const auto& keys=mesh["faces"][face["meshFaceId"].get<std::string>()]["vertices"];const auto& corners=rects.at(face["rectId"])["corners"];for(int i=0;i<4;i++){std::string a=keys[i],b=keys[(i+1)%4];if(b<a)std::swap(a,b);if(seenEdges.insert({a,b}).second)boxEdges.push_back({corners[i],corners[(i+1)%4]});}}
    std::vector<double> vertices,contentVertices,cards,flow,sphere,trace;J faceFits=J::array(),faceAspects=J::array(),facePositions=J::array();bool hasContentFit=false;J media=J::array(),cardFaces=J::array(),names=J::array(),ids=J::array();
    for(size_t fi=0;fi<faces.size();fi++){
        const auto& face=faces[fi];const auto& rect=rects.at(face["rectId"]);const auto& corners=rect["corners"];names.push_back(rect.value("name",std::string{}));ids.push_back(face["id"]);std::vector<double> mediaFace;
        const auto fit=rect.value("contentFit",std::string("inherit"));
        const int fitCode=fit=="stretch"?1:fit=="contain"?2:fit=="cover"?3:0;
        double faceAspect=particleFaceChart(J::object(),rect,data.value("aspect",16./9.),data.value("metricAspect",0.)).value("aspect",1.);
        if(turns%2)faceAspect=1./faceAspect;
        facePositions.push_back(rect.value("contentPosition",J::array({.5,.5})));faceFits.push_back(fitCode);faceAspects.push_back(faceAspect);hasContentFit|=fitCode!=0;
        const auto curve=surface_curvature::from_json(rect.value("curvature",J()));
        auto append=[&](const J& uvs,bool card){
            if(curve.active()&&!hasMesh){
                std::vector<surface_curvature::Point> points,texture;
                for(const auto& p:corners)points.push_back({p[0].get<float>(),p[1].get<float>()});
                for(const auto& p:uvs)texture.push_back({p[0].get<float>(),p[1].get<float>()});
                const auto mesh=surface_curvature::build(points,texture,curve);
                if(!mesh)throw std::invalid_argument("Invalid curved collection face");
                const double seed=instanceSeed(face["id"]);
                // Each tessellation cell carries its original face index, so
                // collection colors, timing, and media assignment stay per face.
                for(size_t vertex=0;vertex<mesh->indices.size();++vertex){
                    auto i=mesh->indices[vertex];const auto& p=mesh->points[i];const auto& uvq=mesh->uvqs[i];
                    double x=p[0]*2-1,y=p[1]*2-1,u=uvq[0],v=uvq[1],q=uvq[2];
                    if(!card){vertices.insert(vertices.end(),{x,y,u,v,q});contentVertices.insert(contentVertices.end(),{x,y,u,v,q,faceAspect*q,fitCode*q,fi*q});continue;}
                    if(vertex%6==0)cardFaces.push_back(fi);
                    cards.insert(cards.end(),{x,y,u,v,q,distances[fi],0,0});
                    mediaFace.insert(mediaFace.end(),{x,y,u,q-v,q,0,0,0});
                    trace.insert(trace.end(),{x,y,u,v,q,fi*q,faces.size()*q,seed*q});
                }
                return;
            }
            const auto h=homography(corners,uvs);if(!h)return;std::array<double,4> qs{};for(int i=0;i<4;i++){qs[i]=(*h)[6]*corners[i][0].get<double>()+(*h)[7]*corners[i][1].get<double>()+1;if(std::abs(qs[i])<1e-9||!std::isfinite(qs[i])||(i>0&&(qs[i]>0)!=(qs[0]>0)))return;}
            if(card)cardFaces.push_back(fi);
            for(int i:triangles){double x=corners[i][0].get<double>()*2-1,y=corners[i][1].get<double>()*2-1,u=uvs[i][0],v=uvs[i][1],q=qs[i];
                if(!card){vertices.insert(vertices.end(),{x,y,u*q,v*q,q});contentVertices.insert(contentVertices.end(),{x,y,u*q,v*q,q,faceAspect*q,fitCode*q,fi*q});continue;}
                cards.insert(cards.end(),{x,y,u*q,v*q,q,distances[fi],0,0});mediaFace.insert(mediaFace.end(),{x,y,u*q,(1-v)*q,q,0,0,0});trace.insert(trace.end(),{x,y,u*q,v*q,q,fi*q,faces.size()*q,instanceSeed(face["id"])*q});
                if(hasMesh){const auto world=vector(face["worldCorners"][i]);flow.insert(flow.end(),{x,y,world[0]*q,world[2]*q,q,world[1]*q,face["normal"][1].get<double>()*q,wet.contains(face["meshFaceId"])?1.:0.});
                    const auto box=boxes.find(face.value("boxId",std::string{}));if(box!=boxes.end()){
                        const auto angles=vector(box->second.value("rotation",J::array({0,0,0})));constexpr double radians=3.14159265358979323846/180.;double cx=std::cos(angles[0]*radians),sx=std::sin(angles[0]*radians),cy=std::cos(angles[1]*radians),sy=std::sin(angles[1]*radians),cz=std::cos(angles[2]*radians),sz=std::sin(angles[2]*radians);
                        const std::array<V,3> transform={V{cz*cy,cz*sy*sx-sz*cx,cz*sy*cx+sz*sx},V{sz*cy,sz*sy*sx+cz*cx,sz*sy*cx-cz*sx},V{-sy,cy*sx,cy*cx}};
                        auto center=vector(box->second["center"]),size=vector(box->second["size"]);V delta{},position{};for(int axis=0;axis<3;axis++)delta[axis]=world[axis]-center[axis];for(int axis=0;axis<3;axis++)for(int j=0;j<3;j++)position[axis]+=delta[j]*transform[j][axis]/(size[axis]*.5);
                        sphere.insert(sphere.end(),{x,y,position[0]*q,position[1]*q,q,position[2]*q,0,0});
                    }
                }
            }
        };
        append(cardUVs,true);media.push_back(mediaFace);append(rect.at("uvs"),false);
    }
    J particleFaces=J::array();for(size_t i=0;i<faces.size();++i){auto chartRect=rects.at(faces[i].at("rectId"));for(int turn=0;turn<turns;++turn)std::rotate(chartRect["corners"].begin(),chartRect["corners"].begin()+1,chartRect["corners"].end());auto chart=particleFaceChart(faces[i],chartRect,data.value("aspect",16./9.),data.value("metricAspect",0.));chart["index"]=i;particleFaces.push_back(chart);}
    // Fit to the actual mapped face in projector pixels. Box world dimensions
    // can differ from manually aligned faces, so do not use their model aspect.
    for(size_t face=0;face<media.size();++face){
        const auto chart=particleFaceChart(J::object(),rects.at(faces[face].at("rectId")),data.value("aspect",16./9.),data.value("metricAspect",0.));
        const double aspect=turns%2?1./chart.value("aspect",1.):chart.value("aspect",1.);
        for(size_t vertex=0;vertex+7<media[face].size();vertex+=8)
            {media[face][vertex+5]=aspect*media[face][vertex+4].get<double>();media[face][vertex+6]=faceFits[face].get<int>()*media[face][vertex+4].get<double>();media[face][vertex+7]=face*media[face][vertex+4].get<double>();}
    }
    return {{"contentVertices",contentVertices},{"faceContentPositions",facePositions},{"faceContentFits",faceFits},{"faceAspects",faceAspects},{"hasContentFit",hasContentFit},{"particleFaces",particleFaces},{"boxEdges",boxEdges},{"sphereVertices",sphere},{"kind",kind},{"vertices",vertices},{"cardVertices",cards},{"cardFaceIndices",cardFaces},{"mediaVertices",media},{"traceVertices",trace},{"flowVertices",flow},{"centers",centers},{"edges",edgeList},{"distances",distances},{"pulseRoot",root},{"faceNames",names},{"faceIds",ids},{"edgeLengths",lengths}};
}
bool truthy(const J& value){if(value.is_null())return false;if(value.is_boolean())return value.get<bool>();if(value.is_number())return value.get<double>()!=0;return !value.empty();}
}
J particleFaceChart(const J& face,const J& rect,double aspect,double metricAspect){
 if(metricAspect<=0)metricAspect=aspect;
 const auto corners=rect.at("corners");auto h=homography(local,corners);
 J result={{"corners",corners},{"metricSource","projectedEstimate"},{"aspect",1.}};
 if(!h){result["valid"]=false;return result;}result["valid"]=true;result["uvToProjector"]=*h;
 const bool world=face.contains("worldCorners")&&face["worldCorners"].size()==4;
 const auto points=world?face["worldCorners"]:corners;
 auto length=[&](int a,int b){double sum=0;for(size_t k=0;k<points[a].size();++k){double d=points[a][k].get<double>()-points[b][k].get<double>();if(!world&&k==0)d*=metricAspect;sum+=d*d;}return std::sqrt(sum);};
 double w=(length(0,1)+length(3,2))*.5,height=(length(0,3)+length(1,2))*.5;
 result["metricAspect"]=metricAspect;result["aspect"]=std::clamp(w/std::max(height,1e-9),.02,50.);result["metricSource"]=world?"worldCorners":"projectedEstimate";
 // Derivative of the chart at its center, for directional transfers.
 auto map=[&](double u,double v){double q=(*h)[6]*u+(*h)[7]*v+(*h)[8];return P{((*h)[0]*u+(*h)[1]*v+(*h)[2])/q,((*h)[3]*u+(*h)[4]*v+(*h)[5])/q};};
 auto c=map(.5,.5),u=map(.51,.5),v=map(.5,.51);result["basis"]={{(u[0]-c[0])*100*aspect,(u[1]-c[1])*100},{(v[0]-c[0])*100*aspect,(v[1]-c[1])*100}};
 return result;
}
J collectionEffectCatalog(){
    auto effects=J::parse(collection_effect_catalog_json);
    for(auto& effect:effects)if(effect["name"]=="flash_faces")effect["parameters"].insert(effect["parameters"].begin(),J{{"name","palette_source"},{"label","Palette source"},{"kind","text"},{"default",""},{"paletteSource",true}});
    return effects;
}
std::string collectionBusName(const std::string& mid,const std::string& cid){boost::uuids::detail::sha1 sha;sha.process_bytes(cid.data(),cid.size());boost::uuids::detail::sha1::digest_type digest;sha.get_digest(digest);std::ostringstream hex;hex<<std::hex<<std::setfill('0');for(auto word:digest)hex<<std::setw(2*sizeof(word))<<static_cast<std::uint32_t>(word);return "collection"+mid+"-"+hex.str().substr(0,12);}
J collectionGeometry(const J& document){
    static std::mutex mutex;static std::map<std::string,J> cache;static std::deque<std::string> order;auto key=document.dump();
    {std::lock_guard lock(mutex);auto found=cache.find(key);if(found!=cache.end())return found->second;}
    auto result=geometry(document);
    {std::lock_guard lock(mutex);if(!cache.contains(key)){if(cache.size()>=128){cache.erase(order.front());order.pop_front();}order.push_back(key);cache[key]=result;}}return result;
}
CollectionRendering collectionRendering(const J& project,const std::string& mid,const std::set<std::string>& activeSources,const std::set<std::string>& traceSources){
    CollectionRendering result;std::map<std::string,J> byId,replacements;std::set<std::string> owned;
    for(const auto& rect:project.at("rects"))byId[rect["id"]]=rect;
    for(const auto& collection:project.value("collections",J::array())){
        const std::string source=collection["content"]["source"],kind=collection["kind"],cid=collection["id"];
        if((!activeSources.contains(source)&&kind!="points")||!collection.value("enabled",true))continue;
        J members=J::array();bool live=true;for(const auto& face:collection["faces"]){auto r=byId.at(face["rectId"]);members.push_back(r);live&=r.value("mode",std::string("live"))=="live";}if(!live)continue;
        int outputRotation=project.value("output",J::object()).value("rotation",0);double metricAspect=((outputRotation%180+180)%180)==90?9./16.:16./9.;
        const auto key=collectionBusName(mid,cid);auto context=collectionGeometry({{"metricAspect",metricAspect},{"contentRotation",collection["content"].value("rotation",0)},{"faces",collection["faces"]},{"rects",members},{"kind",kind},{"mesh",collection.value("mesh",J())},{"boxes",collection.value("boxes",J())},{"points",collection.value("points",J())}});
        context.update({{"pointShape",collection.value("shape",std::string("circle"))},{"traceSeed",instanceSeed(mid+":"+cid)},{"trace",traceOptions(collection["content"].value("trace",J()))}});result.contexts[key]={source,context};
        std::set<std::string> ids;bool rounded=false;J masks=J::array();for(const auto& rect:members){ids.insert(rect["id"]);owned.insert(rect["id"]);rounded|=rect.value("cornerRadius",0.)!=0;masks.push_back({{"corners",rect["corners"]},{"cornerRadius",rect.value("cornerRadius",0.)},{"curvature",rect.value("curvature",J())}});}
        std::string last;for(const auto& rect:project["rects"])if(ids.contains(rect["id"]))last=rect["id"];
        J replacement={{"id",key},{"name",collection["name"]},{"kind","surface"},{"source",source},{"nativeBus",key},{"mode","live"},{"blend","normal"},{"fit","stretch"},{"corners",local},{"uvs",flipped}};replacement["overlaySurfaces"]=masks;if(rounded)replacement["maskSurfaces"]=masks;replacements[last]=replacement;
    }
    for(const auto& rect:project["rects"]){const std::string rid=rect["id"];
        if(!owned.contains(rid)){
            if(traceSources.contains(rect.value("source",std::string{}))&&rect.value("mode",std::string{})=="live"&&rect["corners"].size()==4){
                const auto key=collectionBusName(mid,"rect:"+rid);J face={{"id",rid},{"rectId",rid},{"planeCorners",rect["corners"]}},mapped=rect;bool curved=rect.value("cornerRadius",0.)!=0;
                const auto curve=rect.value("curvature",J::object());if(curve.is_object())for(const auto& value:curve)curved|=truthy(value);
                if(curved){mapped["corners"]=local;face["planeCorners"]=local;}
                const auto fit=rect.value("fit",std::string("stretch"));
                if(fit=="fit"||fit=="fill"){
                    P low={INFINITY,INFINITY},high={-INFINITY,-INFINITY};for(const auto& p:rect["corners"])for(int axis=0;axis<2;axis++){low[axis]=std::min(low[axis],p[axis].get<double>());high[axis]=std::max(high[axis],p[axis].get<double>());}double ratio=(high[1]-low[1])/std::max(high[0]-low[0],1e-9);P scale=fit=="fit"?(ratio>=1?P{1,1/std::max(ratio,1e-9)}:P{ratio,1}):(ratio>=1?P{ratio,1}:P{1,1/std::max(ratio,1e-9)});for(auto& uv:mapped["uvs"])for(int axis=0;axis<2;axis++)uv[axis]=(uv[axis].get<double>()-.5)/std::max(scale[axis],1e-9)+.5;
                }
                auto context=collectionGeometry({{"faces",J::array({face})},{"rects",J::array({mapped})}});context.update({{"traceSeed",instanceSeed(mid+":"+rid)},{"trace",traceOptions(rect.value("trace",J()))},{"traceOnly",true},{"fit",fit}});result.contexts[key]={rect["source"],context};J output=rect;output.update({{"nativeBus",key},{"fit","stretch"},{"corners",curved?rect["corners"]:local},{"uvs",flipped}});result.renderRects.push_back(output);
            }else result.renderRects.push_back(rect);
        }
        if(replacements.contains(rid))result.renderRects.push_back(replacements[rid]);
    }return result;
}
}
