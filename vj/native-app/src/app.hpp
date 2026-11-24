#pragma once
#import <AppKit/AppKit.h>
#include "model.hpp"
@interface VJApplication : NSObject<NSApplicationDelegate,NSWindowDelegate,NSSplitViewDelegate>
- (instancetype)initWithModel:(vj::Model*)model port:(unsigned short)port address:(NSString*)address;
- (BOOL)checkInterface;
@end

// Places a library output into the active embedded Patch session and Compose grid.
vj::Reply VJPlaceLibrarySubpatch(const vj::Json& command);
