#pragma once
#import <AppKit/AppKit.h>
#include "EditorTypography.h"
void VJInstallControlStyle();
// Shared controls own presentation and interaction, never application state.
@interface VJPopup : NSPopUpButton
- (NSMenu*)selectionMenu;
@end
@interface VJFlatColorWell : NSColorWell
@property(nonatomic,readonly) NSView* editorView;
- (BOOL)checkEditor;
@end
@interface VJDisclosureButton : NSButton
@property(nonatomic) BOOL expanded;
@end
@interface VJSection : NSStackView @end
@interface VJParameterRow : NSView
@property(strong) NSTextField* name;
@property(strong) NSControl* control;
@property(strong) NSTextField* value;
@property(strong) NSButton* reset;
@property(nonatomic) BOOL performance;
@property(nonatomic) CGFloat labelHeight;
@property(nonatomic) CGFloat labelWidth;
@end
// Reconcile a detached form in one layout transaction. Standard controls retain
// identity; custom controls opt in to copying their additional bindings.
@protocol VJReusableControl
- (void)updateBindingsFrom:(NSControl*)control;
@end
NSView* VJReconcileView(NSView* current,NSView* next);


@interface VJSidePanel : NSView
@property(nonatomic,strong) NSView* body;
@property(nonatomic,copy) NSString* title;
@property(nonatomic) BOOL collapsed;
@property(copy) void (^toggle)(void);
@end

namespace vj::style {
inline NSColor* hex(unsigned value){return [NSColor colorWithSRGBRed:((value>>16)&255)/255. green:((value>>8)&255)/255. blue:(value&255)/255. alpha:1];}
// A 4-point rhythm; compact controls are reserved for dense performance rows.
constexpr CGFloat unit=4,gap=8,inset=12,sectionGap=16;
constexpr CGFloat controlHeight=30,compactHeight=24,propertyHeight=32;
constexpr CGFloat inspectorLabel=84,formLabel=128,valueWidth=56,corner=3;
inline NSColor* background(){return hex(0x1e2022);} inline NSColor* panel(){return hex(0x292c2f);}
inline NSColor* field(){return hex(0x222427);} inline NSColor* raised(){return hex(0x34383c);}
inline NSColor* border(){return hex(0x41464a);} inline NSColor* text(){return hex(0xe4e7e9);}
inline NSColor* secondary(){return hex(0xa7adb2);} inline NSColor* disabled(){return hex(0x747a80);}
inline NSColor* accent(){return hex(0x8fc6db);} inline NSColor* engaged(){return hex(0x344a52);}
inline NSColor* overlay(){return hex(0xc084fc);} inline NSColor* warning(){return hex(0xdfb86f);}
inline NSColor* danger(){return hex(0xe59186);} inline NSColor* live(){return hex(0x9bc88a);}
inline NSFont* font(CGFloat size=EDITOR_FONT_BODY){return [NSFont systemFontOfSize:size];}
inline NSFont* headingFont(){return [NSFont systemFontOfSize:EDITOR_FONT_BODY weight:NSFontWeightSemibold];}
inline NSFont* valueFont(){return [NSFont monospacedDigitSystemFontOfSize:EDITOR_FONT_ITEM weight:NSFontWeightRegular];}
NSStackView* stack(NSUserInterfaceLayoutOrientation orientation);
NSTextField* label(NSString* text,BOOL secondary=NO);
NSButton* button(NSString* title,id target,SEL action);
VJDisclosureButton* disclosure(NSString* title,BOOL expanded,id target,SEL action);
NSStackView* choiceGroup(NSArray<NSString*>* titles,NSArray<NSString*>* values,NSString* selected,id target,SEL action);
NSStackView* propertyRow(NSString* title,CGFloat labelWidth=formLabel);
VJSection* section(NSString* title);
void apply(NSView* view);
void window(NSWindow* window);
void mount(NSWindow* window,NSView* content); // Stable sheet root; never size a window from a stack.
void menu(NSMenu* menu,NSView* anchor);
NSPopover* popover(NSView* content,NSSize size);
void chevron(NSRect rect,BOOL expanded,NSColor* color);
constexpr double rowHeader=150,column=116,cellHeight=112,pitchX=117,pitchY=113,headerHeight=25;
}
