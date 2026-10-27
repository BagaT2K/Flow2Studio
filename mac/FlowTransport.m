#include "FlowControl.h"
#include "FlowWake.h"
#include "FlowHIDResponse.h"
#include "FlowEditingPolicy.h"
#import "FlowTransport.h"
#include "FlowUSBBattery.h"
#import "FlowBLESerial.h"
#import <IOKit/IOKitLib.h>
#import <IOBluetooth/IOBluetooth.h>
#import <IOKit/hid/IOHIDManager.h>
#import <IOKit/hid/IOHIDKeys.h>
#include <string.h>
#include <stdlib.h>
#include <math.h>
#include "FlowProtocol.h"
#include "FlowPackets.h"
#include "FlowEditing.h"
#include "FlowFactory.h"
#include "FlowModels.h"
#include "FlowKeymapCore.h"
#include "FlowLayerIO.h"
#include "FlowBluetooth.h"

static void fail(NSError **error, NSString *message) {
    if (error) *error=[NSError errorWithDomain:@"Flow2Studio" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}
static void offline(NSError **error) {
 if(error)*error=[NSError errorWithDomain:@"Flow2Studio" code:2 userInfo:@{NSLocalizedDescriptionKey:@"Клавиатура спит или не отвечает. Изменения можно сохранить до восстановления связи."}];
}
static NSString *model(NSString *name, NSNumber *pid) {
    for (NSString *count in @[@"68",@"84",@"100"])
        if ([name rangeOfString:count].location!=NSNotFound) return count;
    if (pid.intValue==1) return @"68";
    if (pid.intValue==2) return @"84";
    if (pid.intValue==3) return @"100";
    if (pid.intValue==3) return @"100";
    return @"";
}
static BOOL flowName(NSString *name) {
    if (![name isKindOfClass:NSString.class]) return NO;
    NSString *compact=[[name.lowercaseString componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] componentsJoinedByString:@""];
    return [compact containsString:@"flow2"];
}
static id property(io_service_t service,NSString *key) {
    return CFBridgingRelease(IORegistryEntrySearchCFProperty(service,kIOServicePlane,(__bridge CFStringRef)key,kCFAllocatorDefault,kIORegistryIterateRecursively|kIORegistryIterateParents));
}
NSArray<NSDictionary *> *FlowDevices(void) {
    io_iterator_t it=0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault,IOServiceMatching("IOHIDDevice"),&it)!=KERN_SUCCESS) return @[];
    NSMutableDictionary *connections=[NSMutableDictionary dictionary];io_service_t service;
    while ((service=IOIteratorNext(it))) {
        CFMutableDictionaryRef raw=NULL;
        if (IORegistryEntryCreateCFProperties(service,&raw,kCFAllocatorDefault,0)!=KERN_SUCCESS) {IOObjectRelease(service);continue;}
        NSDictionary *p=CFBridgingRelease(raw);
        NSString *name=[p[@"Product"] isKindOfClass:NSString.class]?p[@"Product"]:@"";
        NSNumber *vid=p[@"VendorID"],*pid=p[@"ProductID"];
        if(!name.length){id inherited=property(service,@"Product");if([inherited isKindOfClass:NSString.class])name=inherited;}
        if (!flowName(name)) {IOObjectRelease(service);continue;}
        uint64_t registry=0;IORegistryEntryGetRegistryEntryID(service,&registry);
        NSString *transport=[p[@"Transport"] isKindOfClass:NSString.class]?p[@"Transport"]:@"USB";
        BOOL bleTransport=[transport.lowercaseString containsString:@"bluetooth"];
        NSData *descriptor=[p[@"ReportDescriptor"]isKindOfClass:NSData.class]?p[@"ReportDescriptor"]:nil;
        BOOL ble=bleTransport&&descriptor&&flow_ble_descriptor(descriptor.bytes,descriptor.length);
        BOOL vendor=(bleTransport&&(flow_model([model(name,@0)intValue]).model!=0))||(!bleTransport&&[p[@"PrimaryUsagePage"] intValue]==0xff60&&[p[@"PrimaryUsage"] intValue]==0x61);
        NSString *address=[property(service,@"DeviceAddress") description]?:[property(service,@"BD_ADDR") description];
        NSString *location=address.length?address:[p[@"LocationID"] description]?:[NSString stringWithFormat:@"%llu",(unsigned long long)registry];
        NSString *serial=[p[@"SerialNumber"] isKindOfClass:NSString.class]?p[@"SerialNumber"]:@"";
        NSString *usable=[serial stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"0 -"]];
        NSString *key=[NSString stringWithFormat:@"%@-%@-%@",pid?:@0,transport,usable.length?serial:location];
        if (!connections[key] || vendor) {
            int version=[p[@"VersionNumber"] intValue];
            NSString *route=[transport.lowercaseString containsString:@"bluetooth"]?@"Bluetooth":(version==0x2004?@"2.4 ГГц":@"USB");
            NSMutableDictionary *d=[@{@"id":@(registry),@"key":key,@"name":name,@"model":model(name,pid),@"connection":route,
              @"vendor":@(vendor),@"ble":@(ble),@"pid":pid?:@0,@"version":@(version),@"serial":serial} mutableCopy];
            if ([p[@"BatteryPercent"] isKindOfClass:NSNumber.class] && [p[@"BatteryPercent"] intValue]>=0 && [p[@"BatteryPercent"] intValue]<=100)
                d[@"systemBattery"]=p[@"BatteryPercent"];
            else {id battery=property(service,@"BatteryPercent");if([battery isKindOfClass:NSNumber.class]&&[battery intValue]>=0&&[battery intValue]<=100)d[@"systemBattery"]=battery;}
            d[@"vid"]=vid?:@0;
            id usbLocation=p[@"LocationID"]?:property(service,@"locationID")?:property(service,@"LocationID");if([usbLocation isKindOfClass:NSNumber.class])d[@"usbLocation"]=usbLocation;
            NSDictionary *previous=connections[key];
            if(!d[@"systemBattery"]&&previous[@"systemBattery"])d[@"systemBattery"]=previous[@"systemBattery"];
            connections[key]=d;
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(it);
    // Read already connected paired devices only. Never initiate a connection.
    // This fallback is view-only until a matching configuration HID service exists.
    for(IOBluetoothDevice *bt in [IOBluetoothDevice pairedDevices]) {
        if(!bt.isConnected||!flowName(bt.name))continue;
        BOOL found=NO;
        for(NSDictionary *d in connections.allValues)if([d[@"connection"]isEqual:@"Bluetooth"]&&[d[@"name"]isEqual:bt.name]){found=YES;break;}
        if(found)continue;
        NSString *key=[@"Bluetooth-" stringByAppendingString:bt.addressString?:bt.name];
        connections[key]=@{@"id":key,@"key":key,@"name":bt.name,@"model":model(bt.name,@0),@"connection":@"Bluetooth",@"vendor":@((flow_model([model(bt.name,@0)intValue]).model!=0)),@"pid":@0,@"version":@0,@"serial":@""};
    }
    return [[connections allValues] sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [a[@"key"] compare:b[@"key"]];}];
}

