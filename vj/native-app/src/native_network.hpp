#pragma once
#import <AppKit/AppKit.h>
#include "model.hpp"
// Construction is local-only. Opening the sheet explicitly starts receiver
// discovery; stop ends its worker before the Model is destroyed.
@interface VJNetwork : NSObject
- (instancetype)initWithModel:(vj::Model*)model;
- (void)showForWindow:(NSWindow*)window;
- (void)showForWindow:(NSWindow*)window liveServices:(BOOL)liveServices;
- (vj::Json)checkInterface;
- (void)refresh;
- (void)stop;
@end
void VJOpenNetwork(vj::Model* model,NSWindow* parent,bool liveServices=true);
void VJCloseNetworks(vj::Model* model);

vj::Json VJCheckNetwork(vj::Model* model);
