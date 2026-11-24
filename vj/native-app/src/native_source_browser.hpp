#pragma once
#import <AppKit/AppKit.h>
#include "model.hpp"
// An explicit source picker; discovery runs only after its Scan button.
// Completion receives {selection, label, ...}; saved/offline sources remain valid.
void VJChooseLiveSource(vj::Model* model,NSWindow* parent,const std::string& generator,
                        const std::string& current,void (^completion)(vj::Json source));
