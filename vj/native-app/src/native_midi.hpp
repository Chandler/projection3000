#pragma once
#import <AppKit/AppKit.h>
#include "model.hpp"
@interface VJMidiControls : NSView
- (instancetype)initWithFrame:(NSRect)frame model:(vj::Model*)model;
- (void)refresh;
@end
