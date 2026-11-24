#include "media_processing.hpp"
#include <boost/uuid/detail/sha1.hpp>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <deque>
#include <fstream>
#include <iomanip>
#include <map>
#include <mutex>
#include <sstream>
#include <thread>
#include <stdexcept>
#include <cstdlib>
#include <cstring>
#include <cerrno>
#include <algorithm>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>
#ifdef __APPLE__
#include <mach-o/dyld.h>
#endif
extern char** environ;
namespace vj {
namespace fs=std::filesystem;
using Json=nlohmann::json;
namespace {
using Clock=std::chrono::steady_clock;
double now(){return std::chrono::duration<double>(std::chrono::system_clock::now().time_since_epoch()).count();}
std::string executable(const std::string& name){
#ifdef __APPLE__
    char executablePath[4096]{};uint32_t size=sizeof(executablePath);
    if(_NSGetExecutablePath(executablePath,&size)==0){auto helper=fs::path(executablePath).parent_path().parent_path()/"Helpers"/name;if(access(helper.c_str(),X_OK)==0)return helper.string();}
#endif
    std::string paths="/opt/homebrew/bin:/usr/local/bin:/usr/bin";
    std::istringstream stream(paths);std::string part;while(std::getline(stream,part,':'))if(!part.empty()){auto file=fs::path(part)/name;if(access(file.c_str(),X_OK)==0)return file.string();}
    throw std::runtime_error(name+" is unavailable");
}
std::string run(std::vector<std::string> args,int seconds,const std::atomic<bool>& cancelled){
    if(cancelled)throw std::runtime_error("Cancelled");args[0]=executable(args[0]);
    int out[2];if(pipe(out))throw std::runtime_error("Unable to create FFmpeg pipe");
    fcntl(out[0],F_SETFD,FD_CLOEXEC);fcntl(out[1],F_SETFD,FD_CLOEXEC);
    posix_spawn_file_actions_t actions;posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions,STDIN_FILENO,"/dev/null",O_RDONLY,0);
    posix_spawn_file_actions_adddup2(&actions,out[1],STDOUT_FILENO);posix_spawn_file_actions_adddup2(&actions,out[1],STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions,out[0]);posix_spawn_file_actions_addclose(&actions,out[1]);
    posix_spawnattr_t attr;posix_spawnattr_init(&attr);posix_spawnattr_setflags(&attr,POSIX_SPAWN_SETPGROUP);posix_spawnattr_setpgroup(&attr,0);
    std::vector<char*> argv;for(auto& a:args)argv.push_back(a.data());argv.push_back(nullptr);pid_t pid=0;
    int error=posix_spawn(&pid,args[0].c_str(),&actions,&attr,argv.data(),environ);
    posix_spawnattr_destroy(&attr);posix_spawn_file_actions_destroy(&actions);close(out[1]);
    if(error){close(out[0]);throw std::runtime_error(std::string("Unable to start FFmpeg: ")+strerror(error));}
    fcntl(out[0],F_SETFL,O_NONBLOCK);std::string output;int status=0;auto deadline=Clock::now()+std::chrono::seconds(seconds);bool stopped=false;std::string failure;
    for(;;){char buffer[8192];ssize_t n;while((n=read(out[0],buffer,sizeof(buffer)))>0){if(output.size()<2*1024*1024)output.append(buffer,std::min<size_t>(n,2*1024*1024-output.size()));}
        auto waited=waitpid(pid,&status,WNOHANG);if(waited==pid)break;if(waited<0&&errno!=EINTR){failure="Unable to wait for FFmpeg";break;}
        if(!stopped&&(cancelled||Clock::now()>deadline)){failure=cancelled?"Cancelled":"FFmpeg timed out";kill(-pid,SIGTERM);stopped=true;deadline=Clock::now()+std::chrono::seconds(1);}
        else if(stopped&&Clock::now()>deadline){kill(-pid,SIGKILL);while(waitpid(pid,&status,0)<0&&errno==EINTR){}break;}
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
    char buffer[8192];ssize_t n;while((n=read(out[0],buffer,sizeof(buffer)))>0)if(output.size()<2*1024*1024)output.append(buffer,std::min<size_t>(n,2*1024*1024-output.size()));close(out[0]);
    if(!failure.empty())throw std::runtime_error(failure);
    if(!WIFEXITED(status)||WEXITSTATUS(status)!=0)throw std::runtime_error(output.empty()?"FFmpeg failed":output.substr(output.size()>2000?output.size()-2000:0));
    return output;
}
std::string identity(const fs::path& path){return Json::array({fs::canonical(path).string(),fs::file_size(path),fs::last_write_time(path).time_since_epoch().count(),"native-media-v1"}).dump();}
std::string digest(const std::string& value){boost::uuids::detail::sha1 hash;hash.process_bytes(value.data(),value.size());boost::uuids::detail::sha1::digest_type words;hash.get_digest(words);std::ostringstream result;result<<std::hex<<std::setfill('0');for(auto w:words)result<<std::setw(2*sizeof(w))<<static_cast<uint32_t>(w);return result.str();}
void atomicJson(const fs::path& file,const Json& data){auto temp=file;temp+=".tmp";{std::ofstream stream(temp);stream<<data.dump();stream.flush();if(!stream)throw std::runtime_error("Unable to write media cache");}fs::rename(temp,file);}
Json readJson(const fs::path& file){try{std::ifstream stream(file);Json value;stream>>value;return value;}catch(...){return Json();}}
int trackIndex(const std::string& track){if(track.empty()||track.size()>9||!std::all_of(track.begin(),track.end(),[](unsigned char c){return c>='0'&&c<='9';}))throw std::invalid_argument("Subtitle track must be a decimal stream index");return std::stoi(track);}
Json probe(const fs::path& file,const std::atomic<bool>& cancel){return Json::parse(run({"ffprobe","-v","error","-show_streams","-of","json","-protocol_whitelist","file,pipe",file.string()},12,cancel));}
Json tracksFrom(const Json& metadata){Json tracks=Json::array();int ordinal=0;for(auto& stream:metadata.value("streams",Json::array())){if(stream.value("codec_type","")!="subtitle")continue;int current=ordinal++;auto codec=stream.value("codec_name",std::string{});if(codec!="ass"&&codec!="ssa"&&codec!="subrip"&&codec!="srt"&&codec!="text"&&codec!="mov_text"&&codec!="webvtt")continue;auto tags=stream.value("tags",Json::object());auto language=tags.value("language",std::string{}),title=tags.value("title",std::string{});std::string upper=codec;for(auto& c:upper)c=std::toupper((unsigned char)c);std::string label;for(auto& v:{language,title,upper})if(!v.empty()){if(!label.empty())label+=" · ";label+=v;}auto disposition=stream.value("disposition",Json::object());if(disposition.value("forced",0))label+=" · forced";else if(disposition.value("default",0))label+=" · default";auto index=stream.at("index").get<int>();tracks.push_back({{"id",std::to_string(index)},{"stream_index",index},{"subtitle_ordinal",current},{"codec",codec},{"language",language},{"title",title},{"label",label}});}return tracks;}
Json idleStatus(){return {{"state","idle"},{"total",0},{"completed",0},{"processed",0},{"skipped",0},{"failed",0},{"currentFile",nullptr},{"errors",Json::array()},{"startedAt",nullptr},{"finishedAt",nullptr}};}
}
struct MediaProcessing::Impl {
    fs::path root;
    mutable std::mutex mutex;
    mutable std::map<std::string,Json> trackCache, renditionCache;
    std::map<std::string,Json> subtitleJobs;
    struct Subtitle {fs::path file;std::string track,key,fingerprint;};
    std::deque<Subtitle> subtitles;
    std::vector<fs::path> videos;
    Json status=idleStatus();
    std::condition_variable wake;
    std::atomic<bool> stop{false},cancel{false};
    std::atomic<std::uint64_t> revision{0};
    bool videoPending=false;
    std::thread subtitleWorker,videoWorker;
    explicit Impl(fs::path cache):root(std::move(cache)){fs::create_directories(root);subtitleWorker=std::thread([this]{subtitleLoop();});videoWorker=std::thread([this]{videoLoop();});}
    ~Impl(){stop=true;cancel=true;wake.notify_all();subtitleWorker.join();videoWorker.join();}
    fs::path subtitlePath(const fs::path& file,const std::string& track)const{return root/(digest(identity(file)+":"+std::to_string(trackIndex(track)))+".ass");}
    Json tracks(const fs::path& file)const{auto key=identity(file);{std::lock_guard lock(mutex);auto found=trackCache.find(key);if(found!=trackCache.end())return found->second;}auto value=tracksFrom(probe(file,stop));{std::lock_guard lock(mutex);if(trackCache.size()>=256)trackCache.clear();trackCache[key]=value;}return value;}
    Json renditions(const fs::path& file)const{auto fingerprint=identity(file);{std::lock_guard lock(mutex);auto found=renditionCache.find(fingerprint);if(found!=renditionCache.end()){bool valid=true;for(auto& item:found->second)if(!fs::is_regular_file(item.value("path",std::string{}))){valid=false;break;}if(valid)return found->second;renditionCache.erase(found);}}auto info=readJson(root/(digest(fingerprint)+".json"));Json list=Json::array();if(info.is_object()&&info.value("fingerprint","")==fingerprint)for(const auto& rendition:info.value("renditions",Json::array()))if(rendition.is_object()&&rendition.value("width",0)>0&&rendition.value("height",0)>0&&fs::is_regular_file(rendition.value("path",std::string{})))list.push_back(rendition);{std::lock_guard lock(mutex);if(renditionCache.size()>512)renditionCache.clear();renditionCache[fingerprint]=list;}return list;}
    void subtitleLoop(){for(;;){Subtitle job;{std::unique_lock lock(mutex);wake.wait(lock,[&]{return stop||!subtitles.empty();});if(stop)return;job=subtitles.front();subtitles.pop_front();subtitleJobs[job.key]["state"]="running";}
        auto destination=root/(job.key+".ass"),temp=root/(job.key+".tmp.ass");std::string error;
        try{bool supported=false;for(auto& t:tracks(job.file))if(t["id"]==job.track)supported=true;if(!supported)throw std::invalid_argument("Unsupported subtitle track");run({"ffmpeg","-nostdin","-hide_banner","-loglevel","error","-y","-protocol_whitelist","file,pipe","-i",job.file.string(),"-map","0:"+job.track,"-c:s","ass","-f","ass",temp.string()},30,stop);if(!fs::is_regular_file(temp)||fs::file_size(temp)==0)throw std::runtime_error("Subtitle extraction produced no data");if(identity(job.file)!=job.fingerprint)throw std::runtime_error("Video changed during subtitle extraction");fs::rename(temp,destination);}catch(const std::exception& e){error=e.what();std::error_code ignored;fs::remove(temp,ignored);}
        {std::lock_guard lock(mutex);subtitleJobs[job.key]["state"]=error.empty()?"completed":"failed";if(!error.empty())subtitleJobs[job.key]["error"]=error;else subtitleJobs[job.key]["asset"]=destination.string();++revision;}
    }}
    bool process(const fs::path& file){auto fingerprint=identity(file),key=digest(fingerprint);auto existing=readJson(root/(key+".json"));if(existing.is_object()&&existing.value("complete",false)&&!renditions(file).empty()&&renditions(file).size()==existing.value("renditions",Json::array()).size())return false;
        auto source=probe(file,cancel);int width=0,height=0;for(auto& s:source.at("streams"))if(s.value("codec_type","")=="video"){width=s.value("width",0);height=s.value("height",0);break;}if(width<=0||height<=0)throw std::runtime_error("No video stream");
        Json results=Json::array();for(auto [w,h]:{std::pair{960,540},std::pair{1920,1080}}){auto destination=root/(key+"-"+std::to_string(h)+"p.mp4"),temp=root/(key+"-"+std::to_string(h)+"p.tmp.mp4");try{
            auto scale="scale=w='min(iw,"+std::to_string(w)+")':h='min(ih,"+std::to_string(h)+")':force_original_aspect_ratio=decrease:force_divisible_by=2,fps=30";
            run({"ffmpeg","-nostdin","-hide_banner","-loglevel","error","-y","-threads","2","-protocol_whitelist","file,pipe","-i",file.string(),"-filter_threads","1","-map","0:v:0","-map","0:a:0?","-vf",scale,"-c:v","libx264","-threads","2","-preset","veryfast","-crf","20","-profile:v","high","-level:v","4.1","-pix_fmt","yuv420p","-g","30","-keyint_min","30","-sc_threshold","0","-c:a","aac","-b:a","160k","-movflags","+faststart",temp.string()},7200,cancel);
            auto output=probe(temp,cancel);int ow=0,oh=0;for(auto& stream:output.at("streams"))if(stream.value("codec_type","")=="video"){ow=stream.value("width",0);oh=stream.value("height",0);break;}if(ow<=0||oh<=0)throw std::runtime_error("Invalid proxy output");if(identity(file)!=fingerprint)throw std::runtime_error("Video changed during preprocessing");fs::rename(temp,destination);results.push_back({{"path",destination.string()},{"width",ow},{"height",oh},{"codec","h264"}});
        }catch(...){std::error_code ignored;fs::remove(temp,ignored);throw;}if(width<=w&&height<=h)break;}
        atomicJson(root/(key+".json"),{{"fingerprint",fingerprint},{"complete",true},{"renditions",results}});{std::lock_guard lock(mutex);renditionCache[fingerprint]=results;}++revision;return true;
    }
    void videoLoop(){for(;;){std::vector<fs::path> work;{std::unique_lock lock(mutex);wake.wait(lock,[&]{return stop||videoPending;});if(stop)return;videoPending=false;work=videos;}
        for(auto& file:work){if(cancel||stop)break;{std::lock_guard lock(mutex);status["currentFile"]=file.string();}bool processed=false;std::string error;try{processed=process(file);}catch(const std::exception& e){error=e.what();}if(cancel||stop)break;{std::lock_guard lock(mutex);status["completed"]=status["completed"].get<int>()+1;auto count=error.empty()?(processed?"processed":"skipped"):"failed";status[count]=status[count].get<int>()+1;if(!error.empty()&&status["errors"].size()<100)status["errors"].push_back({{"file",file.string()},{"error",error}});}}
        {std::lock_guard lock(mutex);status["state"]=(cancel||stop)?"interrupted":(status["failed"].get<int>()?"completed_with_errors":"completed");status["currentFile"]=nullptr;status["finishedAt"]=now();++revision;}
    }}
};
MediaProcessing::MediaProcessing(fs::path root):impl_(std::make_unique<Impl>(std::move(root))){}
MediaProcessing::~MediaProcessing()=default;
MediaProcessing::Json MediaProcessing::subtitleTracks(const fs::path& file)const{auto result=impl_->tracks(file);for(auto& track:result)track["ready"]=!subtitleAsset(file,track["id"]).empty();return result;}
MediaProcessing::Json MediaProcessing::prepareSubtitle(const fs::path& file,const std::string& track,bool retry){auto normalized=std::to_string(trackIndex(track));auto fingerprint=identity(file),key=digest(fingerprint+":"+normalized);auto asset=subtitleAsset(file,normalized);if(!asset.empty())return {{"state","completed"},{"asset",asset},{"track",normalized}};std::lock_guard lock(impl_->mutex);auto found=impl_->subtitleJobs.find(key);if(found!=impl_->subtitleJobs.end()){if(retry&&found->second["state"]=="failed")impl_->subtitleJobs.erase(found);else return found->second;}if(impl_->subtitles.size()>=64)throw std::runtime_error("Subtitle preparation queue is full");if(impl_->subtitleJobs.size()>512){for(auto it=impl_->subtitleJobs.begin();it!=impl_->subtitleJobs.end();)if(it->second["state"]=="completed"||it->second["state"]=="failed")it=impl_->subtitleJobs.erase(it);else ++it;}Json state={{"state","queued"},{"file",file.string()},{"track",normalized}};impl_->subtitleJobs[key]=state;impl_->subtitles.push_back({file,normalized,key,fingerprint});impl_->wake.notify_all();return state;}
std::string MediaProcessing::subtitleAsset(const fs::path& file,const std::string& track)const{if(track.empty())return {};try{auto path=impl_->subtitlePath(file,track);return fs::is_regular_file(path)&&fs::file_size(path)>0?path.string():std::string{};}catch(...){return {};}}
MediaProcessing::Json MediaProcessing::renditions(const fs::path& file)const{try{return impl_->renditions(file);}catch(...){return Json::array();}}
MediaProcessing::Json MediaProcessing::startPreprocess(const std::vector<fs::path>& files){std::lock_guard lock(impl_->mutex);if(impl_->status["state"]=="running")return impl_->status;executable("ffmpeg");executable("ffprobe");impl_->status=idleStatus();impl_->status["state"]="running";impl_->status["total"]=files.size();impl_->status["startedAt"]=now();impl_->videos=files;impl_->cancel=false;impl_->videoPending=true;impl_->wake.notify_all();return impl_->status;}
MediaProcessing::Json MediaProcessing::cancelPreprocess(){impl_->cancel=true;return preprocessStatus();}
MediaProcessing::Json MediaProcessing::preprocessStatus()const{std::lock_guard lock(impl_->mutex);return impl_->status;}
MediaProcessing::Json MediaProcessing::subtitleStatus()const{std::lock_guard lock(impl_->mutex);Json jobs=Json::array();for(auto& [key,value]:impl_->subtitleJobs)jobs.push_back(value);return {{"jobs",jobs},{"revision",impl_->revision.load()}};}
std::uint64_t MediaProcessing::revision()const{return impl_->revision;}
}