static void callback(void *context,IOReturn result,void *sender,IOHIDReportType type,uint32_t reportID,uint8_t *bytes,CFIndex length) {
    (void)sender;if(length<0)return;
    flow_hid_response_accept(context,result==kIOReturnSuccess,type==kIOHIDReportTypeInput,reportID,bytes,(size_t)length);
}
@class Session;
typedef struct { __unsafe_unretained Session *session; NSError *__autoreleasing *error; } WakeContext;
static bool wakeExchange(void *context,const uint8_t *request,uint8_t *reply);
@interface Session:NSObject { FlowWakeScope _wake; FlowHIDResponse _response; CFRunLoopRef _inputRunLoop; }
@property(nonatomic) IOHIDDeviceRef handle;
@property(nonatomic) uint8_t *input;
@property(nonatomic) BOOL ble;
@property(nonatomic) BOOL serial;
@property(nonatomic) BOOL windowLease;
@property(nonatomic) BOOL editingDark;
@property(nonatomic) BOOL profileBase14;
@property(nonatomic,strong) NSDictionary *device;
- (BOOL)packet:(const uint8_t *)request response:(uint8_t *)response error:(NSError **)error;
- (BOOL)rawPacket:(const uint8_t *)request response:(uint8_t *)response error:(NSError **)error;
- (BOOL)beginOperation:(NSError **)error;
- (void)endOperation;
- (void)attachInput;
- (void)releaseEditing;
@end
@implementation Session
- (BOOL)packet:(const uint8_t *)request response:(uint8_t *)response error:(NSError **)error {
    double now=NSProcessInfo.processInfo.systemUptime;
    if(flow_wake_due(&_wake,now)){
        uint8_t nonce[4];arc4random_buf(nonce,4);WakeContext context={self,error};
        BOOL renewed=NO;
        if(self.windowLease){
            uint8_t p[32],r[32]={0};flow_control_request(p,8,self.editingDark?2:1,0,0,nonce);
            renewed=[self rawPacket:p response:r error:error]&&flow_control_match(p,r)&&r[5]==0;
            if(renewed)_wake.renewed_at=now;
        }else renewed=flow_wake_refresh(&_wake,now,nonce,wakeExchange,&context);
        if(!renewed){
            if(!error||!*error)fail(error,@"Клавиатура не подтвердила продолжение операции. Команда не отправлена.");return NO;
        }
    }
    return [self rawPacket:request response:response error:error];
}
- (BOOL)rawPacket:(const uint8_t *)request response:(uint8_t *)response error:(NSError **)error {
    if(self.serial){
        NSData *data=FlowBLEExchange(self.device,[NSData dataWithBytes:request length:32],error);
        if(data.length!=32)return NO;memcpy(response,data.bytes,32);return YES;
    }
    // One callback registration and one stable context per open device.
    // HID work is pinned to the same NSThread; a serial GCD queue alone may migrate.
    NSCAssert(_inputRunLoop==CFRunLoopGetCurrent(),@"HID session moved to another run loop");
    uint8_t wire[32];
    if(self.ble&&!flow_ble_encode(request,wire)){fail(error,@"Пакет не помещается в служебный BLE-отчёт");return NO;}
    flow_hid_response_begin(&_response,request,self.ble);
    IOReturn result=IOHIDDeviceSetReport(self.handle,kIOHIDReportTypeOutput,self.ble?3:0,self.ble?wire:request,32);
    CFAbsoluteTime deadline=CFAbsoluteTimeGetCurrent()+(self.ble?3:2);
    while(!result&&!_response.done&&CFAbsoluteTimeGetCurrent()<deadline)CFRunLoopRunInMode(kCFRunLoopDefaultMode,.02,true);
    // A report arriving after timeout/completion is ignored until a new request.
    flow_hid_response_end(&_response);
    if(result||_response.done!=1){
        if(self.ble)fail(error,[NSString stringWithFormat:@"BLE: нет подтверждённого ответа на 0x%02x (SetReport=0x%08x, отчётов ID 3: %u, последняя длина: %ld, проверка: %d). Нажми клавишу и запусти Test-Bluetooth.command.",request[0],(unsigned)result,_response.reports,(long)_response.lastLength,_response.done]);
        else fail(error,_response.done==-1?@"Эта команда не поддерживается прошивкой":@"Нет корректного ответа. Нажми клавишу, закрой VIA и обнови устройство.");return NO;
    }
    memcpy(response,_response.reply,32);return YES;
}
- (void)releaseEditing {
    self.windowLease=NO;
    uint8_t nonce[4];arc4random_buf(nonce,4);
    NSError *__autoreleasing ignored=nil;WakeContext context={self,&ignored};
    flow_wake_release_editing(&_wake,nonce,wakeExchange,&context);
}
- (void)attachInput {
    NSCAssert(!_inputRunLoop,@"Input already attached");
    _inputRunLoop=(CFRunLoopRef)CFRetain(CFRunLoopGetCurrent());
    IOHIDDeviceRegisterInputReportCallback(self.handle,self.input,512,callback,&_response);
    IOHIDDeviceScheduleWithRunLoop(self.handle,_inputRunLoop,kCFRunLoopDefaultMode);
}

