#include "led_sampler.hpp"
#include "control_model.hpp"
#include <algorithm>
#include <array>
#include <bit>
#include <cmath>
#include <set>
#include <optional>
#if __has_include("PatchCollection.h")
#define VJ_PATCH_COLLECTION 1
#include "PatchCollection.h"
#include "patch_particles.hpp"
#include "patch_clouds.hpp"
#include "patch_layers.hpp"
#include "patch_trace.hpp"
#endif
namespace vj {
namespace {
using J=SceneJson;using RGB=std::array<float,3>;
double fract(double x){return x-std::floor(x);}
std::string mediaBus(const std::string& bus,const NativeLayer& layer){return "ledmedia-"+bus+"-"+std::to_string(layer.id)+"-"+layer.source_id;}
bool media(const NativeLayer& layer){return layer.generator=="image"||layer.generator=="video";}
std::set<std::string> routes(const J& snapshot){std::set<std::string> result;for(const auto& fixture:snapshot.at("state").value("fixtures",J::array()))if(fixture.value("enabled",false)){auto out=fixture.value("route",J::object()).value("out",std::string("none"));if(out=="out1")out="program";if(out!="none")result.insert(out);}return result;}
std::vector<std::pair<std::string,double>> banks(const NativeScene& scene,const std::string& name){auto it=scene.buses.find(name);if(it==scene.buses.end()||!it->second.running)return {};const auto& x=it->second.crossfade;if(x.empty())return {{name,1}};double amount=std::clamp(x.value("value",0.),0.,1.);return {{x.value("a",name+"A"),1-amount},{x.value("b",name+"B"),amount}};}
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
}
struct LedSampler::Impl {
    NativeScene scene;std::chrono::steady_clock::time_point received=std::chrono::steady_clock::now();J status=J::object();
};
LedSampler::LedSampler():impl_(std::make_unique<Impl>()){}LedSampler::~LedSampler()=default;
void LedSampler::prepareScene(const SceneJson& snapshot,NativeScene& scene,std::map<std::string,std::array<int,2>>& sizes){
    for(const auto& out:routes(snapshot))for(const auto& [busName,amount]:banks(scene,out)){
        if(amount<=0||!scene.buses.contains(busName))continue;auto bus=scene.buses.at(busName);
        for(const auto& layer:bus.layers)if(layer.enabled&&layer.opacity>0&&media(layer)){
            const auto key=mediaBus(busName,layer);NativeBus sample;sample.clock=bus.clock;sample.running=bus.running;sample.bank=true;
            auto raw=layer;raw.opacity=raw.base_opacity=1;raw.blend="normal";sample.layers={raw};scene.buses[key]=std::move(sample);sizes[key]={64,64};
        }
    }
}
void LedSampler::configure(const NativeScene& scene){impl_->scene=scene;impl_->received=std::chrono::steady_clock::now();}
LedSampler::Frames LedSampler::render(const SceneJson& snapshot,NativeRenderGraph& graph,double flash){
    Frames frames;auto& scene=impl_->scene;const auto& state=snapshot.at("state");const auto mix=state.value("mix",J::object()),sync=mix.value("sync",J::object()),clock=state.value("clock",J::object());
#ifdef VJ_PATCH_COLLECTION
    // The snapshot is immutable for this frame. Borrow graph geometry instead
    // of cloning all mappings once for every enabled LED fixture.
    static const J emptyGraphs=J::array();
    const auto meta=snapshot.find("metaMapping");
    const auto& resolvedGraphs=meta!=snapshot.end()&&meta->contains("resolvedGraphs")?meta->at("resolvedGraphs"):emptyGraphs;
#endif
    const double elapsed=std::chrono::duration<double>(std::chrono::steady_clock::now()-impl_->received).count();
    const double ledShift=(sync.value("clock",0.)+sync.value("led",0.))/1000.,videoShift=scene.mix.video_shift_seconds;
    const double flashAt=state.value("flashAt",0.);if(flashAt>0){const double envelope=std::exp(-(controlNow()+ledShift-flashAt)*7);if(envelope>=.01)flash=std::max(flash,std::min(1.,envelope));}
    const double globalBeat=(controlNow()-clock.value("origin",controlNow())+ledShift)*clock.value("bpm",120.)/60.;
    std::map<std::string,RGB> mediaColors;J missing=J::array();std::set<std::string> needed;
    for(const auto& out:routes(snapshot))for(const auto& [busName,amount]:banks(scene,out))if(amount>0&&scene.buses.contains(busName))for(const auto& layer:scene.buses.at(busName).layers)if(layer.enabled&&layer.opacity>0&&media(layer))needed.insert(mediaBus(busName,layer));
    for(const auto& key:needed){auto raw=graph.read_bus_rgb(key,64,64);if(raw.size()!=64*64*3){missing.push_back(key);continue;}RGB average{};for(size_t i=0;i<raw.size();i++)average[i%3]+=raw[i]/float(255*64*64);mediaColors[key]=average;}
    for(const auto& fixture:state.value("fixtures",J::array())){
        const auto id=fixture.value("id",std::string{});if(id.empty())continue;const int count=std::clamp(fixture.value("count",60),2,2000);std::vector<RGB> pixels(count,RGB{});
        const auto route=fixture.value("route",J::object());auto out=route.value("out",std::string("none"));if(out=="out1")out="program";
        if(fixture.value("enabled",false))for(const auto& [busName,amount]:banks(scene,out)){
            if(amount<=0||!scene.buses.contains(busName))continue;const auto& bus=scene.buses.at(busName);std::vector<RGB> composed(count,RGB{});
            const double shiftedElapsed=bus.clock.playing?elapsed+ledShift-videoShift:0.;const double seconds=std::max(0.,bus.clock.seconds+shiftedElapsed),beat=std::max(0.,bus.clock.beat+shiftedElapsed*bus.clock.bpm/60.);
            for(const auto& layer:bus.layers){if(!layer.enabled||layer.opacity<=0||(layer.generator!="patch_trace"&&!media(layer)))continue;
                const auto key=mediaBus(busName,layer);if(media(layer)&&!mediaColors.contains(key))continue;
                const auto seed=instanceSeed(id);
#ifdef VJ_PATCH_COLLECTION
                J traceRecipe=J::object();if(layer.generator=="patch_trace")for(const auto& output:graph.patch_outputs())if(output.value("type",std::string{})=="trace"&&output.value("id",std::string{})==layer.params.value("source",std::string{})&&output.value("available",false))traceRecipe=output.value("recipe",J::object());
                patch_trace::Recipe patchTrace(traceRecipe);
#endif
                for(int i=0;i<count;i++){
                    double t=double(route.value("reverse",false)?count-1-i:i)/(count-1),x=route.value("start",0.)+(route.value("end",1.)-route.value("start",0.))*t,offset=route.value("offset",0.);if(offset!=0)x=fract(x+offset);
                    auto src=media(layer)?mediaColors.at(key):RGB{};
#ifdef VJ_PATCH_COLLECTION
                    if(layer.generator=="patch_trace")src=patchTrace.sample(x,seed,beat);
#endif
                    for(int k=0;k<3;k++){double dst=composed[i][k],value=src[k];if(layer.blend=="add")value=dst+value;else if(layer.blend=="subtract")value=dst-value;else if(layer.blend=="multiply")value=dst*value;else if(layer.blend=="screen")value=1-(1-dst)*(1-value);composed[i][k]=std::clamp(dst+(value-dst)*layer.opacity,0.,1.);}
                }
            }
            for(int i=0;i<count;i++)for(int k=0;k<3;k++)pixels[i][k]+=composed[i][k]*amount;
        }
        // Graph recipes are evaluated directly on the fixture; no video readback.
#ifdef VJ_PATCH_COLLECTION
        if(fixture.value("enabled",false))for(const auto& g:resolvedGraphs){
            if(!g.value("active",false))continue;int face=-1;for(const auto& m:g["members"])if(m["kind"]=="led"&&m["id"]==id)face=m["index"];
            if(face<0)continue;std::string out=g["out"];if(out=="out1")out="program";
            std::vector<RGB> color(count,RGB{});std::vector<double> alpha(count,0);
            for(const auto& [name,amount]:banks(scene,out)){if(amount<=0||!scene.buses.contains(name))continue;const auto& bus=scene.buses.at(name);std::vector<RGB> bankColor(count,RGB{});std::vector<double> bankAlpha(count,0);
                const double seconds=std::max(0.,bus.clock.seconds+(bus.clock.playing?elapsed+ledShift-videoShift:0.));
                for(const auto& layer:bus.layers){if(!layer.enabled||layer.opacity<=0||layer.generator!="patch_collection")continue;
                    J recipe;for(const auto& source:graph.patch_outputs())if(source.value("id",std::string{})==layer.params.value("source",std::string{})&&source.value("available",false))recipe=source.value("recipe",J::object());
                    if(recipe.is_null())continue;for(const auto& leaf:patch_layers::flatten(recipe,layer.opacity)){const auto& recipe=leaf.recipe;const double layerOpacity=leaf.opacity;auto colors=recipe.value("colors",J::array());if(colors.empty()||recipe.value("kind",std::string{})=="surfaceGate")continue;
                    const auto p=recipe.value("params",J::object());const auto travel=g.value("traversal",std::string("loop"));
                    if(recipe.value("kind",std::string{})=="graphClouds" || recipe.value("kind",std::string{})=="graphCloudParticles"){
                        // A fixture is one point in the projector cloud field: its member center.
                        const auto& members=g["members"];const int n=std::max<int>(1,members.size());std::vector<double> centers(n*2,.5);
                        for(int m=0;m<int(members.size());++m)if(members[m].contains("center")){centers[m*2]=members[m]["center"][0].get<double>()*16./9.;centers[m*2+1]=members[m]["center"][1].get<double>();}
                        const auto config=patch_clouds::config(p);std::vector<PatchCloudStreak> streaks;
                        for(int c=0;c<config.count;++c)streaks.push_back(patch_cloud_streak(config,c,centers.data(),n,int(colors.size()),seconds,patch_particles::traversal(travel)));
                        int tint=0;const double x=centers[face*2],y=centers[face*2+1];
                        double coverage=patch_cloud_coverage(streaks.data(),int(streaks.size()),x,y,seconds,p.value("softness",.7),p.value("density",.55),p.value("texture",.6),&tint);
                        const bool particleCloud=recipe.value("kind",std::string{})=="graphCloudParticles";
                        if(particleCloud){
                            std::vector<PatchCloudParticle> particles;
                            const int groups=std::clamp(int(std::round(p.value("clouds",4.))),1,8),detail=std::clamp(int(std::round(p.value("detail",16.))),8,24);
                            for(int group=0;group<groups;group++)for(int i=0;i<detail;i++)particles.push_back(patch_cloud_particle(config,group,i,detail,centers.data(),n,int(colors.size()),seconds,patch_particles::traversal(travel),p.value("wind",-8.)*3.14159265/180));
                            coverage=patch_cloud_particle_coverage(particles.data(),int(particles.size()),x,y,seconds,p.value("speed",.12),p.value("softness",.7),p.value("density",.55),p.value("texture",.6),&tint);
                        }
                        // The particle variant's haze freezes when drift is zero.
                        const double haze=patch_cloud_haze(x,y,seconds,particleCloud?p.value("speed",.12)-.06:p.value("speed",.12),p.value("wind",-8.)*3.14159265/180,p.value("haze",.3));
                        // A clear sky leaves only cloud and wisp coverage, layering over other effects.
                        const int first=config.sky&&colors.size()>1?1:0;const double cover=config.sky?1:1-(1-haze)*(1-coverage);
                        RGB rgb{};for(int k=0;k<3;k++){const char* key=k==0?"r":k==1?"g":"b";double sky=colors[0].value(key,0.),wisp=colors[first].value(key,0.),cloud=colors[tint%colors.size()].value(key,0.);
                            double v=config.sky?sky*sky+(wisp*wisp-sky*sky)*haze:wisp*wisp;rgb[k]=std::sqrt(v+(cloud*cloud-v)*(config.sky?coverage:coverage/std::max(cover,1e-4)));}
                        const double a=layerOpacity*cover*std::clamp(p.value("brightness",1.),0.,1.);
                        for(int i=0;i<count;i++){for(int k=0;k<3;k++){double c=rgb[k]*a;if(layer.blend=="add")bankColor[i][k]+=c;else if(layer.blend=="screen")bankColor[i][k]=1-(1-bankColor[i][k])*(1-c);else bankColor[i][k]=c+bankColor[i][k]*(1-a);}bankAlpha[i]=a+bankAlpha[i]*(1-a);}
                        continue;
                    }
                    PatchCollectionConfig config{int(p.value("pattern",0.)),p.value("speed",2.),p.value("onTime",.8),p.value("fade",0.),p.value("brightness",1.),uint32_t(p.value("seed",1.))};
                    const bool glow=recipe.value("kind",std::string{})=="glowFaces";
                    auto sample=glow?patch_glow_sample(face,int(colors.size()),p.value("brightness",.7)):recipe.value("kind",std::string{})=="graphPulse"?patch_graph_sample(face,int(g["members"].size()),int(colors.size()),seconds,p.value("speed",2.),p.value("trail",1.5),p.value("brightness",1.),travel=="once"?1:travel=="wander"?2:0,uint32_t(p.value("seed",1.))):patch_collection_sample(config,face,int(g["members"].size()),int(colors.size()),seconds);
                    const bool ink=recipe.value("kind",std::string{})=="graphInkFlow",particles=ink||recipe.value("kind",std::string{})=="graphParticles",replace=g.value("blend",std::string{})=="replace";
                    std::vector<PatchParticle> cloud;if(particles){int traversal=patch_particles::traversal(travel);if(ink&&traversal==2&&g.value("topology",std::string("ordered"))!="complete")traversal=0;cloud=patch_particles::cloud(patch_particles::config(p,ink),int(g["members"].size()),int(colors.size()),seconds,traversal,ink,p.value("turbulence",1.),p.value("pulse",.45),p.value("markStyle",0.)>=.5,p.value("startingFaces",100.),p.value("independentTravel",0.)>=.5);cloud.erase(std::remove_if(cloud.begin(),cloud.end(),[&](const auto& s){return s.face!=face;}),cloud.end());}
                    for(int i=0;i<count;i++){
                        RGB rgb{};double coverage=particles?0:sample.level;
                        if(glow)coverage*=patch_glow_weight(count>1?double(i)/(count-1):.5,.5,p.value("center_glow",1.),p.value("falloff",1.5));
                        if(particles){double x=double(route.value("reverse",false)?count-1-i:i)/(count-1);
                            for(auto particle:cloud){
                                if(ink&&particle.neighbor>=0&&particle.neighbor<int(g["members"].size())){const auto& a=g["members"][face]["center"];const auto& b=g["members"][particle.neighbor]["center"];double dx=b[0].get<double>()-a[0].get<double>(),dy=b[1].get<double>()-a[1].get<double>();bool towardEnd=(std::abs(dx)>=std::abs(dy)?dx:dy)>=0;if((particle.stage==2&&towardEnd)||(particle.stage!=2&&!towardEnd))particle.led=1-particle.led;}
                                double a=std::clamp(patch_particle_led(particle,x)*p.value("brightness",1.),0.,1.);const auto& c=colors[particle.color%colors.size()];
                                double distance=(x-particle.led)/std::max(.004,particle.radius*.65),rim=ink?std::exp(-std::pow((std::abs(distance)-1.15)*2.3,2))*p.value("glow",.18)*particle.level*p.value("brightness",1.):0;
                                const bool glass=ink&&p.value("markStyle",0.)>=1.5,circles=ink&&p.value("markStyle",0.)>=.5&&!glass;
                                // LEDs have no backdrop to refract: glass reads as a soft, pale frosted window.
                                if(glass){double soft=.06+.3*p.value("glassFrost",.55);a=(1-patch_collection_smooth((std::abs(distance)-(.7-soft))/(2*soft)))*particle.level*p.value("brightness",1.)*.45;rim=0;}
                                if(circles){double aa=.5/((count-1)*std::max(.004,particle.radius*.65));a=(1-patch_collection_smooth((std::abs(distance)-(.62-aa))/(2*aa)))*particle.level*p.value("brightness",1.);rim=0;}
                                double alpha=std::clamp(a+rim*.3,0.,1.);for(int k=0;k<3;k++){const char* key=k==0?"r":k==1?"g":"b";double luminance=.2126*c.value("r",0.)+.7152*c.value("g",0.)+.0722*c.value("b",0.);rgb[k]=(glass?(luminance*.65+c.value(key,0.)*.35)*a:ink?(circles?0:.002*a)+(luminance*.82+c.value(key,0.)*.18)*rim*.35:c.value(key,0.)*a)+rgb[k]*(1-alpha);}coverage=alpha+coverage*(1-alpha);
                            }
                        }else for(int k=0;k<3;k++){const char* key=k==0?"r":k==1?"g":"b";rgb[k]=(colors[sample.previous].value(key,0.)+(colors[sample.color].value(key,0.)-colors[sample.previous].value(key,0.))*sample.blend)*coverage;}
                        double a=layerOpacity*(replace?1:coverage);
                        for(int k=0;k<3;k++){double c=rgb[k]*layerOpacity;if(layer.blend=="add")bankColor[i][k]+=c;else if(layer.blend=="screen")bankColor[i][k]=1-(1-bankColor[i][k])*(1-c);else bankColor[i][k]=c+bankColor[i][k]*(1-a);}
                        bankAlpha[i]=a+bankAlpha[i]*(1-a);
                    }
                }
                }
                for(int i=0;i<count;i++){for(int k=0;k<3;k++)color[i][k]+=bankColor[i][k]*amount;alpha[i]+=bankAlpha[i]*amount;}
            }
            const double opacity=g.value("opacity",1.);const std::string blend=g.value("blend",std::string("over"));
            for(int i=0;i<count;i++)for(int k=0;k<3;k++){double src=color[i][k]*opacity,dst=pixels[i][k];pixels[i][k]=std::clamp(blend=="add"?dst+src:blend=="screen"?1-(1-dst)*(1-src):src+dst*(1-alpha[i]*opacity),0.,1.);}
        }
#endif
        // Disabled fixtures are black even when master invert/flash is active.
        if(fixture.value("enabled",false))applyLedMix(pixels,mix,globalBeat,flash,fixture.value("brightness",1.),fixture.value("kind",std::string{})=="virtual"?1.:fixture.value("power_limit",128./255.));
        auto& bytes=frames[id];bytes.reserve(count*3);for(const auto& pixel:pixels)for(float value:pixel)bytes.push_back(static_cast<std::uint8_t>(std::floor(std::clamp(value,0.f,1.f)*255+.5f)));
    }
    impl_->status={{"fixtures",frames.size()},{"missingMedia",missing},{"traceEffects",5},{"networkOutput",false},{"mediaSampling","raw-layer-mean"}};return frames;
}
SceneJson LedSampler::diagnostics()const{return impl_->status;}
}
