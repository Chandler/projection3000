#include "syphon_input.hpp"
#import <Cocoa/Cocoa.h>
#import <OpenGL/gl3.h>
#import <Syphon/SyphonOpenGLClient.h>
#import <Syphon/SyphonOpenGLImage.h>
#import <Syphon/SyphonServerDirectory.h>
#include <chrono>
#include <mutex>

using Json = nlohmann::json;
static std::string utf8(NSString *value) { return value ? value.UTF8String : ""; }
static SyphonServerDirectory *directory() {
    // A fresh directory asks senders to announce themselves. Rotating snapshots
    // also detects crashed senders that cannot publish a retirement notice.
    // Do not infer disconnect from frame age: a valid sender may be paused.
    struct DirectoryState {SyphonServerDirectory* active=[[SyphonServerDirectory alloc]init];SyphonServerDirectory* pending=nil;std::chrono::steady_clock::time_point next=std::chrono::steady_clock::now()+std::chrono::seconds(3),ready;};
    // Syphon protects its server snapshots internally. Share discovery across
    // render queues: a serial GCD queue may migrate between worker threads.
    static DirectoryState shared;static std::mutex mutex;std::lock_guard lock(mutex);
    auto& active=shared.active;auto& pending=shared.pending;auto& next=shared.next;auto& ready=shared.ready;
    const auto now = std::chrono::steady_clock::now();
    if (pending && now >= ready) { active = pending; pending = nil; }
    if (!pending && now >= next) {
        pending = [[SyphonServerDirectory alloc] init];
        ready = now + std::chrono::milliseconds(700);
        next = now + std::chrono::seconds(3);
    }
    return active;
}
void syphon_poll() {
    @autoreleasepool {
        directory();
        // Service distributed discovery notifications without waiting for IO.
        for (int i = 0; i < 8; ++i)
            if (![[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate date]]) break;
    }
}
Json syphon_sources() {
    @autoreleasepool {
        Json result = Json::array();
        for (NSDictionary *item in directory().servers) {
            const auto app = utf8(item[SyphonServerDescriptionAppNameKey]);
            const auto name = utf8(item[SyphonServerDescriptionNameKey]);
            const auto uuid = utf8(item[SyphonServerDescriptionUUIDKey]);
            result.push_back({{"app", app}, {"name", name}, {"uuid", uuid},
                {"label", app + (name.empty() ? "" : " — " + name)},
                {"selection", Json({{"app", app}, {"name", name}, {"uuid", uuid}}).dump()}});
        }
        return result;
    }
}
struct SyphonInput::State {
    Json selection;
    SyphonOpenGLClient *client = nil;
    GLuint read_fbo = 0, draw_fbo = 0;
    bool online = false;
    std::string error = "Source offline";
    std::chrono::steady_clock::time_point retry{};
};
SyphonInput::SyphonInput(const std::string &selection) : state_(std::make_unique<State>()) {
    state_->selection = Json::parse(selection, nullptr, false);
}
SyphonInput::~SyphonInput() {
    @autoreleasepool {
        [state_->client stop];
        state_->client = nil;
        if (state_->read_fbo) glDeleteFramebuffers(1, &state_->read_fbo);
        if (state_->draw_fbo) glDeleteFramebuffers(1, &state_->draw_fbo);
    }
}
bool SyphonInput::connected() const { return state_->online; }
std::string SyphonInput::error() const { return state_->error; }
bool SyphonInput::update(unsigned int destination, int &width, int &height) {
    @autoreleasepool {
        auto &s = *state_;
        if (!s.selection.is_object()
            || !s.selection.value("app", Json("")).is_string()
            || !s.selection.value("name", Json("")).is_string()
            || !s.selection.value("uuid", Json("")).is_string()) {
            s.error = "Invalid Syphon source"; return false;
        }
        bool advertised = false;
        if (s.client) {
            NSString *uuid = s.client.serverDescription[SyphonServerDescriptionUUIDKey];
            for (NSDictionary *item in directory().servers)
                if ([uuid isEqual:item[SyphonServerDescriptionUUIDKey]]) { advertised = true; break; }
        }
        if (s.client && (!s.client.isValid || !advertised)) {
            [s.client stop]; s.client = nil; s.online = false;
            s.error = "Source offline";
        }
        if (!s.client) {
            const auto now = std::chrono::steady_clock::now();
            if (now < s.retry) return false;
            s.retry = now + std::chrono::milliseconds(500);
            NSDictionary *match = nil;
            NSMutableArray *named = [NSMutableArray array];
            for (NSDictionary *item in directory().servers) {
                if (utf8(item[SyphonServerDescriptionUUIDKey]) == s.selection.value("uuid", "")) {
                    match = item; break;
                }
                if (utf8(item[SyphonServerDescriptionAppNameKey]) == s.selection.value("app", "")
                    && utf8(item[SyphonServerDescriptionNameKey]) == s.selection.value("name", ""))
                    [named addObject:item];
            }
            if (!match && named.count == 1) match = named.firstObject;
            if (!match) { s.error = named.count > 1 ? "Ambiguous source name" : "Source offline"; return false; }
            s.client = [[SyphonOpenGLClient alloc] initWithServerDescription:match
                context:CGLGetCurrentContext() options:nil newFrameHandler:nil];
            s.error = "Waiting for frames";
        }
        s.online = s.client.isValid;
        if (!s.online || !s.client.hasNewFrame) return false;
        SyphonOpenGLImage *frame = [s.client newFrameImage];
        if (!frame) return false;
        const int w = frame.textureSize.width, h = frame.textureSize.height;
        if (w <= 0 || h <= 0) return false;
        GLint old_read, old_draw, old_texture;
        glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &old_read);
        glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &old_draw);
        glGetIntegerv(GL_TEXTURE_BINDING_2D, &old_texture);
        if (!s.read_fbo) glGenFramebuffers(1, &s.read_fbo);
        if (!s.draw_fbo) glGenFramebuffers(1, &s.draw_fbo);
        glBindTexture(GL_TEXTURE_2D, destination);
        if (width != w || height != h)
            glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
        glBindFramebuffer(GL_READ_FRAMEBUFFER, s.read_fbo);
        glFramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
            GL_TEXTURE_RECTANGLE, frame.textureName, 0);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, s.draw_fbo);
        glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
            GL_TEXTURE_2D, destination, 0);
        const bool complete = glCheckFramebufferStatus(GL_READ_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE
            && glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
        if (complete) {
            const bool scissor = glIsEnabled(GL_SCISSOR_TEST);
            glDisable(GL_SCISSOR_TEST);
            // Syphon is bottom-origin; native bus textures use logical top-origin.
            glBlitFramebuffer(0, h, w, 0, 0, 0, w, h, GL_COLOR_BUFFER_BIT, GL_NEAREST);
            if (scissor) glEnable(GL_SCISSOR_TEST);
            glFlush();
            width = w; height = h; s.error.clear();
        } else s.error = "Syphon framebuffer unavailable";
        glBindFramebuffer(GL_READ_FRAMEBUFFER, s.read_fbo);
        glFramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_RECTANGLE, 0, 0);
        glBindFramebuffer(GL_READ_FRAMEBUFFER, old_read);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, old_draw);
        glBindTexture(GL_TEXTURE_2D, old_texture);
        return complete;
    }
}
