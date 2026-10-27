#import "FlowUpdates.h"
#import <AppKit/AppKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <WebKit/WebKit.h>
#import "FlowTransport.h"
#import "FlowLocalization.h"
#import "FlowDeferredStore.h"
#import "FlowMacroRecorder.h"
#import "FlowBLEBattery.h"
#import "FlowBLESerial.h"
#import "FlowFirmware.h"
#import <IOKit/pwr_mgt/IOPMLib.h>
#include <stdio.h>
#include <math.h>
#include "FlowEditingPolicy.h"
#include "FlowFirmwareConsent.h"
#import "FlowEditingEvent.h"
#import "FlowWindow.h"
#import "FlowPreferences.h"

// Keep IOKit device creation, callback delivery and teardown on one run loop.
// GCD serializes tasks but can execute consecutive tasks on different threads.
@interface FlowHIDThread:NSObject
@property(nonatomic,strong) NSThread *thread;
- (void)run;
- (void)execute:(dispatch_block_t)block;
@end
@implementation FlowHIDThread
- (instancetype)init {
    if((self=[super init])){_thread=[[NSThread alloc]initWithTarget:self selector:@selector(run) object:nil];_thread.name=@"Flow2Studio HID";[_thread start];}
    return self;
}
- (void)run {
    @autoreleasepool {
        NSRunLoop *loop=NSRunLoop.currentRunLoop;
        [loop addPort:[NSMachPort port]forMode:NSDefaultRunLoopMode];
        while(!NSThread.currentThread.cancelled){@autoreleasepool{[loop runMode:NSDefaultRunLoopMode beforeDate:NSDate.distantFuture];}}
    }
}
- (void)execute:(dispatch_block_t)block {@autoreleasepool{block();}}
@end
static void FlowHIDEnqueue(dispatch_queue_t queue,dispatch_block_t block){
    dispatch_async(queue,^{
        static FlowHIDThread *worker;static dispatch_once_t once;
        dispatch_once(&once,^{worker=[FlowHIDThread new];});
        [worker performSelector:@selector(execute:)onThread:worker.thread withObject:[block copy]waitUntilDone:YES modes:@[NSDefaultRunLoopMode]];
    });
}

@interface Studio:NSObject<NSApplicationDelegate,NSWindowDelegate,WKScriptMessageHandler,WKNavigationDelegate,WKUIDelegate>
@property(nonatomic,strong) NSWindow *window;
@property(nonatomic,strong) WKWebView *web;
@property(nonatomic,strong) NSStatusItem *status;
@property(nonatomic,strong) NSDictionary *selected;
@property(nonatomic,strong) NSDictionary *battery;
@property(nonatomic,strong) NSDate *batteryDate;
@property(nonatomic,strong) NSTimer *timer;
@property(nonatomic,strong) NSMenuItem *batteryMenu;
@property(nonatomic,strong) NSDictionary *cachedMenuPreviews;
@property(nonatomic,strong) dispatch_queue_t worker;
@property(nonatomic) BOOL sleeping;
@property(nonatomic,strong) NSTimer *editingTimer;
@property(nonatomic,strong) id activityMonitor;
@property(nonatomic) BOOL editingPending;
@property(nonatomic) BOOL terminating;
@property(nonatomic) BOOL editingWanted;
@property(nonatomic) BOOL editingBlocked;
@property(nonatomic) NSUInteger editingGeneration;
@property(nonatomic) double editingActivity;
@property(nonatomic) FlowEditingPresence editingPresence;
@property(nonatomic) BOOL windowClosed;
@property(nonatomic) BOOL chargeForeground;
@property(nonatomic) BOOL chargeForcePercent;
@property(nonatomic) double editingLastAttempt;
@property(nonatomic) BOOL editingDark;
@property(nonatomic) unsigned editingTimeout;

