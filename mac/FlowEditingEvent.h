#ifndef FLOW_EDITING_EVENT_H
#define FLOW_EDITING_EVENT_H
#import <AppKit/AppKit.h>
// NSEvent keyCode is only valid for keyboard events. Local monitor also gets clicks.
static inline unsigned flow_editing_event_key_code(NSEvent *event){
 return event.type==NSEventTypeKeyDown?event.keyCode:0;
}
#endif
