#pragma once
#import <AppKit/AppKit.h>
#include "model.hpp"
@interface VJLibrary : NSView
- (instancetype)initWithFrame:(NSRect)frame model:(vj::Model*)model;
@property(copy) void (^insert)(vj::Json);
@property(copy) void (^assignOutput)(vj::Json,NSView*);
@property(copy) void (^browse)(void);
@property(copy) void (^sourcesChanged)(void);
@property(copy) void (^inventoryChanged)(void);
- (vj::Json)searchItems;
- (void)refreshSearchItems;
- (vj::Json)filesForEffect:(const std::string&)effect;
- (vj::Json)sourcesForEffect:(const std::string&)effect;
- (void)setLivePreviewsEnabled:(BOOL)enabled;
- (void)setContext:(const vj::Json&)snapshot bus:(NSString*)bus target:(NSString*)target;
- (vj::Json)checkInteractions:(const vj::Json&)sources;
- (NSUInteger)readyLivePreviewCount;
- (void)refresh;
- (void)stop;
@end

vj::Json VJCheckLibraryStructure();