- (BOOL)beginOperation:(NSError **)error {
    uint8_t nonce[4];arc4random_buf(nonce,4);WakeContext context={self,error};
    BOOL ok=flow_wake_begin(&_wake,NSProcessInfo.processInfo.systemUptime,nonce,wakeExchange,&context);
    if(!ok&&(!error||!*error))fail(error,@"Клавиатура не подтвердила запрос пробуждения.");
    return ok;
}
- (void)endOperation {
    if(self.windowLease)return;
    uint8_t nonce[4];arc4random_buf(nonce,4);NSError *__autoreleasing ignored=nil;WakeContext context={self,&ignored};
    flow_wake_end(&_wake,nonce,wakeExchange,&context);
}
- (void)dealloc {
    flow_hid_response_end(&_response);
    if(_handle){
        if(_inputRunLoop)IOHIDDeviceUnscheduleFromRunLoop(_handle,_inputRunLoop,kCFRunLoopDefaultMode);
        IOHIDDeviceClose(_handle,kIOHIDOptionsTypeNone);CFRelease(_handle);
    }
    if(_inputRunLoop)CFRelease(_inputRunLoop);
    free(_input);
}
@end
static bool wakeExchange(void *context,const uint8_t *request,uint8_t *reply){
    WakeContext *c=context;return [c->session rawPacket:request response:reply error:c->error];
}
static BOOL query(Session *s,uint8_t command,uint8_t *reply,NSError **error){uint8_t p[32]={0};p[0]=command;return [s packet:p response:reply error:error];}
static NSData *readBuffer(Session *s,BOOL macro,unsigned offset,unsigned size,NSError **error) {
    NSMutableData *data=[NSMutableData dataWithLength:size];uint8_t *target=data.mutableBytes;
    for(unsigned n=0;n<size;){unsigned count=MIN(flow_read_chunk(s.ble&&!s.serial),size-n),o=offset+n;uint8_t p[32],r[32];
        if(!flow_buffer_request(p,macro,o,count)){fail(error,@"Некорректная область чтения");return nil;}
        if(![s packet:p response:r error:error])return nil;memcpy(target+n,r+4,count);n+=count;}
    return data;
}
static void backup(NSDictionary *device,NSString *kind,NSData *data,NSError **error) {
    NSString *folder=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Flow2Studio/Backups"];
    if(![[NSFileManager defaultManager]createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:error])return;
    NSString *name=[NSString stringWithFormat:@"%@-%llu-%@.bin",kind,(unsigned long long)(NSDate.date.timeIntervalSince1970*1000),device[@"id"]];
    [data writeToFile:[folder stringByAppendingPathComponent:name] options:NSDataWritingAtomic error:error];
}
static NSDictionary *control(Session *s,unsigned op,unsigned flags,unsigned brightness,unsigned seconds,NSError **error){
 uint8_t p[32],r[32],nonce[4];arc4random_buf(nonce,4);flow_control_request(p,op,flags,brightness,seconds,nonce);
 if(![s packet:p response:r error:error])return nil;
 if(!flow_control_match(p,r)||!flow_control_model_matches(r,[s.device[@"model"]intValue])){fail(error,[NSString stringWithFormat:@"Ответ не прошёл проверку LFC %u/%u (версия %u.%u, статус %u).",op,flags,r[21],r[22],r[5]]);return nil;}
 if(r[5]){
   NSString *reason=r[5]==2?@"Область профиля занята или команда временно недоступна. Настройки не перезаписаны.":@"Клавиатура отклонила условия команды.";

   fail(error,[NSString stringWithFormat:@"%@ [LFC %u/%u; код %u; Studio %u.%u; яркость %u%%; этап %u]",reason,op,flags,r[5],r[21],r[22],r[24],r[29]]);return nil;
 }
 unsigned generation=flow_control_generation(r);
 s.profileBase14=generation==19&&r[23]==0x14;
 return @{@"base14":@(s.profileBase14),@"rf":@((r[6]&1)!=0),@"bluetooth":@((r[6]&2)!=0),@"indicatorBrightness":@(r[7]),@"timeout":@((r[8]<<8)|r[9]),@"touchWake":@((r[6]&4)!=0),@"bootEntryPreserved":@(generation>=11),@"animationsSupported":@(generation>=15),@"zoneAnimationsSupported":@(generation>=15),@"fillAnimationSupported":@(generation>=16),@"animationMode":@(generation>=15?(r[28]&15):0),@"animationSpeed":@(generation>=15?(r[28]>>4):1),@"legacyAnimationMode":@(generation>=10&&generation<15?r[28]:0),@"usbBatteryRefreshSupported":@(generation>=9),@"zoneTestSupported":@(generation>=12),@"zoneDiagnosticsSupported":@(generation>=13),@"zoneChargingSupported":@(generation>=14),@"zoneBlockMask":@(generation>=13?r[27]:0),@"sleepState":@(generation>=13?r[30]:0),@"powerState":@(generation>=13?r[31]:0),@"zoneTestStage":@(generation>=12?r[29]:0),@"independentIndicatorSupported":@(generation>=18),@"independentSyncBrightnessSupported":@(generation>=17),@"firmwareVersion":[NSString stringWithFormat:@"%u.%u",r[21],r[22]],@"editingSleepSupported":@(r[10]==255&&generation>=3),@"fullLightSleepSupported":@(r[10]==255&&generation>=4),@"rfLightGateSupported":@(r[10]==255&&generation>=5),@"packedStateSupported":@(r[10]==255&&generation>=6),@"quietReleaseSupported":@(r[10]==255&&generation>=7),@"advancedSupported":@(generation>=8),@"lowBatteryThreshold":@(generation>=8?r[25]:0),@"syncBrightness":@(generation>=8&&r[26]==1),@"syncBreathing":@((r[6]&8)!=0),@"mainBrightness":@(r[24]),@"fineBrightness":@YES,@"keepAwakeSupported":@YES,@"capabilityBits":@(r[10]),@"model":s.device[@"model"]};
}
static BOOL writeBuffer(Session *s,BOOL macro,NSData *data,NSError **error){
 const uint8_t *b=data.bytes;unsigned size=(unsigned)data.length;FlowModel shape=flow_model([s.device[@"model"]intValue]);
 if(!shape.model||(macro&&size!=shape.macroBytes)||(!macro&&size!=shape.keyBytes)){fail(error,@"Некорректный размер памяти");return NO;}
 uint8_t p[32],r[32];
 // Last byte is the stock macro-validity guard: disable invocation during transfer.
 if(macro){flow_buffer_request(p,YES,size-1,1);p[0]=0xf;p[4]=255;if(![s packet:p response:r error:error])return NO;}
 for(unsigned n=0;n<size;){unsigned count=MIN(28,size-n);flow_buffer_request(p,macro,n,count);p[0]=macro?0xf:0x13;memcpy(p+4,b+n,count);if(![s packet:p response:r error:error])return NO;n+=count;}
 NSData *actual=readBuffer(s,macro,0,size,error);if(!actual)return NO;
 if(![actual isEqual:data]){fail(error,@"Проверка записанной памяти не совпала");return NO;}return YES;
}
static BOOL setAnimation(Session *s,NSDictionary *profile,unsigned mode,unsigned speed,NSError **error){
 if(mode==5&&![profile[@"fillAnimationSupported"]boolValue]){fail(error,@"Для режима «Водопад» обновите расширение по USB.");return NO;}
 if([profile[@"zoneAnimationsSupported"]boolValue]){
  if([profile[@"animationMode"]unsignedIntValue]!=mode||[profile[@"animationSpeed"]unsignedIntValue]!=speed)return control(s,11,mode,speed,0,error)!=nil;
  return YES;
 }
 if(mode){fail(error,@"Для волн и перелива обновите расширение до 3.15 по USB.");return NO;}
 if([profile[@"legacyAnimationMode"]unsignedIntValue])return control(s,11,0,0,0,error)!=nil;
 return YES;
}
static BOOL lightingSet(Session *s,unsigned brightness,unsigned effect,unsigned speed,NSError **error){
 if(effect>6||speed>3)return NO;
 NSDictionary *profile=control(s,1,0,0,0,error);if(!profile)return NO;
 unsigned animation=effect>1?effect-1:0;
 if(!setAnimation(s,profile,animation,speed,error))return NO;
 uint8_t p[32]={7,1,2,0},r[32];p[3]=effect!=0;
 if(![s packet:p response:r error:error])return NO;
 p[0]=8;if(![s packet:p response:r error:error]||(r[3]!=0)!=(effect!=0))return NO;
 if(!control(s,5,0,brightness,0,error))return NO;
 memset(p,0,32);p[0]=9;p[1]=1;return [s packet:p response:r error:error];
}

