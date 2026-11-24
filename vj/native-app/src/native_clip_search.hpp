#pragma once
#import <AppKit/AppKit.h>
#include "model.hpp"

// Local inventory search. Opening/filtering never starts a capture or decoder.
@interface VJClipSearch : NSWindowController
- (instancetype)initWithItems:(const vj::Json&)items completion:(void(^)(vj::Json))completion;
- (void)showForWindow:(NSWindow*)parent target:(NSString*)target;
- (void)setSearchTitle:(NSString*)title placeholder:(NSString*)placeholder;
- (void)updateItems:(const vj::Json&)items;
- (void)cancel;
- (vj::Json)checkInteractions;
@end
