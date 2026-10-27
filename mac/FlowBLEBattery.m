#import "FlowBLEBattery.h"
#import <CoreBluetooth/CoreBluetooth.h>

static BOOL sameUUID(CBUUID *u, NSString *s) { return [u isEqual:[CBUUID UUIDWithString:s]]; }
static NSError *batteryError(NSString *text) {
    return [NSError errorWithDomain:@"Flow2BluetoothBattery" code:1 userInfo:@{NSLocalizedDescriptionKey:text}];
}
@interface FlowBLEBattery () <CBCentralManagerDelegate, CBPeripheralDelegate>
@property(nonatomic,strong) CBCentralManager *central;
@property(nonatomic,strong) CBPeripheral *peripheral;
@property(nonatomic,strong) CBCharacteristic *level;
@property(nonatomic,strong) NSString *name;
@property(nonatomic,strong) id deviceID;
@property(nonatomic,strong) NSMutableArray *callbacks;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) BOOL started;
- (void)start;
- (void)finish:(NSDictionary *)value error:(NSError *)error;
@end
@implementation FlowBLEBattery
- (void)clearSession {
    // Invalidate delegates before cancelling our client's connection. macOS's
    // keyboard connection is not unpaired or forcibly disconnected.
    self.central.delegate=nil;
    self.peripheral.delegate=nil;
    if(self.peripheral)[self.central cancelPeripheralConnection:self.peripheral];
    self.peripheral=nil;self.level=nil;self.central=nil;self.started=NO;
}
- (void)finish:(NSDictionary *)value error:(NSError *)error {
    NSArray *callbacks=[self.callbacks copy];self.callbacks=nil;
    self.generation++;[self clearSession];self.name=nil;self.deviceID=nil;
    for(void (^callback)(NSDictionary *,NSError *) in callbacks)callback(value,error);
}
- (void)cancel {
    [self finish:nil error:batteryError(@"Чтение заряда отменено: устройство сменилось или Mac засыпает.")];
}
- (void)readDevice:(NSDictionary *)device completion:(void (^)(NSDictionary *, NSError *))completion {
    NSAssert(NSThread.isMainThread,@"CoreBluetooth battery must run on main thread");
    if(self.callbacks&&[self.deviceID isEqual:device[@"id"]]){[self.callbacks addObject:[completion copy]];return;}
    [self cancel];
    self.name=[device[@"name"] copy];self.deviceID=device[@"id"];
    self.callbacks=[NSMutableArray arrayWithObject:[completion copy]];
    if(!self.name.length){[self finish:nil error:batteryError(@"Неизвестно имя Bluetooth-клавиатуры.")];return;}
    NSUInteger generation=self.generation;
    self.central=[[CBCentralManager alloc]initWithDelegate:self queue:dispatch_get_main_queue() options:@{CBCentralManagerOptionShowPowerAlertKey:@NO}];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,18*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        if(self.callbacks&&self.generation==generation)[self finish:nil error:batteryError(@"Bluetooth: заряд не получен. Разбудите клавиатуру и нажмите «Обновить заряд».")];
    });
}
- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    if(central!=self.central||!self.callbacks)return;
    if(central.state==CBManagerStateUnauthorized){[self finish:nil error:batteryError(@"Разрешите Flow 2 Studio доступ к Bluetooth в настройках конфиденциальности macOS.")];return;}
    if(central.state==CBManagerStateUnsupported){[self finish:nil error:batteryError(@"Bluetooth недоступен на этом Mac.")];return;}
    if(central.state==CBManagerStatePoweredOff){[self finish:nil error:batteryError(@"Bluetooth выключен.")];return;}
    if(central.state==CBManagerStatePoweredOn)[self start];
}
- (void)start {
    if(self.started||!self.callbacks)return;self.started=YES;
    NSArray *connected=[self.central retrieveConnectedPeripheralsWithServices:@[[CBUUID UUIDWithString:@"180F"],[CBUUID UUIDWithString:@"1812"],[CBUUID UUIDWithString:@"180A"]]];
    NSMutableArray *matches=[NSMutableArray array];
    for(CBPeripheral *p in connected)if([p.name isEqualToString:self.name])[matches addObject:p];
    // IORegistry IDs cannot be translated into CBPeripheral UUIDs. With two
    // identical names there is no proven identity mapping: do not pick the first.
    if(matches.count!=1){[self finish:nil error:batteryError(matches.count?@"Подключены несколько клавиатур с одинаковым именем. Для чтения заряда оставьте одну Bluetooth Flow 2.":@"Эта клавиатура не видна через Bluetooth. Проверьте подключение и разбудите её.")];return;}
    self.peripheral=matches[0];self.peripheral.delegate=self;
    [self.central connectPeripheral:self.peripheral options:nil];
}
- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral {
    if(central!=self.central||peripheral!=self.peripheral)return;
    [peripheral discoverServices:@[[CBUUID UUIDWithString:@"180F"]]];
}
- (void)centralManager:(CBCentralManager *)central didFailToConnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    if(central==self.central&&peripheral==self.peripheral)[self finish:nil error:error?:batteryError(@"Не удалось прочитать заряд по Bluetooth.")];
}
- (void)centralManager:(CBCentralManager *)central didDisconnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    if(central==self.central&&peripheral==self.peripheral)[self finish:nil error:error?:batteryError(@"Bluetooth-клавиатура отключена.")];
}
- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error {
    if(peripheral!=self.peripheral)return;
    if(error){[self finish:nil error:error];return;}
    NSMutableArray *services=[NSMutableArray array];for(CBService *s in peripheral.services)if(sameUUID(s.UUID,@"180F"))[services addObject:s];
    if(services.count!=1){[self finish:nil error:batteryError(@"Не найдена однозначная служба заряда Bluetooth.")];return;}
    [peripheral discoverCharacteristics:@[[CBUUID UUIDWithString:@"2A19"]] forService:services[0]];
}
- (void)peripheral:(CBPeripheral *)peripheral didDiscoverCharacteristicsForService:(CBService *)service error:(NSError *)error {
    if(peripheral!=self.peripheral||!sameUUID(service.UUID,@"180F"))return;
    if(error){[self finish:nil error:error];return;}
    NSMutableArray *levels=[NSMutableArray array];
    for(CBCharacteristic *c in service.characteristics)if(sameUUID(c.UUID,@"2A19")&&(c.properties&CBCharacteristicPropertyRead))[levels addObject:c];
    if(levels.count!=1){[self finish:nil error:batteryError(@"Характеристика заряда Bluetooth недоступна для чтения.")];return;}
    self.level=levels[0];[peripheral readValueForCharacteristic:self.level];
}
- (void)peripheral:(CBPeripheral *)peripheral didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    if(peripheral!=self.peripheral||characteristic!=self.level)return;
    if(error){[self finish:nil error:error];return;}
    NSData *data=characteristic.value;
    if(data.length!=1||((const uint8_t *)data.bytes)[0]>100){[self finish:nil error:batteryError(@"Некорректный ответ Bluetooth-службы заряда.")];return;}
    unsigned percent=((const uint8_t *)data.bytes)[0];
    [self finish:@{@"valid":@YES,@"percent":@(percent),@"source":@"ble-standard",@"peripheralID":peripheral.identifier.UUIDString,@"updatedAt":@([NSDate.date timeIntervalSince1970])} error:nil];
}
@end