static NSArray *keyArray(NSData *data){NSMutableArray *keys=[NSMutableArray array];const uint8_t *b=data.bytes;for(NSUInteger i=0;i<data.length/2;i++)[keys addObject:@((b[i*2]<<8)|b[i*2+1])];return keys;}
static NSData *keyData(id array,FlowModel shape,NSError **error){
 if(![array isKindOfClass:NSArray.class]||[array count]!=shape.positions){fail(error,@"Число позиций не соответствует модели клавиатуры.");return nil;}
 NSMutableData *data=[NSMutableData dataWithLength:shape.layerBytes];uint8_t *b=data.mutableBytes;
 for(unsigned i=0;i<shape.positions;i++){id value=array[i];if(![value isKindOfClass:NSNumber.class]||[value doubleValue]!=[value intValue]||[value intValue]<0||[value intValue]>65535){fail(error,@"Неверный код клавиши.");return nil;}unsigned code=[value unsignedIntValue];b[i*2]=code>>8;b[i*2+1]=code;}
 return data;
}
typedef struct {__unsafe_unretained Session *session;NSError *__autoreleasing *error;} LayerContext;
static bool layerRead(void *context,unsigned offset,uint8_t *out,size_t length){LayerContext *c=context;NSData *data=readBuffer(c->session,NO,offset,(unsigned)length,c->error);if(data.length!=length)return false;memcpy(out,data.bytes,length);return true;}
static bool layerWrite(void *context,unsigned offset,const uint8_t *data,size_t length){LayerContext *c=context;uint8_t p[32],r[32];if(!length||length>28||!flow_buffer_request(p,NO,offset,(unsigned)length))return false;p[0]=0x13;memcpy(p+4,data,length);return [c->session packet:p response:r error:c->error];}
static BOOL writeLayer(Session *s,unsigned layer,NSData *data,NSError **error){LayerContext context={s,error};FlowLayerIO io={&context,layerRead,layerWrite};return flow_layer_write_verify_sized(&io,layer,data.bytes,data.length,flow_model([s.device[@"model"]intValue]).layerBytes);}

typedef struct {__unsafe_unretained Session *session;NSError *__autoreleasing *error;} USBBatteryContext;
static bool usbBatteryExchange(void *context,const uint8_t p[32],uint8_t r[32]){USBBatteryContext *c=context;return [c->session packet:p response:r error:c->error];}
static void usbBatteryNonce(void *context,uint8_t nonce[4]){(void)context;arc4random_buf(nonce,4);}
static void usbBatteryWait(void *context,unsigned milliseconds){(void)context;CFAbsoluteTime until=CFAbsoluteTimeGetCurrent()+milliseconds/1000.0;while(CFAbsoluteTimeGetCurrent()<until)CFRunLoopRunInMode(kCFRunLoopDefaultMode,.02,true);}

