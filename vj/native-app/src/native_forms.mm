#import "native_style.hpp"
#include <algorithm>

@implementation VJParameterRow
- (instancetype)initWithFrame:(NSRect)frame{if((self=[super initWithFrame:frame]))_labelWidth=vj::style::inspectorLabel;return self;}
- (BOOL)isFlipped{return YES;}
- (void)layout{[super layout];const double width=NSWidth(self.bounds);if(self.performance){self.name.frame=NSMakeRect(0,0,width,self.labelHeight);self.control.frame=NSMakeRect(0,self.labelHeight+4,width,22);self.value.frame=NSMakeRect(0,self.labelHeight+30,MAX(0,width-24),22);self.reset.frame=NSMakeRect(MAX(0,width-22),self.labelHeight+30,22,22);}else{const CGFloat h=std::min(vj::style::controlHeight,NSHeight(self.bounds)),y=(NSHeight(self.bounds)-h)/2;self.name.frame=NSMakeRect(0,NSMidY(self.bounds)-9,self.labelWidth,20);CGFloat x=self.labelWidth+vj::style::gap,right=width;if(self.reset){self.reset.frame=NSMakeRect(right-24,y,24,h);right-=28;}if(self.value){CGFloat w=std::min(vj::style::valueWidth,std::max(36.,(right-x)*.4));self.value.frame=NSMakeRect(right-w,y,w,h);right-=w+4;}self.control.frame=NSMakeRect(x,y,MAX(0,right-x),h);if([self.control isKindOfClass:NSButton.class]&&![self.control isKindOfClass:NSPopUpButton.class]&&((NSButton*)self.control).title.length==0)self.control.frame=NSMakeRect(x,y,30,h);}self.value.font=vj::style::valueFont();}
@end

namespace {
BOOL reusable(NSView* a,NSView* b){
 if(a.class!=b.class)return NO;
 if([a isKindOfClass:NSStackView.class]){auto left=(NSStackView*)a,right=(NSStackView*)b;if(left.orientation!=right.orientation||left.arrangedSubviews.count!=right.arrangedSubviews.count)return NO;for(NSUInteger i=0;i<left.arrangedSubviews.count;++i)if(!reusable(left.arrangedSubviews[i],right.arrangedSubviews[i]))return NO;return YES;}
 if([a isKindOfClass:VJParameterRow.class])return reusable(((VJParameterRow*)a).name,((VJParameterRow*)b).name)&&reusable(((VJParameterRow*)a).control,((VJParameterRow*)b).control);
 // Do not reuse arbitrary subclasses with opaque application bindings.
 return a.class==NSTextField.class||a.class==NSButton.class||a.class==VJPopup.class||a.class==VJDisclosureButton.class||a.class==VJFlatColorWell.class||[a conformsToProtocol:@protocol(VJReusableControl)];
}
void update(NSView* a,NSView* b){
 a.identifier=b.identifier;a.hidden=b.hidden;a.toolTip=b.toolTip;
 if([a isKindOfClass:NSStackView.class]){auto left=(NSStackView*)a,right=(NSStackView*)b;left.spacing=right.spacing;left.edgeInsets=right.edgeInsets;for(NSUInteger i=0;i<left.arrangedSubviews.count;++i)update(left.arrangedSubviews[i],right.arrangedSubviews[i]);return;}
 if([a isKindOfClass:VJParameterRow.class]){auto left=(VJParameterRow*)a,right=(VJParameterRow*)b;left.labelWidth=right.labelWidth;update(left.name,right.name);update(left.control,right.control);return;}
 auto old=(NSControl*)a,next=(NSControl*)b;old.target=next.target;old.action=next.action;old.enabled=next.enabled;old.font=next.font;old.accessibilityLabel=next.accessibilityLabel;
 if([a isKindOfClass:NSPopUpButton.class]){auto left=(NSPopUpButton*)a,right=(NSPopUpButton*)b;BOOL same=left.itemArray.count==right.itemArray.count;if(same)for(NSUInteger i=0;i<left.itemArray.count;++i)if(![left.itemArray[i].title isEqual:right.itemArray[i].title]||![(left.itemArray[i].representedObject?:NSNull.null) isEqual:(right.itemArray[i].representedObject?:NSNull.null)]){same=NO;break;}if(!same){[left removeAllItems];for(NSMenuItem* item in right.itemArray)[left.menu addItem:[item copy]];}[left selectItemAtIndex:right.indexOfSelectedItem];}
 else if([a isKindOfClass:NSTextField.class]){auto left=(NSTextField*)a,right=(NSTextField*)b;left.stringValue=right.stringValue;left.placeholderString=right.placeholderString;left.textColor=right.textColor;left.editable=right.editable;}
 else if([a isKindOfClass:NSColorWell.class])((NSColorWell*)a).color=((NSColorWell*)b).color;
 else if([a isKindOfClass:NSButton.class]){auto left=(NSButton*)a,right=(NSButton*)b;left.title=right.title;left.state=right.state;if([a isKindOfClass:VJDisclosureButton.class])((VJDisclosureButton*)a).expanded=((VJDisclosureButton*)b).expanded;}
 else if([a isKindOfClass:NSSlider.class]){auto left=(NSSlider*)a,right=(NSSlider*)b;left.minValue=right.minValue;left.maxValue=right.maxValue;left.doubleValue=right.doubleValue;}
 if([a conformsToProtocol:@protocol(VJReusableControl)])[(id<VJReusableControl>)a updateBindingsFrom:next];
 a.needsDisplay=YES;
}
}
NSView* VJReconcileView(NSView* current,NSView* next){if(current&&next&&reusable(current,next)){update(current,next);return current;}return next;}
