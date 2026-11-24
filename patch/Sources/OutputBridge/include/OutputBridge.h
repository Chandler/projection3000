#include "EditorTypography.h"
#include "PatchStereoRing.h"
#include "PatchCollection.h"
#include "PatchParticles.h"
#include "PatchClouds.h"
#include "PatchCloudParticles.h"
#include "PatchTrace.h"
#include "PatchTraceGPU.h"
#include "PatchMappedSurface.h"
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <CoreVideo/CoreVideo.h>
NS_ASSUME_NONNULL_BEGIN
@interface PatchSyphon : NSObject
@property(class, readonly) BOOL available;
@property(nonatomic, readonly) NSDictionary<NSString *,NSString *> *selection;
- (nullable instancetype)initWithName:(NSString *)name device:(id<MTLDevice>)device;
- (void)publish:(id<MTLTexture>)texture commandBuffer:(id<MTLCommandBuffer>)buffer;
@end
@interface PatchSyphonInput : NSObject
@property(class, readonly) NSArray<NSDictionary<NSString *,NSString *> *> *sources;
@property(nonatomic, readonly) NSString *status;
- (instancetype)initWithSelection:(NSDictionary<NSString *,NSString *> *)selection device:(id<MTLDevice>)device;
- (nullable id<MTLTexture>)currentTexture;
@end
@interface PatchNDI : NSObject
@property(class, readonly) BOOL available;
- (nullable instancetype)initWithName:(NSString *)name;
- (void)sendBytes:(const void *)bytes width:(int)width height:(int)height stride:(int)stride fps:(int)fps;
@end
// Receives one named NDI source on a background thread into Metal-compatible BGRA buffers.
@interface PatchNDIReceiver : NSObject
@property(class, readonly) BOOL available;
// Names of sources currently visible on the network; discovery keeps running after the first call.
@property(class, readonly) NSArray<NSString *> *sources;
@property(nonatomic, readonly) NSString *source;
@property(atomic, readonly, copy) NSString *status;
- (nullable instancetype)initWithSource:(NSString *)source;
// The newest frame, or NULL when nothing arrived since the previous call.
- (nullable CVPixelBufferRef)copyNewFrame CF_RETURNS_RETAINED;
@end
NS_ASSUME_NONNULL_END

#include "PatchVectorArt.h"