@property(nonatomic,strong) FlowMacroRecorder *macroRecorder;
@property(nonatomic,strong) FlowDeferredStore *deferred;
@property(nonatomic) BOOL deferredRunning;
@property(nonatomic) double lastDeferredAttempt;
@property(nonatomic) BOOL chargePending;
@property(nonatomic) double lastChargeAttempt;
@property(nonatomic,strong) NSString *usbInventory;
@property(nonatomic) BOOL firmwareBusy;
@property(nonatomic,strong) NSDictionary *firmwareConfirmation;
@property(nonatomic,strong) FlowBLEBattery *bleBattery;
@property(nonatomic) NSUInteger selectionGeneration;
- (void)readCharge:(NSDictionary *)device request:(NSNumber *)identifier;
- (void)readCharge:(NSDictionary *)device request:(NSNumber *)identifier forcePercent:(BOOL)forcePercent;
- (void)showWindow;
- (void)refreshCharge;
- (void)quit;
- (void)updateEditing;
- (void)stopEditing;
- (void)editingActivityOccurred;
- (void)processDeferred;
- (void)publishDeferred;
- (void)monitorConnections;
- (void)cacheResult:(NSDictionary *)result action:(NSString *)action device:(NSDictionary *)device;
@end
@implementation Studio
- (NSDictionary *)preferences {
    NSUserDefaults *d=NSUserDefaults.standardUserDefaults;
    NSString *style=[d stringForKey:@"batteryStyle"];if(![@[@"keyboardPercent",@"logo"]containsObject:style])style=@"keyboardPercent";
    return @{@"language":FlowCurrentLanguage(),@"theme":[d stringForKey:@"theme"]?:@"dark",@"batteryStyle":style,@"autoCharge":@([d boolForKey:@"autoCharge"]),@"editingConnection":@([d boolForKey:@"editingConnection"]),@"keycaps":[d dictionaryForKey:@"keycaps"]?:@{},@"menuPreviews":[self menuPreviews]};
}
- (void)appearance {
    NSString *theme=[self preferences][@"theme"];
    self.window.appearance=[NSAppearance appearanceNamed:[theme isEqual:@"light"]?NSAppearanceNameAqua:NSAppearanceNameDarkAqua];
    NSColor *background=FlowWindowBackground([theme isEqual:@"light"]);
    self.window.backgroundColor=background;
    self.web.underPageBackgroundColor=background;
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    FlowMigratePreferences();
    [NSUserDefaults.standardUserDefaults registerDefaults:@{@"theme":@"dark",@"batteryStyle":@"keyboardPercent",@"autoCharge":@YES,@"editingConnection":@YES}];
    self.deferred=[[FlowDeferredStore alloc]initWithDefaults:NSUserDefaults.standardUserDefaults];
    self.worker=dispatch_queue_create("local.flow2studio.hid",DISPATCH_QUEUE_SERIAL);
    self.window=FlowCreateStudioWindow(NSMakeRect(0,0,1180,800));
    self.window.delegate=self;
    self.window.title=@"Flow 2 Studio";self.window.minSize=NSMakeSize(1000,720);
    self.window.titlebarAppearsTransparent=YES;[self appearance];
    WKWebViewConfiguration *config=[WKWebViewConfiguration new];
    [config.userContentController addScriptMessageHandler:self name:@"flow"];
    self.web=[[WKWebView alloc]initWithFrame:self.window.contentView.bounds configuration:config];
    self.web.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;self.web.navigationDelegate=self;self.web.UIDelegate=self;
    self.window.contentView=self.web;
    [self appearance];
    NSURL *resources=[NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"ui"];
    [self.web loadFileURL:[resources URLByAppendingPathComponent:@"index.html"] allowingReadAccessToURL:resources];
    self.status=[NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    NSMenu *menu=[NSMenu new];self.batteryMenu=[[NSMenuItem alloc]initWithTitle:FlowLocalized(@"Клавиатура · заряд недоступен") action:nil keyEquivalent:@""];self.batteryMenu.enabled=NO;[menu addItem:self.batteryMenu];[menu addItem:NSMenuItem.separatorItem];
    for(NSArray *item in @[@[FlowLocalized(@"Открыть Flow 2 Studio"),NSStringFromSelector(@selector(showWindow)),@""],
                          @[FlowLocalized(@"Обновить заряд"),NSStringFromSelector(@selector(refreshCharge)),@"r"],
                          @[FlowLocalized(@"Завершить"),NSStringFromSelector(@selector(quit)),@"q"]]) {
        NSMenuItem *m=[[NSMenuItem alloc]initWithTitle:item[0] action:NSSelectorFromString(item[1]) keyEquivalent:item[2]];m.target=self;m.representedObject=item[0];m.title=FlowLocalized(item[0]);[menu addItem:m];
    }
    self.status.menu=menu;[self renderStatus];
    __weak Studio *weak=self;
    self.timer=[NSTimer timerWithTimeInterval:2 repeats:YES block:^(NSTimer *t){(void)t;[weak monitorConnections];[weak processDeferred];}];
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
    NSNotificationCenter *nc=NSWorkspace.sharedWorkspace.notificationCenter;
    [nc addObserverForName:NSWorkspaceWillSleepNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n){(void)n;weak.sleeping=YES;weak.chargeForeground=NO;[weak.macroRecorder stopNotifying:YES reason:FlowLocalized(@"Запись остановлена: Mac засыпает.")];[weak stopEditing];weak.selectionGeneration++;[weak.bleBattery cancel];FlowBLESerialReset();weak.battery=nil;[weak renderStatus];}];
    [nc addObserverForName:NSWorkspaceDidWakeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n){(void)n;weak.sleeping=NO;[weak editingActivityOccurred];}];
    self.editingActivity=NSProcessInfo.processInfo.systemUptime;
    NSNotificationCenter *appNC=NSNotificationCenter.defaultCenter;
    for(NSNotificationName name in @[NSApplicationDidBecomeActiveNotification,NSApplicationDidResignActiveNotification,NSWindowDidBecomeKeyNotification,NSWindowDidResignKeyNotification,NSWindowDidMiniaturizeNotification,NSWindowDidDeminiaturizeNotification,NSWindowDidChangeOcclusionStateNotification,NSWindowWillCloseNotification]){
        [appNC addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n){
            if([n.name isEqual:NSWindowWillCloseNotification]&&n.object==weak.window){weak.windowClosed=YES;weak.chargeForeground=NO;[weak stopEditing];return;}
            if([n.name isEqual:NSApplicationDidBecomeActiveNotification]||([n.name isEqual:NSWindowDidBecomeKeyNotification]&&n.object==weak.window))[weak editingActivityOccurred];
            else [weak updateEditing];
        }];
    }
    self.activityMonitor=[NSEvent addLocalMonitorForEventsMatchingMask:(NSEventMaskKeyDown|NSEventMaskLeftMouseDown|NSEventMaskRightMouseDown|NSEventMaskScrollWheel) handler:^NSEvent *(NSEvent *event){
        BOOL key=event.type==NSEventTypeKeyDown;
        NSPoint point=[weak.window.contentView convertPoint:event.locationInWindow fromView:nil];
        BOOL content=NSPointInRect(point,weak.window.contentView.bounds);
        if(flow_editing_event_activity(event.window==weak.window,content,key,(event.modifierFlags&NSEventModifierFlagCommand)!=0,flow_editing_event_key_code(event)))[weak editingActivityOccurred];
        return event;
    }];
    self.editingTimer=[NSTimer timerWithTimeInterval:1 repeats:YES block:^(NSTimer *t){(void)t;[weak updateEditing];}];
    [NSRunLoop.mainRunLoop addTimer:self.editingTimer forMode:NSRunLoopCommonModes];
    [self.window center];[self showWindow];
}
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender{
 (void)sender;
 if(self.firmwareBusy){[self showWindow];[self reply:@0 result:@{@"preparation":@{@"phase":@"busy",@"done":@0,@"total":@1}} error:nil];return NSTerminateCancel;}
 if(self.terminating)return NSTerminateLater;
 self.terminating=YES;self.selectionGeneration++;
 [self.timer invalidate];self.timer=nil;
 [self.editingTimer invalidate];self.editingTimer=nil;
 if(self.activityMonitor){[NSEvent removeMonitor:self.activityMonitor];self.activityMonitor=nil;}
 [self.macroRecorder stopNotifying:NO reason:nil];[self.bleBattery cancel];
 self.firmwareConfirmation=nil;
 [self stopEditing];
 // The worker barrier completes after all pending HID operations and lease release.
 FlowHIDEnqueue(self.worker,^{dispatch_async(dispatch_get_main_queue(),^{[NSApp replyToApplicationShouldTerminate:YES];});});
 return NSTerminateLater;
}
- (BOOL)windowShouldClose:(NSWindow *)sender{(void)sender;
 if(self.firmwareBusy){[self reply:@0 result:@{@"preparation":@{@"phase":@"busy",@"done":@0,@"total":@1}}error:nil];return NO;}
 if(self.firmwareConfirmation&&NSProcessInfo.processInfo.systemUptime<[self.firmwareConfirmation[@"deadline"]doubleValue])return NO;
 self.firmwareConfirmation=nil;return YES;
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender{(void)sender;return NO;}
- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)visible{(void)sender;(void)visible;[self showWindow];return YES;}
- (void)showWindow {self.windowClosed=NO;[self.window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];}
- (void)quit {[NSApp terminate:nil];}
- (void)stopEditing {
    self.editingPresence=(FlowEditingPresence){0};
    self.editingWanted=NO;self.editingBlocked=NO;self.editingTimeout=0;self.editingLastAttempt=0;self.editingGeneration++;
    FlowHIDEnqueue(self.worker,^{FlowEditingEnd();});
}
- (void)editingActivityOccurred {
    self.editingActivity=NSProcessInfo.processInfo.systemUptime;
    // A failed/unsupported session is retried only on explicit settings requests
    // or on a new window session, never on every mouse event.
    [self updateEditing];[self processDeferred];
}
- (void)updateEditing {
    if(self.terminating)return;
    double now=NSProcessInfo.processInfo.systemUptime;
    BOOL visible=self.window.visible&&(self.window.occlusionState&NSWindowOcclusionStateVisible)!=0;
    BOOL foreground=!self.sleeping&&!self.terminating&&flow_window_foreground(NSApp.active,self.window.keyWindow,visible,self.window.miniaturized);
    BOOL activated=foreground&&!self.chargeForeground;self.chargeForeground=foreground;
    if(activated){
        self.editingBlocked=NO;
        if(self.selected&&!self.firmwareBusy)[self readCharge:self.selected request:@0 forcePercent:YES];
    }
    BOOL rf=[self.selected[@"connection"]isEqual:@"2.4 ГГц"];
    BOOL wanted=flow_editing_presence_tick(&_editingPresence,now,[[self preferences][@"editingConnection"]boolValue],foreground,!self.windowClosed,self.sleeping,self.firmwareBusy||self.terminating,rf);
    if(!wanted){if(self.editingWanted)[self stopEditing];return;}
    self.editingWanted=YES;
    if(self.editingPending||self.editingBlocked)return;
    BOOL dark=flow_editing_dark(now,self.editingActivity,self.editingTimeout);
    if(self.editingLastAttempt>0&&now-self.editingLastAttempt<4&&dark==self.editingDark)return;
    self.editingDark=dark;self.editingLastAttempt=now;
    self.editingPending=YES;NSUInteger generation=self.editingGeneration;
    NSDictionary *device=self.selected;double idleSeconds=MAX(0,now-self.editingActivity);
    FlowHIDEnqueue(self.worker,^{NSError *error=nil;NSDictionary *result=FlowEditingTick(device,idleSeconds,&error);
        dispatch_async(dispatch_get_main_queue(),^{self.editingPending=NO;
            if(generation!=self.editingGeneration){[self updateEditing];return;}
            if(result[@"timeout"]){self.editingTimeout=[result[@"timeout"]unsignedIntValue];self.editingDark=[result[@"dark"]boolValue];}
            self.editingBlocked=!result||[@[@"upgrade",@"unsupported"]containsObject:result[@"state"]];
        });
    });
}

