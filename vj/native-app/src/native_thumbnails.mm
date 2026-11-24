#if __has_include("PatchTrace.h")
#include "patch_trace.hpp"
#endif
#import "native_thumbnails.hpp"
#include "native_render_graph.hpp"
#include "ndi_output.hpp"
#include "ndi_runtime.hpp"
#include "syphon_input.hpp"
#import <Syphon/SyphonOpenGLServer.h>
#import <Syphon/SyphonServerDirectory.h>
#include "vector_host.hpp"
#include "led_sampler.hpp"
#include "media_thumbnail.hpp"
#include "collection_rendering.hpp"
#include "mapping_collections.hpp"
#include <set>
#include <boost/uuid/detail/sha1.hpp>
#include <atomic>
#include <cmath>
#include <cstring>
#include <iomanip>
#include <fstream>
#include <thread>
#include <sstream>

namespace {
using J=vj::Json;namespace fs=std::filesystem;
constexpr int width=192,height=108;
constexpr std::array<std::array<double,2>,3> phases={{{1.4,1.05},{2.2,1.4},{3.,1.75}}};
std::string hash(const std::string& value){boost::uuids::detail::sha1 sha;sha.process_bytes(value.data(),value.size());boost::uuids::detail::sha1::digest_type words;sha.get_digest(words);std::ostringstream out;out<<std::hex<<std::setfill('0');for(auto word:words)out<<std::setw(sizeof(word)*2)<<uint32_t(word);return out.str();}
NSImage* image(const std::vector<uint8_t>& rgb){if(rgb.size()!=width*height*3)return nil;auto rep=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nil pixelsWide:width pixelsHigh:height bitsPerSample:8 samplesPerPixel:3 hasAlpha:NO isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:width*3 bitsPerPixel:24];if(!rep)return nil;std::memcpy(rep.bitmapData,rgb.data(),rgb.size());auto value=[[NSImage alloc] initWithSize:NSMakeSize(width,height)];[value addRepresentation:rep];return value;}
#if __has_include("PatchTrace.h")
std::vector<uint8_t> patchTracePoster(const J& recipe){
 vj::patch_trace::Recipe effect(recipe);std::vector<uint8_t> rgb(width*height*3,0);
 for(int y=0;y<height;++y)for(int x=0;x<width;++x){
  double px=(double(x)/(width-1)-.1)/.8,py=(double(y)/(height-1)-.15)/.7;if(px<0||px>1||py<0||py>1)continue;
  std::array<double,4> edges={py,1-px,1-py,px};auto edge=std::min_element(edges.begin(),edges.end())-edges.begin();if(edges[edge]>=.07)continue;
  std::array<double,4> along={px,1+py,3-px,4-py};auto color=effect.sample(along[edge]/4,0,effect.time*2);
  for(int c=0;c<3;c++)rgb[(y*width+x)*3+c]=uint8_t(std::clamp(color[c],0.f,1.f)*255);
 }return rgb;
}
#endif
J sampleGeometry(bool boxes=false){
 if(boxes){static const J geometry=[](){J project={{"rects",J::array()}};vj::requestMappingCollection(project,"POST","",{{"kind","boxes"},{"preset","stack"}});auto description=project["collections"][0];description["rects"]=project["rects"];return vj::collectionGeometry(description);}();return geometry;}
 J faces=J::array(),rects=J::array();for(int y=0;y<2;++y)for(int x=0;x<3;++x){auto id="sample-"+std::to_string(y*3+x);double l=.04+x*.32,t=.06+y*.46;J corners={{l,t},{l+.28,t},{l+.28,t+.38},{l,t+.38}};faces.push_back({{"id",id},{"rectId",id},{"name",id},{"planeCorners",corners}});rects.push_back({{"id",id},{"corners",corners},{"uvs",{{0,0},{1,0},{1,1},{0,1}}}});}return vj::collectionGeometry({{"kind","planar"},{"faces",faces},{"rects",rects}});
}
// A small independent preview graph retains visible live inputs across requests.
// It never adds a layer to an Out and never enables audio or publication.
class LiveRenderer {
 NSOpenGLContext* context_=nil;std::unique_ptr<NativeRenderGraph> graph_;std::map<std::string,std::pair<J,double>> clips_;uint64_t revision_=0;std::function<std::unique_ptr<LiveCapture>(const std::string&)> factory_;
public:
 explicit LiveRenderer(std::function<std::unique_ptr<LiveCapture>(const std::string&)> factory={}):factory_(std::move(factory)){}
 ~LiveRenderer(){if(context_){[context_ makeCurrentContext];graph_.reset();[NSOpenGLContext clearCurrentContext];}}
 NSImage* render(const J& clip){
  if(!context_){NSOpenGLPixelFormatAttribute attrs[]={NSOpenGLPFAOpenGLProfile,NSOpenGLProfileVersion3_2Core,NSOpenGLPFAAccelerated,NSOpenGLPFAColorSize,24,0};auto format=[[NSOpenGLPixelFormat alloc]initWithAttributes:attrs];context_=[[NSOpenGLContext alloc]initWithFormat:format shareContext:nil];if(!context_)return nil;[context_ makeCurrentContext];graph_=std::make_unique<NativeRenderGraph>(factory_);}
  [context_ makeCurrentContext];const auto now=[NSDate timeIntervalSinceReferenceDate];auto key=hash(J::array({clip["gen"],clip["params"]}).dump());clips_[key]={clip,now};
  for(auto i=clips_.begin();i!=clips_.end();)if(now-i->second.second>2)i=clips_.erase(i);else ++i;
  while(clips_.size()>12){auto oldest=std::min_element(clips_.begin(),clips_.end(),[](const auto& a,const auto& b){return a.second.second<b.second.second;});clips_.erase(oldest);}
  NativeScene scene;scene.revision=++revision_;scene.canvas_width=width;scene.canvas_height=height;std::map<std::string,std::array<int,2>> sizes;
  int index=0;std::string requested;for(const auto& [id,value]:clips_){auto bus=index==0?"program":"out"+std::to_string(index+1);NativeLayer layer;layer.id=++index;layer.source_id=id;layer.generator=value.first["gen"];layer.params=value.first["params"];layer.resolved_file=layer.params.value(layer.generator=="usb_webcam"?"device":"source",std::string{});layer.params["audio_enabled"]=false;layer.params["fit"]="contain";scene.buses[bus].layers.push_back(layer);scene.outputs.push_back(bus);sizes[bus]={width,height};if(id==key)requested=bus;}
  graph_->apply_scene(std::move(scene));graph_->set_bus_sizes(sizes);graph_->render();bool ready=false;auto diagnostics=graph_->diagnostics();for(const auto& source:diagnostics["sources"])if(source["sourceId"]==key)ready=source.value("width",0)>1&&source.value("height",0)>1&&source.value("error",std::string{}).empty();
  if(getenv("VJ_DEBUG_LIVE"))NSLog(@"Live %s %s",key.c_str(),diagnostics.dump().c_str());auto result=ready?image(graph_->read_bus_rgb(requested,width,height)):nil;[NSOpenGLContext clearCurrentContext];return result;
 }
};
class Renderer {
 fs::path root_;J catalog_;NSOpenGLContext* context_=nil;std::unique_ptr<NativeRenderGraph> graph_;std::unique_ptr<vj::VectorHost> vectors_;uint64_t revision_=0;std::function<bool()> cancelled_;
 void context(){if(context_&&graph_&&vectors_){[context_ makeCurrentContext];return;}if(context_){[context_ makeCurrentContext];vectors_.reset();graph_.reset();context_=nil;}NSOpenGLPixelFormatAttribute attributes[]={NSOpenGLPFAOpenGLProfile,NSOpenGLProfileVersion3_2Core,NSOpenGLPFAAccelerated,NSOpenGLPFAColorSize,24,0};auto format=[[NSOpenGLPixelFormat alloc] initWithAttributes:attributes];context_=[[NSOpenGLContext alloc] initWithFormat:format shareContext:nil];if(!context_)throw std::runtime_error("Thumbnail OpenGL context unavailable");[context_ makeCurrentContext];graph_=std::make_unique<NativeRenderGraph>([](const std::string&)->std::unique_ptr<LiveCapture>{throw std::runtime_error("Live capture is disabled in thumbnails");});vectors_=std::make_unique<vj::VectorHost>(root_/"vector-modules");vectors_->install(*graph_);}
 fs::path cache(){auto path=root_/"thumbnail-cache";fs::create_directories(path);return path;}
 fs::path plate(){const auto path=cache()/"adjustment-plate-v1.png";if(fs::is_regular_file(path))return path;std::vector<uint8_t> rgb(width*height*3);for(int y=0;y<height;++y)for(int x=0;x<width;++x){double px=double(x)/(width-1),py=double(y)/(height-1);std::array<double,3> value={px,py,.45+.35*std::sin((px+py)*M_PI*5)};for(int c=0;c<3;++c)rgb[(y*width+x)*3+c]=(y%18==0||x%24==0)?255:uint8_t(value[c]*255);}auto bitmap=(NSBitmapImageRep*)image(rgb).representations.firstObject;auto data=[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];if(![data writeToFile:[NSString stringWithUTF8String:path.c_str()] atomically:YES])throw std::runtime_error("Cannot cache thumbnail plate");return path;}
 fs::path poster(const std::string& file,const J& params){
  if(file.empty())throw std::runtime_error("Resolved video media unavailable");auto destination=vj::mediaClipThumbnail(file,cache(),params,cancelled_);std::vector<fs::directory_entry> posters;for(const auto& entry:fs::directory_iterator(destination.parent_path()))if(entry.is_regular_file()&&entry.path().filename().string().starts_with("poster-"))posters.push_back(entry);if(posters.size()>128){std::sort(posters.begin(),posters.end(),[](const auto& a,const auto& b){return a.last_write_time()<b.last_write_time();});for(size_t i=0;i<posters.size()-128;++i)if(posters[i].path()!=destination){std::error_code ignored;fs::remove(posters[i],ignored);}}return destination;
 }

public:
 Renderer(fs::path root,J catalog,std::function<bool()> cancelled={}):root_(std::move(root)),catalog_(std::move(catalog)),cancelled_(std::move(cancelled)){}
 ~Renderer(){if(context_){[context_ makeCurrentContext];vectors_.reset();graph_.reset();[NSOpenGLContext clearCurrentContext];context_=nil;}}
 NSImage* render(J clip,vj::Model* model){
  (void)model;auto effect=clip.value("gen",std::string{});if(effect=="ndi"||effect=="syphon"||effect=="usb_webcam"||clip.value("nativeImportUnsupported",false))return nil;
  auto findSpec=[&](const std::string& name){for(const auto& item:catalog_)if(item["name"]==name)return item;return J::object();};auto spec=findSpec(effect);if(spec.empty()&&!clip.contains("vector"))return nil;
  auto params=clip.value("params",J::object());for(const auto& parameter:spec.value("parameters",J::array()))if(!params.contains(parameter.at("name").get<std::string>()))params[parameter.at("name").get<std::string>()]=parameter.at("default");
  #if __has_include("PatchTrace.h")
  if(effect=="patch_trace"){for(const auto& output:model->patchOutputs())if(output.value("type",std::string{})=="trace"&&output.value("id",std::string{})==params.value("source",std::string{})&&output.value("available",false))return image(patchTracePoster(output.value("recipe",J::object())));return nil;}
#endif
  auto contexts=clip.value("_thumbnailContexts",J::array());bool boxes=false;
  if(effect=="patch_collection")for(const auto& output:model->patchOutputs())if(output.value("id",std::string{})==params.value("source",std::string{})){
    const auto kind=output.value("recipe",J::object()).value("kind",std::string{});boxes=kind=="boxWaterfall"||kind=="sphereGimbal"||kind=="boxEdges";break;
  }
  if(effect!="patch_trace")contexts.erase(std::remove_if(contexts.begin(),contexts.end(),[&](const J& geometry){return geometry.value("traceOnly",false)||(boxes&&geometry.value("kind",std::string{})!="boxes");}),contexts.end());
  if(spec.value("collectionGeometry",J()).is_string()&&effect!="media_collection"&&contexts.empty())contexts.push_back(sampleGeometry(boxes));
  if(effect=="text"&&clip.value("resolved_file",std::string{}).empty()){vj::TextSource source(cache()/"text");clip["resolved_file"]=source.asset(params,width,height);}
  if((effect=="image"||effect=="video")&&clip.contains("mediaStatus")&&!clip["mediaStatus"].value("available",true))return nil;if(contexts.empty())contexts.push_back(J::object());
  auto makeLayer=[&](const std::string& name,J values,const J& asset,int id){
    auto childSpec=findSpec(name);for(const auto& p:childSpec.value("parameters",J::array()))if(!values.contains(p["name"].get<std::string>()))values[p["name"].get<std::string>()]=p["default"];
    NativeLayer layer;layer.id=id;layer.source_id="thumbnail:"+hash(J::array({name,values,asset.value("resolved_file",std::string{})}).dump());layer.generator=name;layer.params=values;layer.params["audio_enabled"]=false;layer.params["playing"]=false;layer.resolved_file=asset.value("resolved_file",std::string{});
    if(childSpec.value("collectionGeometry",J()).is_string())layer.collection_geometry=childSpec["collectionGeometry"];
    if(name=="video"){layer.generator="image";layer.resolved_file=poster(layer.resolved_file,values).string();layer.params["scale"]=1.;layer.params["x"]=.5;layer.params["y"]=.5;}
    if((name=="image"||name=="text")&&layer.resolved_file.empty())throw std::runtime_error("Resolved thumbnail asset unavailable");
    if(name.starts_with("external_")){if(!asset.contains("vector"))throw std::runtime_error("Thumbnail module unavailable");layer.vector=asset["vector"];layer.vector["canvas"]={width,height};}return layer;
  };
  context();std::vector<uint8_t> maximum(width*height*3,0);for(const auto& geometry:contexts){if(cancelled_&&cancelled_())return nil;NativeBus bus;bus.running=true;bus.clock.playing=false;bus.collection=geometry;
    if(effect=="media_collection"){
      auto items=params.value("items",J::array()),resolved=clip.value("resolvedItems",J::array());if(items.empty())return nil;const size_t faceCount=geometry.empty()?1:geometry.value("faceIds",J::array()).size();
      for(size_t i=0;i<std::min(items.size(),faceCount);++i){auto name=items[i].at("type").get<std::string>();J values=J::object();for(const auto& p:findSpec(name).value("parameters",J::array())){auto key=p["name"].get<std::string>();values[key]=params.value(key,p["default"]);}values["file"]=items[i]["file"];J asset=i<resolved.size()?resolved[i]:J::object();auto layer=makeLayer(name,values,asset,int(i)+2);
        if(!geometry.empty()){J vertices=J::array();auto faces=geometry.value("mediaVertices",J::array());for(size_t face=i;face<faceCount;face+=items.size())if(face<faces.size())for(const auto& vertex:faces[face])vertices.push_back(vertex);layer.params["_media_vertices"]=vertices;layer.params["_media_group"]="thumbnail-collection";}bus.layers.push_back(std::move(layer));
      }
    }else{
      if(spec.value("adjustment",false)){NativeLayer background;background.id=1;background.source_id="thumbnail-plate";background.generator="image";background.resolved_file=plate().string();background.params={{"fit","stretch"}};bus.layers.push_back(background);}bus.layers.push_back(makeLayer(effect,params,clip,2));
    }
    for(auto phase:phases){if(cancelled_&&cancelled_())return nil;bus.clock.seconds=phase[0];bus.clock.beat=phase[1];NativeScene scene;scene.revision=++revision_;scene.canvas_width=width;scene.canvas_height=height;scene.outputs={"program"};scene.buses["program"]=bus;graph_->apply_scene(std::move(scene));graph_->set_bus_sizes({{"program",{width,height}}});vectors_->beginFrame(revision_);graph_->set_patch_outputs(model->patchOutputs());graph_->render();
    // Only the background poster worker waits for image decode; live outputs
    // keep rendering while these jobs finish. Never cache a partial poster.
    const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(15);
    while(graph_->static_images_pending()){
        if(cancelled_&&cancelled_())return nil;
        if(std::chrono::steady_clock::now()>=deadline)throw std::runtime_error("Thumbnail images still loading");
        std::this_thread::sleep_for(std::chrono::milliseconds(10));graph_->render();
    }
    vectors_->endFrame();const auto vectorStatus=vectors_->diagnostics();for(const auto& status:vectorStatus["sources"])if(!status.value("error",std::string{}).empty())throw std::runtime_error(status["error"].get<std::string>());auto pixels=graph_->read_bus_rgb("program",width,height);if(pixels.size()!=maximum.size())throw std::runtime_error("Thumbnail readback unavailable");for(size_t i=0;i<pixels.size();++i)maximum[i]=std::max(maximum[i],pixels[i]);}
  }return image(maximum);
 }

};
}
@implementation VJClipThumbnails {
 NSCache<NSString*,NSImage*>* _patchPosters;
    vj::Model* _model;NSMutableDictionary<NSString*,NSImage*>* _images;NSMutableDictionary<NSString*,NSString*>* _identities;NSMutableArray<NSString*>* _recent;
    NSMutableDictionary<NSString*,NSString*>* _wanted;NSMutableDictionary<NSString*,NSString*>* _failedIdentity;NSMutableSet<NSString*>* _pending;NSMutableDictionary<NSString*,NSDate*>* _failed;NSMutableDictionary<NSString*,NSDate*>* _updated;BOOL _liveEnabled;NSTimer* _idleTimer;NSTimeInterval _lastLiveUse;
    dispatch_queue_t _queue;dispatch_group_t _tasks;void(^_redraw)(void);std::atomic<bool> _stopped;
    std::unique_ptr<Renderer> _renderer;std::unique_ptr<LiveRenderer> _liveRenderer;dispatch_queue_t _liveQueue;vj::Json _catalog,_contexts;std::set<std::string> _contextEffects;std::string _contextKey,_contextState;
}
- (instancetype)initWithModel:(vj::Model*)model redraw:(void(^)(void))redraw {
    if((self=[super init])){_model=model;_liveEnabled=YES;_patchPosters=[NSCache new];_patchPosters.countLimit=256;_wanted=[NSMutableDictionary dictionary];_failedIdentity=[NSMutableDictionary dictionary];_updated=[NSMutableDictionary dictionary];_liveQueue=dispatch_queue_create("com.vibe.live-posters",DISPATCH_QUEUE_SERIAL);_catalog=vj::Model::catalog();_contexts=J::array();for(const auto& effect:_catalog)if(effect.value("kind",std::string{})=="collection"||effect.value("collectionGeometry",J()).is_string())_contextEffects.insert(effect["name"].get<std::string>());_redraw=[redraw copy];_images=[NSMutableDictionary dictionary];_identities=[NSMutableDictionary dictionary];_recent=[NSMutableArray array];_pending=[NSMutableSet set];_failed=[NSMutableDictionary dictionary];_queue=dispatch_queue_create("com.vibe.clip-posters",DISPATCH_QUEUE_SERIAL);_tasks=dispatch_group_create();__weak VJClipThumbnails* weak=self;_idleTimer=[NSTimer timerWithTimeInterval:1 repeats:YES block:^(NSTimer*){VJClipThumbnails* owner=weak;if(owner&&owner->_lastLiveUse>0&&[NSDate timeIntervalSinceReferenceDate]-owner->_lastLiveUse>2){owner->_lastLiveUse=0;dispatch_async(owner->_liveQueue,^{owner->_liveRenderer.reset();});}}];[[NSRunLoop mainRunLoop] addTimer:_idleTimer forMode:NSRunLoopCommonModes];}return self;
}
- (void)setContext:(const vj::Json&)snapshot bus:(NSString*)bus {
    J contexts=J::array();const std::string selected=bus?bus.UTF8String:"program",source=selected=="program"?"out1":selected;J revisions=J::array({selected});for(const auto& mapping:snapshot.value("mappings",J::object()))revisions.push_back({mapping.value("mappingId",std::string{}),mapping.value("revision",uint64_t(0))});auto state=revisions.dump();if(state==_contextState)return;_contextState=state;
    for(const auto& mapping:snapshot.value("mappings",J::object())){
        if(mapping.contains("project")){
            // Thumbnail the content against saved geometry even while the mapper
            // shows alignment patterns. This is a temporary preview description.
            auto project=mapping["project"];for(auto& rect:project["rects"])rect["mode"]="live";
            auto derived=vj::collectionRendering(project,mapping.value("mappingId",std::string("1")),{source},{source});
            for(const auto& [name,context]:derived.contexts){(void)name;if(context.first==source)contexts.push_back(context.second);}
        }else for(const auto& context:mapping.value("collectionContexts",J::object())){auto out=context.value("source",std::string{});if(out=="out1")out="program";if(out==selected&&context.contains("geometry"))contexts.push_back(context["geometry"]);}
    }
    _contexts=std::move(contexts);_contextKey=hash(_contexts.dump());
}
- (void)setLivePreviewsEnabled:(BOOL)enabled {_liveEnabled=enabled;if(!enabled)dispatch_async(_liveQueue,^{self->_liveRenderer.reset();});}
- (NSImage*)imageForClip:(const vj::Json&)raw {
    if(_stopped)return nil;auto clip=raw;auto effect=clip.value("gen",std::string{});
    if(effect=="patch_video"){
      auto id=clip.value("params",J::object()).value("source",std::string{});auto stable=[NSString stringWithUTF8String:id.c_str()];
      for(const auto& output:_model->patchOutputs())if(output["id"]==id&&output.value("available",false)&&output.value("active",true)&&!output.value("selection",std::string{}).empty()){clip["gen"]="syphon";clip["params"]["source"]=output.value("selection",std::string{});auto poster=[self imageForClip:clip];if(poster)[_patchPosters setObject:poster forKey:stable];return poster?:[_patchPosters objectForKey:stable];}
      auto cached=[_patchPosters objectForKey:stable];if(!cached)_model->requestPatchPoster(id);return cached;
    }
    if(effect=="patch_collection"||effect=="patch_trace"){
      bool available=false;for(const auto& output:_model->patchOutputs())if(output["id"]==clip.value("params",J::object()).value("source",std::string{}))available=output.value("available",false)&&output.value("active",true);
      if(!available){auto stable=clip.contains("id")?J::array({clip["id"],effect}).dump():J::array({effect,clip.value("params",J::object())}).dump();auto cached=_images[[NSString stringWithUTF8String:hash(stable).c_str()]];if(!cached)_model->requestPatchPoster(clip.value("params",J::object()).value("source",std::string{}));return cached;}
    }const bool live=effect=="ndi"||effect=="syphon"||effect=="usb_webcam";if(effect=="usb_webcam"||(live&&!_liveEnabled)||clip.value("nativeImportUnsupported",false))return nil;
    J identity={{"gen",effect},{"params",clip.value("params",J::object())}};for(auto name:{"vector","resolved_file","resolvedItems","mediaStatus","textStatus"})if(clip.contains(name))identity[name]=clip[name];
    if(_contextEffects.contains(effect)&&effect!="patch_trace"){identity["geometry"]=_contextKey;clip["_thumbnailContexts"]=_contexts;}
    NSString* identityKey=[NSString stringWithUTF8String:hash(identity.dump()).c_str()];
    // Keep one strong poster per clip. Parameter scrubbing must not fill an
    // opportunistic NSCache with old versions and evict every unchanged slot.
    // Library effects have no clip ID; their effect/source identity is stable.
    auto stable=clip.contains("id")?J::array({clip["id"],effect}).dump():J::array({effect,clip.value("params",J::object())}).dump();
    NSString* key=[NSString stringWithUTF8String:hash(stable).c_str()];
    [_recent removeObject:key];[_recent addObject:key];
    while(_recent.count>256){NSString* oldest=_recent.firstObject;[_recent removeObjectAtIndex:0];[_images removeObjectForKey:oldest];[_identities removeObjectForKey:oldest];[_updated removeObjectForKey:oldest];[_failed removeObjectForKey:oldest];[_wanted removeObjectForKey:oldest];[_failedIdentity removeObjectForKey:oldest];}
    _wanted[key]=identityKey;
    NSImage* cached=_images[key];BOOL current=[_identities[key]isEqual:identityKey];
    // A clip poster is a snapshot, including Patch/Syphon and NDI. Only a
    // source/parameter change requests another frame; retain the old poster
    // until that replacement is ready. A/B/output monitors remain live.
    if(cached&&current)return cached;
    NSDate* failed=_failed[key];if([_failedIdentity[key]isEqual:identityKey]&&failed&&-[failed timeIntervalSinceNow]<(live?.5:10))return cached;
    if([_pending containsObject:key]||_pending.count>=12)return cached;[_pending addObject:key];if(live)_lastLiveUse=[NSDate timeIntervalSinceReferenceDate];
    dispatch_group_async(_tasks,live?_liveQueue:_queue,^{@autoreleasepool{
        if(self->_stopped)return;NSImage* rendered=nil;
        try{if(live){if(!self->_liveRenderer)self->_liveRenderer=std::make_unique<LiveRenderer>();rendered=self->_liveRenderer->render(clip);}else{auto* stopped=&self->_stopped;if(!self->_renderer)self->_renderer=std::make_unique<Renderer>(self->_model->stateRoot(),self->_catalog,[stopped](){return stopped->load();});rendered=self->_renderer->render(clip,self->_model);}}catch(const std::exception& error){NSLog(@"Thumbnail %s: %s",effect.c_str(),error.what());}
        dispatch_async(dispatch_get_main_queue(),^{
            if(self->_stopped)return;[self->_pending removeObject:key];
            if(![self->_recent containsObject:key])return;
            if(![self->_wanted[key]isEqual:identityKey]){if(self->_redraw)self->_redraw();return;}
            if(rendered){self->_identities[key]=identityKey;self->_updated[key]=[NSDate date];self->_images[key]=rendered;[self->_failed removeObjectForKey:key];[self->_failedIdentity removeObjectForKey:key];}
            else{self->_failed[key]=[NSDate date];self->_failedIdentity[key]=identityKey;}
            if(self->_redraw)self->_redraw();
        });
    }});return cached;
}
- (void)stop {if(_stopped.exchange(true))return;[_idleTimer invalidate];dispatch_group_wait(_tasks,DISPATCH_TIME_FOREVER);dispatch_sync(_queue,^{self->_renderer.reset();});dispatch_sync(_liveQueue,^{self->_liveRenderer.reset();});_redraw=nil;[_images removeAllObjects];[_pending removeAllObjects];[_failed removeAllObjects];}
@end
vj::Json VJCheckClipThumbnailRendering(vj::Model* model){
 Renderer renderer(model->stateRoot(),vj::Model::catalog());J checks=J::array();for(const auto& effect:vj::Model::catalog()){const auto name=effect.at("name").get<std::string>();if(name=="image"||name=="video"||name=="media_collection"||effect.value("liveSource",false))continue;J clip={{"gen",name},{"params",J::object()}};NSImage* value=nil;try{value=renderer.render(clip,model);}catch(const std::exception& error){NSLog(@"Preview check %s: %s",name.c_str(),error.what());}auto bitmap=(NSBitmapImageRep*)value.representations.firstObject;bool nonblack=false;if(bitmap)for(NSInteger i=0;i<bitmap.bytesPerRow*bitmap.pixelsHigh;++i)if(bitmap.bitmapData[i]){nonblack=true;break;}checks.push_back({{"effect",name},{"rendered",value!=nil},{"nonblack",nonblack}});}return {{"checks",checks},{"width",width},{"height",height},{"liveCapture",false},{"audio",false}};
}

