#import "show_library.hpp"
#include <nlohmann/json.hpp>
#include <fstream>
#include <fcntl.h>
#include <sys/file.h>
#include <unistd.h>
namespace fs=std::filesystem;
using Json=nlohmann::json;
static NSString* const lastShowKey=@"VJLastShow";
// Machine-local files, skipped when a show is copied.
static NSArray<NSString*>* const runtimeFiles=@[@"native.lock",@"native-state.json.bak",@"ndi-clients.json",@"thumbnail-cache",@"media-cache",@"media-processing",@"text-cache"];

namespace vj::shows {
fs::path library(){
    if(const char* configured=std::getenv("VJ_SHOWS_DIRECTORY");configured&&*configured)return fs::weakly_canonical(configured);
    return fs::weakly_canonical(fs::path(NSHomeDirectory().fileSystemRepresentation)/"Projection3000/VJ/Shows");
}
bool inLibrary(const fs::path& root){std::error_code error;return fs::equivalent(fs::weakly_canonical(root).parent_path(),library(),error);}
fs::path startupRoot(){
    NSString* last=[NSUserDefaults.standardUserDefaults stringForKey:lastShowKey];
    if(last&&fs::is_directory(last.fileSystemRepresentation))return last.fileSystemRepresentation;
    if(fs::is_directory(library()/"Default"))return library()/"Default";
    return fs::path(NSHomeDirectory().fileSystemRepresentation)/"Library/Application Support/VJ Native Development";
}
void remember(const fs::path& root){[NSUserDefaults.standardUserDefaults setObject:@(fs::weakly_canonical(root).c_str()) forKey:lastShowKey];}

static std::vector<fs::path> candidates(const fs::path& root,const fs::path& missing){
    std::vector<fs::path> parts(missing.begin(),missing.end()),found;auto repo=library().parent_path().parent_path();
    auto tail=[&](size_t from){fs::path p;for(size_t i=from;i<parts.size();++i)p/=parts[i];return p;};
    // Show-relative first (media moved with the show), longest suffix wins; one component is too ambiguous.
    for(size_t i=1;i+2<=parts.size();++i)found.push_back(root/tail(i));
    for(size_t i=1;i<parts.size();++i)if(parts[i]==repo.filename())found.push_back(repo/tail(i+1));
    if(parts.size()>3&&parts[1]=="Users")found.push_back(fs::path(NSHomeDirectory().fileSystemRepresentation)/tail(3));
    return found;
}
static bool relocateStrings(Json& value,const fs::path& root){
    bool changed=false;
    if(value.is_object()||value.is_array()){for(auto& child:value)changed|=relocateStrings(child,root);return changed;}
    if(!value.is_string())return false;
    const auto& text=value.get_ref<const std::string&>();std::error_code error;
    if(text.size()<2||text[0]!='/'||text.find('\n')!=std::string::npos||fs::exists(text,error))return false;
    for(const auto& candidate:candidates(root,text))if(fs::is_regular_file(candidate,error)){value=candidate.string();return true;}
    return false;
}
void relocate(const fs::path& root){
    for(const auto* name:{"native-state.json","Patch/session.json"}){
        auto path=root/name;std::ifstream in(path);if(!in)continue;
        Json document=Json::parse(in,nullptr,false);in.close();if(document.is_discarded()||!relocateStrings(document,root))continue;
        auto temp=path;temp+=".relocate";{std::ofstream out(temp);out<<document.dump(2)<<'\n';if(!out.good())continue;}
        fs::rename(temp,path);NSLog(@"Relocated missing file paths in %s",path.c_str());
    }
}
}

static bool inUse(const fs::path& root){
    int fd=::open((root/"native.lock").c_str(),O_RDONLY);if(fd<0)return false;
    bool busy=::flock(fd,LOCK_SH|LOCK_NB)!=0;::close(fd);return busy;
}
static NSString* nameOf(const fs::path& root){return @(root.filename().c_str());}

