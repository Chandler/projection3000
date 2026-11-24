#include <algorithm>
#import <objc/runtime.h>
#import "native_style.hpp"

static BOOL patchControl(NSView* view) {
    for(NSView* ancestor=view;ancestor;ancestor=ancestor.superview)if([ancestor.identifier isEqualToString:@"patch-editor-root"])return YES;
    return [view.window.title hasPrefix:@"Patch"] || [view.window.className hasPrefix:@"PatchKit."];
}
// Shared visual grammar. AppKit continues to own focus, actions and accessibility.
@interface VJFlatButtonCell : NSButtonCell { NSButtonType _type; }
@end
@implementation VJFlatButtonCell
- (void)setButtonType:(NSButtonType)type { _type=type;[super setButtonType:type]; }
- (NSSize)cellSize {if(patchControl(self.controlView))return [super cellSize]; auto size=[self.title sizeWithAttributes:@{NSFontAttributeName:self.font?:vj::style::font(11)}];return NSMakeSize(ceil(size.width)+20+(_type==NSButtonTypeSwitch?24:0),vj::style::controlHeight); }
- (void)drawWithFrame:(NSRect)frame inView:(NSView*)view {
    if(patchControl(view)){[super drawWithFrame:frame inView:view];return;}
    const BOOL tab=[view.identifier hasPrefix:@"tab-"];
    BOOL selected=self.state==NSControlStateValueOn&&(tab||_type==NSButtonTypeSwitch||_type==NSButtonTypePushOnPushOff||_type==NSButtonTypeToggle||_type==NSButtonTypeOnOff||_type==NSButtonTypeRadio);
    NSColor* foreground=self.enabled?(selected||!tab?vj::style::text():vj::style::secondary()):vj::style::disabled();
    if([view isKindOfClass:NSButton.class]&&((NSButton*)view).contentTintColor&&self.enabled)foreground=((NSButton*)view).contentTintColor;
    if(_type==NSButtonTypeSwitch){
        auto box=NSMakeRect(frame.origin.x+2,NSMidY(frame)-7,14,14);[vj::style::background() setFill];NSRectFill(box);[vj::style::border() setStroke];[NSBezierPath strokeRect:NSInsetRect(box,.5,.5)];
        if(selected){[(self.enabled?vj::style::accent():vj::style::disabled()) setStroke];auto mark=[NSBezierPath bezierPath];[mark moveToPoint:NSMakePoint(NSMinX(box)+3,NSMidY(box))];[mark lineToPoint:NSMakePoint(NSMinX(box)+6,NSMidY(box)+(view.isFlipped?3:-3))];[mark lineToPoint:NSMakePoint(NSMaxX(box)-2,NSMidY(box)+(view.isFlipped?-4:4))];mark.lineWidth=1.5;[mark stroke];}frame.origin.x+=24;frame.size.width-=24;
    }else{
        [(self.highlighted?vj::style::raised():selected?vj::style::engaged():tab?vj::style::panel():vj::style::field()) setFill];[[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(frame,.5,.5) xRadius:tab?0:vj::style::corner yRadius:tab?0:vj::style::corner]fill];
        if(!tab&&self.bordered){[(selected&&self.enabled?vj::style::accent():vj::style::border()) setStroke];[[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(frame,.5,.5) xRadius:vj::style::corner yRadius:vj::style::corner]stroke];}
        if(tab&&selected){[vj::style::accent() setFill];NSRectFill(NSMakeRect(frame.origin.x,view.isFlipped?NSMaxY(frame)-2:frame.origin.y,frame.size.width,2));}
    }
    auto para=[NSMutableParagraphStyle new];para.alignment=_type==NSButtonTypeSwitch?NSTextAlignmentLeft:self.alignment;para.lineBreakMode=NSLineBreakByTruncatingTail;
    NSFont* font=self.font?:vj::style::font(11);CGFloat height=ceil(font.ascender-font.descender+2);
    [self.title drawInRect:NSMakeRect(frame.origin.x+4,NSMidY(frame)-height/2,MAX(0,frame.size.width-8),height) withAttributes:@{NSFontAttributeName:font,NSForegroundColorAttributeName:foreground,NSParagraphStyleAttributeName:para}];
    if(view.window.firstResponder==view){[vj::style::accent() setStroke];[NSBezierPath strokeRect:NSInsetRect(frame,2,2)];}
}
@end
@interface VJFlatPopupCell : NSPopUpButtonCell @end
@implementation VJFlatPopupCell
- (NSSize)cellSize {if(patchControl(self.controlView))return [super cellSize];CGFloat width=0;for(NSMenuItem* item in self.menu.itemArray)width=MAX(width,[item.title sizeWithAttributes:@{NSFontAttributeName:self.font?:vj::style::font()}].width);return NSMakeSize(ceil(width)+32,vj::style::controlHeight);}
- (void)drawWithFrame:(NSRect)frame inView:(NSView*)view {
    if(patchControl(view)){[super drawWithFrame:frame inView:view];return;}
    [vj::style::field() setFill];auto outline=[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(frame,.5,.5) xRadius:vj::style::corner yRadius:vj::style::corner];[outline fill];[vj::style::border() setStroke];[outline stroke];
    auto p=[NSMutableParagraphStyle new];p.lineBreakMode=NSLineBreakByTruncatingTail;
    NSDictionary* attrs=@{NSFontAttributeName:self.font?:vj::style::font(11),NSForegroundColorAttributeName:self.enabled?vj::style::text():vj::style::disabled(),NSParagraphStyleAttributeName:p};
    [self.title drawInRect:NSMakeRect(frame.origin.x+6,NSMidY(frame)-8,MAX(0,frame.size.width-23),16) withAttributes:attrs];
    vj::style::chevron(NSMakeRect(NSMaxX(frame)-19,NSMidY(frame)-5,10,10),YES,self.enabled?vj::style::secondary():vj::style::disabled());
    if(view.window.firstResponder==view){[vj::style::accent() setStroke];[NSBezierPath strokeRect:NSInsetRect(frame,2,2)];}
}
@end
@interface VJFlatTextCell : NSTextFieldCell @end
@implementation VJFlatTextCell
- (NSRect)contentRect:(NSRect)frame {CGFloat height=MIN(NSHeight(frame)-2,ceil((self.font?:vj::style::font()).ascender-(self.font?:vj::style::font()).descender)+2);return NSMakeRect(NSMinX(frame)+5,NSMidY(frame)-height/2,MAX(0,NSWidth(frame)-10),height);}
- (void)selectWithFrame:(NSRect)frame inView:(NSView*)view editor:(NSText*)editor delegate:(id)delegate start:(NSInteger)start length:(NSInteger)length {[super selectWithFrame:(!patchControl(view)&&(self.isBordered||self.isBezeled))?[self contentRect:frame]:frame inView:view editor:editor delegate:delegate start:start length:length];}
- (void)editWithFrame:(NSRect)frame inView:(NSView*)view editor:(NSText*)editor delegate:(id)delegate event:(NSEvent*)event {[super editWithFrame:(!patchControl(view)&&(self.isBordered||self.isBezeled))?[self contentRect:frame]:frame inView:view editor:editor delegate:delegate event:event];}
- (void)drawWithFrame:(NSRect)frame inView:(NSView*)view {
    if(patchControl(view)){[super drawWithFrame:frame inView:view];return;}
 if(self.isBordered||self.isBezeled){[vj::style::field() setFill];auto outline=[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(frame,.5,.5) xRadius:vj::style::corner yRadius:vj::style::corner];[outline fill];[vj::style::border() setStroke];[outline stroke];[super drawInteriorWithFrame:[self contentRect:frame] inView:view];}else [super drawWithFrame:frame inView:view];
}
@end
@interface VJFlatSliderCell : NSSliderCell @end
@implementation VJFlatSliderCell
- (void)drawBarInside:(NSRect)rect flipped:(BOOL)flipped {
    if(patchControl(self.controlView)){[super drawBarInside:rect flipped:flipped];return;}
    (void)flipped;const auto track=self.isVertical?NSMakeRect(NSMidX(rect)-2,rect.origin.y,4,rect.size.height):NSMakeRect(rect.origin.x,NSMidY(rect)-2,rect.size.width,4);[vj::style::border() setFill];NSRectFill(track);
    double fraction=(self.doubleValue-self.minValue)/std::max(.000001,self.maxValue-self.minValue);auto fill=track;if(self.isVertical)fill.size.height*=fraction;else fill.size.width*=fraction;[(self.enabled?vj::style::accent():vj::style::disabled())setFill];NSRectFill(fill);
}
- (void)drawKnob:(NSRect)rect {if(patchControl(self.controlView)){[super drawKnob:rect];return;}[(self.enabled?vj::style::text():vj::style::disabled()) setFill];NSRectFill(self.isVertical?NSMakeRect(NSMidX(rect)-6.5,NSMidY(rect)-3.5,13,7):NSMakeRect(NSMidX(rect)-3.5,NSMidY(rect)-6.5,7,13));}
@end
void VJInstallControlStyle(){static dispatch_once_t once;dispatch_once(&once,^{[NSButton setCellClass:VJFlatButtonCell.class];[NSPopUpButton setCellClass:VJFlatPopupCell.class];[NSSlider setCellClass:VJFlatSliderCell.class];[NSTextField setCellClass:VJFlatTextCell.class];});}

