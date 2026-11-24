#pragma once
#import <AppKit/AppKit.h>
#include "model.hpp"
@interface VJOutputs : NSObject
- (instancetype)initWithModel:(vj::Model*)model allowOutputs:(BOOL)allow;
- (void)refresh;
- (void)showPreviewForWindow:(NSWindow*)window;
- (void)showForWindow:(NSWindow*)window;
- (void)showForWindow:(NSWindow*)window projector:(NSString*)mid;
- (vj::Json)checkAssignment:(NSWindow*)window;
- (void)stop;
@end
