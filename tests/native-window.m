#import "../mac/FlowWindow.h"
#include <assert.h>
#include <stdio.h>
int main(void){@autoreleasepool{
 [NSApplication sharedApplication];
 NSWindow *window=FlowCreateStudioWindow(NSMakeRect(0,0,560,300));
 __weak NSWindow *reference=window;
 assert(!window.releasedWhenClosed);
 assert(window.opaque);
 assert([window.backgroundColor isEqual:FlowWindowBackground(NO)]);
 assert(window.titlebarSeparatorStyle==NSTitlebarSeparatorStyleNone);
 assert(FlowWindowBackground(YES).alphaComponent==1&&FlowWindowBackground(NO).alphaComponent==1);
 for(unsigned i=0;i<5;i++){
  @autoreleasepool{
   [window close];
   [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
  }
  // Simulate the poller's accesses after the close event and autorelease drain.
  assert(reference!=nil);
  assert(!window.visible);
  (void)window.occlusionState;(void)window.keyWindow;(void)window.miniaturized;
  assert(window.contentView!=nil);
 }
 [window orderFront:nil];assert(window.visible);[window orderOut:nil];
 puts("Passed: production ARC window survives repeated close/autorelease/poll cycles and reopens without reallocation.");
}return 0;}