vj::Json VJCheckThumbnailStability(vj::Model* model){
 auto thumbnails=[[VJClipThumbnails alloc]initWithModel:model redraw:^{}];
 J untouched={{"id","stable-color"},{"gen","solid_color"},{"params",{{"color","#aabbcc"}}}};
 J edited={{"id","edited-plasma"},{"gen","plasma"},{"params",{{"speed",1.}}}};
 auto wait=[&](const J& clip){NSImage* image=nil;auto limit=[NSDate dateWithTimeIntervalSinceNow:3];while(!(image=[thumbnails imageForClip:clip])&&limit.timeIntervalSinceNow>0)[[NSRunLoop mainRunLoop]runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];return image;};
 auto first=wait(untouched);auto initial=wait(edited);bool stable=first&&initial;
 for(int i=0;i<160;++i){edited["params"]["speed"]=i%2?double(i)/20.:.1;stable=stable&&[thumbnails imageForClip:edited]!=nil&&[thumbnails imageForClip:untouched]==first;[[NSRunLoop mainRunLoop]runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.002]];}
 bool camera=[thumbnails imageForClip:J{{"id","unused-camera"},{"gen","usb_webcam"},{"params",{{"device","must-not-open"}}}}]==nil;
 [thumbnails stop];return {{"stableDuringSpeedEdits",stable},{"cameraThumbnailDisabled",camera}};
}

