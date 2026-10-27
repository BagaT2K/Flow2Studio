#import <AppKit/AppKit.h>
#include <stdint.h>
static inline unsigned short flow_macro_event_key_code(NSEvent *event){
    NSEventType type=event.type;
    return (type==NSEventTypeKeyDown||type==NSEventTypeKeyUp||type==NSEventTypeFlagsChanged)?event.keyCode:UINT16_MAX;
}
@interface FlowMacroRecorder:NSObject
- (instancetype)initWithSink:(void (^)(NSDictionary *))sink;
- (BOOL)startForWindow:(NSWindow *)window;
- (void)stopNotifying:(BOOL)notify reason:(NSString *)reason;
@end
