#pragma once
#import <AppKit/AppKit.h>
#include "model.hpp"
// Opens the native camera/card selection and Gray-code scan workflow.
// Opening the window does not open a camera or activate projector patterns.
void VJOpenCalibration(vj::Model* model,NSWindow* parent);

void VJCloseCalibrations(vj::Model* model);
vj::Json VJCheckCalibrationInterface(vj::Model* model);