// Explicit local signal test, enabled only by VJ_CHECK_LIVE_PREVIEWS. No saved
// outputs, external devices or production sources are changed.
vj::Json VJCheckLiveClipPreviews(void(^present)(J,BOOL)){
 J results=J::array();NSOpenGLPixelFormatAttribute attrs[]={NSOpenGLPFAOpenGLProfile,NSOpenGLProfileVersion3_2Core,NSOpenGLPFAAccelerated,NSOpenGLPFAColorSize,24,0};auto format=[[NSOpenGLPixelFormat alloc]initWithAttributes:attrs];auto context=[[NSOpenGLContext alloc]initWithFormat:format shareContext:nil];[context makeCurrentContext];
 GLuint texture=0;glGenTextures(1,&texture);glBindTexture(GL_TEXTURE_2D,texture);std::vector<uint8_t> rgba(width*height*4),rgb(width*height*3);for(int i=0;i<width*height;++i){rgba[i*4]=rgb[i*3]=210;rgba[i*4+1]=rgb[i*3+1]=50;rgba[i*4+2]=rgb[i*3+2]=110;rgba[i*4+3]=255;}glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,width,height,0,GL_RGBA,GL_UNSIGNED_BYTE,rgba.data());glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
 auto server=[[SyphonOpenGLServer alloc]initWithName:@"VJ Composer Preview Check" context:context.CGLContextObj options:nil];auto description=server.serverDescription;J syphon={{"app",[(NSString*)description[SyphonServerDescriptionAppNameKey] UTF8String]?:""},{"name",[(NSString*)description[SyphonServerDescriptionNameKey] UTF8String]?:""},{"uuid",[(NSString*)description[SyphonServerDescriptionUUIDKey] UTF8String]?:""}};
 NdiOutput ndi("VJ Composer Preview Check",width,height,30);auto readyUntil=[NSDate dateWithTimeIntervalSinceNow:3];while(!ndi.diagnostics().value("ready",false)&&readyUntil.timeIntervalSinceNow>0)[[NSRunLoop mainRunLoop]runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]];
 J ndiSelection={{"name",ndi.diagnostics().value("source_name",ndi.name)},{"url",""},{"extra_ips","127.0.0.1"}};const char* external=getenv("VJ_CHECK_NDI_SOURCE");if(external){std::ifstream file(external);file>>ndiSelection;}auto runtime=NdiRuntime::get();NDIlib_find_create_t settings;settings.show_local_sources=true;settings.p_extra_ips="127.0.0.1";auto finder=!external&&runtime->api?runtime->api->find_create_v2(&settings):nullptr;auto discoveryUntil=[NSDate dateWithTimeIntervalSinceNow:8];bool discovered=external!=nullptr;while(finder&&!discovered&&discoveryUntil.timeIntervalSinceNow>0){ndi.publish(rgb);runtime->api->find_wait_for_sources(finder,1);uint32_t count=0;auto sources=runtime->api->find_get_current_sources(finder,&count);for(uint32_t i=0;i<count;++i)if(sources[i].p_ndi_name&&std::string(sources[i].p_ndi_name).find(ndi.name)!=std::string::npos){ndiSelection["name"]=sources[i].p_ndi_name;ndiSelection["url"]=sources[i].p_url_address?:"";discovered=true;}[[NSRunLoop mainRunLoop]runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.03]];}if(finder)runtime->api->find_destroy(finder);NSLog(@"Preview NDI discovery %d %s",discovered,ndiSelection.dump().c_str());
 for(const auto* effect:{"syphon","ndi","usb_webcam"}){
  LiveRenderer renderer(std::string(effect)=="usb_webcam"?std::function<std::unique_ptr<LiveCapture>(const std::string&)>([](const std::string& device){return std::make_unique<LiveCapture>(device,"lavfi");}):std::function<std::unique_ptr<LiveCapture>(const std::string&)>{});
  J params=std::string(effect)=="usb_webcam"?J{{"device","testsrc2=size=192x108:rate=12"}}:J{{"source",std::string(effect)=="syphon"?syphon.dump():ndiSelection.dump()}};J clip={{"gen",effect},{"params",params}};NSImage* frame=nil;const auto until=[NSDate dateWithTimeIntervalSinceNow:8];
  while(!frame&&until.timeIntervalSinceNow>0){[context makeCurrentContext];[server publishFrameTexture:texture textureTarget:GL_TEXTURE_2D imageRegion:NSMakeRect(0,0,width,height) textureDimensions:NSMakeSize(width,height) flipped:NO];glFlush();ndi.publish(rgb);frame=renderer.render(clip);[[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.03]];}
  BOOL matched=NO;if(frame){auto bitmap=(NSBitmapImageRep*)frame.representations.firstObject;auto pixel=bitmap.bitmapData+(height/2)*bitmap.bytesPerRow+(width/2)*3;matched=std::string(effect)=="usb_webcam"?(pixel[0]+pixel[1]+pixel[2]>0):(abs(pixel[0]-210)<25&&abs(pixel[1]-50)<25&&abs(pixel[2]-110)<25);if(const char* dir=getenv("VJ_UI_CAPTURE_DIR"))[[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}]writeToFile:[[NSString stringWithUTF8String:dir]stringByAppendingPathComponent:[NSString stringWithFormat:@"live-%s.png",effect]] atomically:YES];}
  if(std::string(effect)=="syphon"&&frame){bool handoff=true;for(int i=0;i<2;++i){NSImage* next=nil;std::thread worker([&]{@autoreleasepool{next=renderer.render(clip);}});worker.join();auto bitmap=(NSBitmapImageRep*)next.representations.firstObject;if(!bitmap){handoff=false;continue;}auto pixel=bitmap.bitmapData+(height/2)*bitmap.bytesPerRow+(width/2)*3;handoff=handoff&&abs(pixel[0]-210)<25&&abs(pixel[1]-50)<25&&abs(pixel[2]-110)<25;}results.push_back({{"effect","syphon-worker-handoff"},{"frame",handoff},{"pixels",handoff}});}
  NSLog(@"Live preview result %s frame %d pixels %d sender %s",effect,frame!=nil,matched,ndi.diagnostics().dump().c_str());results.push_back({{"effect",effect},{"frame",frame!=nil},{"pixels",bool(matched)}});
 }
 if(present){J sources={{"usb_webcam",J::array()},{"syphon",J::array({{{"label","VJ Composer Preview Check"},{"selection",syphon.dump()}}})},{"ndi",J::array({{{"label",ndiSelection["name"]},{"selection",ndiSelection.dump()}}})}};present(sources,YES);auto until=[NSDate dateWithTimeIntervalSinceNow:5];while(until.timeIntervalSinceNow>0){[context makeCurrentContext];[server publishFrameTexture:texture textureTarget:GL_TEXTURE_2D imageRegion:NSMakeRect(0,0,width,height) textureDimensions:NSMakeSize(width,height) flipped:NO];glFlush();ndi.publish(rgb);[[NSRunLoop mainRunLoop]runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.03]];}present(sources,NO);}
 [context makeCurrentContext];[server stop];glDeleteTextures(1,&texture);[NSOpenGLContext clearCurrentContext];return results;
}