static NSDictionary *performAction(Session *s,NSDictionary *device,NSString *action,NSDictionary *arguments,NSError **error) {
    uint8_t r[32],p[32]={0};
    if([action isEqual:@"status"]){
        uint8_t nonce[4];arc4random_buf(nonce,4);flow_request(p,nonce);
        if(![s packet:p response:r error:error])return nil;
        NSString *reason=@"";BOOL queried=NO;
        if([device[@"connection"]isEqual:@"USB"]&&flow_model([device[@"model"]intValue]).model&&([device[@"version"]intValue]==9||[device[@"version"]intValue]==20)){
            // The legacy status only reads a radio-fed RAM byte. Ask the proven
            // 3.9 extension to enqueue OEM A6/53; never send it to a USB endpoint.
            NSError *__autoreleasing refreshError=nil;NSDictionary *profile=control(s,1,0,0,0,&refreshError);
            if([profile[@"usbBatteryRefreshSupported"]boolValue]){
                USBBatteryContext context={s,&refreshError};FlowUSBBatteryIO io={&context,usbBatteryExchange,usbBatteryNonce,usbBatteryWait};
                FlowUSBBatteryResult got=flow_usb_battery_refresh(&io,r);queried=got.requested;
                switch(got.state){
                    case FlowUSBBatteryValid:break;
                    case FlowUSBBatteryRefreshFailed:reason=@"usb-battery-refresh-failed";break;
                    case FlowUSBBatteryNotWired:reason=@"usb-mode-not-confirmed";break;
                    case FlowUSBBatteryQueueFull:reason=@"usb-battery-queue-unavailable";break;
                    case FlowUSBBatteryPending:reason=@"usb-radio-battery-pending";break;
                    case FlowUSBBatteryReadFailed:reason=@"usb-battery-read-failed";break;
                }
            }else reason=@"usb-extension-update";
        }
        return @{@"valid":@((r[5]&1)&&r[6]<=100),@"percent":@(r[6]),@"power":@((r[5]&2)!=0),@"full":@((r[5]&6)==6),@"usbBatteryRequested":@(queried),@"batteryReason":reason};
    }
    // A USB receiver alone is not proof that the keyboard is online.
    // Require the nonce-correlated keyboard response before enabling configuration.
    uint8_t alive[32],nonce[4];arc4random_buf(nonce,4);flow_request(alive,nonce);
    NSError *wakeError=nil;
    if(![s packet:alive response:r error:&wakeError]){
        // Retry only a nonce read. Never replay a settings write after an ambiguous result.
        arc4random_buf(nonce,4);flow_request(alive,nonce);wakeError=nil;
        if(![s packet:alive response:r error:&wakeError]){offline(error);return nil;}
    }
    if([action isEqual:@"wake"])return @{@"online":@YES};
    if(!query(s,1,r,error))return nil;
    unsigned protocol=(r[1]<<8)|r[2];
    FlowModel shape=flow_model([device[@"model"]intValue]);
    if(!shape.model||(!s.ble&&[device[@"pid"]unsignedIntValue]!=shape.pid)||protocol!=12){fail(error,@"Настройка этой модели ещё не проверена. Доступен просмотр устройства.");return nil;}
    if([action isEqual:@"capabilities"]){
        NSMutableDictionary *result=[@{@"protocol":@(protocol),@"rows":@(shape.rows),@"cols":@(shape.cols),@"positions":@(shape.positions)}mutableCopy];
        if(!query(s,0x11,r,error))return nil;if(!r[1]||r[1]>16){fail(error,@"Неизвестная структура слоёв");return nil;}result[@"layers"]=@(r[1]);
        if(!query(s,0xc,r,error))return nil;result[@"macros"]=@(r[1]);
        if(!query(s,0xd,r,error))return nil;result[@"macroBytes"]=@((r[1]<<8)|r[2]);
        p[0]=8;p[1]=1;p[2]=1;if(![s packet:p response:r error:error])return nil;result[@"brightness"]=@(flow_brightness_level(r[3])*25);
        p[2]=2;if(![s packet:p response:r error:error])return nil;result[@"effect"]=@(r[3]!=0);
        NSError *profileError=nil;NSDictionary *profile=control(s,1,0,0,0,&profileError);
        result[@"profileSupported"]=@(profile!=nil);if(profile){result[@"profile"]=profile;result[@"brightness"]=profile[@"mainBrightness"];result[@"waveSpeed"]=profile[@"animationSpeed"];result[@"effectFamily"]=@"zones-v1";if([result[@"effect"]boolValue]&&[profile[@"animationMode"]unsignedIntValue])result[@"effect"]=@([profile[@"animationMode"]unsignedIntValue]+1);}
        return result;
    }
    // The native boundary rechecks a fresh nonce-correlated feature reply before every mutation.
    NSDictionary *mutationProfile=nil;
    if([@[@"lighting",@"profile",@"advanced",@"setKey",@"setLayer",@"resetLayer",@"layerTemplate",@"initializeLayers",@"saveMacros",@"resetKeys",@"resetAll"]containsObject:action]){
        NSError *gateError=nil;mutationProfile=control(s,1,0,0,0,&gateError);if(!mutationProfile){fail(error,@"Расширение Studio не подтверждено. Подготовьте клавиатуру по USB; настройки не записаны.");return nil;}
    }
    if([mutationProfile[@"zoneTestStage"]unsignedIntValue]){fail(error,@"Клавиатура временно занята. Повторите настройку.");return nil;}
    if([action isEqual:@"lighting"]){
        int level=[arguments[@"brightness"]intValue],effect=[arguments[@"effect"]intValue],speed=arguments[@"waveSpeed"]?[arguments[@"waveSpeed"]intValue]:[mutationProfile[@"animationSpeed"]intValue];
        if(level<0||level>100||effect<0||effect>6||speed<0||speed>3){fail(error,@"Яркость 0–100%; неизвестный эффект");return nil;}
        unsigned animation=effect>1?(unsigned)effect-1:0;
        if(animation&&![arguments[@"effectFamily"]isEqual:@"zones-v1"]){fail(error,@"Прежние глобальные эффекты удалены. Выберите волну заново.");return nil;}
        if(!setAnimation(s,mutationProfile,animation,(unsigned)speed,error))return nil;
        p[0]=7;p[1]=1;p[2]=2;p[3]=effect!=0;if(![s packet:p response:r error:error])return nil;
        p[0]=8;if(![s packet:p response:r error:error]||(r[3]!=0)!=(effect!=0)){fail(error,@"Клавиатура не подтвердила эффект");return nil;}
        NSDictionary *v=control(s,[arguments[@"persist"]boolValue]?5:4,0,level,0,error);if(!v)return nil;
        if([v[@"mainBrightness"]intValue]!=level||([mutationProfile[@"zoneAnimationsSupported"]boolValue]&&([v[@"animationMode"]unsignedIntValue]!=animation||[v[@"animationSpeed"]unsignedIntValue]!=(unsigned)speed))){fail(error,@"Клавиатура не подтвердила яркость");return nil;}
        if([arguments[@"persist"]boolValue]){memset(p,0,32);p[0]=9;p[1]=1;if(![s packet:p response:r error:error])return nil;}
        return @{@"brightness":@(level),@"effect":@(effect),@"waveSpeed":@(speed),@"effectFamily":@"zones-v1"};
    }
    if([action isEqual:@"profile"]){
        int brightness=[arguments[@"indicatorBrightness"]intValue],seconds=[arguments[@"timeout"]intValue];
        if(brightness<0||brightness>255||seconds<0||seconds>3600){fail(error,@"Яркость 0–255; время 0–3600 секунд");return nil;}
        unsigned flags=([arguments[@"rf"]boolValue]?1:0)|([arguments[@"bluetooth"]boolValue]?2:0)|([arguments[@"touchWake"]boolValue]?4:0)|([arguments[@"syncBreathing"]boolValue]?8:0);
        NSDictionary *v=control(s,[arguments[@"persist"]boolValue]?2:7,flags,brightness,seconds,error);if(!v)return nil;
        if([v[@"indicatorBrightness"]intValue]!=brightness||[v[@"timeout"]intValue]!=seconds||[v[@"rf"]boolValue]!=[arguments[@"rf"]boolValue]||[v[@"bluetooth"]boolValue]!=[arguments[@"bluetooth"]boolValue]||[v[@"touchWake"]boolValue]!=[arguments[@"touchWake"]boolValue]||[v[@"syncBreathing"]boolValue]!=[arguments[@"syncBreathing"]boolValue]){fail(error,@"Значения профиля не подтверждены");return nil;}return v;
    }
    if([action isEqual:@"advanced"]){
        NSDictionary *before=control(s,1,0,0,0,error);if(![before[@"advancedSupported"]boolValue]){fail(error,@"Для этих настроек требуется расширение Studio 3.8. Обновите расширение по USB.");return nil;}
        int threshold=[arguments[@"lowBatteryThreshold"]intValue];if(threshold<0||threshold>100){fail(error,@"Порог заряда должен быть 0–100%.");return nil;}
        BOOL sync=[arguments[@"syncBrightness"]boolValue];NSDictionary *v=control(s,[arguments[@"persist"]boolValue]?10:9,sync,threshold,0,error);
        if(!v)return nil;if([v[@"lowBatteryThreshold"]intValue]!=threshold||[v[@"syncBrightness"]boolValue]!=sync){fail(error,@"Настройки индикатора не подтверждены.");return nil;}return v;
    }
    if([action isEqual:@"readMacros"]||[action isEqual:@"saveMacros"]){
        if(!query(s,0xc,r,error)||r[1]!=16){fail(error,@"Неизвестное число макросов");return nil;}
        if(!query(s,0xd,r,error)||(((unsigned)r[1]<<8)|r[2])!=shape.macroBytes){fail(error,@"Неизвестный размер памяти макросов");return nil;}
        NSData *old=readBuffer(s,YES,0,shape.macroBytes,error);if(!old)return nil;
        if([action isEqual:@"saveMacros"]){
            NSData *expected=[[NSData alloc]initWithBase64EncodedString:arguments[@"expected"]?:@"" options:0];
            NSData *next=[[NSData alloc]initWithBase64EncodedString:arguments[@"data"]?:@"" options:0];
            if([old isEqual:next])return @{@"data":[old base64EncodedStringWithOptions:0],@"count":@16,@"size":@(shape.macroBytes)};
            if(![old isEqual:expected]){fail(error,@"Макросы изменились с момента чтения. Прочитай их заново.");return nil;}
            if(!next||!flow_macros_valid_sized(next.bytes,next.length,shape.macroBytes)){fail(error,@"Неподдерживаемый или повреждённый формат макросов");return nil;}
            backup(device,@"macros",old,error);if(error&&*error)return nil;
            NSError *transfer=nil;
            if(!writeBuffer(s,YES,next,&transfer)){
                NSError *rollback=nil;BOOL restored=writeBuffer(s,YES,old,&rollback);
                fail(error,restored?@"Запись макросов не подтверждена; прежние восстановлены и проверены.":@"Запись и откат макросов не подтверждены. Не запускай макросы до повторного чтения. Резервная копия сохранена.");return nil;
            }old=next;
        }
        return @{@"data":[old base64EncodedStringWithOptions:0],@"count":@16,@"size":@(shape.macroBytes)};
    }
    if([action isEqual:@"layerTemplate"]){
        int layer=[arguments[@"layer"]intValue];NSString *kind=arguments[@"template"];uint8_t data[216];
        if(layer<0||!flow_layer_valid(layer)||![@[@"factory",@"normal",@"fkeys"]containsObject:kind]){fail(error,@"Неизвестный шаблон слоя.");return nil;}
        if([kind isEqual:@"factory"])memcpy(data,flow_model_keys(shape,s.profileBase14)+layer*shape.layerBytes,shape.layerBytes);
        else if([kind isEqual:@"normal"])flow_model_default(shape,s.profileBase14,layer,data);
        else if(!flow_model_fn(shape,s.profileBase14,layer,data)){fail(error,@"Шаблон F1–F12 доступен для Fn-слоёв.");return nil;}
        return @{@"layer":@(layer),@"keys":keyArray([NSData dataWithBytes:data length:shape.layerBytes])};
    }
    if([action isEqual:@"initializeLayers"]){
        if(!query(s,0x11,r,error)||r[1]!=6){fail(error,@"Неизвестная структура слоёв.");return nil;}
        NSData *before=readBuffer(s,NO,0,shape.keyBytes,error);if(!before)return nil;NSMutableData *desired=[before mutableCopy];NSMutableArray *changed=[NSMutableArray array];
        for(unsigned layer=0;layer<6;layer++)if(flow_model_initializable(shape,s.profileBase14,layer,(const uint8_t *)before.bytes+layer*shape.layerBytes)){uint8_t next[216];flow_model_default(shape,s.profileBase14,layer,next);if(memcmp(next,(const uint8_t *)before.bytes+layer*shape.layerBytes,shape.layerBytes)){memcpy((uint8_t *)desired.mutableBytes+layer*shape.layerBytes,next,shape.layerBytes);[changed addObject:@(layer)];}}
        if(changed.count){backup(device,@"layers-before-initialization",before,error);if(error&&*error)return nil;BOOL ok=YES;NSError *change=nil;
            for(NSNumber *layer in changed)if(!writeLayer(s,layer.unsignedIntValue,[desired subdataWithRange:NSMakeRange(layer.unsignedIntValue*shape.layerBytes,shape.layerBytes)],&change)){ok=NO;break;}
            if(ok)ok=[readBuffer(s,NO,0,shape.keyBytes,&change)isEqual:desired];
            if(!ok){BOOL restored=YES;for(NSNumber *layer in changed){NSError *rollback=nil;restored=writeLayer(s,layer.unsignedIntValue,[before subdataWithRange:NSMakeRange(layer.unsignedIntValue*shape.layerBytes,shape.layerBytes)],&rollback)&&restored;}fail(error,restored?@"Подготовка слоёв не подтверждена; прежние восстановлены.":@"Не удалось подтвердить подготовку и восстановление слоёв. Копия сохранена.");return nil;}
        }
        NSMutableArray *layers=[NSMutableArray array];for(unsigned layer=0;layer<6;layer++)[layers addObject:keyArray([desired subdataWithRange:NSMakeRange(layer*shape.layerBytes,shape.layerBytes)])];return @{@"initialized":@YES,@"changedLayers":changed,@"layers":layers};
    }
    if([action isEqual:@"setLayer"]||[action isEqual:@"resetLayer"]){
        if(!query(s,0x11,r,error)||r[1]!=6){fail(error,@"Неизвестная структура слоёв.");return nil;}
        int layer=[arguments[@"layer"]intValue];if(layer<0||!flow_layer_valid(layer)){fail(error,@"Неизвестный слой.");return nil;}
        NSData *before=readBuffer(s,NO,layer*shape.layerBytes,shape.layerBytes,error);if(!before)return nil;
        BOOL reset=[action isEqual:@"resetLayer"];NSData *next=reset?[NSData dataWithBytes:flow_model_keys(shape,s.profileBase14)+layer*shape.layerBytes length:shape.layerBytes]:keyData(arguments[@"keys"],shape,error);if(!next)return nil;
        if(!reset){NSData *expected=keyData(arguments[@"expected"],shape,error);if(!expected)return nil;if(![before isEqual:expected]&&![before isEqual:next]){fail(error,@"Слой изменился с момента чтения. Прочитайте его заново; ожидающее изменение не перезаписало чужие назначения.");return nil;}}
        if(![before isEqual:next]){backup(device,[NSString stringWithFormat:@"layer-%d-before-replace",layer],before,error);if(error&&*error)return nil;NSError *change=nil;
            if(!writeLayer(s,layer,next,&change)){NSError *rollback=nil;BOOL restored=writeLayer(s,layer,before,&rollback);fail(error,restored?@"Изменение слоя не подтверждено; прежний слой восстановлен.":@"Запись и откат слоя не подтверждены. Резервная копия сохранена.");return nil;}
        }
        return @{@"layer":@(layer),@"keys":keyArray(next),@"before":keyArray(before),@"reset":@(reset)};
    }
    if([action isEqual:@"resetKeys"]||[action isEqual:@"resetAll"]){
        BOOL all=[action isEqual:@"resetAll"];
        if(!query(s,0x11,r,error)||r[1]!=6){fail(error,@"Неизвестная структура слоёв");return nil;}
        NSData *keys=readBuffer(s,NO,0,shape.keyBytes,error);if(!keys)return nil;
        backup(device,@"all-layers-before-reset",keys,error);if(error&&*error)return nil;
        NSData *macros=nil;NSDictionary *profile=nil;unsigned level=0,effect=0,speed=1;
        if(all){
            macros=readBuffer(s,YES,0,shape.macroBytes,error);if(!macros)return nil;backup(device,@"macros-before-reset",macros,error);if(error&&*error)return nil;
            uint8_t q[32]={8,1,1};if(![s packet:q response:r error:error])return nil;level=flow_brightness_level(r[3])*25;
            q[2]=2;if(![s packet:q response:r error:error])return nil;effect=r[3]!=0;
            NSError *unsupported=nil;profile=control(s,1,0,0,0,&unsupported);if(profile){level=[profile[@"mainBrightness"]unsignedIntValue];speed=[profile[@"animationSpeed"]unsignedIntValue];if(effect&&[profile[@"animationMode"]unsignedIntValue])effect=[profile[@"animationMode"]unsignedIntValue]+1;}
            NSDictionary *settings=@{@"brightness":@(level),@"effect":@(effect),@"profile":profile?:@{}};
            NSData *settingsData=[NSJSONSerialization dataWithJSONObject:settings options:NSJSONWritingPrettyPrinted error:error];if(!settingsData)return nil;
            backup(device,@"settings-before-reset-json",settingsData,error);if(error&&*error)return nil;
        }
        NSError *change=nil;BOOL ok=query(s,6,r,&change);
        if(ok){NSData *actual=readBuffer(s,NO,0,shape.keyBytes,&change);ok=[actual isEqual:[NSData dataWithBytes:flow_model_keys(shape,s.profileBase14) length:shape.keyBytes]];}
        if(ok&&all){ok=writeBuffer(s,YES,[NSMutableData dataWithLength:shape.macroBytes],&change)&&lightingSet(s,75,0,1,&change);if(ok&&profile)ok=control(s,3,0,0,0,&change)!=nil;}
        if(!ok){
            NSError *ignored=nil;BOOL restored=writeBuffer(s,NO,keys,&ignored);
            if(all){ignored=nil;BOOL m=writeBuffer(s,YES,macros,&ignored);ignored=nil;BOOL l=lightingSet(s,level,effect,speed,&ignored);BOOL c=YES;
                if(profile){ignored=nil;unsigned f=([profile[@"rf"]boolValue]?1:0)|([profile[@"bluetooth"]boolValue]?2:0)|([profile[@"touchWake"]boolValue]?4:0)|([profile[@"syncBreathing"]boolValue]?8:0);c=control(s,2,f,[profile[@"indicatorBrightness"]unsignedIntValue],[profile[@"timeout"]unsignedIntValue],&ignored)!=nil;}
                if(profile&&[profile[@"advancedSupported"]boolValue]){ignored=nil;c=c&&control(s,10,[profile[@"syncBrightness"]boolValue],[profile[@"lowBatteryThreshold"]unsignedIntValue],0,&ignored)!=nil;}
                restored=restored&&m&&l&&c;
            }
            fail(error,restored?@"Сброс не подтверждён. Прежние настройки восстановлены и проверены.":@"Сброс и откат не удалось полностью подтвердить. Резервные копии сохранены в Application Support/Flow2Studio/Backups.");return nil;
        }
        return @{@"reset":@YES,@"all":@(all),@"profileReset":@(all&&profile!=nil)};
    }
    if([action isEqual:@"readLayer"]||[action isEqual:@"setKey"]){
        int layer=[arguments[@"layer"]intValue];
        if(!query(s,0x11,r,error))return nil;
        if(layer<0||layer>=r[1]||layer>15){fail(error,@"Неизвестный слой");return nil;}
        NSData *data=readBuffer(s,NO,(unsigned)layer*shape.layerBytes,shape.layerBytes,error);if(!data)return nil;
        NSData *beforeChange=data;
        if([action isEqual:@"setKey"]){
            int row=[arguments[@"row"]intValue],col=[arguments[@"col"]intValue],code=[arguments[@"code"]intValue];
            if(row<0||row>=(int)shape.rows||col<0||col>=(int)shape.cols||code<0||code>65535){fail(error,@"Некорректное назначение клавиши");return nil;}
            backup(device,[NSString stringWithFormat:@"layer-%d",layer],data,error);if(error&&*error)return nil;
            const uint8_t *b=data.bytes;unsigned pos=2*(row*shape.cols+col);uint16_t old=(b[pos]<<8)|b[pos+1];
            if([arguments[@"expectedCode"]isKindOfClass:NSNumber.class]&&old!=[arguments[@"expectedCode"]intValue]&&old!=code){fail(error,@"Назначение изменилось с момента чтения. Прочитайте слой заново.");return nil;}
            uint8_t set[32],get[32];flow_key_request_sized(set,1,layer,row,col,code,shape.rows,shape.cols);flow_key_request_sized(get,0,layer,row,col,0,shape.rows,shape.cols);
            NSError *transferError=nil;[s packet:set response:r error:&transferError];
            transferError=nil;
            if(![s packet:get response:r error:&transferError]||((r[4]<<8)|r[5])!=code){
                flow_key_request_sized(set,1,layer,row,col,old,shape.rows,shape.cols);transferError=nil;[s packet:set response:r error:&transferError];transferError=nil;
                BOOL restored=[s packet:get response:r error:&transferError]&&((r[4]<<8)|r[5])==old;
                fail(error,restored?@"Новое назначение не подтверждено. Прежнее восстановлено и проверено.":@"Назначение и откат не удалось подтвердить. Обнови слой; резервная копия сохранена.");return nil;
            }
            data=readBuffer(s,NO,(unsigned)layer*shape.layerBytes,shape.layerBytes,error);if(!data)return nil;
        }
        NSMutableArray *keys=[NSMutableArray array];const uint8_t *bytes=data.bytes;
        for(int i=0;i<(int)shape.positions;i++)[keys addObject:@((bytes[i*2]<<8)|bytes[i*2+1])];return @{@"keys":keys,@"layer":@(layer),@"before":keyArray(beforeChange)};
    }
    fail(error,@"Неизвестное действие");return nil;
}

