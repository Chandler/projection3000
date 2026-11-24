#pragma once
#import <AppKit/AppKit.h>
#include "model.hpp"
@interface VJRoom : NSView
- (instancetype)initWithFrame:(NSRect)frame model:(vj::Model*)model;
- (void)refresh;
- (void)stop;
- (BOOL)checkRendering;
@end