@interface VJPanelToggle : NSButton
@property(nonatomic) BOOL collapsed;
@property(nonatomic) BOOL right;
@end
@implementation VJPanelToggle
- (void)drawRect:(NSRect)dirty {
    (void)dirty;[vj::style::panel() setFill];NSRectFill(self.bounds);
    auto attrs=@{NSFontAttributeName:vj::style::font(12),NSForegroundColorAttributeName:vj::style::secondary()};
    NSString* arrow=self.right?(self.collapsed?@"‹":@"›"):(self.collapsed?@"›":@"‹");
    auto chevron=@{NSFontAttributeName:vj::style::font(23),NSForegroundColorAttributeName:vj::style::text()};
    if(self.collapsed){
        auto arrowSize=[arrow sizeWithAttributes:chevron];[arrow drawAtPoint:NSMakePoint((self.bounds.size.width-arrowSize.width)/2,5) withAttributes:chevron];
        // Rotate in the flipped view about the rail's centre, keeping the entire
        // label inside the rail instead of translating it through the left edge.
        [NSGraphicsContext saveGraphicsState];auto t=[NSAffineTransform transform];
        [t translateXBy:self.bounds.size.width/2+7 yBy:44];[t rotateByDegrees:90];[t concat];
        [self.title drawInRect:NSMakeRect(0,0,MAX(0,self.bounds.size.height-54),16) withAttributes:attrs];
        [NSGraphicsContext restoreGraphicsState];
        [vj::style::border() setFill];NSRectFill(NSMakeRect(self.right?0:self.bounds.size.width-1,0,1,self.bounds.size.height));
    }else{
        [self.title drawAtPoint:NSMakePoint(self.right?10:36,9) withAttributes:attrs];
        [arrow drawAtPoint:NSMakePoint(self.right?self.bounds.size.width-25:11,0) withAttributes:chevron];
        [vj::style::border() setFill];NSRectFill(NSMakeRect(0,self.bounds.size.height-1,self.bounds.size.width,1));
    }
}
- (BOOL)isFlipped{return YES;}
@end
@implementation VJSidePanel { VJPanelToggle* _header; }
- (instancetype)initWithFrame:(NSRect)frame {if((self=[super initWithFrame:frame])){_header=[VJPanelToggle buttonWithTitle:@"" target:self action:@selector(togglePanel:)];[self addSubview:_header];self.wantsLayer=YES;self.layer.backgroundColor=vj::style::panel().CGColor;}return self;}
- (BOOL)isFlipped{return YES;}
- (void)setBody:(NSView*)body {[_body removeFromSuperview];_body=body;[self addSubview:body];self.needsLayout=YES;}
- (void)setTitle:(NSString*)title {_title=[title copy];_header.title=title;_header.right=_header.right||[title isEqualToString:@"Clip"];}
- (void)setCollapsed:(BOOL)collapsed {_collapsed=collapsed;_body.hidden=collapsed;_header.collapsed=collapsed;_header.toolTip=[NSString stringWithFormat:@"%@ %@",collapsed?@"Expand":@"Collapse",self.title];_header.accessibilityLabel=_header.toolTip;self.needsLayout=YES;[_header setNeedsDisplay:YES];}
- (void)layout {[super layout];_header.frame=NSMakeRect(0,0,self.bounds.size.width,self.collapsed?self.bounds.size.height:34);_body.frame=NSMakeRect(0,34,self.bounds.size.width,MAX(0,self.bounds.size.height-34));}
- (void)togglePanel:(id)sender {(void)sender;if(self.toggle)self.toggle();}
@end


