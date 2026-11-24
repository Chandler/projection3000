#pragma once
#import <AppKit/AppKit.h>
#include "model.hpp"
@interface VJMapper : NSView
- (instancetype)initWithFrame:(NSRect)frame model:(vj::Model*)model;
@property(copy) void (^outputAction)(NSString*);
- (void)refresh;
- (void)findAction:(id)sender;
- (BOOL)handleKeyEvent:(NSEvent*)event;
- (NSView*)layoutPopoverView;
- (BOOL)checkRendering;
- (BOOL)checkSelectionInterface;
- (vj::Json)checkObjectParity;
- (void)stop;
@end
// Local gesture regression; no model mutation or device activation.
BOOL VJCheckMapperSelection();