vj::Json VJCheckHeldPatchThumbnails(vj::Model* model) {
 J checks=J::object();NSOpenGLPixelFormatAttribute attrs[]={NSOpenGLPFAOpenGLProfile,NSOpenGLProfileVersion3_2Core,NSOpenGLPFAAccelerated,NSOpenGLPFAColorSize,24,0};
 auto format=[[NSOpenGLPixelFormat alloc]initWithAttributes:attrs];auto context=[[NSOpenGLContext alloc]initWithFormat:format shareContext:nil];[context makeCurrentContext];
 GLuint texture=0;glGenTextures(1,&texture);glBindTexture(GL_TEXTURE_2D,texture);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
 auto server=[[SyphonOpenGLServer alloc]initWithName:@"VJ Held Poster Check" context:context.CGLContextObj options:nil];auto description=server.serverDescription;
 J selection={{"app",[(NSString*)description[SyphonServerDescriptionAppNameKey] UTF8String]?:""},{"name",[(NSString*)description[SyphonServerDescriptionNameKey] UTF8String]?:""},{"uuid",[(NSString*)description[SyphonServerDescriptionUUIDKey] UTF8String]?:""}};
 J clip={{"id","held-patch"},{"gen","syphon"},{"params",{{"source",selection.dump()},{"gain",1.}}}};
 auto thumbnails=[[VJClipThumbnails alloc]initWithModel:model redraw:^{}];
 auto publish=[&](bool green){[context makeCurrentContext];std::vector<uint8_t> rgba(width*height*4);for(size_t i=0;i<rgba.size();i+=4){rgba[i]=green?0:210;rgba[i+1]=green?210:0;rgba[i+3]=255;}glBindTexture(GL_TEXTURE_2D,texture);glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,width,height,0,GL_RGBA,GL_UNSIGNED_BYTE,rgba.data());[server publishFrameTexture:texture textureTarget:GL_TEXTURE_2D imageRegion:NSMakeRect(0,0,width,height) textureDimensions:NSMakeSize(width,height) flipped:NO];glFlush();[NSOpenGLContext clearCurrentContext];};
 auto spin=[]{[[NSRunLoop mainRunLoop]runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.03]];};
 auto sample=[](NSImage* image,int channel){auto bitmap=(NSBitmapImageRep*)image.representations.firstObject;return bitmap?int(bitmap.bitmapData[(height/2)*bitmap.bytesPerRow+(width/2)*3+channel]):-1;};
 NSImage* first=nil;auto deadline=[NSDate dateWithTimeIntervalSinceNow:6];
 while(!first&&deadline.timeIntervalSinceNow>0){publish(false);first=[thumbnails imageForClip:clip];spin();}
 checks["Patch poster captures actual source pixels"]=first&&sample(first,0)>180;
 if(first){
  bool held=true;deadline=[NSDate dateWithTimeIntervalSinceNow:3.2];while(deadline.timeIntervalSinceNow>0){publish(true);held&=[thumbnails imageForClip:clip]==first;spin();}
  checks["Patch poster stays fixed while source changes"]=held&&sample(first,0)>180;
  clip["params"]["gain"]=.5;NSImage* replacement=first;bool continuous=true;deadline=[NSDate dateWithTimeIntervalSinceNow:5];
  while(replacement==first&&deadline.timeIntervalSinceNow>0){publish(true);replacement=[thumbnails imageForClip:clip];continuous&=replacement!=nil;spin();}
  checks["Patch edits replace poster without clearing"]=continuous&&replacement!=first&&sample(replacement,1)>85&&sample(replacement,1)<125;
  clip["params"]["source"]=J{{"app","Unavailable"},{"name","Absent"},{"uuid","no-such-test-sender"}}.dump();
  bool retained=true;deadline=[NSDate dateWithTimeIntervalSinceNow:2.5];while(deadline.timeIntervalSinceNow>0){retained&=[thumbnails imageForClip:clip]==replacement;spin();}
  checks["Unavailable patch replacement retains last poster"]=retained;
 }
 [thumbnails stop];[context makeCurrentContext];[server stop];glDeleteTextures(1,&texture);[NSOpenGLContext clearCurrentContext];return checks;
}

