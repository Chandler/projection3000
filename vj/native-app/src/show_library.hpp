#pragma once
#import <AppKit/AppKit.h>
#include <filesystem>
#include "native_style.hpp"
// A show is one state root: grid, mappings, LEDs, outputs and the Patch session.
// Shows live in ~/Projection3000/VJ/Shows (override with VJ_SHOWS_DIRECTORY).
namespace vj::shows {
std::filesystem::path library();
// Root for a launch without --state-root: the last show opened, else Default.
std::filesystem::path startupRoot();
bool inLibrary(const std::filesystem::path& root);
void remember(const std::filesystem::path& root);
// Repoints file paths missing on this machine (other home folder, checkout or show
// location) at the existing file in this show or checkout.
void relocate(const std::filesystem::path& root);
}
@interface VJShowLibraryPicker : VJPopup
- (instancetype)initWithRoot:(std::filesystem::path)root;
@end