// Accessed only on Studio's serial HID worker. No packet-level parallelism.
static Session *editingSession;
void FlowEditingEnd(void) {
    Session *s=editingSession;editingSession=nil;
    if(!s)return;
    [s releaseEditing];
}
static Session *openSession(NSDictionary *device,NSError **error) {
    BOOL bluetooth=[device[@"connection"]isEqual:@"Bluetooth"];
    Session *s=[Session new];s.device=device;s.ble=bluetooth;s.serial=bluetooth;
    if(!bluetooth){
        io_service_t service=IOServiceGetMatchingService(kIOMainPortDefault,IORegistryEntryIDMatching([device[@"id"] unsignedLongLongValue]));
        if(!service){fail(error,@"Устройство отключено");return nil;}
        s.handle=IOHIDDeviceCreate(kCFAllocatorDefault,service);IOObjectRelease(service);s.input=calloc(512,1);
        if(!s.handle||!s.input||IOHIDDeviceOpen(s.handle,kIOHIDOptionsTypeNone)!=kIOReturnSuccess){fail(error,@"Нет доступа к устройству. Закрой VIA и проверь разрешение «Мониторинг ввода».");return nil;}
        [s attachInput];
    }
    return s;
}
NSDictionary *FlowEditingTick(NSDictionary *device,double idleSeconds,NSError **error) {
    if(![device[@"connection"]isEqual:@"2.4 ГГц"]||!flow_model([device[@"model"]intValue]).model||![device[@"vendor"]boolValue]){
        FlowEditingEnd();return @{@"state":@"unsupported"};
    }
    if(editingSession&&![editingSession.device[@"id"]isEqual:device[@"id"]])FlowEditingEnd();
    Session *s=editingSession?:openSession(device,error);if(!s)return nil;
    if(!editingSession&&![s beginOperation:error])return nil;
    NSDictionary *profile=control(s,1,0,0,0,error);
    if(![profile[@"quietReleaseSupported"]boolValue]){
            if(editingSession)FlowEditingEnd();else [s endOperation];if(!profile)return nil;
            return @{@"state":@"upgrade"};
    }
    unsigned timeout=[profile[@"timeout"]unsignedIntValue];
    BOOL dark=flow_editing_dark(idleSeconds,0,timeout);
    s.editingDark=dark;
    if(!control(s,8,dark?2:1,0,0,error)){
        // Even an ambiguous reply may have applied the RAM lease. Best effort release;
        // firmware expiry remains authoritative if the keyboard cannot answer.
        [s releaseEditing];editingSession=nil;return nil;
    }
    s.windowLease=YES;editingSession=s;
    return @{@"state":dark?@"dark":@"active",@"dark":@(dark),@"timeout":@(timeout)};
}

