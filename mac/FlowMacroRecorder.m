#import "FlowMacroRecorder.h"
#import <CoreGraphics/CoreGraphics.h>
#include "FlowMacroKeys.h"
@interface FlowMacroRecorder ()
@property(nonatomic,copy) void (^sink)(NSDictionary *);
@property(nonatomic,strong) id monitor;
@property(nonatomic,weak) NSWindow *window;
@property(nonatomic,strong) NSMutableArray *observers;
@property(nonatomic,strong) NSMutableSet *held;
@property(nonatomic) BOOL capsLocked;
@end
@implementation FlowMacroRecorder
- (instancetype)initWithSink:(void (^)(NSDictionary *))sink {if((self=[super init]))_sink=[sink copy];return self;}
- (void)emit:(unsigned)code down:(BOOL)down time:(NSTimeInterval)timestamp {
    NSNumber *key=@(code);if(down){if([self.held containsObject:key])return;[self.held addObject:key];}else{if(![self.held containsObject:key])return;[self.held removeObject:key];}
    if(self.sink)self.sink(@{@"macroKey":@{@"code":key,@"down":@(down),@"milliseconds":@(timestamp*1000)}});
}
- (BOOL)startForWindow:(NSWindow *)window {
    NSAssert(NSThread.isMainThread,@"Recorder must use the app main thread");
    [self stopNotifying:NO reason:nil];if(!NSApp.active||!window.keyWindow)return NO;
    self.window=window;self.held=[NSMutableSet set];self.capsLocked=([NSEvent modifierFlags]&NSEventModifierFlagCapsLock)!=0;self.observers=[NSMutableArray array];__weak FlowMacroRecorder *weak=self;
    self.monitor=[NSEvent addLocalMonitorForEventsMatchingMask:(NSEventMaskKeyDown|NSEventMaskKeyUp|NSEventMaskFlagsChanged) handler:^NSEvent *(NSEvent *event){
        FlowMacroRecorder *recorder=weak;if(!recorder||!recorder.monitor||!recorder.window||!NSApp.active||NSApp.keyWindow!=recorder.window)return event;
        unsigned short virtualKey=flow_macro_event_key_code(event);if(virtualKey==UINT16_MAX)return event;
        unsigned code=flow_macro_mac_key(virtualKey);if(!code)return nil;
        if(event.type==NSEventTypeKeyDown&&event.isARepeat)return nil;
        if(event.type==NSEventTypeFlagsChanged&&code==57){BOOL enabled=(event.modifierFlags&NSEventModifierFlagCapsLock)!=0;if(enabled!=recorder.capsLocked){recorder.capsLocked=enabled;[recorder emit:code down:YES time:event.timestamp];[recorder emit:code down:NO time:event.timestamp];}return nil;}
        BOOL down=event.type==NSEventTypeKeyDown;
        if(event.type==NSEventTypeFlagsChanged)down=CGEventSourceKeyState(kCGEventSourceStateCombinedSessionState,virtualKey);
        [recorder emit:code down:down time:event.timestamp];return nil;
    }];
    if(!self.monitor){self.window=nil;return NO;}
    for(NSNotificationName name in @[NSApplicationDidResignActiveNotification,NSWindowDidResignKeyNotification,NSWindowWillCloseNotification,NSWindowDidMiniaturizeNotification]){
        id token=[NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n){FlowMacroRecorder *recorder=weak;if(!recorder)return;if([n.name isEqual:NSApplicationDidResignActiveNotification]||n.object==recorder.window)[recorder stopNotifying:YES reason:@"Запись остановлена: окно Studio потеряло фокус."]; }];[self.observers addObject:token];
    }
    return YES;
}
- (void)stopNotifying:(BOOL)notify reason:(NSString *)reason {
    BOOL active=self.monitor!=nil;if(self.monitor){[NSEvent removeMonitor:self.monitor];self.monitor=nil;}
    for(id token in self.observers)[NSNotificationCenter.defaultCenter removeObserver:token];self.observers=nil;self.held=nil;self.window=nil;
    if(active&&notify&&self.sink)self.sink(@{@"macroStopped":@{@"message":reason?:@"Запись остановлена."}});
}
- (void)dealloc {if(_monitor)[NSEvent removeMonitor:_monitor];for(id token in _observers)[NSNotificationCenter.defaultCenter removeObserver:token];}
@end