vj::Json VJCheckTraceThumbnails(vj::Model* model) {
 Renderer renderer(model->stateRoot(),vj::Model::catalog());J checks=J::object();bool same=true,margin=true,visible=true;int index=0;
 for(const auto& effect:vj::Model::catalog()){auto name=effect.at("name").get<std::string>();if(!name.starts_with("trace_"))continue;J clip={{"gen",name},{"params",J::object()}};auto flat=renderer.render(clip,model);clip["_thumbnailContexts"]=J::array({sampleGeometry(true)});auto boxed=renderer.render(clip,model);auto a=(NSBitmapImageRep*)flat.representations.firstObject,b=(NSBitmapImageRep*)boxed.representations.firstObject;same&=a&&b&&a.bytesPerRow==b.bytesPerRow&&std::memcmp(a.bitmapData,b.bitmapData,a.bytesPerRow*a.pixelsHigh)==0;bool lit=false;for(int y=0;y<height;y++)for(int x=0;x<width;x++)for(int c=0;c<3;c++){auto pixel=a.bitmapData[y*a.bytesPerRow+x*3+c];lit|=pixel!=0;if(x<width*.08||x>width*.92||y<height*.12||y>height*.88)margin&=pixel==0;}visible&=lit;if(auto directory=getenv("VJ_UI_CAPTURE_DIR")){auto data=[a representationUsingType:NSBitmapImageFileTypePNG properties:@{}];[data writeToFile:[NSString stringWithFormat:@"%s/trace-%02d.png",directory,index++] atomically:YES];}}
 checks["Trace previews ignore collection box geometry"]=same;checks["Trace previews keep clear margins"]=margin;checks["Trace previews render visible effect"]=visible;return checks;
}
