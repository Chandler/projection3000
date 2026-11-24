#pragma once
#import <AppKit/AppKit.h>
#include "model.hpp"
// Master, clock, DMX and fixture controls use precisely the same API dispatch
// as remote clients. The view does not scan, open, or contact any hardware.
@interface VJControls : NSView
- (instancetype)initWithFrame:(NSRect)frame model:(vj::Model*)model;
- (void)refresh;
- (BOOL)checkLayout;
- (vj::Json)checkParity;
- (BOOL)checkPage:(NSInteger)page;
- (BOOL)checkScrollToEnd; // Test-only: checks reset, leaves the current page at its bottom.
- (void)selectPage:(NSInteger)page;
- (void)showLights;
@property(copy) void (^settingsAction)(NSString*);
- (void)stop;
@end
