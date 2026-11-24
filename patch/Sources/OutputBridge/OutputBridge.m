#import "OutputBridge.h"
#import <dlfcn.h>
#import <limits.h>
#import <os/lock.h>

// Runtime-loaded to allow editing projects even when external outputs are unavailable.
@protocol SyphonMetalAPI
- (id)initWithName:(NSString *)name device:(id<MTLDevice>)device options:(NSDictionary *)options;
- (void)publishFrameTexture:(id<MTLTexture>)texture onCommandBuffer:(id<MTLCommandBuffer>)buffer imageRegion:(NSRect)region flipped:(BOOL)flipped;
- (void)stop;
- (NSDictionary *)serverDescription;
@end
static Class syphonClass(void) {
    static Class cls; static dispatch_once_t once;
    dispatch_once(&once, ^{
        cls = NSClassFromString(@"SyphonMetalServer");
        if (cls) return; // The host may already link the complete shared Syphon framework.
        NSArray *paths = @[
            [[[NSBundle mainBundle] privateFrameworksPath] stringByAppendingPathComponent:@"Syphon.framework"],
            @"/Library/Frameworks/Syphon.framework",
            [[[NSProcessInfo processInfo] environment][@"PATCH_SYPHON_FRAMEWORK"] stringByStandardizingPath] ?: @""
        ];
        for (NSString *path in paths) {
            if ([[NSBundle bundleWithPath:path] load]) { cls = NSClassFromString(@"SyphonMetalServer"); if (cls) break; }
        }
    });
    return cls;
}
@implementation PatchSyphon { id<SyphonMetalAPI> _server; }
+ (BOOL)available { return syphonClass() != Nil; }
- (instancetype)initWithName:(NSString *)name device:(id<MTLDevice>)device {
    self = [super init]; if (self) { _server = [[syphonClass() alloc] initWithName:name device:device options:nil]; if (!_server) return nil; } return self;
}
- (NSDictionary *)selection { NSDictionary *d=[_server serverDescription];return @{@"app":d[@"SyphonServerDescriptionAppNameKey"]?:@"",@"name":d[@"SyphonServerDescriptionNameKey"]?:@"",@"uuid":d[@"SyphonServerDescriptionUUIDKey"]?:@""}; }
- (void)publish:(id<MTLTexture>)texture commandBuffer:(id<MTLCommandBuffer>)buffer {
    // Patch textures have row zero at the top. Syphon's shared surface uses
    // bottom-origin rows for OpenGL clients, so convert at the publish boundary.
    [_server publishFrameTexture:texture onCommandBuffer:buffer imageRegion:NSMakeRect(0, 0, texture.width, texture.height) flipped:YES];
}
- (void)dealloc { [_server stop]; }
@end

// ABI for NDI's documented C send API (video_frame_v2 and send_create).
typedef struct { const char *name, *groups; bool clockVideo, clockAudio; } SendSettings;
typedef struct {
    int width, height; uint32_t fourCC; int numerator, denominator; float aspect; int format;
    int64_t timecode; uint8_t *data; int stride; const char *metadata; int64_t timestamp;
} VideoFrame;
static void *(*createSender)(const SendSettings *);
static void (*destroySender)(void *);
static void (*sendVideo)(void *, const VideoFrame *);
static BOOL loadNDI(void) {
    static BOOL ready; static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *custom = [NSProcessInfo processInfo].environment[@"NDI_RUNTIME_DIR_V6"] ?: [NSProcessInfo processInfo].environment[@"NDI_RUNTIME_DIR_V5"];
        NSArray *paths = @[
            custom ? [custom stringByAppendingPathComponent:@"libndi.dylib"] : @"",
            [[[NSBundle mainBundle] privateFrameworksPath] stringByAppendingPathComponent:@"libndi.dylib"],
            @"/usr/local/lib/libndi.dylib", @"/Library/NDI SDK for Apple/lib/macOS/libndi.dylib",
            @"/Applications/NDI Video Monitor.app/Contents/Frameworks/libndi.dylib",
            @"/Applications/TouchDesigner.app/Contents/Frameworks/libndi.dylib"
        ];
        for (NSString *path in paths) {
            void *lib = dlopen(path.UTF8String, RTLD_LOCAL | RTLD_NOW);
            if (!lib) continue;
            bool (*initialize)(void) = dlsym(lib, "NDIlib_initialize");
            createSender = dlsym(lib, "NDIlib_send_create");
            destroySender = dlsym(lib, "NDIlib_send_destroy");
            sendVideo = dlsym(lib, "NDIlib_send_send_video_v2");
            if (initialize && createSender && destroySender && sendVideo && initialize()) { ready = YES; break; }
            dlclose(lib);
        }
    }); return ready;
}
@implementation PatchNDI { void *_sender; }
+ (BOOL)available { return loadNDI(); }
- (instancetype)initWithName:(NSString *)name {
    self = [super init]; if (self) {
        if (!loadNDI()) return nil;
        SendSettings settings = { name.UTF8String, NULL, false, false };
        _sender = createSender(&settings); if (!_sender) return nil;
    } return self;
}
- (void)sendBytes:(const void *)bytes width:(int)width height:(int)height stride:(int)stride fps:(int)fps {
    VideoFrame frame = { width, height, 0x41524742, fps, 1, (float)width / height, 1, INT64_MAX, (uint8_t *)bytes, stride, NULL, 0 };
    sendVideo(_sender, &frame);
}
- (void)dealloc { if (_sender) destroySender(_sender); }
@end