@implementation VJShowLibraryPicker {fs::path _root;NSArray<NSString*>* _relaunch;}
- (instancetype)initWithRoot:(fs::path)root {
    if((self=[super initWithFrame:NSZeroRect pullsDown:NO])){_root=fs::weakly_canonical(root);self.target=self;self.action=@selector(choose:);self.toolTip=[NSString stringWithFormat:@"Show · everything in VJ belongs to it. Shows are stored in %s",vj::shows::library().c_str()];[self reload];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(willTerminate:) name:NSApplicationWillTerminateNotification object:nil];}
    return self;
}
- (void)reload {
    [self removeAllItems];std::vector<fs::path> shows;std::error_code error;
    for(const auto& entry:fs::directory_iterator(vj::shows::library(),error))if(entry.is_directory()&&entry.path().filename().string()[0]!='.')shows.push_back(fs::weakly_canonical(entry.path()));
    std::sort(shows.begin(),shows.end(),[](const auto& a,const auto& b){return [nameOf(a) localizedStandardCompare:nameOf(b)]==NSOrderedAscending;});
    if(std::find(shows.begin(),shows.end(),_root)==shows.end())shows.insert(shows.begin(),_root);
    for(const auto& show:shows){
        bool current=show==_root,busy=!current&&inUse(show);
        [self addItemWithTitle:busy?[nameOf(show) stringByAppendingString:@" · open in another VJ"]:nameOf(show)];
        self.lastItem.representedObject=@(show.c_str());self.lastItem.enabled=!busy;if(current)[self selectItem:self.lastItem];
    }
    [self.menu addItem:NSMenuItem.separatorItem];
    for(NSArray* spec in @[@[@"New Show…",@"new"],@[@"Duplicate Show…",@"duplicate"],@[@"Export Patch Show…",@"convert"],@[@"Show in Finder",@"finder"]]){[self addItemWithTitle:spec[0]];self.lastItem.representedObject=spec[1];}
    [self invalidateIntrinsicContentSize];
}
- (void)mouseDown:(NSEvent*)event {[self reload];[super mouseDown:event];}
- (void)performClick:(id)sender {[self reload];[super performClick:sender];}
- (void)choose:(id)sender {
    (void)sender;NSString* choice=self.selectedItem.representedObject;[self reload];
    if([choice isEqualToString:@"convert"]){[self exportPatchShow];return;}
    if([choice isEqualToString:@"finder"]){[NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:@(_root.c_str())]]];return;}
    if([choice isEqualToString:@"new"]||[choice isEqualToString:@"duplicate"]){[self create:[choice isEqualToString:@"duplicate"]];return;}
    if(!choice||fs::path(choice.fileSystemRepresentation)==_root)return;
    auto alert=[[NSAlert alloc]init];alert.messageText=[NSString stringWithFormat:@"Open “%@”?",nameOf(choice.fileSystemRepresentation)];
    alert.informativeText=[NSString stringWithFormat:@"VJ saves “%@” and reopens on “%@”. Outputs go dark for a few seconds.",nameOf(_root),nameOf(choice.fileSystemRepresentation)];
    [alert addButtonWithTitle:@"Open"];[alert addButtonWithTitle:@"Cancel"];
    if([alert runModal]==NSAlertFirstButtonReturn)[self reopen:choice copyFrom:nil];
}
- (void)exportPatchShow {
    auto panel=[NSSavePanel savePanel];
    panel.title=@"Export Patch Show";
    panel.nameFieldStringValue=[nameOf(_root) stringByAppendingString:@" Patch"];
    panel.directoryURL=[NSURL fileURLWithPath:@(vj::shows::library().c_str())];
    if([panel runModal]!=NSModalResponseOK)return;
    auto task=[NSTask new];
    task.executableURL=[NSBundle.mainBundle.bundleURL URLByAppendingPathComponent:@"Contents/Helpers/patch-migrate"];
    task.arguments=@[@"compose",@((_root/"native-state.json").c_str()),@((_root/"Patch/session.json").c_str()),
                     [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"Subpatches"],panel.URL.path];
    auto errors=[NSPipe pipe];
    task.standardError=errors;
    NSURL* destination=panel.URL;
    task.terminationHandler=^(NSTask* finished){
        NSData* message=[errors.fileHandleForReading readDataToEndOfFile];
        dispatch_async(dispatch_get_main_queue(),^{
            if(finished.terminationStatus==0){
                [self reload];
                [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[destination]];
            }else{
                auto alert=[NSAlert new];alert.messageText=@"Show export failed";
                alert.informativeText=[[NSString alloc]initWithData:message encoding:NSUTF8StringEncoding]?:@"";
                [alert beginSheetModalForWindow:self.window completionHandler:nil];
            }
        });
    };
    NSError* error=nil;
    if(![task launchAndReturnError:&error])[[NSAlert alertWithError:error] beginSheetModalForWindow:self.window completionHandler:nil];
}
- (void)create:(BOOL)duplicate {
    auto alert=[[NSAlert alloc]init];alert.messageText=duplicate?@"Duplicate show":@"New show";
    alert.informativeText=[NSString stringWithFormat:@"VJ saves “%@” and reopens on the %@ show.",nameOf(_root),duplicate?@"copied":@"new"];
    auto field=[[NSTextField alloc]initWithFrame:NSMakeRect(0,0,260,24)];field.stringValue=duplicate?[nameOf(_root) stringByAppendingString:@" copy"]:@"";field.placeholderString=@"Show name";alert.accessoryView=field;alert.window.initialFirstResponder=field;
    [alert addButtonWithTitle:duplicate?@"Duplicate":@"Create"];[alert addButtonWithTitle:@"Cancel"];
    if([alert runModal]!=NSAlertFirstButtonReturn)return;
    NSString* name=[field.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];auto target=vj::shows::library()/name.fileSystemRepresentation;
    NSString* problem=!name.length||[name hasPrefix:@"."]||[name containsString:@"/"]||[name containsString:@":"]?@"Use a name without “/”, “:” or a leading dot.":fs::exists(target)?@"A show with that name already exists.":nil;
    if(problem){auto error=[[NSAlert alloc]init];error.messageText=@"Can't use that name";error.informativeText=problem;[error runModal];return;}
    if(!duplicate){std::error_code error;fs::create_directories(target,error);}
    [self reopen:@(target.c_str()) copyFrom:duplicate?@(_root.c_str()):nil];
}
// Relaunch once this process has exited and released the show lock; a duplicate is copied
// then too, so it captures the state saved on quit.
- (void)reopen:(NSString*)target copyFrom:(NSString*)source {
    vj::shows::remember(target.fileSystemRepresentation);
    _relaunch=@[target,source?:@""];[NSApp terminate:nil];
}
- (void)willTerminate:(NSNotification*)notification {
    (void)notification;if(!_relaunch)return;
    NSMutableString* clean=[NSMutableString string];for(NSString* name in runtimeFiles)[clean appendFormat:@" \"$3/%@\"",name];
    NSString* script=[NSString stringWithFormat:@"while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; if [ -n \"$4\" ]; then /usr/bin/ditto \"$4\" \"$3\" && rm -rf%@; fi; exec /usr/bin/open -n \"$2\" --args --state-root \"$3\"",clean];
    auto task=[[NSTask alloc]init];task.executableURL=[NSURL fileURLWithPath:@"/bin/sh"];
    task.arguments=@[@"-c",script,@"sh",@(getpid()).stringValue,NSBundle.mainBundle.bundlePath,_relaunch[0],_relaunch[1]];
    NSError* error=nil;if(![task launchAndReturnError:&error])NSLog(@"Show relaunch failed: %@",error);
}
@end
