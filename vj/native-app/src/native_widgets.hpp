#pragma once
#import <AppKit/AppKit.h>
// A hue spectrum with native slider tracking, keyboard and accessibility support.
@interface VJHueSlider : NSSlider
@end
@interface VJRotary : NSControl
@property double minValue;
@property double maxValue;
@property double valueStep;
@property(copy) NSString* caption;
@property(copy) NSString* valueLabel;
@property(copy) void (^tracking)(BOOL);
@end
@interface VJPositionPad : NSControl
@property(nonatomic) NSPoint position;
@property(nonatomic) NSPoint motionTarget;
@property(copy) void (^tracking)(BOOL);
@end
@interface VJRGBStrip : NSView
@property(nonatomic,copy) NSData* pixels;
@end
