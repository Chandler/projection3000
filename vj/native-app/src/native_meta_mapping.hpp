#pragma once
#import <AppKit/AppKit.h>
#include "model.hpp"
@interface VJMetaMapping : NSView
- (instancetype)initWithFrame:(NSRect)frame model:(vj::Model*)model;
- (void)refresh;
- (BOOL)handleKeyEvent:(NSEvent*)event;
- (void)focusCanvas;
- (void)stop;
@end