namespace vj::style {
NSStackView* stack(NSUserInterfaceLayoutOrientation orientation){auto view=[[NSStackView alloc]init];view.orientation=orientation;view.alignment=orientation==NSUserInterfaceLayoutOrientationVertical?NSLayoutAttributeLeading:NSLayoutAttributeCenterY;view.spacing=gap;return view;}
NSTextField* label(NSString* value,BOOL subdued){auto field=[NSTextField labelWithString:value];field.font=font();field.textColor=subdued?secondary():text();field.lineBreakMode=NSLineBreakByTruncatingTail;return field;}
NSButton* button(NSString* title,id target,SEL action){auto result=[NSButton buttonWithTitle:title target:target action:action];result.font=font();[result.heightAnchor constraintEqualToConstant:controlHeight].active=YES;return result;}
VJDisclosureButton* disclosure(NSString* title,BOOL expanded,id target,SEL action){auto result=[VJDisclosureButton buttonWithTitle:title target:target action:action];result.expanded=expanded;result.alignment=NSTextAlignmentLeft;[result.heightAnchor constraintEqualToConstant:controlHeight].active=YES;return result;}
NSStackView* choiceGroup(NSArray<NSString*>* titles,NSArray<NSString*>* values,NSString* selected,id target,SEL action){auto group=stack(NSUserInterfaceLayoutOrientationHorizontal);group.spacing=4;group.distribution=NSStackViewDistributionFillEqually;for(NSUInteger i=0;i<titles.count;++i){auto button=[NSButton buttonWithTitle:titles[i] target:target action:action];button.identifier=values[i];button.font=headingFont();button.buttonType=NSButtonTypeRadio;button.alignment=NSTextAlignmentCenter;button.bordered=YES;button.state=[selected isEqual:values[i]]?NSControlStateValueOn:NSControlStateValueOff;[button.heightAnchor constraintEqualToConstant:36].active=YES;[group addArrangedSubview:button];}return group;}
NSStackView* propertyRow(NSString* title,CGFloat labelWidth){auto row=stack(NSUserInterfaceLayoutOrientationHorizontal);auto name=label(title,YES);name.toolTip=title;[name.widthAnchor constraintEqualToConstant:labelWidth].active=YES;[row addArrangedSubview:name];[row.heightAnchor constraintGreaterThanOrEqualToConstant:propertyHeight].active=YES;return row;}
VJSection* section(NSString* title){auto result=[[VJSection alloc]init];if(title.length){auto heading=label(title);heading.font=headingFont();[result addArrangedSubview:heading];}return result;}
void chevron(NSRect rect,BOOL expanded,NSColor* color){[color setStroke];auto path=[NSBezierPath bezierPath];if(expanded){[path moveToPoint:NSMakePoint(NSMinX(rect)+2,NSMidY(rect)-2)];[path lineToPoint:NSMakePoint(NSMidX(rect),NSMidY(rect)+1)];[path lineToPoint:NSMakePoint(NSMaxX(rect)-2,NSMidY(rect)-2)];}else{[path moveToPoint:NSMakePoint(NSMidX(rect)-1,NSMinY(rect)+2)];[path lineToPoint:NSMakePoint(NSMidX(rect)+2,NSMidY(rect))];[path lineToPoint:NSMakePoint(NSMidX(rect)-1,NSMaxY(rect)-2)];}path.lineWidth=1.5;[path stroke];}
NSPopover* popover(NSView* content,NSSize size){auto controller=[[NSViewController alloc]init];auto root=[[NSView alloc]initWithFrame:NSMakeRect(0,0,size.width,size.height)];root.wantsLayer=YES;root.layer.backgroundColor=panel().CGColor;controller.view=root;content.translatesAutoresizingMaskIntoConstraints=NO;[root addSubview:content];[NSLayoutConstraint activateConstraints:@[[content.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],[content.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],[content.topAnchor constraintEqualToAnchor:root.topAnchor]]];auto result=[[NSPopover alloc]init];result.animates=NO;result.behavior=NSPopoverBehaviorTransient;result.contentViewController=controller;result.contentSize=size;root.appearance=[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];apply(root);return result;}
void menu(NSMenu* menu,NSView* anchor){menu.font=font();[menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0,anchor.isFlipped?NSHeight(anchor.bounds)+unit:-unit) inView:anchor];}
void apply(NSView* view){
    if(patchControl(view))return;
    if([view isKindOfClass:NSControl.class]){auto control=(NSControl*)view;if(!control.font||control.font.pointSize==[NSFont systemFontSizeForControlSize:control.controlSize])control.font=font();}
    if([view isKindOfClass:NSTextField.class]){auto field=(NSTextField*)view;if(!field.textColor||[field.textColor isEqual:NSColor.labelColor]||[field.textColor isEqual:NSColor.controlTextColor])field.textColor=text();if(field.isEditable){field.bezeled=NO;field.bordered=YES;field.backgroundColor=vj::style::field();field.focusRingType=NSFocusRingTypeNone;if(field.alignment==NSTextAlignmentRight)field.font=valueFont();if([field isKindOfClass:NSSearchField.class]){field.bordered=NO;field.bezeled=YES;}}}
    if([view isKindOfClass:NSButton.class]){auto b=(NSButton*)view;if(b.bezelStyle==NSBezelStyleRounded)b.bezelStyle=NSBezelStyleSmallSquare;}
    if([view isKindOfClass:NSScrollView.class]){auto s=(NSScrollView*)view;s.backgroundColor=panel();s.autohidesScrollers=YES;}
    if([view isKindOfClass:NSTableView.class]){auto table=(NSTableView*)view;table.backgroundColor=panel();table.gridColor=border();}
    // AppKit owns the search/cancel glyph controls inside a search field.
    if([view isKindOfClass:NSSearchField.class])return;
    for(NSView* child in view.subviews)apply(child);
}
void window(NSWindow* win){win.appearance=[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];win.backgroundColor=background();apply(win.contentView);}
void mount(NSWindow* win,NSView* content){auto root=[[NSView alloc]initWithFrame:win.contentView.bounds];root.wantsLayer=YES;root.layer.backgroundColor=panel().CGColor;win.contentView=root;content.translatesAutoresizingMaskIntoConstraints=NO;[root addSubview:content];[NSLayoutConstraint activateConstraints:@[[content.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],[content.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],[content.topAnchor constraintEqualToAnchor:root.topAnchor],[content.bottomAnchor constraintEqualToAnchor:root.bottomAnchor]]];window(win);}
}
@implementation VJSection
- (instancetype)initWithFrame:(NSRect)frame{if((self=[super initWithFrame:frame])){self.orientation=NSUserInterfaceLayoutOrientationVertical;self.alignment=NSLayoutAttributeLeading;self.spacing=vj::style::gap;self.edgeInsets=NSEdgeInsetsMake(vj::style::inset,vj::style::inset,vj::style::sectionGap,vj::style::inset);}return self;}
- (BOOL)isFlipped{return YES;}
- (void)drawRect:(NSRect)dirty{(void)dirty;[vj::style::panel()setFill];NSRectFill(self.bounds);[vj::style::border()setFill];NSRectFill(NSMakeRect(vj::style::inset,NSHeight(self.bounds)-1,MAX(0,NSWidth(self.bounds)-2*vj::style::inset),1));}
@end
@implementation VJDisclosureButton
- (BOOL)isFlipped{return YES;}
- (void)setExpanded:(BOOL)value{_expanded=value;self.state=value?NSControlStateValueOn:NSControlStateValueOff;self.accessibilityValue=value?@"Expanded":@"Collapsed";self.needsDisplay=YES;}
- (void)drawRect:(NSRect)dirty{(void)dirty;[(self.isHighlighted?vj::style::raised():vj::style::panel())setFill];NSRectFill(self.bounds);vj::style::chevron(NSMakeRect(4,NSMidY(self.bounds)-6,12,12),self.expanded,vj::style::secondary());[self.title drawInRect:NSMakeRect(24,NSMidY(self.bounds)-8,MAX(0,NSWidth(self.bounds)-30),18) withAttributes:@{NSFontAttributeName:vj::style::headingFont(),NSForegroundColorAttributeName:vj::style::text()}];[vj::style::border()setFill];NSRectFill(NSMakeRect(0,NSHeight(self.bounds)-1,NSWidth(self.bounds),1));if(self.window.firstResponder==self){[vj::style::accent()setStroke];[NSBezierPath strokeRect:NSInsetRect(self.bounds,1,1)];}}
@end
@implementation VJPopup
- (NSSize)intrinsicContentSize {CGFloat width=0;for(NSMenuItem* item in self.itemArray)width=MAX(width,[item.title sizeWithAttributes:@{NSFontAttributeName:self.font?:vj::style::font()}].width);return NSMakeSize(MAX(84,ceil(width)+36),vj::style::controlHeight);}
- (NSMenu*)selectionMenu{auto menu=[[NSMenu alloc]initWithTitle:self.title];menu.autoenablesItems=NO;menu.font=vj::style::font();for(NSUInteger index=0;index<self.itemArray.count;++index){NSMenuItem* source=self.itemArray[index];if(self.pullsDown&&index==0)continue;if(source.separatorItem){[menu addItem:NSMenuItem.separatorItem];continue;}auto item=[[NSMenuItem alloc]initWithTitle:source.title action:@selector(chooseValue:) keyEquivalent:@""];item.target=self;item.tag=index;item.enabled=source.enabled;item.representedObject=source.representedObject;item.state=!self.pullsDown&&source==self.selectedItem?NSControlStateValueOn:NSControlStateValueOff;[menu addItem:item];}return menu;}
- (void)mouseDown:(NSEvent*)event{(void)event;if(!self.enabled)return;[self.window makeFirstResponder:self];vj::style::menu([self selectionMenu],self);}
- (void)performClick:(id)sender{(void)sender;if(!self.enabled)return;[self.window makeFirstResponder:self];vj::style::menu([self selectionMenu],self);}
- (void)chooseValue:(NSMenuItem*)item{if(item.tag<0||item.tag>=self.numberOfItems)return;auto original=[self itemAtIndex:item.tag];if(!original.enabled)return;[self selectItemAtIndex:item.tag];if(self.pullsDown&&original.action)[NSApp sendAction:original.action to:original.target from:original];else [self sendAction:self.action to:self.target];self.needsDisplay=YES;}
- (void)keyDown:(NSEvent*)event{if(event.keyCode==49||event.keyCode==36||(event.keyCode==125&&(event.modifierFlags&NSEventModifierFlagOption))){[self performClick:nil];return;}[super keyDown:event];}
@end
