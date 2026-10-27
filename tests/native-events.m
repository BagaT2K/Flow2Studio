#import <AppKit/AppKit.h>
#import "../mac/FlowMacroRecorder.h"
#import "../mac/FlowEditingEvent.h"
#include <assert.h>
#include <stdio.h>
int main(void){@autoreleasepool{
 @try {
  for(NSNumber *type in @[@(NSEventTypeLeftMouseDown),@(NSEventTypeRightMouseDown),@(NSEventTypeOtherMouseDown)]){
   NSEvent *mouse=[NSEvent mouseEventWithType:type.unsignedIntegerValue location:NSMakePoint(10,10) modifierFlags:0 timestamp:1 windowNumber:0 context:nil eventNumber:1 clickCount:1 pressure:1];
   assert(mouse);assert(flow_editing_event_key_code(mouse)==0);assert(flow_macro_event_key_code(mouse)==UINT16_MAX);
  }
  NSEvent *key=[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:NSEventModifierFlagCommand timestamp:1 windowNumber:0 context:nil characters:@"m" charactersIgnoringModifiers:@"m" isARepeat:NO keyCode:46];
  assert(key);assert(flow_editing_event_key_code(key)==46);assert(flow_macro_event_key_code(key)==46);
  puts("Passed: real AppKit mouse events avoid keyCode; keyboard event retains its keyCode.");
 } @catch(NSException *exception){fprintf(stderr,"Event regression: %s\n",exception.description.UTF8String);return 1;}
}return 0;}
