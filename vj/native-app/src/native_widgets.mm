#import "native_widgets.hpp"
#import "native_style.hpp"
#include <algorithm>
#include <cmath>
@interface VJHueSliderCell : NSSliderCell @end
@implementation VJHueSliderCell
- (void)drawBarInside:(NSRect)rect flipped:(BOOL)flipped {
    (void)flipped;
    auto track=NSMakeRect(rect.origin.x,NSMidY(rect)-7,rect.size.width,14);
    auto path=[NSBezierPath bezierPathWithRoundedRect:track xRadius:3 yRadius:3];
    NSMutableArray<NSColor*>* colors=[NSMutableArray arrayWithCapacity:7];
    for(int i=0;i<=6;i++)[colors addObject:[NSColor colorWithHue:i/6. saturation:1 brightness:1 alpha:self.enabled?1:.35]];
    auto gradient=[[NSGradient alloc]initWithColors:colors];
    [gradient drawInBezierPath:path angle:0];
    [vj::style::border() setStroke];path.lineWidth=1;[path stroke];
}
- (void)drawKnob:(NSRect)rect {
    auto thumb=[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(NSMidX(rect)-4,NSMidY(rect)-9,8,18) xRadius:2 yRadius:2];
    CGFloat hue=(self.doubleValue-self.minValue)/std::max(.000001,self.maxValue-self.minValue);
    [[NSColor colorWithHue:hue saturation:1 brightness:1 alpha:1]setFill];[thumb fill];
    [NSColor.blackColor setStroke];thumb.lineWidth=3;[thumb stroke];
    [NSColor.whiteColor setStroke];thumb.lineWidth=1;[thumb stroke];
}
@end
@implementation VJHueSlider
- (instancetype)initWithFrame:(NSRect)frame {
    if((self=[super initWithFrame:frame])){self.cell=[[VJHueSliderCell alloc]init];self.minValue=0;self.maxValue=1;self.continuous=YES;self.accessibilityLabel=@"Hue";}
    return self;
}
@end
@implementation VJRotary {double _value;}
- (instancetype)initWithFrame:(NSRect)frame {if((self=[super initWithFrame:frame])){_maxValue=1;_valueStep=.001;self.accessibilityRole=NSAccessibilitySliderRole;}return self;}
- (BOOL)acceptsFirstResponder{return YES;}
- (double)doubleValue{return _value;}
- (void)setDoubleValue:(double)value {_value=std::clamp(value,self.minValue,self.maxValue);self.accessibilityValue=@(_value);[self setNeedsDisplay:YES];}
- (void)drawRect:(NSRect)dirty {(void)dirty;auto b=self.bounds;double radius=std::max(4.,std::min(b.size.width-8,b.size.height-22)*.5),cx=NSMidX(b),cy=NSMidY(b)+7;auto circle=[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(cx-radius,cy-radius,radius*2,radius*2)];[vj::style::panel() setFill];[circle fill];[vj::style::border() setStroke];[circle stroke];double f=(self.doubleValue-self.minValue)/std::max(.000001,self.maxValue-self.minValue),angle=(225-f*270)*M_PI/180;auto line=[NSBezierPath bezierPath];[line moveToPoint:NSMakePoint(cx+cos(angle)*radius*.4,cy+sin(angle)*radius*.4)];[line lineToPoint:NSMakePoint(cx+cos(angle)*radius*.85,cy+sin(angle)*radius*.85)];[(self.enabled?vj::style::accent():vj::style::secondary()) setStroke];line.lineWidth=2;[line stroke];auto attrs=@{NSFontAttributeName:vj::style::font(10),NSForegroundColorAttributeName:vj::style::text()};NSString* value=self.valueLabel?:[NSString stringWithFormat:@"%.3g",self.doubleValue];auto size=[value sizeWithAttributes:attrs];[value drawAtPoint:NSMakePoint(cx-size.width/2,0) withAttributes:attrs];if(self.window.firstResponder==self){[vj::style::accent() setStroke];[NSBezierPath strokeRect:NSInsetRect(b,1,1)];}}
- (void)change:(double)value {if(self.valueStep>0)value=self.minValue+std::round((value-self.minValue)/self.valueStep)*self.valueStep;self.doubleValue=value;[self sendAction:self.action to:self.target];}
- (void)mouseDown:(NSEvent*)event {
    if(!self.enabled)return;[self.window makeFirstResponder:self];if(self.tracking)self.tracking(YES);double previous=event.locationInWindow.y,value=self.doubleValue;
    for(;;){auto e=[NSApp nextEventMatchingMask:NSEventMaskLeftMouseDragged|NSEventMaskLeftMouseUp|NSEventMaskKeyDown untilDate:[NSDate dateWithTimeIntervalSinceNow:.1] inMode:NSEventTrackingRunLoopMode dequeue:YES];if(!e){if(!self.window||!NSApp.active)break;continue;}if(e.type==NSEventTypeKeyDown){if(e.keyCode==53)break;continue;}double y=e.locationInWindow.y;value=std::clamp(value+(y-previous)/180*(self.maxValue-self.minValue)*((e.modifierFlags&NSEventModifierFlagShift)?.1:1.),self.minValue,self.maxValue);previous=y;[self change:value];if(e.type==NSEventTypeLeftMouseUp)break;}
    if(self.tracking)self.tracking(NO);
}
- (void)keyDown:(NSEvent*)event {if(event.keyCode>=123&&event.keyCode<=126){[self change:self.doubleValue+((event.keyCode==123||event.keyCode==125)?-1:1)*std::max(self.valueStep,(self.maxValue-self.minValue)/100)*((event.modifierFlags&NSEventModifierFlagShift)?.1:1.)];return;}[super keyDown:event];}
- (BOOL)accessibilityPerformIncrement{[self change:self.doubleValue+std::max(self.valueStep,(self.maxValue-self.minValue)/100)];return YES;}
- (BOOL)accessibilityPerformDecrement{[self change:self.doubleValue-std::max(self.valueStep,(self.maxValue-self.minValue)/100)];return YES;}
@end
@implementation VJPositionPad
- (BOOL)isFlipped{return YES;}
- (BOOL)acceptsFirstResponder{return YES;}
- (void)setPosition:(NSPoint)value {_position=value;[self setNeedsDisplay:YES];}
- (void)setMotionTarget:(NSPoint)value {_motionTarget=value;[self setNeedsDisplay:YES];}
- (void)drawRect:(NSRect)dirty {(void)dirty;[vj::style::panel() setFill];NSRectFill(self.bounds);[vj::style::border() setStroke];auto p=[NSBezierPath bezierPath];[p moveToPoint:NSMakePoint(NSMidX(self.bounds),0)];[p lineToPoint:NSMakePoint(NSMidX(self.bounds),self.bounds.size.height)];[p moveToPoint:NSMakePoint(0,NSMidY(self.bounds))];[p lineToPoint:NSMakePoint(self.bounds.size.width,NSMidY(self.bounds))];[p stroke];[NSBezierPath strokeRect:NSInsetRect(self.bounds,.5,.5)];for(int i=0;i<2;i++){auto point=i?self.motionTarget:self.position;[(i?vj::style::hex(0xe0b56b):vj::style::accent()) setFill];[[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(point.x*self.bounds.size.width-4,point.y*self.bounds.size.height-4,8,8)] fill];}}
- (void)mouseDown:(NSEvent*)event {if(!self.enabled)return;[self.window makeFirstResponder:self];if(self.tracking)self.tracking(YES);auto last=[self convertPoint:event.locationInWindow fromView:nil];if(!(event.modifierFlags&NSEventModifierFlagShift)){self.position=NSMakePoint(std::clamp(last.x/self.bounds.size.width,0.,1.),std::clamp(last.y/self.bounds.size.height,0.,1.));[self sendAction:self.action to:self.target];}for(;;){auto e=[NSApp nextEventMatchingMask:NSEventMaskLeftMouseDragged|NSEventMaskLeftMouseUp|NSEventMaskKeyDown untilDate:[NSDate dateWithTimeIntervalSinceNow:.1] inMode:NSEventTrackingRunLoopMode dequeue:YES];if(!e){if(!self.window||!NSApp.active)break;continue;}if(e.type==NSEventTypeKeyDown){if(e.keyCode==53)break;continue;}auto p=[self convertPoint:e.locationInWindow fromView:nil];double f=(e.modifierFlags&NSEventModifierFlagShift)?.1:1.;self.position=NSMakePoint(std::clamp(self.position.x+(p.x-last.x)/self.bounds.size.width*f,0.,1.),std::clamp(self.position.y+(p.y-last.y)/self.bounds.size.height*f,0.,1.));last=p;[self sendAction:self.action to:self.target];if(e.type==NSEventTypeLeftMouseUp)break;}if(self.tracking)self.tracking(NO);}
- (void)keyDown:(NSEvent*)event {if(event.keyCode>=123&&event.keyCode<=126){auto p=self.position;double step=(event.modifierFlags&NSEventModifierFlagShift)?.001:.01;if(event.keyCode==123)p.x-=step;if(event.keyCode==124)p.x+=step;if(event.keyCode==125)p.y+=step;if(event.keyCode==126)p.y-=step;self.position=NSMakePoint(std::clamp(p.x,0.,1.),std::clamp(p.y,0.,1.));[self sendAction:self.action to:self.target];return;}[super keyDown:event];}
@end
@implementation VJRGBStrip
- (void)setPixels:(NSData*)data {_pixels=[data copy];[self setNeedsDisplay:YES];}
- (void)drawRect:(NSRect)dirty {(void)dirty;[NSColor.blackColor setFill];NSRectFill(self.bounds);const auto* bytes=(const unsigned char*)self.pixels.bytes;NSUInteger count=self.pixels.length/3;for(NSUInteger i=0;i<count;i++){[vj::style::hex((bytes[i*3]<<16)|(bytes[i*3+1]<<8)|bytes[i*3+2]) setFill];double x=self.bounds.size.width*i/count,next=self.bounds.size.width*(i+1)/count;NSRectFill(NSMakeRect(x,0,std::max(1.,next-x),self.bounds.size.height));}}
@end