// ABI for NDI's documented C find/receive API (find_create_v2, recv_create_v3, recv_capture_v2).
typedef struct { const char *name, *url; } NDISource;
typedef struct { bool showLocalSources; const char *groups, *extraIPs; } FindSettings;
typedef struct { NDISource source; int colorFormat; int bandwidth; bool allowVideoFields; const char *receiverName; } ReceiveSettings;
enum { ColorBGRXBGRA = 0, BandwidthHighest = 100, FrameVideo = 1, FrameError = 4 };
static const uint32_t FourCCBGRA = 0x41524742, FourCCBGRX = 0x58524742;
static void *(*createFinder)(const FindSettings *);
static void (*destroyFinder)(void *);
static bool (*waitForSources)(void *, uint32_t);
static const NDISource *(*currentSources)(void *, uint32_t *);
static void *(*createReceiver)(const ReceiveSettings *);
static void (*destroyReceiver)(void *);
static void (*connectReceiver)(void *, const NDISource *);
static int (*captureFrame)(void *, VideoFrame *, void *, void *, uint32_t);
static void (*freeVideo)(void *, const VideoFrame *);
static int (*connectionCount)(void *);
static BOOL loadNDIReceive(void) {
    static BOOL ready; static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!loadNDI()) return;
        // loadNDI keeps its library loaded; this handle only resolves the receive symbols.
        Dl_info info; if (!dladdr((const void *)sendVideo, &info)) return;
        void *lib = dlopen(info.dli_fname, RTLD_LOCAL | RTLD_NOW); if (!lib) return;
        createFinder = dlsym(lib, "NDIlib_find_create_v2"); destroyFinder = dlsym(lib, "NDIlib_find_destroy");
        waitForSources = dlsym(lib, "NDIlib_find_wait_for_sources"); currentSources = dlsym(lib, "NDIlib_find_get_current_sources");
        createReceiver = dlsym(lib, "NDIlib_recv_create_v3"); destroyReceiver = dlsym(lib, "NDIlib_recv_destroy");
        connectReceiver = dlsym(lib, "NDIlib_recv_connect"); captureFrame = dlsym(lib, "NDIlib_recv_capture_v2");
        freeVideo = dlsym(lib, "NDIlib_recv_free_video_v2"); connectionCount = dlsym(lib, "NDIlib_recv_get_no_connections");
        ready = createFinder && destroyFinder && waitForSources && currentSources && createReceiver && destroyReceiver
            && connectReceiver && captureFrame && freeVideo && connectionCount;
    }); return ready;
}

// Shared by the receiver object and its worker thread, so the worker never retains the receiver.
@interface PatchNDIReceiveState : NSObject
@property(atomic) BOOL stop;
@property(atomic, copy) NSString *status;
@end
@implementation PatchNDIReceiveState { @public os_unfair_lock lock; CVPixelBufferRef latest; }
- (void)dealloc { if (latest) CVPixelBufferRelease(latest); }
@end

