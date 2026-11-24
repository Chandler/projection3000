#import "native_style.hpp"
#import "native_widgets.hpp"
#include <algorithm>
#include <cmath>
@interface VJColorPlane : NSControl
@property CGFloat hue;
@property CGFloat saturation;
@property CGFloat brightness;
@end
@implementation VJColorPlane
- (BOOL)isFlipped{return YES;}
- (BOOL)acceptsFirstResponder{return YES;}
- (void)drawRect:(NSRect)dirty{(void)dirty;auto hue=[NSColor colorWithHue:self.hue saturation:1 brightness:1 alpha:1];auto horizontal=[[NSGradient alloc]initWithStartingColor:NSColor.whiteColor endingColor:hue];[horizontal drawInRect:self.bounds angle:0];auto vertical=[[NSGradient alloc]initWithStartingColor:[NSColor colorWithWhite:0 alpha:0] endingColor:NSColor.blackColor];[vertical drawInRect:self.bounds angle:90];auto point=NSMakePoint(self.saturation*NSWidth(self.bounds),(1-self.brightness)*NSHeight(self.bounds));auto ring=[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(point.x-4,point.y-4,8,8)];[NSColor.blackColor setStroke];ring.lineWidth=3;[ring stroke];[NSColor.whiteColor setStroke];ring.lineWidth=1;[ring stroke];}
- (void)changePoint:(NSEvent*)event{auto p=[self convertPoint:event.locationInWindow fromView:nil];self.saturation=std::clamp(p.x/NSWidth(self.bounds),0.,1.);self.brightness=1-std::clamp(p.y/NSHeight(self.bounds),0.,1.);self.needsDisplay=YES;[self sendAction:self.action to:self.target];}
- (void)mouseDown:(NSEvent*)event{[self.window makeFirstResponder:self];[self changePoint:event];while(YES){auto next=[NSApp nextEventMatchingMask:NSEventMaskLeftMouseDragged|NSEventMaskLeftMouseUp untilDate:NSDate.distantFuture inMode:NSEventTrackingRunLoopMode dequeue:YES];[self changePoint:next];if(next.type==NSEventTypeLeftMouseUp)break;}}
- (void)keyDown:(NSEvent*)event{CGFloat step=(event.modifierFlags&NSEventModifierFlagShift)?.001:.01;if(event.keyCode==123)self.saturation-=step;else if(event.keyCode==124)self.saturation+=step;else if(event.keyCode==125)self.brightness-=step;else if(event.keyCode==126)self.brightness+=step;else{[super keyDown:event];return;}self.saturation=std::clamp(self.saturation,0.,1.);self.brightness=std::clamp(self.brightness,0.,1.);self.needsDisplay=YES;[self sendAction:self.action to:self.target];}
@end
@interface VJColorEditor : NSViewController<NSPopoverDelegate>
@property(weak) VJFlatColorWell* well;
@property(weak) NSPopover* popover;
@property(strong) VJColorPlane* plane;
@property(strong) NSSlider* hue;
@property(strong) NSTextField* hex;
- (void)sync;
@end
@implementation VJColorEditor
- (void)loadView{
 self.view=[[NSView alloc]initWithFrame:NSMakeRect(0,0,280,302)];self.view.wantsLayer=YES;self.view.layer.backgroundColor=vj::style::panel().CGColor;
 auto root=vj::style::stack(NSUserInterfaceLayoutOrientationVertical);root.translatesAutoresizingMaskIntoConstraints=NO;[self.view addSubview:root];[NSLayoutConstraint activateConstraints:@[[root.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],[root.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],[root.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:12]]];
 auto title=vj::style::label(@"Color");title.font=vj::style::headingFont();[root addArrangedSubview:title];
 self.plane=[[VJColorPlane alloc]init];self.plane.accessibilityLabel=@"Saturation and brightness";self.plane.target=self;self.plane.action=@selector(changed:);[root addArrangedSubview:self.plane];[self.plane.widthAnchor constraintEqualToAnchor:root.widthAnchor].active=YES;[self.plane.heightAnchor constraintEqualToConstant:144].active=YES;
 auto hueRow=vj::style::propertyRow(@"Hue",40);self.hue=[[VJHueSlider alloc]initWithFrame:NSZeroRect];self.hue.target=self;self.hue.action=@selector(changed:);[hueRow addArrangedSubview:self.hue];[self.hue.widthAnchor constraintEqualToConstant:200].active=YES;[self.hue.heightAnchor constraintEqualToConstant:26].active=YES;[root addArrangedSubview:hueRow];
 auto values=vj::style::stack(NSUserInterfaceLayoutOrientationHorizontal);self.hex=[[NSTextField alloc]init];self.hex.font=vj::style::valueFont();self.hex.accessibilityLabel=@"Hex color";self.hex.target=self;self.hex.action=@selector(hexChanged:);[self.hex.widthAnchor constraintEqualToConstant:120].active=YES;[self.hex.heightAnchor constraintEqualToConstant:vj::style::controlHeight].active=YES;[values addArrangedSubview:self.hex];auto close=vj::style::button(@"Done",self,@selector(close:));[close.widthAnchor constraintEqualToConstant:128].active=YES;[values addArrangedSubview:close];[root addArrangedSubview:values];
 auto presets=vj::style::stack(NSUserInterfaceLayoutOrientationHorizontal);presets.spacing=4;for(unsigned rgb:{0xffffff,0x000000,0xff4949,0xffb74d,0xffeb65,0x66d890,0x63c7e6,0xc084fc}){auto b=[NSButton buttonWithTitle:@"●" target:self action:@selector(preset:)];b.tag=rgb;b.contentTintColor=vj::style::hex(rgb);b.toolTip=[NSString stringWithFormat:@"#%06X",rgb];b.accessibilityLabel=b.toolTip;[b.widthAnchor constraintEqualToConstant:28].active=YES;[b.heightAnchor constraintEqualToConstant:24].active=YES;[presets addArrangedSubview:b];}[root addArrangedSubview:presets];vj::style::apply(self.view);
}
- (void)sync{auto color=[self.well.color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];if(!color)return;CGFloat h,s,b,a;[color getHue:&h saturation:&s brightness:&b alpha:&a];if(s>0)self.hue.doubleValue=h;self.plane.hue=self.hue.doubleValue;self.plane.saturation=s;self.plane.brightness=b;self.plane.needsDisplay=YES;self.hex.stringValue=[NSString stringWithFormat:@"#%02X%02X%02X",int(std::round(color.redComponent*255)),int(std::round(color.greenComponent*255)),int(std::round(color.blueComponent*255))];}
- (void)commit:(NSColor*)color{self.well.color=color;[self sync];[self.well sendAction:self.well.action to:self.well.target];}
- (void)changed:(id)sender{(void)sender;self.plane.hue=self.hue.doubleValue;[self commit:[NSColor colorWithHue:self.hue.doubleValue saturation:self.plane.saturation brightness:self.plane.brightness alpha:1]];}
- (void)hexChanged:(id)sender{(void)sender;auto value=[self.hex.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];if([value hasPrefix:@"#"])value=[value substringFromIndex:1];unsigned hex=0;auto scanner=[NSScanner scannerWithString:value];if(value.length!=6||![scanner scanHexInt:&hex]||!scanner.atEnd){self.hex.textColor=vj::style::danger();return;}self.hex.textColor=vj::style::text();[self commit:vj::style::hex(hex)];}
- (void)preset:(NSButton*)sender{[self commit:vj::style::hex(unsigned(sender.tag))];}
- (void)close:(id)sender{(void)sender;[self.well deactivate];}
- (void)cancelOperation:(id)sender{[self close:sender];}
- (void)popoverDidClose:(NSNotification*)notification{(void)notification;[self.well setNeedsDisplay:YES];}
@end
static __weak VJFlatColorWell* activeColorWell;
@implementation VJFlatColorWell {VJColorEditor* _editor;NSPopover* _popover;}
- (BOOL)isActive{return _editor.popover.shown;}
- (NSView*)editorView{return _editor.view;}
- (void)activate:(BOOL)exclusive{(void)exclusive;if(!self.enabled||!self.window)return;if(activeColorWell!=self)[activeColorWell deactivate];activeColorWell=self;if(!_editor){_editor=[[VJColorEditor alloc]init];_editor.well=self;_popover=[[NSPopover alloc]init];_editor.popover=_popover;_editor.popover.animates=NO;_editor.popover.behavior=NSPopoverBehaviorTransient;_editor.popover.contentViewController=_editor;_editor.popover.delegate=_editor;_editor.popover.contentSize=NSMakeSize(280,302);}_editor.view.appearance=[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];[_editor sync];[_editor.popover showRelativeToRect:self.bounds ofView:self preferredEdge:NSRectEdgeMinX];self.needsDisplay=YES;}
- (void)deactivate{[_editor.popover close];self.needsDisplay=YES;}
- (void)viewWillMoveToWindow:(NSWindow*)window{if(!window)[self deactivate];[super viewWillMoveToWindow:window];}
- (void)mouseDown:(NSEvent*)event{(void)event;if(self.isActive)[self deactivate];else[self activate:YES];}
- (void)keyDown:(NSEvent*)event{if(event.keyCode==36||event.keyCode==49){[self activate:YES];return;}[super keyDown:event];}
- (void)drawRect:(NSRect)dirty{(void)dirty;[vj::style::field()setFill];auto outline=[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,.5,.5) xRadius:3 yRadius:3];[outline fill];[(self.isActive?vj::style::accent():vj::style::border())setStroke];[outline stroke];CGFloat size=MAX(8,MIN(18,NSHeight(self.bounds)-8));[self.color setFill];[[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(5,(NSHeight(self.bounds)-size)/2,size,size) xRadius:2 yRadius:2]fill];if(NSWidth(self.bounds)>74){auto rgb=[self.color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];NSString* value=[NSString stringWithFormat:@"#%02X%02X%02X",int(round(rgb.redComponent*255)),int(round(rgb.greenComponent*255)),int(round(rgb.blueComponent*255))];[value drawInRect:NSMakeRect(size+11,NSMidY(self.bounds)-7,NSWidth(self.bounds)-size-14,16) withAttributes:@{NSFontAttributeName:vj::style::valueFont(),NSForegroundColorAttributeName:vj::style::text()}];}}
- (BOOL)checkEditor{[self activate:YES];[_editor.view layoutSubtreeIfNeeded];BOOL result=self.isActive&&NSWidth(_editor.view.bounds)==280&&NSHeight(_editor.view.bounds)==302;_editor.hex.stringValue=@"#8060C0";[_editor hexChanged:nil];result=result&&[_editor.hex.stringValue isEqual:@"#8060C0"];_editor.hex.stringValue=@"invalid";auto before=self.color;[_editor hexChanged:nil];result=result&&[self.color isEqual:before];[_editor sync];return result;}
@end