NSDictionary *FlowPerform(NSDictionary *device,NSString *action,NSDictionary *arguments,NSError **error) {
    if(![device[@"vendor"] boolValue]){
        if([action isEqual:@"status"]){for(NSDictionary *fresh in FlowDevices())if([fresh[@"id"]isEqual:device[@"id"]]){
            NSNumber *level=fresh[@"systemBattery"];
            return @{@"valid":@(level!=nil),@"percent":level?:@0,@"system":@YES,@"power":@NO};
        }}
        fail(error,@"Bluetooth подключён, но служебный HID-канал настроек не найден. Для настройки используйте USB или 2.4 ГГц.");return nil;
    }
    BOOL retained=editingSession&&[editingSession.device[@"id"]isEqual:device[@"id"]];
    Session *s=retained?editingSession:openSession(device,error);if(!s)return nil;
    BOOL bluetooth=s.ble;
    if(retained&&![action isEqual:@"status"]){
        s.editingDark=NO;
        if(!control(s,8,1,0,0,error)){offline(error);return nil;}
    }
    FlowModel operationModel=flow_model([device[@"model"]intValue]);BOOL eligible=operationModel.model&&(bluetooth||[device[@"pid"]unsignedIntValue]==operationModel.pid)&&![action isEqual:@"status"];
    if(eligible&&!retained){
        // Send the wake request BEFORE ordinary liveness reads, including after sleep.
        // This is volatile: firmware limits it to 15 seconds if the app/link fails.
        NSError *wakeError=nil;BOOL awake=[s beginOperation:&wakeError];
        if(!awake&&![action isEqual:@"capabilities"]){
            offline(error);return nil;
        }
        // A factory/unsupported extension can still be inspected; setters retain their fresh proof gate.
    }
    NSDictionary *result=performAction(s,device,action,arguments,error);
    [s endOperation];
    // A lost release ACK does not invalidate an already verified write; expiry is <=15 seconds.
    return result;
}