@implementation PatchNDIReceiver { PatchNDIReceiveState *_state; }
+ (BOOL)available { return loadNDIReceive(); }
+ (NSArray<NSString *> *)sources {
    static void *finder; static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    if (!loadNDIReceive()) return @[];
    os_unfair_lock_lock(&lock);
    if (!finder) { FindSettings settings = { true, NULL, NULL }; finder = createFinder(&settings); }
    NSMutableArray *names = [NSMutableArray array];
    uint32_t count = 0; const NDISource *found = finder ? currentSources(finder, &count) : NULL;
    for (uint32_t i = 0; i < count; i++) if (found[i].name) [names addObject:@(found[i].name)];
    os_unfair_lock_unlock(&lock);
    return [names sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
}
- (instancetype)initWithSource:(NSString *)source {
    self = [super init]; if (!self) return nil;
    if (!loadNDIReceive() || source.length == 0) return nil;
    _source = [source copy]; _state = [PatchNDIReceiveState new]; _state->lock = OS_UNFAIR_LOCK_INIT; _state.status = @"Connecting";
    PatchNDIReceiveState *state = _state; NSString *name = _source;
    NSThread *thread = [[NSThread alloc] initWithBlock:^{ [PatchNDIReceiver run:state source:name]; }];
    thread.name = @"Patch NDI In"; thread.qualityOfService = NSQualityOfServiceUserInteractive; [thread start];
    return self;
}
- (NSString *)status { return _state.status; }
- (CVPixelBufferRef)copyNewFrame {
    os_unfair_lock_lock(&_state->lock); CVPixelBufferRef frame = _state->latest; _state->latest = NULL; os_unfair_lock_unlock(&_state->lock);
    return frame;
}
- (void)dealloc { _state.stop = YES; }
+ (void)run:(PatchNDIReceiveState *)state source:(NSString *)name {
    FindSettings findSettings = { true, NULL, NULL };
    void *finder = createFinder(&findSettings);
    ReceiveSettings settings = { { name.UTF8String, NULL }, ColorBGRXBGRA, BandwidthHighest, false, "Patch NDI In" };
    void *receiver = createReceiver(&settings);
    if (!receiver) { state.status = @"NDI receiver unavailable"; if (finder) destroyFinder(finder); return; }
    NSDictionary *attributes = @{ (id)kCVPixelBufferMetalCompatibilityKey: @YES, (id)kCVPixelBufferIOSurfacePropertiesKey: @{} };
    CVPixelBufferPoolRef pool = NULL; int poolWidth = 0, poolHeight = 0;
    NSString *url = nil; CFAbsoluteTime rediscover = 0;
    while (!state.stop) {
        // Follow the named source when its address changes, as VJ's NDI input does.
        if (finder && CFAbsoluteTimeGetCurrent() >= rediscover) {
            rediscover = CFAbsoluteTimeGetCurrent() + 1;
            uint32_t count = 0; const NDISource *found = currentSources(finder, &count);
            for (uint32_t i = 0; i < count; i++) if (found[i].name && [name isEqualToString:@(found[i].name)]) {
                NSString *current = found[i].url ? @(found[i].url) : @"";
                if (![current isEqualToString:url ?: @""]) { connectReceiver(receiver, &found[i]); url = current; }
                break;
            }
        }
        VideoFrame video = {0};
        int type = captureFrame(receiver, &video, NULL, NULL, 100);
        if (type == FrameVideo) {
            if (!video.data || video.width <= 0 || video.height <= 0 || video.width > 16384 || video.height > 16384
                || video.stride < video.width * 4 || (video.fourCC != FourCCBGRA && video.fourCC != FourCCBGRX)) {
                state.status = @"Unsupported NDI frame"; freeVideo(receiver, &video); continue;
            }
            if (!pool || poolWidth != video.width || poolHeight != video.height) {
                if (pool) CVPixelBufferPoolRelease(pool); pool = NULL;
                NSMutableDictionary *pixel = [attributes mutableCopy];
                pixel[(id)kCVPixelBufferPixelFormatTypeKey] = @(kCVPixelFormatType_32BGRA);
                pixel[(id)kCVPixelBufferWidthKey] = @(video.width); pixel[(id)kCVPixelBufferHeightKey] = @(video.height);
                CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)pixel, &pool); poolWidth = video.width; poolHeight = video.height;
            }
            CVPixelBufferRef buffer = NULL;
            if (pool && CVPixelBufferPoolCreatePixelBuffer(NULL, pool, &buffer) == kCVReturnSuccess) {
                CVPixelBufferLockBaseAddress(buffer, 0);
                uint8_t *destination = CVPixelBufferGetBaseAddress(buffer); size_t stride = CVPixelBufferGetBytesPerRow(buffer), row = (size_t)video.width * 4;
                for (int y = 0; y < video.height; y++) {
                    uint8_t *out = destination + y * stride; memcpy(out, video.data + (size_t)y * video.stride, row);
                    if (video.fourCC == FourCCBGRX) for (size_t x = 3; x < row; x += 4) out[x] = 255;
                }
                CVPixelBufferUnlockBaseAddress(buffer, 0);
                os_unfair_lock_lock(&state->lock); if (state->latest) CVPixelBufferRelease(state->latest); state->latest = buffer; os_unfair_lock_unlock(&state->lock);
                double fps = video.denominator > 0 ? (double)video.numerator / video.denominator : 0;
                state.status = [NSString stringWithFormat:@"Receiving %d×%d · %.4g fps", video.width, video.height, fps];
            }
            freeVideo(receiver, &video);
        } else if (type == FrameError) state.status = @"NDI receive error";
        else if (connectionCount(receiver) == 0) state.status = [NSString stringWithFormat:@"Waiting for %@", name];
    }
    if (pool) CVPixelBufferPoolRelease(pool);
    destroyReceiver(receiver); if (finder) destroyFinder(finder);
}
@end
