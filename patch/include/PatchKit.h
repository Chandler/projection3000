#pragma once
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN
// Objective-C host contract for the Swift PatchKit library. No graph or video
// implementation leaks into the host. Each controller owns its own render queue.
@interface PatchEditorController : NSViewController
- (nullable instancetype)initWithWindow:(NSWindow *)window
                            sessionURL:(NSURL *)sessionURL
                               apiPort:(uint16_t)apiPort
                                 error:(NSError **)error;
@property(nonatomic, readonly) BOOL active;
@property(nonatomic, readonly) NSInteger renderedFrames;
@property(nonatomic, readonly) NSDictionary *state;
@property(nonatomic, readonly) NSArray<NSDictionary *> *paletteSources;
@property(nonatomic, readonly) NSArray<NSDictionary *> *publishedOutputs;
- (void)retainPublishedOutputs:(NSArray<NSString *> *)ids;
- (void)setEditorActive:(BOOL)active;
- (void)setEditorVisible:(BOOL)visible;
- (void)setEditorFocused:(BOOL)focused;
- (NSApplicationTerminateReply)shouldTerminateApplication:(NSApplication *)application;
- (void)receiveHostFader:(nullable NSNumber *)value;
@property(nonatomic, readonly) BOOL followsHostCrossfader;
@property(nonatomic, readonly) BOOL ownsHostAPC;
- (void)receiveHostAPC:(NSArray<NSArray<NSNumber *> *> *)messages;
@property(nonatomic, readonly) BOOL followsHostChannelFaders;
- (void)receiveHostChannelFaders:(NSArray<NSNumber *> *)values;
// Perform these three calls on the main thread. Commit or discard before yielding.
- (nullable NSDictionary *)instantiateLibrarySubpatch:(NSString *)libraryID outputID:(NSString *)outputID error:(NSError **)error;
- (nullable NSDictionary *)instantiateLibrarySubpatch:(NSString *)libraryID outputID:(NSString *)outputID inputSource:(NSString *)inputSource error:(NSError **)error;
- (BOOL)encodeProcessor:(NSString *)source input:(id<MTLTexture>)input output:(id<MTLTexture>)output
          commandBuffer:(id<MTLCommandBuffer>)commandBuffer time:(double)seconds context:(NSString *)destination
                   error:(NSError **)error;
- (nullable NSDictionary *)duplicatePublishedOutput:(NSString *)source error:(NSError **)error;
- (void)commitLibrarySubpatch:(NSString *)instanceID;
- (BOOL)discardLibrarySubpatch:(NSString *)instanceID error:(NSError **)error;
- (void)saveSession;
- (nullable NSView *)controlsForPublishedOutput:(NSString *)source;
- (void)focusPublishedOutput:(NSString *)source;
- (void)frameGraph;
- (void)stop;
@end
NS_ASSUME_NONNULL_END
