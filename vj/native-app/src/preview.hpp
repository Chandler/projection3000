#pragma once
#import <AppKit/AppKit.h>
#include "model.hpp"
@class PatchEditorController;
@interface VJPreview : NSOpenGLView
- (instancetype)initWithFrame:(NSRect)frame model:(vj::Model*)model;
- (void)setProcessorController:(PatchEditorController*)controller;
- (void)setSingleMonitor:(BOOL)single;
- (void)setMonitorBank:(NSString*)bank;
- (void)setBus:(NSString*)bus;
- (void)setPhysicalOutput:(BOOL)physical;
- (void)setIgnoreOutputRotation:(BOOL)ignore;
- (double)movieFrameRate;
- (void)setMediaClockSuspended:(BOOL)suspended;
- (void)setPresentationFPS:(double)fps;
- (void)setMapping:(NSString*)mapping;
- (void)setEditorMapping:(const vj::Json&)mapping;
// Offscreen readback follows the canvas consuming its image (main thread).
- (void)setReadbackConsumer:(NSView*)consumer;
- (NSImage*)mappingImage;
- (void)setRoom:(const vj::Json&)descriptor camera:(const vj::Json&)camera;
- (void)setOutputSize:(NSSize)size;
- (void)setPublicationEnabled:(BOOL)enabled;
- (void)stop;
- (BOOL)checkRendering;
- (NSImage*)capturePresentation; // Explicit UI-check capture, never used by the render timer.
@end
