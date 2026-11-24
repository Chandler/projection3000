#include "room_render_pass.hpp"
#include "projector_raster.hpp"
#include <array>
#include <cmath>
#include <limits>
#include <stdexcept>
namespace vj {
namespace {
using Json=nlohmann::json;
using Vec=std::array<double,3>;
using Matrix=std::array<float,16>;
constexpr double pi=3.14159265358979323846;
Vec vec(const Json& value){if(!value.is_array()||value.size()!=3)throw std::invalid_argument("Room camera needs XYZ coordinates");Vec p{};for(int i=0;i<3;i++){p[i]=value[i].get<double>();if(!std::isfinite(p[i]))throw std::invalid_argument("Room camera needs finite coordinates");}return p;}
Vec add(Vec a,Vec b){for(int i=0;i<3;i++)a[i]+=b[i];return a;}
Vec sub(Vec a,Vec b){for(int i=0;i<3;i++)a[i]-=b[i];return a;}
Vec mul(Vec a,double b){for(auto& n:a)n*=b;return a;}
double dot(Vec a,Vec b){return a[0]*b[0]+a[1]*b[1]+a[2]*b[2];}
Vec cross(Vec a,Vec b){return {a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]};}
Vec unit(Vec p){double n=std::sqrt(dot(p,p));if(n<1e-10)throw std::invalid_argument("Degenerate room camera");return mul(p,1/n);}
Matrix multiply(const Matrix& a,const Matrix& b){Matrix out{};for(int col=0;col<4;col++)for(int row=0;row<4;row++)for(int i=0;i<4;i++)out[col*4+row]+=a[i*4+row]*b[col*4+i];return out;}
Matrix view(Vec eye,Vec right,Vec up,Vec direction){return {float(right[0]),float(up[0]),float(-direction[0]),0,float(right[1]),float(up[1]),float(-direction[1]),0,float(right[2]),float(up[2]),float(-direction[2]),0,float(-dot(right,eye)),float(-dot(up,eye)),float(dot(direction,eye)),1};}
Matrix perspective(double verticalDegrees,double aspect,double near,double far,double sx=0,double sy=0){if(!(verticalDegrees>0&&verticalDegrees<179&&aspect>0&&near>0&&far>near))throw std::invalid_argument("Invalid room camera lens");double f=1/std::tan(verticalDegrees*pi/360);return {float(f/aspect),0,0,0,0,float(f),0,0,float(-2*sx),float(2*sy),float(-(far+near)/(far-near)),-1,0,0,float(-2*far*near/(far-near)),0};}
Matrix projectorMatrix(const Json& p){auto shift=p.value("shift",Json::array({0,0}));double aspect=p.at("aspect"),ratio=p.at("throwRatio"),fov=2*std::atan(1/(2*ratio*aspect))*180/pi;return multiply(perspective(fov,aspect,p.value("near",.05),p.value("far",200.),shift[0],shift[1]),view(vec(p.at("position")),vec(p.at("right")),vec(p.at("up")),vec(p.at("direction"))));}
GLuint program(const char* vertex,const char* fragment){GLuint v=projector_raster::compile_shader(GL_VERTEX_SHADER,vertex),f=0,p=0;try{f=projector_raster::compile_shader(GL_FRAGMENT_SHADER,fragment);p=glCreateProgram();glAttachShader(p,v);glAttachShader(p,f);glLinkProgram(p);GLint okay=0;glGetProgramiv(p,GL_LINK_STATUS,&okay);if(!okay){GLint length=0;glGetProgramiv(p,GL_INFO_LOG_LENGTH,&length);std::string log(std::max(1,length),'\0');glGetProgramInfoLog(p,length,nullptr,log.data());throw std::runtime_error("Room shader link failed: "+log);}glDeleteShader(v);glDeleteShader(f);return p;}catch(...){glDeleteShader(v);if(f)glDeleteShader(f);if(p)glDeleteProgram(p);throw;}}
constexpr const char* vertex=R"GLSL(#version 330 core
layout(location=0) in vec3 position;
layout(location=1) in vec3 normal;
uniform mat4 camera;
out vec3 worldPosition;
out vec3 worldNormal;
void main(){worldPosition=position;worldNormal=normal;gl_Position=camera*vec4(position,1.0);}
)GLSL";
constexpr const char* fragment=R"GLSL(#version 330 core
in vec3 worldPosition;
in vec3 worldNormal;
uniform sampler2D feed0;uniform sampler2D feed1;uniform sampler2D feed2;uniform sampler2D feed3;
uniform sampler2D shadow0;uniform sampler2D shadow1;uniform sampler2D shadow2;uniform sampler2D shadow3;
uniform mat4 projector0;uniform mat4 projector1;uniform mat4 projector2;uniform mat4 projector3;
uniform vec3 origin0;uniform vec3 origin1;uniform vec3 origin2;uniform vec3 origin3;
uniform float live0;uniform float live1;uniform float live2;uniform float live3;
out vec4 color;
vec3 linearRGB(vec3 c){return mix(c/12.92,pow((c+.055)/1.055,vec3(2.4)),step(vec3(.04045),c));}
vec3 outputRGB(vec3 c){c=max(c,vec3(0));return mix(c*12.92,1.055*pow(c,vec3(1.0/2.4))-.055,step(vec3(.0031308),c));}
vec3 light(sampler2D feed,sampler2D shadow,mat4 matrix,vec3 origin,float live){
 if(live<.5)return vec3(0);
 vec4 clip=matrix*vec4(worldPosition,1);if(clip.w<=0.)return vec3(0);
 vec3 p=clip.xyz/clip.w*.5+.5;
 if(any(lessThan(p,vec3(0)))||any(greaterThan(p,vec3(1))))return vec3(0);
 if(dot(normalize(worldNormal),normalize(origin-worldPosition))<=.001)return vec3(0);
 if(p.z>texture(shadow,p.xy).r+.00035)return vec3(0);
 return linearRGB(texture(feed,p.xy).rgb);
}
void main(){vec3 value=vec3(.075,.08,.085)*(.45+.55*max(0.,dot(normalize(worldNormal),normalize(vec3(.3,.8,.6)))));
 value+=light(feed0,shadow0,projector0,origin0,live0);
 value+=light(feed1,shadow1,projector1,origin1,live1);
 value+=light(feed2,shadow2,projector2,origin2,live2);
 value+=light(feed3,shadow3,projector3,origin3,live3);
 color=vec4(outputRGB(value),1);
}
)GLSL";
constexpr const char* depthFragment="#version 330 core\nvoid main(){}";
struct Range {GLint first=0;GLsizei count=0;bool wall=false;Vec center{},outward{};};
struct Mesh {std::vector<float> vertices;std::vector<Range> ranges;};
void quad(Mesh& mesh,const std::array<Vec,4>& p,bool wall=false,Vec outward={}){Vec normal=unit(cross(sub(p[1],p[0]),sub(p[2],p[1])));Range range;range.first=GLint(mesh.vertices.size()/6);range.count=6;range.wall=wall;range.outward=outward;for(auto v:p)range.center=add(range.center,mul(v,.25));for(int i:{0,1,2,0,2,3}){for(double n:p[i])mesh.vertices.push_back(float(n));for(double n:normal)mesh.vertices.push_back(float(n));}mesh.ranges.push_back(range);}
Mesh meshFor(const Json& descriptor){Mesh mesh;const auto& dimensions=descriptor.at("scene").at("room");double w=dimensions[0].get<double>()/2,h=dimensions[1],d=dimensions[2].get<double>()/2;
    quad(mesh,{{{-w,0,-d},{-w,0,d},{w,0,d},{w,0,-d}}},true,{0,-1,0});
    quad(mesh,{{{-w,h,d},{-w,h,-d},{w,h,-d},{w,h,d}}},true,{0,1,0});
    quad(mesh,{{{-w,0,-d},{w,0,-d},{w,h,-d},{-w,h,-d}}},true,{0,0,-1});
    quad(mesh,{{{w,0,d},{-w,0,d},{-w,h,d},{w,h,d}}},true,{0,0,1});
    quad(mesh,{{{-w,0,d},{-w,0,-d},{-w,h,-d},{-w,h,d}}},true,{-1,0,0});
    quad(mesh,{{{w,0,-d},{w,0,d},{w,h,d},{w,h,-d}}},true,{1,0,0});
    for(const auto& box:descriptor.at("boxes"))for(const auto& face:box.at("faces")){std::array<Vec,4> points;for(int i=0;i<4;i++)points[i]=vec(box.at("vertices").at(face.at("vertices").at(i).get<size_t>()));quad(mesh,points);}
    return mesh;
}
}
Json roomCameraProjection(const Json& room,const Json& camera,int width,int height){if(width<1||height<1)throw std::invalid_argument("Invalid room preview dimensions");Matrix matrix;Vec eye;std::array<int,4> viewport={0,0,width,height};if(camera.contains("projectorId")){bool found=false;for(const auto& p:room.at("projectors"))if(p.at("id")==camera.at("projectorId")){eye=vec(p.at("position"));matrix=projectorMatrix(p);double aspect=p.at("aspect");if(double(width)/height>aspect){viewport[2]=std::max(1,int(std::round(height*aspect)));viewport[0]=(width-viewport[2])/2;}else {viewport[3]=std::max(1,int(std::round(width/aspect)));viewport[1]=(height-viewport[3])/2;}found=true;break;}if(!found)throw std::invalid_argument("Unknown room camera projector");}else {eye=vec(camera.value("eye",Json::array({7,5,8})));auto target=vec(camera.value("target",Json::array({0,1,-.5}))),up=vec(camera.value("up",Json::array({0,1,0}))),direction=unit(sub(target,eye)),right=unit(cross(direction,up));up=cross(right,direction);matrix=multiply(perspective(camera.value("verticalFovDegrees",48.),double(width)/height,camera.value("near",.035),camera.value("far",150.)),view(eye,right,up,direction));}return {{"viewProjection",matrix},{"eye",eye},{"viewport",viewport}};}
struct RoomRenderPass::Impl {
    GLuint shaded=0,depth=0,vao=0,vbo=0,black=0;
    std::array<GLuint,4> shadowTextures{},shadowFbos{};
    Json geometryKey;
    Mesh mesh;
    bool shadowsDirty=true;
    Impl(){try{shaded=program(vertex,fragment);depth=program(vertex,depthFragment);glGenVertexArrays(1,&vao);glGenBuffers(1,&vbo);glBindVertexArray(vao);glBindBuffer(GL_ARRAY_BUFFER,vbo);glEnableVertexAttribArray(0);glVertexAttribPointer(0,3,GL_FLOAT,GL_FALSE,6*sizeof(float),nullptr);glEnableVertexAttribArray(1);glVertexAttribPointer(1,3,GL_FLOAT,GL_FALSE,6*sizeof(float),reinterpret_cast<void*>(3*sizeof(float)));glBindVertexArray(0);glGenTextures(1,&black);glBindTexture(GL_TEXTURE_2D,black);const unsigned char pixel[4]={0,0,0,255};glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,1,1,0,GL_RGBA,GL_UNSIGNED_BYTE,pixel);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_NEAREST);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_NEAREST);}catch(...){release();throw;}}
    void release(){for(auto f:shadowFbos)if(f)glDeleteFramebuffers(1,&f);for(auto t:shadowTextures)if(t)glDeleteTextures(1,&t);if(black)glDeleteTextures(1,&black);if(vbo)glDeleteBuffers(1,&vbo);if(vao)glDeleteVertexArrays(1,&vao);if(depth)glDeleteProgram(depth);if(shaded)glDeleteProgram(shaded);}
    ~Impl(){release();}
    void shadow(int index){if(shadowFbos[index])return;glGenTextures(1,&shadowTextures[index]);glBindTexture(GL_TEXTURE_2D,shadowTextures[index]);glTexImage2D(GL_TEXTURE_2D,0,GL_DEPTH_COMPONENT24,1024,1024,0,GL_DEPTH_COMPONENT,GL_UNSIGNED_INT,nullptr);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_NEAREST);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_NEAREST);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_COMPARE_MODE,GL_NONE);glGenFramebuffers(1,&shadowFbos[index]);glBindFramebuffer(GL_FRAMEBUFFER,shadowFbos[index]);glFramebufferTexture2D(GL_FRAMEBUFFER,GL_DEPTH_ATTACHMENT,GL_TEXTURE_2D,shadowTextures[index],0);glDrawBuffer(GL_NONE);glReadBuffer(GL_NONE);if(glCheckFramebufferStatus(GL_FRAMEBUFFER)!=GL_FRAMEBUFFER_COMPLETE)throw std::runtime_error("Room shadow framebuffer incomplete");}
    void render(const Json& room,const Json& camera,int width,int height,const ProjectorTextureLookup& lookup){
        auto projection=roomCameraProjection(room,camera,width,height);auto matrix=projection["viewProjection"].get<Matrix>();auto viewport=projection["viewport"].get<std::array<int,4>>();auto eye=vec(projection["eye"]);
        Json key={{"scene",room.at("scene")},{"boxes",room.at("boxes")},{"projectors",room.at("projectors")}};
        if(key!=geometryKey){auto next=meshFor(room);glBindBuffer(GL_ARRAY_BUFFER,vbo);glBufferData(GL_ARRAY_BUFFER,next.vertices.size()*sizeof(float),next.vertices.data(),GL_DYNAMIC_DRAW);mesh=std::move(next);geometryKey=std::move(key);shadowsDirty=true;}
        GLint target=0,read=0;glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING,&target);glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING,&read);
        struct Restore {GLint draw,read;~Restore(){glBindFramebuffer(GL_DRAW_FRAMEBUFFER,draw);glBindFramebuffer(GL_READ_FRAMEBUFFER,read);glColorMask(GL_TRUE,GL_TRUE,GL_TRUE,GL_TRUE);glDepthMask(GL_TRUE);glDisable(GL_DEPTH_TEST);glBindVertexArray(0);glUseProgram(0);glActiveTexture(GL_TEXTURE0);}} restore{target,read};
        std::array<Matrix,4> projectorMatrices{};std::array<Vec,4> origins{};std::array<NativeBusTexture,4> textures{};std::array<bool,4> enabled{};
        // Shared mappingTexture may render a feed and mutate all GL state. Resolve
        // every source before binding any room geometry/shadow rendering state.
        for(const auto& p:room.at("projectors")){int index=std::stoi(p.at("id").get<std::string>())-1;if(index<0||index>=4)throw std::invalid_argument("Invalid room projector");projectorMatrices[index]=projectorMatrix(p);origins[index]=vec(p.at("position"));enabled[index]=p.value("enabled",false);if(enabled[index]&&lookup)textures[index]=lookup(p.value("mappingId",p.at("id").get<std::string>()));}
        glDisable(GL_SCISSOR_TEST);glDisable(GL_STENCIL_TEST);glDisable(GL_BLEND);glDisable(GL_CULL_FACE);glDisable(GL_FRAMEBUFFER_SRGB);glEnable(GL_DEPTH_TEST);glDepthFunc(GL_LEQUAL);glDepthMask(GL_TRUE);glClearDepth(1);glBindVertexArray(vao);glActiveTexture(GL_TEXTURE0);
        for(int index=0;index<4;index++){if(!enabled[index])continue;shadow(index);if(shadowsDirty){glBindFramebuffer(GL_FRAMEBUFFER,shadowFbos[index]);glViewport(0,0,1024,1024);glColorMask(GL_FALSE,GL_FALSE,GL_FALSE,GL_FALSE);glClear(GL_DEPTH_BUFFER_BIT);glUseProgram(depth);glUniformMatrix4fv(glGetUniformLocation(depth,"camera"),1,GL_FALSE,projectorMatrices[index].data());glDrawArrays(GL_TRIANGLES,0,GLsizei(mesh.vertices.size()/6));}}
        shadowsDirty=false;glBindFramebuffer(GL_DRAW_FRAMEBUFFER,target);glBindFramebuffer(GL_READ_FRAMEBUFFER,read);glViewport(0,0,width,height);glColorMask(GL_TRUE,GL_TRUE,GL_TRUE,GL_TRUE);glClearColor(23.f/255,25.f/255,27.f/255,1);glClear(GL_COLOR_BUFFER_BIT|GL_DEPTH_BUFFER_BIT);glViewport(viewport[0],viewport[1],viewport[2],viewport[3]);glUseProgram(shaded);glUniformMatrix4fv(glGetUniformLocation(shaded,"camera"),1,GL_FALSE,matrix.data());
        for(int i=0;i<4;i++){auto suffix=std::to_string(i);glActiveTexture(GL_TEXTURE0+i);glBindTexture(GL_TEXTURE_2D,textures[i].texture?textures[i].texture:black);glUniform1i(glGetUniformLocation(shaded,("feed"+suffix).c_str()),i);glActiveTexture(GL_TEXTURE4+i);glBindTexture(GL_TEXTURE_2D,shadowTextures[i]?shadowTextures[i]:black);glUniform1i(glGetUniformLocation(shaded,("shadow"+suffix).c_str()),4+i);glUniformMatrix4fv(glGetUniformLocation(shaded,("projector"+suffix).c_str()),1,GL_FALSE,projectorMatrices[i].data());glUniform3f(glGetUniformLocation(shaded,("origin"+suffix).c_str()),origins[i][0],origins[i][1],origins[i][2]);glUniform1f(glGetUniformLocation(shaded,("live"+suffix).c_str()),enabled[i]&&textures[i].texture?1.f:0.f);}
        for(const auto& range:mesh.ranges){if(range.wall&&dot(range.outward,sub(eye,range.center))>.02)continue;glDrawArrays(GL_TRIANGLES,range.first,range.count);}
    }
};
RoomRenderPass::RoomRenderPass():impl_(std::make_unique<Impl>()){}
RoomRenderPass::~RoomRenderPass()=default;
void RoomRenderPass::render(const Json& room,const Json& camera,int width,int height,const ProjectorTextureLookup& lookup){impl_->render(room,camera,width,height,lookup);}
}
