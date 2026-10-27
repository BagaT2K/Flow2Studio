#ifndef FLOW_WINDOW_H
#define FLOW_WINDOW_H
#import <AppKit/AppKit.h>
static inline NSColor *FlowWindowBackground(BOOL light){
 return light?[NSColor colorWithSRGBRed:243.0/255 green:243.0/255 blue:236.0/255 alpha:1]:
              [NSColor colorWithSRGBRed:16.0/255 green:18.0/255 blue:18.0/255 alpha:1];
}
static inline NSWindow *FlowCreateStudioWindow(NSRect frame){
 NSWindow *window=[[NSWindow alloc]initWithContentRect:frame
  styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable
  backing:NSBackingStoreBuffered defer:NO];
 // ARC owns this window. NSWindow's default close-time release would over-release it.
 // Closing the window keeps the menu-bar app alive and the same window can reopen.
 window.releasedWhenClosed=NO;
 window.opaque=YES;
 window.backgroundColor=FlowWindowBackground(NO);
 window.titlebarSeparatorStyle=NSTitlebarSeparatorStyleNone;
 return window;
}
#endif