- (void)webView:(WKWebView *)web decidePolicyForNavigationAction:(WKNavigationAction *)action decisionHandler:(void (^)(WKNavigationActionPolicy))decision {
    (void)web;NSURL *url=action.request.URL;
    NSString *root=[NSBundle.mainBundle.resourceURL.path stringByAppendingPathComponent:@"ui/"];
    decision(url.isFileURL&&[url.path hasPrefix:root]?WKNavigationActionPolicyAllow:WKNavigationActionPolicyCancel);
}
- (void)reply:(NSNumber *)identifier result:(id)value error:(NSString *)error {
    NSDictionary *payload=@{@"id":identifier?:@0,@"result":value?:NSNull.null,@"error":error?:NSNull.null};
    NSData *data=[NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL];
    NSString *json=[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding];
    if(json)[self.web evaluateJavaScript:[NSString stringWithFormat:@"window.flowReceive(%@)",json] completionHandler:nil];
}
- (void)logBattery {
    if(![self.battery[@"valid"] boolValue])return;
    NSString *folder=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Flow2Studio"];
    if(![NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:NULL])return;
    NSString *path=[folder stringByAppendingPathComponent:@"history.csv"];BOOL exists=[NSFileManager.defaultManager fileExistsAtPath:path];
    FILE *file=fopen(path.fileSystemRepresentation,"a");if(!file)return;
    if(!exists)fputs("response_time,connection_id,percent,power\n",file);
    NSString *time=[[NSISO8601DateFormatter new]stringFromDate:NSDate.date];
    NSString *power=self.battery[@"power"]?([self.battery[@"power"]boolValue]?@"1":@"0"):@"";
    fprintf(file,"%s,%s,%d,%s\n",time.UTF8String,[self.selected[@"id"] description].UTF8String,[self.battery[@"percent"] intValue],power.UTF8String);fclose(file);
}
- (NSImage *)menuImage:(NSString *)style percent:(int)percent valid:(BOOL)valid {
    (void)percent;(void)valid;BOOL logo=[style isEqual:@"logo"],power=[self.battery[@"power"]boolValue];
    CGFloat width=logo?21:27;
    NSImage *image=[NSImage imageWithSize:NSMakeSize(width+(power?28:0),20) flipped:NO drawingHandler:^BOOL(NSRect frame){
        (void)frame;[NSColor.blackColor set];
        if(logo){NSFont *font=[[NSFontManager sharedFontManager]convertFont:[NSFont systemFontOfSize:23 weight:NSFontWeightSemibold]toHaveTrait:NSItalicFontMask];
            NSAttributedString *text=[[NSAttributedString alloc]initWithString:@"f." attributes:@{NSFontAttributeName:font,NSForegroundColorAttributeName:NSColor.blackColor}];[text drawAtPoint:NSMakePoint(0,(20-text.size.height)/2)];
        }else{
            NSBezierPath *body=[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(1,3.5,25,13) xRadius:2.2 yRadius:2.2];body.lineWidth=1.25;[body stroke];
            for(int row=0;row<2;row++)for(int col=0;col<6;col++)NSRectFill(NSMakeRect(4+col*3.3,11.5-row*3,1.8,1.3));
            NSBezierPath *space=[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(7,6,13,1.4) xRadius:.6 yRadius:.6];[space fill];
        }
        if(power){CGFloat x=width+5;NSBezierPath *bolt=[NSBezierPath bezierPath];
            [bolt moveToPoint:NSMakePoint(x+10,18)];[bolt lineToPoint:NSMakePoint(x+2,8)];[bolt lineToPoint:NSMakePoint(x+8,8)];[bolt lineToPoint:NSMakePoint(x+6,2)];[bolt lineToPoint:NSMakePoint(x+16,12)];[bolt lineToPoint:NSMakePoint(x+10,12)];[bolt closePath];
            bolt.lineWidth=1.25;bolt.lineJoinStyle=NSLineJoinStyleRound;[bolt stroke];
        }return YES;
    }];image.template=YES;return image;
}
- (NSDictionary *)menuPreviews {
    if(self.cachedMenuPreviews)return self.cachedMenuPreviews;
    NSMutableDictionary *assets=[NSMutableDictionary dictionary];
    for(NSString *style in @[@"keyboardPercent",@"logo"]){
        NSImage *image=[self menuImage:style percent:38 valid:YES];
        NSBitmapImageRep *rep=[[NSBitmapImageRep alloc]initWithData:image.TIFFRepresentation];
        NSData *png=[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        if(png)assets[style]=[NSString stringWithFormat:@"data:image/png;base64,%@",[png base64EncodedStringWithOptions:0]];
    }self.cachedMenuPreviews=[assets copy];return self.cachedMenuPreviews;
}
- (void)renderStatus {
    for(NSMenuItem *item in self.status.menu.itemArray)if([item.representedObject isKindOfClass:NSString.class])item.title=FlowLocalized(item.representedObject);
    BOOL valid=[self.battery[@"valid"]boolValue];int percent=[self.battery[@"percent"]intValue];
    NSString *style=[self preferences][@"batteryStyle"];BOOL logo=[style isEqual:@"logo"];
    self.status.button.title=logo?@"":valid?[NSString stringWithFormat:@" %d%%",percent]:@" —";
    self.status.button.image=[self menuImage:style percent:percent valid:valid];
    self.status.button.imagePosition=NSImageLeading;
    NSString *name=self.selected?[NSString stringWithFormat:FlowLocalized(@"Клавиатура Lofree Flow 2 %@"),self.selected[@"model"]?:@""]:@"Flow 2 Studio";
    NSString *text=valid?[NSString stringWithFormat:@"%@ · %d%% · %@",name,percent,FlowLocalized(self.selected[@"connection"]?:@"")]:[name stringByAppendingString:FlowLocalized(@" · заряд недоступен")];
    if([self.battery[@"power"]boolValue])text=[text stringByAppendingString:[self.battery[@"full"]boolValue]?FlowLocalized(@" · Питание подключено, заряд полный"):FlowLocalized(@" · Заряжается")];
    self.status.button.toolTip=text;self.status.button.accessibilityLabel=text;self.batteryMenu.title=text;
}
- (void)readCharge:(NSDictionary *)device request:(NSNumber *)identifier {
    [self readCharge:device request:identifier forcePercent:NO];
}
- (void)readCharge:(NSDictionary *)device request:(NSNumber *)identifier forcePercent:(BOOL)forcePercent {
    if(self.terminating)return;
    if(self.firmwareBusy){if(identifier.unsignedIntegerValue)[self reply:identifier result:nil error:FlowLocalized(@"Идёт подготовка клавиатуры.")];return;}
    self.chargeForcePercent=self.chargeForcePercent||forcePercent;
    if(self.chargePending){if(identifier.unsignedIntegerValue)[self reply:identifier result:self.battery?:@{@"pending":@YES} error:nil];return;}
    self.chargePending=YES;self.lastChargeAttempt=NSProcessInfo.processInfo.systemUptime;
    NSUInteger generation=self.selectionGeneration;
    void (^complete)(NSDictionary *,NSError *)=^(NSDictionary *value,NSError *error){
        BOOL forced=self.chargeForcePercent;self.chargeForcePercent=NO;self.chargePending=NO;
        if(self.terminating)return;
        if(generation!=self.selectionGeneration||self.sleeping||![self.selected[@"id"]isEqual:device[@"id"]]){
            if(identifier.unsignedIntegerValue)[self reply:identifier result:nil error:FlowLocalized(@"Выбранное устройство изменилось.")];
            if(forced&&self.selected&&!self.sleeping&&!self.firmwareBusy)[self readCharge:self.selected request:@0 forcePercent:YES];
            return;
        }
        NSDictionary *display=value;
        if(value&&!forced&&!identifier.unsignedIntegerValue&&![[self preferences][@"autoCharge"]boolValue]&&self.battery){NSMutableDictionary *powerOnly=[value mutableCopy];powerOnly[@"percent"]=self.battery[@"percent"]?:@0;powerOnly[@"valid"]=self.battery[@"valid"]?:@NO;display=powerOnly;}
        self.battery=display;self.batteryDate=value?NSDate.date:nil;[self renderStatus];[self logBattery];
        [self reply:identifier result:identifier.unsignedIntegerValue?(id)display:@{@"battery":display?:NSNull.null} error:error.localizedDescription];
    };
    if([device[@"connection"]isEqual:@"Bluetooth"]&&![device[@"vendor"]boolValue]){
        if(!self.bleBattery)self.bleBattery=[FlowBLEBattery new];
        [self.bleBattery readDevice:device completion:complete];
    }else{
        FlowHIDEnqueue(self.worker,^{NSError *error=nil;NSDictionary *value=FlowPerform(device,@"status",@{},&error);
            dispatch_async(dispatch_get_main_queue(),^{
                if(self.terminating){self.chargePending=NO;self.chargeForcePercent=NO;return;}
                if(!value&&[device[@"connection"]isEqual:@"Bluetooth"]){if(!self.bleBattery)self.bleBattery=[FlowBLEBattery new];[self.bleBattery readDevice:device completion:complete];}
                else complete(value,error);
            });});
    }
}
- (void)webView:(WKWebView *)webView runJavaScriptConfirmPanelWithMessage:(NSString *)message initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(BOOL))completionHandler {
    (void)webView;if(!frame.isMainFrame){completionHandler(NO);return;}
    NSAlert *alert=[NSAlert new];alert.messageText=FlowLocalized(message);[alert addButtonWithTitle:FlowLocalized(@"Продолжить")];[alert addButtonWithTitle:FlowLocalized(@"Отмена")];completionHandler([alert runModal]==NSAlertFirstButtonReturn);
}
- (void)refreshCharge {
    if(!self.selected||self.sleeping||self.firmwareBusy||self.terminating)return;
    [self readCharge:self.selected request:@0];
}
- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message {
    (void)controller;
    if(!message.frameInfo.isMainFrame||![message.body isKindOfClass:NSDictionary.class])return;
    NSDictionary *body=message.body;NSNumber *identifier=body[@"id"];NSString *action=body[@"action"];
    if(![identifier isKindOfClass:NSNumber.class]||![action isKindOfClass:NSString.class]||self.terminating)return;
    NSDictionary *args=[body[@"args"]isKindOfClass:NSDictionary.class]?body[@"args"]:@{};
    if([action isEqual:@"checkUpdates"]){FlowCheckUpdates([args[@"force"]boolValue],^(NSDictionary *result,NSString *error){[self reply:identifier result:result error:error?FlowLocalized(error):nil];});return;}
    if([action isEqual:@"openUpdate"]){BOOL opened=!self.firmwareBusy&&FlowOpenUpdate();[self reply:identifier result:opened?@{@"opened":@YES}:nil error:opened?nil:FlowLocalized(@"Не удалось открыть ссылку в браузере.")];return;}
    if([action isEqual:@"openExternal"]){
        NSDictionary *links=@{@"github":@"https://github.com/BagaT2K",@"kofi":@"https://ko-fi.com/bagat2k/tip"};
        NSString *key=[args[@"link"]isKindOfClass:NSString.class]?args[@"link"]:nil;
        NSString *destination=key?links[key]:nil;
        BOOL opened=destination&&[NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:destination]];
        [self reply:identifier result:opened?@{@"opened":@YES}:nil error:opened?nil:FlowLocalized(@"Не удалось открыть ссылку в браузере.")];return;
    }
    if([action isEqual:@"openFirmwareBackups"]){NSString *path=[NSHomeDirectory()stringByAppendingPathComponent:@"Library/Application Support/Flow2Studio/FirmwareBackups"];[NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:path isDirectory:YES]];[self reply:identifier result:@{@"opened":@YES}error:nil];return;}
    if([action isEqual:@"startMacroRecording"]){
        if(self.firmwareBusy){[self reply:identifier result:nil error:FlowLocalized(@"Дождитесь завершения подготовки.")];return;}
        if(!self.macroRecorder){__weak Studio *weak=self;self.macroRecorder=[[FlowMacroRecorder alloc]initWithSink:^(NSDictionary *event){if([event[@"macroKey"][@"down"]boolValue])[weak editingActivityOccurred];[weak reply:@0 result:event error:nil];}];}
        BOOL started=[self.macroRecorder startForWindow:self.window];[self reply:identifier result:started?@{@"recording":@YES,@"source":@"native"}:nil error:started?nil:FlowLocalized(@"Откройте окно Studio, чтобы записать макрос.")];return;
    }
    if([action isEqual:@"stopMacroRecording"]){[self.macroRecorder stopNotifying:NO reason:nil];[self reply:identifier result:@{@"recording":@NO} error:nil];return;}
    if([action isEqual:@"preferences"]){[self reply:identifier result:[self preferences] error:nil];return;}
    if([action isEqual:@"savePreferences"]){
        NSUserDefaults *d=NSUserDefaults.standardUserDefaults;
        if(FlowLanguageSupported(args[@"language"]))[d setObject:args[@"language"]forKey:@"language"];
        if([@[@"dark",@"light"]containsObject:args[@"theme"]])[d setObject:args[@"theme"] forKey:@"theme"];
        if([@[@"keyboardPercent",@"logo"]containsObject:args[@"batteryStyle"]])[d setObject:args[@"batteryStyle"] forKey:@"batteryStyle"];
        if([args[@"editingConnection"]isKindOfClass:NSNumber.class]){[d setBool:[args[@"editingConnection"]boolValue]forKey:@"editingConnection"];[self stopEditing];[self updateEditing];}
        if([args[@"autoCharge"]isKindOfClass:NSNumber.class])[d setBool:[args[@"autoCharge"]boolValue]forKey:@"autoCharge"];
        if(self.selected&&[@[@"white",@"black"]containsObject:args[@"keycaps"]]){
            NSMutableDictionary *caps=[[d dictionaryForKey:@"keycaps"]mutableCopy]?:[NSMutableDictionary dictionary];caps[self.selected[@"key"]]=args[@"keycaps"];[d setObject:caps forKey:@"keycaps"];
        }
        [self appearance];[self renderStatus];[self reply:identifier result:[self preferences]error:nil];return;
    }
    if([action isEqual:@"cancelFirmwareConfirmation"]){self.firmwareConfirmation=nil;[self reply:identifier result:@{@"cancelled":@YES}error:nil];return;}
    if(self.firmwareBusy){if([action isEqual:@"scan"])[self reply:identifier result:@{@"devices":self.selected?@[self.selected]:@[]} error:nil];else [self reply:identifier result:nil error:FlowLocalized(@"Дождитесь завершения подготовки клавиатуры.")];return;}
    if([action isEqual:@"scan"]){NSMutableArray *devices=[FlowDevices() mutableCopy];[devices addObjectsFromArray:FlowFirmwareDevices()];
        if(self.selected){BOOL present=NO;for(NSDictionary *device in devices)if([device[@"id"]isEqual:self.selected[@"id"]])present=YES;
          if(!present){[self.macroRecorder stopNotifying:YES reason:FlowLocalized(@"Запись остановлена: устройство отключено.")];self.selectionGeneration++;[self.bleBattery cancel];FlowBLESerialReset();self.selected=nil;[self stopEditing];self.battery=nil;[self renderStatus];}}
        [self reply:identifier result:@{@"devices":devices}error:nil];return;
    }
    NSDictionary *selected=nil;
    NSMutableArray *allDevices=[FlowDevices()mutableCopy];[allDevices addObjectsFromArray:FlowFirmwareDevices()];
    for(NSDictionary *d in allDevices)if([d[@"id"]isEqual:body[@"device"]]){selected=d;break;}
    if(!selected){[self reply:identifier result:nil error:FlowLocalized(@"Устройство отключено")];return;}
    if([action isEqual:@"preparationStatus"]){[self reply:identifier result:FlowFirmwareStatus(selected) error:nil];return;}
    if([action isEqual:@"prepareKeyboard"]||[action isEqual:@"restoreFirmware"]||[action isEqual:@"restoreBackup"]||[action isEqual:@"installOEM14"]||[action isEqual:@"rollbackOEM14"]){
        [self.macroRecorder stopNotifying:YES reason:FlowLocalized(@"Запись остановлена перед подготовкой клавиатуры.")];
        unsigned restoreMode=[action isEqual:@"restoreFirmware"]?1:[action isEqual:@"restoreBackup"]?2:[action isEqual:@"installOEM14"]?3:[action isEqual:@"rollbackOEM14"]?4:0;BOOL restore=restoreMode!=0;NSDictionary *status=FlowFirmwareStatus(selected);
        if(![status[@"available"]boolValue]||(!restore&&![status[@"canPrepare"]boolValue])||(restore&&(!(restoreMode==1?[status[@"canRestoreFactory"]boolValue]:[status[@"canRestore"]boolValue])||(![status[@"wired"]boolValue]&&![status[@"recovery"]boolValue])))){[self reply:identifier result:nil error:status[@"message"]?:FlowLocalized(@"Подключите клавиатуру кабелем для подготовки.")];return;}
        NSString *consentToken=[args[@"confirmationToken"]isKindOfClass:NSString.class]?args[@"confirmationToken"]:nil;
        NSDictionary *proposal=self.firmwareConfirmation;
        if(consentToken&&!flow_firmware_consent_valid(NSProcessInfo.processInfo.systemUptime,[proposal[@"deadline"]doubleValue],self.selectionGeneration,[proposal[@"generation"]unsignedLongLongValue],[proposal[@"token"]isEqual:consentToken],[proposal[@"action"]isEqual:action]&&[proposal[@"device"]isEqual:selected[@"id"]])){self.firmwareConfirmation=nil;[self reply:identifier result:nil error:FlowLocalized(@"Подтверждение устарело или устройство изменилось. Откройте окно обновления заново. Запись не начата.")];return;}
        NSDictionary *chosenBackup=restoreMode==2&&consentToken?proposal[@"backup"]:nil;
        if(restoreMode==2&&!consentToken){
            NSOpenPanel *panel=[NSOpenPanel openPanel];panel.title=FlowLocalized(@"Выберите резервную копию прошивки");panel.message=FlowLocalized(@"Выберите original.bin, before.bin или другой сохранённый полный образ Flow 2 68, 84 или 100.");panel.prompt=FlowLocalized(@"Выбрать копию");panel.allowedContentTypes=@[[UTType typeWithFilenameExtension:@"bin"]?:UTTypeData];panel.canChooseFiles=YES;panel.canChooseDirectories=NO;panel.allowsMultipleSelection=NO;
            panel.directoryURL=[NSURL fileURLWithPath:[NSHomeDirectory()stringByAppendingPathComponent:@"Library/Application Support/Flow2Studio/FirmwareBackups"]isDirectory:YES];
            if([panel runModal]!=NSModalResponseOK){[self reply:identifier result:@{@"cancelled":@YES}error:nil];return;}
            NSError *backupError=nil;chosenBackup=FlowFirmwareReadBackup(panel.URL,&backupError);
            if(!chosenBackup){[self reply:identifier result:nil error:backupError.localizedDescription];return;}
        }
        if(!flow_firmware_backup_selection_valid(restoreMode,[selected[@"bootloader"]boolValue],[chosenBackup[@"model"]intValue],[selected[@"model"]intValue],[chosenBackup[@"image"]isKindOfClass:NSData.class]&&[chosenBackup[@"image"]length]==262144)){self.firmwareConfirmation=nil;[self reply:identifier result:nil error:FlowLocalized(@"Резервная копия относится к другой модели клавиатуры. Запись не начата.")];return;}
        if(!consentToken){
            NSString *title=restoreMode==3?FlowLocalized(@"Установить заводскую Lofree 0.14?"):restoreMode==4?FlowLocalized(@"Вернуть прошивку до обновления?"):restoreMode==1?FlowLocalized(@"Установить заводскую прошивку?"):restoreMode==2?FlowLocalized(@"Восстановить из копии?"):FlowLocalized(@"Подготовить клавиатуру?");
            NSString *model=chosenBackup[@"model"]?:status[@"model"]?:selected[@"model"]?:@"";
            NSString *details=restoreMode==0?[NSString stringWithFormat:FlowLocalized(@"Flow 2 %@ → Studio 0.9 на официальной базе Lofree 0.14.\n\nПри ошибке записи Studio попытается вернуть прежний образ. Сохранённую копию можно выбрать вручную. Оставьте USB подключённым и закройте VIA."),model]:restoreMode==1?[NSString stringWithFormat:FlowLocalized(@"Будет установлена заводская Lofree 0.14 для Flow 2 %@ без расширений Studio. Текущая прошивка будет сохранена и проверена. Не отключайте USB."),model]:restoreMode==2?[NSString stringWithFormat:FlowLocalized(@"Файл: %@\nПрошивка: %@\nМодель: Flow 2 %@\n\nТекущий образ будет сохранён перед восстановлением. Не отключайте USB."),chosenBackup[@"file"],FlowLocalized(chosenBackup[@"label"]),model]:FlowLocalized(@"Будет восстановлена проверенная прошивка, сохранённая перед обновлением. Используйте тот же USB-порт. Для другого порта выберите before.bin вручную. Не отключайте USB.");
            NSString *token=NSUUID.UUID.UUIDString;
            self.firmwareConfirmation=@{@"token":token,@"action":action,@"device":selected[@"id"],@"generation":@(self.selectionGeneration),@"deadline":@(NSProcessInfo.processInfo.systemUptime+120),@"backup":chosenBackup?:@{}};
            NSString *warning=FlowLocalized(@"Обновление выполняется на ваш страх и риск. При ошибке Studio попытается восстановить прежнюю прошивку из проверенной копии. При отключении питания, потере USB или неисправности устройства откат может потребовать отдельного восстановления и не гарантируется.");
            [self reply:identifier result:@{@"confirmation":@{@"token":token,@"title":title,@"details":details,@"warning":warning,@"model":selected[@"model"]?:@"",@"confirmLabel":restoreMode==3?FlowLocalized(@"Установить 0.14"):restore?FlowLocalized(@"Восстановить"):FlowLocalized(@"Обновить прошивку")}}error:nil];return;
        }
        self.firmwareConfirmation=nil; // Single use, bound to action/device/selection generation.
        // A cached extension belongs to the pre-flash firmware. Invalidate it
        // after confirmation, including interrupted operations, before reconnect.
        NSMutableDictionary *verified=[[NSUserDefaults.standardUserDefaults dictionaryForKey:@"verifiedCapabilities.v1"]mutableCopy]?:[NSMutableDictionary dictionary];
        if(selected[@"key"]){[verified removeObjectForKey:selected[@"key"]];[NSUserDefaults.standardUserDefaults setObject:verified forKey:@"verifiedCapabilities.v1"];}
        self.firmwareBusy=YES;[self stopEditing];self.selectionGeneration++;[self.bleBattery cancel];FlowBLESerialReset();self.battery=nil;[self renderStatus];
        FlowHIDEnqueue(self.worker,^{
            IOPMAssertionID power=kIOPMNullAssertionID;IOReturn assertion=IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep,kIOPMAssertionLevelOn,CFSTR("Flow 2 keyboard preparation"),&power);
            NSError *error=nil;NSDictionary *result=nil;
            if(assertion==kIOReturnSuccess){result=FlowFirmwarePrepare(selected,restoreMode,chosenBackup[@"image"],^(NSDictionary *step){dispatch_async(dispatch_get_main_queue(),^{[self reply:@0 result:@{@"preparation":step}error:nil];});},&error);IOPMAssertionRelease(power);}
            else error=[NSError errorWithDomain:@"Flow2Firmware" code:1 userInfo:@{NSLocalizedDescriptionKey:FlowLocalized(@"Не удалось удержать Mac от автоматического сна. Подготовка не начата.")}];
            dispatch_async(dispatch_get_main_queue(),^{self.firmwareBusy=NO;if(result&&![result[@"cancelled"]boolValue])[self.deferred clear:selected[@"key"]];self.selected=nil;[self reply:identifier result:result error:error.localizedDescription];});
        });return;
    }
    if([action isEqual:@"cachedState"]){NSDictionary *caps=[NSUserDefaults.standardUserDefaults dictionaryForKey:@"verifiedCapabilities.v1"][selected[@"key"]];if(caps&&![caps[@"profile"][@"zoneAnimationsSupported"]boolValue]&&[caps[@"effect"]unsignedIntValue]>1){NSMutableDictionary *m=[caps mutableCopy];m[@"effect"]=@1;m[@"waveSpeed"]=@1;m[@"effectFamily"]=@"zones-v1";caps=m;}[self reply:identifier result:@{@"caps":caps?:NSNull.null,@"jobs":[self.deferred jobs:selected[@"key"]]} error:nil];return;}
    if([action isEqual:@"clearDeferred"]){[self.deferred clear:selected[@"key"]];[self publishDeferred];[self reply:identifier result:@{@"cleared":@YES} error:nil];return;}
    if([action isEqual:@"initializeLayers"]&&[[NSUserDefaults.standardUserDefaults arrayForKey:@"initializedLayers.v1"]containsObject:selected[@"key"]]){[self reply:identifier result:@{@"initialized":@YES,@"changedLayers":@[]} error:nil];return;}
    if([action isEqual:@"select"]){[self.macroRecorder stopNotifying:YES reason:FlowLocalized(@"Запись остановлена: выбрано устройство.")];[self stopEditing];self.selectionGeneration++;[self.bleBattery cancel];FlowBLESerialReset();self.firmwareConfirmation=nil;self.selected=selected;[self editingActivityOccurred];self.battery=nil;[self renderStatus];[self reply:identifier result:selected error:nil];return;}
    if(![@[@"status",@"capabilities",@"lighting",@"readLayer",@"setKey",@"setLayer",@"resetLayer",@"layerTemplate",@"initializeLayers",@"profile",@"advanced",@"wake",@"readMacros",@"saveMacros",@"resetKeys",@"resetAll"]containsObject:action]){[self reply:identifier result:nil error:FlowLocalized(@"Действие недоступно")];return;}
    if([action isEqual:@"status"]){
        if(self.sleeping){[self reply:identifier result:nil error:FlowLocalized(@"Mac засыпает.")];return;}
        [self readCharge:selected request:identifier];return;
    }
    if([action isEqual:@"resetLayer"]){NSAlert *alert=[NSAlert new];alert.messageText=[NSString stringWithFormat:FlowLocalized(@"Вернуть заводские назначения слоя %d?"),[args[@"layer"]intValue]+1];alert.informativeText=FlowLocalized(@"Изменится только выбранный слой. Остальные слои сохранятся. Изменение можно отменить в истории текущей сессии.");[alert addButtonWithTitle:FlowLocalized(@"Отмена")];[alert addButtonWithTitle:FlowLocalized(@"Сбросить слой")];if([alert runModal]!=NSAlertSecondButtonReturn){[self reply:identifier result:@{@"cancelled":@YES} error:nil];return;}}
    if([action isEqual:@"resetKeys"]||[action isEqual:@"resetAll"]){
        NSAlert *alert=[NSAlert new];alert.messageText=[action isEqual:@"resetAll"]?FlowLocalized(@"Сбросить настройки клавиатуры?"):FlowLocalized(@"Восстановить заводские назначения?");
        alert.informativeText=[action isEqual:@"resetAll"]?FlowLocalized(@"Будут сброшены назначения всех 6 слоёв, макросы, яркость, эффект и поддерживаемый профиль индикатора/таймера. Сопряжения Bluetooth, прошивка и патч панели сохранятся. Перед записью приложение сохранит резервные копии."):FlowLocalized(@"Будут восстановлены заводские назначения всех 6 слоёв. Макросы и подсветка сохранятся. Перед записью приложение сохранит резервную копию.");
        [alert addButtonWithTitle:FlowLocalized(@"Отмена")];[alert addButtonWithTitle:FlowLocalized(@"Сбросить")];
        if([alert runModal]!=NSAlertSecondButtonReturn){[self reply:identifier result:@{@"cancelled":@YES} error:nil];return;}
    }
    if([FlowDeferredStore accepts:action]&&[self.deferred jobs:selected[@"key"]].count){
        [self.deferred enqueue:action arguments:args deviceKey:selected[@"key"]];
        NSMutableDictionary *queued=[args mutableCopy];queued[@"queued"]=@YES;[self reply:identifier result:queued error:nil];[self publishDeferred];[self processDeferred];return;
    }
    self.editingActivity=NSProcessInfo.processInfo.systemUptime;self.editingBlocked=NO;[self updateEditing];
    NSDictionary *requestArgs=args;
    FlowHIDEnqueue(self.worker,^{NSError *error=nil;NSDictionary *result=FlowPerform(selected,action,requestArgs,&error);
      dispatch_async(dispatch_get_main_queue(),^{
        if(!result&&[error.domain isEqual:@"Flow2Studio"]&&error.code==2&&[FlowDeferredStore accepts:action]){
            [self.deferred enqueue:action arguments:requestArgs deviceKey:selected[@"key"]];NSMutableDictionary *queued=[requestArgs mutableCopy];queued[@"queued"]=@YES;
            [self reply:identifier result:queued error:nil];[self publishDeferred];return;
        }
        if(result){
            if([action isEqual:@"initializeLayers"]){NSMutableArray *done=[[NSUserDefaults.standardUserDefaults arrayForKey:@"initializedLayers.v1"]mutableCopy]?:[NSMutableArray array];if(![done containsObject:selected[@"key"]])[done addObject:selected[@"key"]];[NSUserDefaults.standardUserDefaults setObject:done forKey:@"initializedLayers.v1"];}
            if([action isEqual:@"resetLayer"]&&![result[@"cancelled"]boolValue]){for(NSDictionary *job in [self.deferred jobs:selected[@"key"]])if([@[@"setKey",@"setLayer"]containsObject:job[@"action"]]&&[job[@"args"][@"layer"]isEqual:requestArgs[@"layer"]])[self.deferred complete:job[@"id"] deviceKey:selected[@"key"]];[self publishDeferred];}
            [self cacheResult:result action:action device:selected];
            if([@[@"resetAll",@"resetKeys"]containsObject:action]&&![result[@"cancelled"]boolValue]){if([action isEqual:@"resetAll"])[self.deferred clear:selected[@"key"]];else for(NSDictionary *job in [self.deferred jobs:selected[@"key"]])if([@[@"setKey",@"setLayer"]containsObject:job[@"action"]])[self.deferred complete:job[@"id"] deviceKey:selected[@"key"]];[self publishDeferred];}
        }
        NSDictionary *profile=[@[@"profile",@"advanced"]containsObject:action]?result:result[@"profile"];
        if([self.selected[@"id"]isEqual:selected[@"id"]]&&profile[@"timeout"]){self.editingTimeout=[profile[@"timeout"]unsignedIntValue];[self updateEditing];}
        [self reply:identifier result:result error:error.localizedDescription];
      });});
}
- (void)cacheResult:(NSDictionary *)result action:(NSString *)action device:(NSDictionary *)device {
    NSString *key=device[@"key"];if(!key)return;
    NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;NSMutableDictionary *all=[[defaults dictionaryForKey:@"verifiedCapabilities.v1"]mutableCopy]?:[NSMutableDictionary dictionary];
    NSMutableDictionary *caps=[all[key]mutableCopy];
    if([action isEqual:@"capabilities"]&&[result[@"profileSupported"]boolValue])caps=[result mutableCopy];
    else if(caps){if([@[@"profile",@"advanced"]containsObject:action])caps[@"profile"]=result;else if([action isEqual:@"lighting"])[caps addEntriesFromDictionary:result];}
    if(caps){all[key]=caps;[defaults setObject:all forKey:@"verifiedCapabilities.v1"];}
}
- (void)publishDeferred {
    NSString *key=self.selected[@"key"];if(!key)return;
    NSArray *jobs=[self.deferred jobs:key];BOOL paused=jobs.count>0;for(NSDictionary *job in jobs)if(!job[@"error"])paused=NO;[self reply:@0 result:@{@"deferred":@{@"device":self.selected[@"id"],@"count":@(jobs.count),@"paused":@(paused)}} error:nil];
}
- (void)processDeferred {
    if(self.deferredRunning||self.firmwareBusy||self.sleeping||self.terminating||!self.selected)return;
    NSDictionary *device=self.selected;NSString *key=device[@"key"];NSArray *jobs=[self.deferred jobs:key];if(!jobs.count)return;
    NSDictionary *job=nil;for(NSDictionary *candidate in jobs)if(!candidate[@"error"]){job=candidate;break;}if(!job)return;
    double now=NSProcessInfo.processInfo.systemUptime;if(now-self.lastDeferredAttempt<4)return;self.lastDeferredAttempt=now;self.deferredRunning=YES;
    FlowHIDEnqueue(self.worker,^{NSError *error=nil;
        // Poll only a nonce status read while waiting; start the bounded editing operation
        // only after the keyboard answers, including when Studio is minimized.
        NSDictionary *online=FlowPerform(device,@"status",@{},&error);BOOL waiting=online==nil;
        NSDictionary *result=nil;if(!waiting){error=nil;result=FlowPerform(device,job[@"action"],job[@"args"],&error);}
        dispatch_async(dispatch_get_main_queue(),^{self.deferredRunning=NO;
            if(result){[self.deferred complete:job[@"id"] deviceKey:key];[self cacheResult:result action:job[@"action"] device:device];
                if([self.selected[@"id"]isEqual:device[@"id"]]){[self reply:@0 result:@{@"deferredApplied":@{@"device":device[@"id"],@"action":job[@"action"],@"args":job[@"args"],@"value":result,@"superseded":@([self.deferred jobs:key].count>0)}} error:nil];self.editingBlocked=NO;[self updateEditing];}
            }else if(!waiting&&!([error.domain isEqual:@"Flow2Studio"]&&error.code==2)){
                [self.deferred block:job[@"id"] error:error.localizedDescription deviceKey:key];if([self.selected[@"id"]isEqual:device[@"id"]])[self reply:@0 result:@{@"deferredError":@{@"device":device[@"id"],@"action":job[@"action"],@"args":job[@"args"],@"message":error.localizedDescription?:FlowLocalized(@"Настройка не подтверждена. Автоматическое применение приостановлено.")}} error:nil];
            }
            [self publishDeferred];
        });
    });
}
- (void)monitorConnections {
    if(self.sleeping||self.firmwareBusy||self.terminating)return;
    NSArray *devices=FlowDevices();NSMutableArray *usb=[NSMutableArray array];for(NSDictionary *device in devices)if([device[@"connection"]isEqual:@"USB"])[usb addObject:[device[@"id"]description]];
    NSString *inventory=[[usb sortedArrayUsingSelector:@selector(compare:)]componentsJoinedByString:@","];BOOL changed=![inventory isEqual:self.usbInventory];self.usbInventory=inventory;
    if(changed)[self reply:@0 result:@{@"connectionsChanged":@YES} error:nil];
    if(!self.selected||self.chargePending)return;
    BOOL foreground=flow_window_foreground(NSApp.active,self.window.keyWindow,self.window.visible&&(self.window.occlusionState&NSWindowOcclusionStateVisible)!=0,self.window.miniaturized);
    // Status reads do not start an editing lease. Plug changes trigger an immediate refresh;
    // GPIO power state also covers a charging cable while RF/Bluetooth remains selected.
    if(flow_battery_poll_due(NSProcessInfo.processInfo.systemUptime,self.lastChargeAttempt,foreground,[[self preferences][@"autoCharge"]boolValue],changed))[self refreshCharge];
}

@end
int main(void){@autoreleasepool{NSApplication *app=NSApplication.sharedApplication;[app setActivationPolicy:NSApplicationActivationPolicyRegular];
    __attribute__((objc_precise_lifetime)) Studio *delegate=[Studio new];app.delegate=delegate;[app run];}return 0;}
