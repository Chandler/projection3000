#pragma once
#import <AppKit/AppKit.h>
#include "model.hpp"
@interface VJApplication : NSObject<NSApplicationDelegate,NSWindowDelegate,NSSplitViewDelegate>
- (instancetype)initWithModel:(vj::Model*)model port:(unsigned short)port address:(NSString*)address;
- (BOOL)checkInterface;
@end
