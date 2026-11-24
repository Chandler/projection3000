#pragma once
#import <AppKit/AppKit.h>
#include "model.hpp"
// Presents a searchable library sheet. Completion receives a catalog item with
// file/type/name suitable for put_clip. Closing the sheet does not mutate clips.
void VJChooseMedia(vj::Model* model,NSWindow* parent,void (^completion)(vj::Json item));
// Collection picker returns all selected media in displayed order.
void VJChooseMediaItems(vj::Model* model,NSWindow* parent,void (^completion)(vj::Json items));
// Embedded text subtitle tracks for an existing video clip.
void VJChooseSubtitles(vj::Model* model,NSWindow* parent,const std::string& file,
                       const std::string& current,void (^completion)(std::string track));
