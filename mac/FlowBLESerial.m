#import "FlowBLESerial.h"
#import <CoreBluetooth/CoreBluetooth.h>
#import "FlowSerialProtocol.h"
static BOOL uuidIs(CBUUID *u,NSString *s){return [u isEqual:[CBUUID UUIDWithString:s]];}
static NSError *serialError(NSString *text){return [NSError errorWithDomain:@"Flow2BLESerial" code:1 userInfo:@{NSLocalizedDescriptionKey:text}];}
typedef NS_ENUM(NSUInteger,FlowSerialStage){FlowSerialIdle,FlowSerialWake,FlowSerialWakeWait,FlowSerialPayload};
@interface FlowSerialClient:NSObject<CBCentralManagerDelegate,CBPeripheralDelegate>
@property(nonatomic,strong) CBCentralManager *central;
@property(nonatomic,strong) CBPeripheral *peripheral;
@property(nonatomic,strong) id deviceID;
@property(nonatomic,strong) NSString *name;
@property(nonatomic,strong) NSString *manufacturer;
@property(nonatomic,strong) NSString *revision;
@property(nonatomic,strong) NSMutableArray *jobs;
@property(nonatomic,strong) id currentJob;
@property(nonatomic,strong) CBCharacteristic *output;
@property(nonatomic,strong) NSArray *inputs;
@property(nonatomic,strong) NSMutableSet *subscribed;
@property(nonatomic,strong) NSData *request;
@property(nonatomic,copy) void (^completion)(NSData *,NSError *);
@property(nonatomic) NSUInteger generation;
@property(nonatomic) BOOL writeAcked;
@property(nonatomic,strong) NSData *pendingReply;
@property(nonatomic) BOOL started;
@property(nonatomic) BOOL ready;
@property(nonatomic) FlowSerialStage stage;
- (void)exchange:(NSDictionary *)device request:(NSData *)request completion:(void (^)(NSData *,NSError *))completion;
- (void)finish:(NSData *)data error:(NSError *)error;
- (void)reset;
- (void)next;
- (void)prepare;
- (void)send;
- (void)sendPayload;
@end
@implementation FlowSerialClient
- (void)closeConnection{
    self.central.delegate=nil;self.peripheral.delegate=nil;
    if(self.peripheral)[self.central cancelPeripheralConnection:self.peripheral];
    self.central=nil;self.peripheral=nil;self.ready=NO;self.started=NO;
    self.output=nil;self.inputs=nil;self.subscribed=nil;self.jobs=nil;self.currentJob=nil;
    self.manufacturer=nil;self.revision=nil;self.deviceID=nil;self.name=nil;
}
- (void)reset{[self finish:nil error:serialError(@"Bluetooth-сеанс закрыт: устройство сменилось, отключилось или Mac засыпает.")];}
- (void)finish:(NSData *)data error:(NSError *)error{
    void (^complete)(NSData *,NSError *)=self.completion;self.completion=nil;self.request=nil;
    self.pendingReply=nil;self.writeAcked=NO;self.stage=FlowSerialIdle;self.generation++;
    if(error)[self closeConnection];
    else{
        NSUInteger generation=self.generation;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,60*NSEC_PER_SEC),dispatch_get_main_queue(),^{
            if(generation==self.generation&&!self.completion)[self reset];
        });
    }
    if(complete)complete(data,error);
}
- (void)exchange:(NSDictionary *)device request:(NSData *)request completion:(void (^)(NSData *,NSError *))completion{
    NSAssert(NSThread.isMainThread,@"BLE state belongs to the main queue");
    if(self.completion){completion(nil,serialError(@"Предыдущая Bluetooth-команда ещё выполняется."));return;}
    if(request.length!=32){completion(nil,serialError(@"Некорректная длина команды Bluetooth."));return;}
    if(![self.deviceID isEqual:device[@"id"]])[self reset];
    self.deviceID=device[@"id"];self.name=device[@"name"];
    self.request=[request copy];self.completion=completion;NSUInteger generation=++self.generation;
    NSTimeInterval wait=self.ready?7:25;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(wait*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        if(generation==self.generation&&self.completion)[self finish:nil error:serialError(@"Нет ответа Bluetooth. Разбудите клавиатуру и обновите устройство. Неподтверждённая команда не повторяется автоматически.")];
    });
    if(self.ready&&self.peripheral.state==CBPeripheralStateConnected){[self send];return;}
    // A failed previous connection is never reused. Name/ID and this pending
    // packet remain intact while a fresh central is created.
    [self closeConnection];self.deviceID=device[@"id"];self.name=device[@"name"];
    self.central=[[CBCentralManager alloc]initWithDelegate:self queue:dispatch_get_main_queue() options:@{CBCentralManagerOptionShowPowerAlertKey:@NO}];
}
- (void)centralManagerDidUpdateState:(CBCentralManager *)central{
    if(central!=self.central)return;
    if(central.state==CBManagerStateUnauthorized){[self finish:nil error:serialError(@"Разрешите Flow 2 Studio доступ к Bluetooth в настройках macOS.")];return;}
    if(central.state==CBManagerStatePoweredOff||central.state==CBManagerStateUnsupported){[self finish:nil error:serialError(@"Bluetooth выключен или недоступен.")];return;}
    if(central.state!=CBManagerStatePoweredOn||self.started||!self.completion)return;self.started=YES;
    NSArray *connected=[central retrieveConnectedPeripheralsWithServices:@[[CBUUID UUIDWithString:@"180A"],[CBUUID UUIDWithString:@"180F"],[CBUUID UUIDWithString:@"1812"]]];
    NSMutableArray *matches=[NSMutableArray array];for(CBPeripheral *p in connected)if([p.name isEqualToString:self.name])[matches addObject:p];
    if(matches.count!=1){[self finish:nil error:serialError(matches.count?@"Несколько Bluetooth-клавиатур с одинаковым именем. Оставьте подключённой одну для настройки.":@"Выбранная клавиатура не видна через Bluetooth.")];return;}
    self.peripheral=matches[0];self.peripheral.delegate=self;[central connectPeripheral:self.peripheral options:nil];
}
- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral{
    if(central==self.central&&peripheral==self.peripheral)[peripheral discoverServices:@[[CBUUID UUIDWithString:@"180A"],[CBUUID UUIDWithString:@"FFF0"]]];
}
- (void)centralManager:(CBCentralManager *)central didFailToConnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error{
    if(central==self.central&&peripheral==self.peripheral)[self finish:nil error:error?:serialError(@"Не удалось открыть Bluetooth-канал.")];
}
- (void)centralManager:(CBCentralManager *)central didDisconnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error{
    if(central==self.central&&peripheral==self.peripheral)[self finish:nil error:error?:serialError(@"Bluetooth-клавиатура отключена.")];
}
- (void)next{
    if(!self.completion||self.currentJob)return;
    if(!self.jobs.count){[self prepare];return;}
    self.currentJob=self.jobs[0];[self.jobs removeObjectAtIndex:0];
    if([self.currentJob isKindOfClass:CBService.class])[self.peripheral discoverCharacteristics:nil forService:self.currentJob];
    else [self.peripheral readValueForCharacteristic:self.currentJob];
}
- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error{
    if(peripheral!=self.peripheral||!self.completion)return;if(error){[self finish:nil error:error];return;}
    self.jobs=[NSMutableArray array];for(CBService *s in peripheral.services)if(uuidIs(s.UUID,@"180A")||uuidIs(s.UUID,@"FFF0"))[self.jobs addObject:s];[self next];
}
- (void)peripheral:(CBPeripheral *)peripheral didDiscoverCharacteristicsForService:(CBService *)service error:(NSError *)error{
    if(peripheral!=self.peripheral||service!=self.currentJob)return;if(error){[self finish:nil error:error];return;}
    for(CBCharacteristic *c in service.characteristics)if(uuidIs(service.UUID,@"180A")&&(uuidIs(c.UUID,@"2A29")||uuidIs(c.UUID,@"2A26"))&&(c.properties&CBCharacteristicPropertyRead))[self.jobs addObject:c];
    self.currentJob=nil;[self next];
}
- (void)prepare{
    if(![@[@"flow2-68@lofree",@"flow2-84@lofree",@"flow2-100@lofree"]containsObject:self.name.lowercaseString]||![self.manufacturer isEqual:@"Freqchip"]||![self.revision isEqual:@"0.2.6"]){[self finish:nil error:serialError(@"Для Bluetooth-настройки нужна обычная Flow 2 с Freqchip 0.2.6. Заряд доступен отдельно.")];return;}
    NSMutableArray *services=[NSMutableArray array];for(CBService *s in self.peripheral.services)if(uuidIs(s.UUID,@"FFF0"))[services addObject:s];
    if(services.count!=1){[self finish:nil error:serialError(@"Не найден однозначный Bluetooth-канал FFF0.")];return;}
    CBService *s=services[0];NSMutableArray *a=[NSMutableArray array],*b=[NSMutableArray array];
    for(CBCharacteristic *c in s.characteristics){if(uuidIs(c.UUID,@"0783B03E-8535-B5A0-7140-A304D2495CB8"))[a addObject:c];if(uuidIs(c.UUID,@"0783B03E-8535-B5A0-7140-A304D2495CBA"))[b addObject:c];}
    if(s.characteristics.count!=2||a.count!=1||b.count!=1){[self finish:nil error:serialError(@"Bluetooth-профиль отличается от проверенного.")];return;}
    CBCharacteristic *out=a[0],*in=b[0];
    if(!(out.properties&CBCharacteristicPropertyWrite)||!(out.properties&CBCharacteristicPropertyNotify)||!(in.properties&CBCharacteristicPropertyNotify)||[self.peripheral maximumWriteValueLengthForType:CBCharacteristicWriteWithResponse]<35){[self finish:nil error:serialError(@"Bluetooth-канал не поддерживает проверенный формат пакета.")];return;}
    self.output=out;self.inputs=@[out,in];self.subscribed=[NSMutableSet set];
    for(CBCharacteristic *c in self.inputs)[self.peripheral setNotifyValue:YES forCharacteristic:c];
}
- (void)peripheral:(CBPeripheral *)peripheral didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)c error:(NSError *)error{
    if(peripheral!=self.peripheral||![self.inputs containsObject:c]||self.ready)return;
    if(error||!c.isNotifying){[self finish:nil error:error?:serialError(@"Не удалось включить ответы Bluetooth.")];return;}
    [self.subscribed addObject:c];if(self.subscribed.count==self.inputs.count){self.ready=YES;[self send];}
}
- (void)send{
    if(!self.request||!self.completion||!self.ready)return;
    self.writeAcked=NO;self.pendingReply=nil;
    if(flow_serial_needs_radio_wake(self.request.bytes)){
        uint8_t wake[4];flow_serial_radio_wake(wake);self.stage=FlowSerialWake;
        [self.peripheral writeValue:[NSData dataWithBytes:wake length:sizeof wake] forCharacteristic:self.output type:CBCharacteristicWriteWithResponse];
    }else [self sendPayload];
}
- (void)sendPayload{
    if(!self.request||!self.completion||!self.ready)return;
    self.stage=FlowSerialPayload;self.writeAcked=NO;self.pendingReply=nil;
    uint8_t wire[35];flow_serial_wrap(self.request.bytes,wire);
    [self.peripheral writeValue:[NSData dataWithBytes:wire length:sizeof wire] forCharacteristic:self.output type:CBCharacteristicWriteWithResponse];
}
- (void)peripheral:(CBPeripheral *)peripheral didWriteValueForCharacteristic:(CBCharacteristic *)c error:(NSError *)error{
    if(peripheral!=self.peripheral||c!=self.output||!self.completion)return;
    if(error){[self finish:nil error:error];return;}
    if(self.stage==FlowSerialWake){
        self.stage=FlowSerialWakeWait;NSUInteger generation=self.generation;
        // v028 wake path includes 200 ms + 10 ms UART signaling. Wait before VIA.
        __weak FlowSerialClient *weak=self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,300*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
            if(weak.generation==generation&&weak.completion&&weak.stage==FlowSerialWakeWait)[weak sendPayload];
        });return;
    }
    if(self.stage!=FlowSerialPayload)return;
    self.writeAcked=YES;if(self.pendingReply)[self finish:self.pendingReply error:nil];
}
- (void)peripheral:(CBPeripheral *)peripheral didUpdateValueForCharacteristic:(CBCharacteristic *)c error:(NSError *)error{
    if(peripheral!=self.peripheral)return;
    if([self.inputs containsObject:c]){
        if(!self.request||!self.completion||self.stage!=FlowSerialPayload)return;if(error){[self finish:nil error:error];return;}
        NSData *v=c.value;uint8_t reply[32];if(!flow_serial_unwrap(v.bytes,v.length,reply))return;
        int matched=flow_serial_match(self.request.bytes,reply);
        if(matched<0)[self finish:nil error:serialError(@"Эта команда не поддерживается прошивкой клавиатуры.")];
        else if(matched==1){self.pendingReply=[NSData dataWithBytes:reply length:32];if(self.writeAcked)[self finish:self.pendingReply error:nil];}
        return;
    }
    if(c!=self.currentJob)return;if(error){[self finish:nil error:error];return;}
    NSString *value=[[NSString alloc]initWithData:c.value?:NSData.data encoding:NSUTF8StringEncoding];
    if(uuidIs(c.UUID,@"2A29"))self.manufacturer=value;
    else if(uuidIs(c.UUID,@"2A26"))self.revision=value;
    self.currentJob=nil;[self next];
}
@end
static FlowSerialClient *client;
void FlowBLESerialReset(void){NSCAssert(NSThread.isMainThread,@"Reset on main queue");[client reset];}
NSData *FlowBLEExchange(NSDictionary *device,NSData *request,NSError **error){
    if(NSThread.isMainThread){if(error)*error=serialError(@"Bluetooth-обмен должен выполняться в рабочей очереди.");return nil;}
    dispatch_semaphore_t done=dispatch_semaphore_create(0);__block NSData *result=nil;__block NSError *problem=nil;
    dispatch_async(dispatch_get_main_queue(),^{
        if(!client)client=[FlowSerialClient new];
        [client exchange:device request:request completion:^(NSData *data,NSError *e){result=data;problem=e;dispatch_semaphore_signal(done);}];
    });
    // Internal main-queue deadlines close a failed session and signal this wait.
    dispatch_semaphore_wait(done,DISPATCH_TIME_FOREVER);
    if(error)*error=problem;return result;
}
