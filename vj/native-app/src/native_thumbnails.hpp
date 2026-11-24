#pragma once
#import <AppKit/AppKit.h>
#include "model.hpp"
@interface VJClipThumbnails : NSObject
- (instancetype)initWithModel:(vj::Model*)model redraw:(void(^)(void))redraw;
- (void)setContext:(const vj::Json&)snapshot bus:(NSString*)bus;
- (NSImage*)imageForClip:(const vj::Json&)clip;
- (void)setLivePreviewsEnabled:(BOOL)enabled;
- (void)stop;
@end
// Targeted no-device readback check; not run during normal UI construction.
vj::Json VJCheckClipThumbnailRendering(vj::Model* model);

vj::Json VJCheckLiveClipPreviews(void(^present)(vj::Json,BOOL));

vj::Json VJCheckThumbnailStability(vj::Model* model);
vj::Json VJCheckHeldPatchThumbnails(vj::Model* model);

vj::Json VJCheckTraceThumbnails(vj::Model* model);
