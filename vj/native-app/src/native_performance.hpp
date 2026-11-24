#pragma once
#import <AppKit/AppKit.h>
#include "model.hpp"

@interface VJPerformanceBar : NSView
- (instancetype)initWithModel:(vj::Model*)model;
- (void)stop;
@end
