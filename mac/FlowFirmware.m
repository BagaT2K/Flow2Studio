#import "FlowFirmware.h"
#import "FlowTransport.h"
#import <IOKit/IOKitLib.h>
#import <IOKit/IOCFPlugIn.h>
#import <IOKit/usb/IOUSBLib.h>
#import <IOKit/hid/IOHIDManager.h>
#import <CommonCrypto/CommonDigest.h>
#include <fcntl.h>
#include <unistd.h>
#include "FlowFlashCore.h"
#include "FlowDFUWire.h"
#include "FlowBackupFile.h"
#include "FlowV14Registry.h"
#include "FlowModels.h"
#include "FlowFirmwareModel.h"
#include "FlowFirmwareMigration.h"

static void firmwareError(NSError **e,NSString *message){if(e)*e=[NSError errorWithDomain:@"Flow2Firmware" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];}
static NSString *sha256(NSData *data){unsigned char hash[CC_SHA256_DIGEST_LENGTH];CC_SHA256(data.bytes,(CC_LONG)data.length,hash);NSMutableString *s=[NSMutableString string];for(unsigned i=0;i<sizeof hash;i++)[s appendFormat:@"%02x",hash[i]];return s;}
static uint32_t get32(const uint8_t *b){return (uint32_t)b[0]|((uint32_t)b[1]<<8)|((uint32_t)b[2]<<16)|((uint32_t)b[3]<<24);}
static void put32(uint8_t *b,uint32_t n){for(unsigned i=0;i<4;i++)b[i]=(uint8_t)(n>>(8*i));}
static id usbProperty(io_service_t service,NSString *key){return CFBridgingRelease(IORegistryEntryCreateCFProperty(service,(__bridge CFStringRef)key,kCFAllocatorDefault,0));}
static NSArray<NSNumber *> *dfuServices(void){
 NSMutableDictionary *found=[NSMutableDictionary dictionary];
 for(NSString *className in @[@"IOUSBHostDevice",@"IOUSBDevice"]){io_iterator_t iterator=0;
  if(IOServiceGetMatchingServices(kIOMainPortDefault,IOServiceMatching(className.UTF8String),&iterator)!=KERN_SUCCESS)continue;
  io_service_t service;while((service=IOIteratorNext(iterator))){
   if([usbProperty(service,@"idVendor")intValue]==0x342d&&[usbProperty(service,@"idProduct")intValue]==0xdfa0){
    uint64_t registry=0;IORegistryEntryGetRegistryEntryID(service,&registry);NSNumber *location=usbProperty(service,@"locationID");if(location&&!found[location])found[location]=@(registry);
   }IOObjectRelease(service);
  }IOObjectRelease(iterator);
 }
 return found.allValues;
}
NSArray<NSDictionary *> *FlowFirmwareDevices(void){
 NSMutableArray *devices=[NSMutableArray array];for(NSNumber *registry in dfuServices()){
  io_service_t s=IOServiceGetMatchingService(kIOMainPortDefault,IORegistryEntryIDMatching(registry.unsignedLongLongValue));if(!s)continue;
  NSNumber *location=usbProperty(s,@"locationID");IOObjectRelease(s);if(!location)continue;
  NSString *key=[NSString stringWithFormat:@"dfu-%@",location];[devices addObject:@{@"id":key,@"key":key,@"name":@"Устройство USB · восстановление",@"connection":@"USB",@"model":@"",@"vendor":@NO,@"bootloader":@YES,@"location":location}];
 }return devices;
}
static NSDictionary *catalogForModel(unsigned model,NSError **error){
 const char *expected=flow_v14_catalog_sha(model);if(!expected){firmwareError(error,@"Неизвестная модель клавиатуры");return nil;}
 NSURL *folder=[NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"firmware"];
 NSData *raw=[NSData dataWithContentsOfURL:[folder URLByAppendingPathComponent:[NSString stringWithFormat:@"model-%u-v14.json",model]]];
 if(!raw||![sha256(raw)isEqual:[NSString stringWithUTF8String:expected]]){firmwareError(error,@"Каталог модели повреждён. Запись запрещена.");return nil;}
 NSDictionary *meta=[NSJSONSerialization JSONObjectWithData:raw options:0 error:error];
 if(![[meta[@"model"]description]isEqual:[@(model)description]]){firmwareError(error,@"Каталог другой модели. Запись запрещена.");return nil;}
 NSArray *pages=meta[@"pages"];unsigned previous=0;if(!pages.count||pages.count>300){firmwareError(error,@"Неверная карта страниц модели");return nil;}
 for(unsigned i=0;i<pages.count;i++){unsigned page=[pages[i]unsignedIntValue];if(page%256||page+256>FLOW_FLASH_SIZE||(i&&page<=previous)){firmwareError(error,@"Неверные границы страниц модели");return nil;}previous=page;}
 NSMutableDictionary *images=[NSMutableDictionary dictionary],*labels=[NSMutableDictionary dictionary],*releases=[NSMutableDictionary dictionary];NSString *target=nil,*factory=nil;
 for(NSDictionary *item in meta[@"images"]){NSData *image=[NSData dataWithContentsOfURL:[folder URLByAppendingPathComponent:item[@"file"]]];NSString *hash=item[@"sha256"];
  if(image.length!=FLOW_FLASH_SIZE||![sha256(image)isEqual:hash]||!flow_firmware_model_matches(image.bytes,image.length,model,[item[@"usbRelease"]unsignedIntValue])){firmwareError(error,@"Образ модели повреждён. Запись запрещена.");return nil;}
  images[hash]=image;releases[hash]=item[@"usbRelease"]?:@9;NSString *label=item[@"description"]?:item[@"id"];
  if([item[@"id"]isEqual:meta[@"target"]]){target=hash;label=[NSString stringWithFormat:@"Studio 0.9 · Flow 2 %u · база 0.14",model];}
  if([item[@"id"]isEqual:meta[@"factory"]]){factory=hash;label=[NSString stringWithFormat:@"Заводская Flow 2 %u USB 0.14",model];}
  labels[hash]=label;
 }
 if(!target||!factory||images.count>32){firmwareError(error,@"Неполный каталог модели");return nil;}
 return @{@"model":meta[@"model"],@"enabled":meta[@"enabled"]?:@NO,@"images":images,@"labels":labels,@"releases":releases,@"pages":pages,@"target":target,@"factory":factory,@"oem14":factory};
}
static NSString *backupRoot(void){return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Flow2Studio/FirmwareBackups"];}
/* A separate immutable source archive, independent of transaction backups.
   Known Studio images are not mislabeled as pre-Studio originals. */
static BOOL archiveInitial(NSData *data,NSDictionary *package,NSNumber *location,NSError **error){
 NSString *hash=sha256(data);BOOL factory=[package[@"labels"][hash]hasPrefix:@"Заводская"];
 if(package[@"images"][hash]&&!factory)return YES;
 NSString *device=[NSString stringWithFormat:@"Flow2-%@-USB-%@",package[@"model"],location?:@0];
 NSString *folder=[[[backupRoot()stringByAppendingPathComponent:@"Original"]stringByAppendingPathComponent:device]stringByAppendingPathComponent:hash];
 if(![NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:error])return NO;
 NSString *path=[folder stringByAppendingPathComponent:@"original.bin"];
 if(!flow_backup_write_once(path.fileSystemRepresentation,data.bytes,data.length)||![[NSData dataWithContentsOfFile:path]isEqual:data]){firmwareError(error,@"Исходная копия не прошла проверку. Существующий файл не перезаписан; запись прошивки не начата.");return NO;}
 NSString *metadata=[folder stringByAppendingPathComponent:@"info.json"];
 if([NSFileManager.defaultManager fileExistsAtPath:metadata]){
  NSData *raw=[NSData dataWithContentsOfFile:metadata];NSDictionary *info=raw?[NSJSONSerialization JSONObjectWithData:raw options:0 error:NULL]:nil;
  if(![info isKindOfClass:NSDictionary.class]||![info[@"sha256"]isEqual:hash]||![info[@"location"]isEqual:location]){firmwareError(error,@"Сведения об исходной копии повреждены. Запись прошивки не начата.");return NO;}
  return YES;
 }
 NSDateFormatter *format=[NSDateFormatter new];format.locale=[[NSLocale alloc]initWithLocaleIdentifier:@"en_US_POSIX"];format.timeZone=[NSTimeZone timeZoneForSecondsFromGMT:0];format.dateFormat=@"yyyy-MM-dd'T'HH:mm:ss'Z'";
 unsigned release=0;flow_firmware_identify(data.bytes,data.length,&release);
 NSDictionary *info=@{@"model":package[@"model"],@"usbRelease":@(release),@"location":location?:@0,@"sha256":hash,@"bytes":@(data.length),@"createdAt":[format stringFromDate:NSDate.date],@"kind":factory?@"verified-factory":@"initial-image",@"label":factory?package[@"labels"][hash]:[NSString stringWithFormat:@"Исходная прошивка перед Studio · USB 0x%04x",release]};
 NSData *raw=[NSJSONSerialization dataWithJSONObject:info options:NSJSONWritingPrettyPrinted error:error];
 if(!raw||!flow_backup_write_once(metadata.fileSystemRepresentation,raw.bytes,raw.length)){firmwareError(error,@"Не удалось сохранить сведения об исходной копии. Запись прошивки не начата.");return NO;}
 return YES;
}
NSDictionary *FlowFirmwareReadBackup(NSURL *url,NSError **error){

 if(!url.isFileURL){firmwareError(error,@"Выберите локальный файл резервной копии .bin.");return nil;}
 NSNumber *size=nil;if(![url getResourceValue:&size forKey:NSURLFileSizeKey error:error]||size.unsignedLongLongValue!=FLOW_FLASH_SIZE){firmwareError(error,@"Копия должна быть полным образом прошивки размером 256 КБ.");return nil;}
 NSData *image=[NSData dataWithContentsOfURL:url options:0 error:error];if(!image)return nil;
 NSString *hash=sha256(image);unsigned release=0,model=flow_firmware_identify(image.bytes,image.length,&release);
 if(!model){firmwareError(error,@"Копия не является полным образом обычной Flow 2 68/84/100: модель или таблица запуска не подтверждены.");return nil;}
 NSDictionary *package=catalogForModel(model,error);if(!package)return nil;
 NSString *label=package[@"labels"][hash]?:[NSString stringWithFormat:@"Личная копия Flow 2 %u · USB 0x%04x",model,release];
 return @{@"image":image,@"sha256":hash,@"label":label,@"model":[@(model)description],@"file":url.path};
}
static BOOL saveUnsupportedSnapshot(NSData *data,NSNumber *location){
 NSString *folder=[backupRoot()stringByAppendingPathComponent:[@"unsupported-"stringByAppendingString:sha256(data)]];
 if(![NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:NULL])return NO;
 NSString *path=[folder stringByAppendingPathComponent:@"before.bin"];
 if(![data writeToFile:path options:NSDataWritingAtomic error:NULL])return NO;
 int fd=open(path.fileSystemRepresentation,O_RDWR);BOOL saved=fd>=0&&fcntl(fd,F_FULLFSYNC)==0;if(fd>=0)close(fd);
 if(!saved||![[NSData dataWithContentsOfFile:path]isEqual:data])return NO;
 NSDictionary *info=@{@"sha256":sha256(data),@"location":location?:@0,@"status":@"unsupported-no-writes",@"bytes":@(data.length)};
 NSData *json=[NSJSONSerialization dataWithJSONObject:info options:NSJSONWritingPrettyPrinted error:NULL];return [json writeToFile:[folder stringByAppendingPathComponent:@"info.json"]options:NSDataWritingAtomic error:NULL];
}
static NSData *recordImage(NSDictionary *record,NSString *folder,NSString *key,NSString *filename,NSDictionary *package){
 NSString *hash=record[key];if(![hash isKindOfClass:NSString.class])return nil;
 NSData *data=package[@"images"][hash]?:[NSData dataWithContentsOfFile:[folder stringByAppendingPathComponent:filename]];
 if(data.length!=FLOW_FLASH_SIZE||![sha256(data)isEqual:hash]||flow_firmware_identify(data.bytes,data.length,NULL)!=(unsigned)[package[@"model"]intValue])return nil;
 return data;
}
static NSDictionary *recordForKey(NSString *key,NSDictionary *package,NSNumber *location){
    if(![location isKindOfClass:NSNumber.class])return nil;
    NSArray *children=[NSFileManager.defaultManager contentsOfDirectoryAtPath:backupRoot() error:NULL];NSMutableArray *records=[NSMutableArray array];
    for(NSString *name in children){NSString *path=[backupRoot() stringByAppendingPathComponent:name];NSDictionary *record=[NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"record.plist"]];
        if(![record[@"location"]isEqual:location]||![record[@"model"]isEqual:package[@"model"]])continue;
        if(![record isKindOfClass:NSDictionary.class]||![record[@"createdAt"]isKindOfClass:NSDate.class])continue;
        NSData *rollback=recordImage(record,path,@"rollbackSHA256",@"rollback.bin",package),*target=recordImage(record,path,@"targetSHA256",@"target.bin",package);
        if(!rollback||!target)continue;
        if([key isEqual:@"oem14Rollback"]&&(!([record[@"operation"]isEqual:@"install-oem14"]||[record[@"operation"]isEqual:@"prepare-v14"])||![record[@"beforeSHA256"]isEqual:record[@"rollbackSHA256"]]))continue;
        if([key isEqual:@"firmwareRestoreRecord"]&&(![record[@"operation"]isEqual:@"prepare"]||![record[@"beforeSHA256"]isEqual:record[@"rollbackSHA256"]]))continue;
        NSData *before=[NSData dataWithContentsOfFile:[path stringByAppendingPathComponent:@"before.bin"]];if(before.length!=FLOW_FLASH_SIZE||![sha256(before)isEqual:record[@"beforeSHA256"]])continue;
        NSMutableDictionary *r=[record mutableCopy];r[@"folder"]=path;r[@"rollbackImage"]=rollback;r[@"targetImage"]=target;r[@"beforeImage"]=before;[records addObject:r];
    }
    [records sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [b[@"createdAt"]compare:a[@"createdAt"]];}];return [key isEqual:@"firmwareRestoreRecord"]?records.lastObject:records.firstObject;
}
static NSDictionary *packageForDevice(NSDictionary *device,NSError **error){
 unsigned model=[device[@"model"]intValue];if(flow_model(model).model)return catalogForModel(model,error);
 NSNumber *location=device[@"usbLocation"]?:device[@"location"];NSDictionary *latest=nil,*selected=nil;
 for(NSNumber *candidate in @[@68,@84,@100]){NSDictionary *package=catalogForModel(candidate.unsignedIntValue,error);if(!package)return nil;NSDictionary *record=recordForKey(@"firmwareRecoveryRecord",package,location);if(record&&(!latest||[record[@"createdAt"]compare:latest[@"createdAt"]]==NSOrderedDescending)){latest=record;selected=package;}}
 return selected?:catalogForModel(68,error);
}
NSDictionary *FlowFirmwareStatus(NSDictionary *device){
 NSError *error=nil;NSDictionary *package=packageForDevice(device,&error);if(!package)return @{@"available":@NO,@"message":error.localizedDescription?:@"Пакет подготовки недоступен"};
 BOOL dfu=[device[@"bootloader"]boolValue];FlowModel shape=flow_model([device[@"model"]intValue]);BOOL wired=shape.model&&[device[@"connection"]isEqual:@"USB"]&&[device[@"vid"]intValue]==0x388d&&[device[@"pid"]unsignedIntValue]==shape.pid;
 NSNumber *location=device[@"usbLocation"]?:device[@"location"];BOOL verifiedRecovery=dfu&&recordForKey(@"firmwareRecoveryRecord",package,location)!=nil;BOOL rollback=recordForKey(@"oem14Rollback",package,location)!=nil;
 return @{@"canInstallOEM14":@NO,@"base14Target":@YES,@"model":package[@"model"],@"canRollbackOEM14":@((wired||dfu)&&rollback),@"oem14Installed":@(wired&&[device[@"version"]intValue]==0x14),@"available":@YES,@"wired":@(wired),@"recovery":@(dfu),@"canPrepare":@((wired||verifiedRecovery)&&[package[@"enabled"]boolValue]),@"canRestoreFactory":@(wired||verifiedRecovery),@"canRestore":@(wired||dfu),@"backupExists":@([NSFileManager.defaultManager fileExistsAtPath:backupRoot()]),@"message":dfu?@"Клавиатура в режиме восстановления. Подключение USB сохранено.":wired?@"Можно проверить совместимость и подготовить клавиатуру.":@"Подключите обычную Flow 2 68, 84 или 100 кабелем в проводном USB-режиме."};
}

@interface FlowDFU:NSObject
@property(nonatomic) IOUSBDeviceInterface300 **device;
@property(nonatomic) IOUSBInterfaceInterface300 **interface;
@property(nonatomic) UInt8 inputPipe;
@property(nonatomic) UInt8 outputPipe;
@property(nonatomic) BOOL chipVerified;
@property(nonatomic,strong) NSDictionary *images;
@property(nonatomic,strong) NSDictionary *labels;
@property(nonatomic,strong) NSString *folder;
@property(nonatomic,strong) NSString *rollbackHash;
@property(nonatomic,strong) NSString *targetHash;
@property(nonatomic,strong) NSNumber *location;
@property(nonatomic) BOOL restore;
@property(nonatomic) BOOL oemTransition;
@property(nonatomic) unsigned sourceRelease;
@property(nonatomic,copy) NSString *model;
@property(nonatomic,strong) NSArray *pageOffsets;
@property(nonatomic,copy) NSString *operation;
@property(nonatomic,copy) void (^progress)(NSDictionary *);
@property(nonatomic,strong) NSString *lastError;
- (BOOL)openLocation:(NSNumber *)location error:(NSError **)error;
- (NSData *)exchange:(NSData *)packet expected:(unsigned)expected;
- (BOOL)read:(uint32_t)address bytes:(uint8_t *)bytes size:(size_t)size;
- (BOOL)page:(uint32_t)address bytes:(const uint8_t *)bytes;
- (BOOL)save:(const uint8_t *)bytes size:(size_t)size;
- (void)report:(const char *)phase done:(unsigned)done total:(unsigned)total;
- (BOOL)reset;
@end
@implementation FlowDFU
- (BOOL)openLocation:(NSNumber *)location error:(NSError **)error{
 NSArray *services=dfuServices();
 if(!services.count){firmwareError(error,@"Загрузчик WB32 не обнаружен по USB. Запись прошивки не начиналась. Для расширений 3.9/3.10 войдите вручную: удерживайте Fn, затем левый Shift, затем нажмите Esc и выберите появившееся устройство восстановления.");return NO;}
 if(services.count!=1){firmwareError(error,[NSString stringWithFormat:@"Найдено устройств восстановления USB: %lu. Оставьте подключённой одну клавиатуру для восстановления.",(unsigned long)services.count]);return NO;}
 io_service_t service=IOServiceGetMatchingService(kIOMainPortDefault,IORegistryEntryIDMatching([services[0]unsignedLongLongValue]));
 if(!service){firmwareError(error,@"Загрузчик отключён");return NO;}
 NSNumber *actual=usbProperty(service,@"locationID");
 if(location&&![actual isEqual:location]){IOObjectRelease(service);firmwareError(error,@"Загрузчик появился на другом USB-порту. Запись запрещена.");return NO;}self.location=actual;
 IOCFPlugInInterface **plugin=NULL;SInt32 score=0;
 IOReturn result=IOCreatePlugInInterfaceForService(service,kIOUSBDeviceUserClientTypeID,kIOCFPlugInInterfaceID,&plugin,&score);IOObjectRelease(service);
 if(result||!plugin){firmwareError(error,@"macOS не открыла интерфейс загрузчика USB");return NO;}
 IOUSBDeviceInterface300 **device=NULL;HRESULT h=(*plugin)->QueryInterface(plugin,CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID300),(LPVOID *)&device);IODestroyPlugInInterface(plugin);
 if(h||!device){firmwareError(error,@"Интерфейс загрузчика USB недоступен");return NO;}self.device=device;
 if((*device)->USBDeviceOpen(device)!=kIOReturnSuccess){firmwareError(error,@"Загрузчик USB занят. Закройте VIA и другие утилиты.");return NO;}
 UInt8 configuration=0;result=(*device)->GetConfiguration(device,&configuration);
 if(!result&&!configuration){IOUSBConfigurationDescriptorPtr descriptor=NULL;result=(*device)->GetConfigurationDescriptorPtr(device,0,&descriptor);if(!result&&descriptor)result=(*device)->SetConfiguration(device,descriptor->bConfigurationValue);else result=kIOReturnError;}
 if(result){firmwareError(error,@"Не удалось выбрать конфигурацию загрузчика");return NO;}
 IOUSBFindInterfaceRequest find={kIOUSBFindInterfaceDontCare,kIOUSBFindInterfaceDontCare,kIOUSBFindInterfaceDontCare,kIOUSBFindInterfaceDontCare};io_iterator_t iterator=0;
 if((*device)->CreateInterfaceIterator(device,&find,&iterator)!=kIOReturnSuccess){firmwareError(error,@"Не найден интерфейс загрузчика");return NO;}
 io_service_t child;unsigned matches=0;
 while((child=IOIteratorNext(iterator))){IOCFPlugInInterface **p=NULL;score=0;
  result=IOCreatePlugInInterfaceForService(child,kIOUSBInterfaceUserClientTypeID,kIOCFPlugInInterfaceID,&p,&score);IOObjectRelease(child);if(result||!p)continue;
  IOUSBInterfaceInterface300 **interface=NULL;h=(*p)->QueryInterface(p,CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID300),(LPVOID *)&interface);IODestroyPlugInInterface(p);if(h||!interface)continue;
  UInt8 number=255;if((*interface)->GetInterfaceNumber(interface,&number)||number!=0){(*interface)->Release(interface);continue;}
  matches++;if(matches>1){(*interface)->Release(interface);continue;}self.interface=interface;
 }
 IOObjectRelease(iterator);if(matches!=1||!self.interface){firmwareError(error,@"Неоднозначный интерфейс загрузчика");return NO;}
 IOUSBInterfaceInterface300 **interface=self.interface;
 if((*interface)->USBInterfaceOpen(interface)!=kIOReturnSuccess){firmwareError(error,@"Не удалось открыть канал загрузчика");return NO;}
 UInt8 endpoints=0;(*interface)->GetNumEndpoints(interface,&endpoints);
 for(UInt8 pipe=1;pipe<=endpoints;pipe++){UInt8 direction=0,number=0,type=0,interval=0;UInt16 maxPacket=0;
  if((*interface)->GetPipeProperties(interface,pipe,&direction,&number,&type,&maxPacket,&interval))continue;
  if(number==1&&type==kUSBBulk&&maxPacket==64){if(direction==kUSBIn)self.inputPipe=pipe;else if(direction==kUSBOut)self.outputPipe=pipe;}
 }
 if(!self.inputPipe||!self.outputPipe){firmwareError(error,@"Неизвестные конечные точки загрузчика. Запись запрещена.");return NO;}return YES;
}
- (NSData *)exchange:(NSData *)packet expected:(unsigned)expected{
 const uint8_t *b=packet.bytes;size_t n=packet.length;const uint8_t *images[32]={0};unsigned imageCount=0;
 for(NSData *image in self.images.allValues){if(imageCount<32)images[imageCount++]=image.bytes;}
 unsigned pages[FLOW_FLASH_MAX_PAGES];size_t pageCount=self.pageOffsets.count;if(pageCount>FLOW_FLASH_MAX_PAGES){self.lastError=@"Неверная карта страниц";return nil;}for(unsigned i=0;i<pageCount;i++)pages[i]=[self.pageOffsets[i]unsignedIntValue];
 BOOL allowed=flow_dfu_allowed(b,n,expected,self.chipVerified,images,imageCount,pages,pageCount);
 if(!allowed){self.lastError=@"Команда вне разрешённых областей памяти отклонена";return nil;}
 IOUSBInterfaceInterface300 **interface=self.interface;
 IOReturn result=(*interface)->WritePipeTO(interface,self.outputPipe,(void *)packet.bytes,(UInt32)n,5000,5000);
 if(result){self.lastError=[NSString stringWithFormat:@"Ошибка передачи USB: 0x%08x",(unsigned)result];return nil;}
 uint8_t response[512]={0};UInt32 length=sizeof response;result=(*interface)->ReadPipeTO(interface,self.inputPipe,response,&length,5000,5000);
 if(result||length!=expected||length<2||response[1]){self.lastError=!result&&length>=2&&response[1]==0x1a?@"Загрузчик сообщил защиту памяти. Защита не изменяется.":@"Загрузчик не подтвердил операцию USB";return nil;}
 return [NSData dataWithBytes:response length:length];
}
- (BOOL)read:(uint32_t)address bytes:(uint8_t *)bytes size:(size_t)size{
 uint8_t p[10]={0x72,0,0,0};put32(p+4,address);p[8]=(uint8_t)size;p[9]=(uint8_t)(size>>8);
 NSData *reply=[self exchange:[NSData dataWithBytes:p length:10] expected:(unsigned)size+2];if(!reply)return NO;memcpy(bytes,(const uint8_t *)reply.bytes+2,size);return YES;
}
- (BOOL)page:(uint32_t)address bytes:(const uint8_t *)bytes{
 uint8_t p[268]={0x5e,0,0,0};put32(p+4,address);put32(p+8,1);
 if(![self exchange:[NSData dataWithBytes:p length:12] expected:2])return NO;
 p[0]=0x6a;put32(p+8,256);memcpy(p+12,bytes,256);return [self exchange:[NSData dataWithBytes:p length:268] expected:2]!=nil;
}
- (BOOL)save:(const uint8_t *)bytes size:(size_t)size{
 NSError *error=nil;self.folder=[backupRoot() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
 if(![NSFileManager.defaultManager createDirectoryAtPath:self.folder withIntermediateDirectories:YES attributes:nil error:&error]){self.lastError=@"Не удалось создать резервную копию. Запись не начата.";return NO;}
 NSString *path=[self.folder stringByAppendingPathComponent:@"before.bin"];NSData *data=[NSData dataWithBytes:bytes length:size];
 if(![data writeToFile:path options:NSDataWritingAtomic error:&error]){self.lastError=@"Не удалось сохранить резервную копию. Запись не начата.";return NO;}
 int fd=open(path.fileSystemRepresentation,O_RDWR);BOOL durable=fd>=0&&fcntl(fd,F_FULLFSYNC)==0;if(fd>=0)close(fd);
 if(!durable||![[NSData dataWithContentsOfFile:path]isEqual:data]){self.lastError=@"Резервная копия не прошла проверку. Запись не начата.";return NO;}
 for(NSString *name in @[@"rollback",@"target"]){NSString *hash=[name isEqual:@"rollback"]?self.rollbackHash:self.targetHash;NSData *image=self.images[hash];NSString *file=[self.folder stringByAppendingPathComponent:[name stringByAppendingString:@".bin"]];
  if(image.length!=FLOW_FLASH_SIZE||![sha256(image)isEqual:hash]||!flow_backup_write_once(file.fileSystemRepresentation,image.bytes,image.length)||![[NSData dataWithContentsOfFile:file]isEqual:image]){self.lastError=@"Не удалось сохранить и проверить образы восстановления. Запись не начата.";return NO;}
 }
 NSDictionary *record=@{@"model":self.model,@"usbRelease":@(self.sourceRelease),@"beforeFirmware":self.labels[sha256(data)]?:@"Неизвестная версия",@"targetFirmware":self.labels[self.targetHash]?:@"Неизвестная версия",@"beforeSHA256":sha256(data),@"rollbackSHA256":self.rollbackHash,@"targetSHA256":self.targetHash,@"location":self.location,@"createdAt":NSDate.date,@"operation":self.operation?: (self.restore?@"restore":@"prepare")};
 if(![record writeToFile:[self.folder stringByAppendingPathComponent:@"record.plist"] atomically:YES]){self.lastError=@"Не удалось сохранить сведения для восстановления. Запись не начата.";return NO;}
 NSDictionary *savedRecord=[NSDictionary dictionaryWithContentsOfFile:[self.folder stringByAppendingPathComponent:@"record.plist"]];
 for(NSString *key in @[@"beforeSHA256",@"rollbackSHA256",@"targetSHA256",@"location",@"operation"]){if(![savedRecord[key]isEqual:record[key]]){self.lastError=@"Сведения для отката не прошли проверку чтением. Запись не начата.";return NO;}}
 fd=open([[self.folder stringByAppendingPathComponent:@"record.plist"]fileSystemRepresentation],O_RDWR);durable=fd>=0&&fcntl(fd,F_FULLFSYNC)==0;if(fd>=0)close(fd);if(!durable){self.lastError=@"Не удалось зафиксировать сведения восстановления";return NO;}
 [NSUserDefaults.standardUserDefaults setObject:self.folder forKey:@"firmwareRecoveryRecord"];
 if(!self.restore&&[self.rollbackHash isEqual:sha256(data)])[NSUserDefaults.standardUserDefaults setObject:self.folder forKey:@"firmwareRestoreRecord"];
 [NSUserDefaults.standardUserDefaults synchronize];[self report:"backup-saved" done:1 total:1];return YES;
}
- (void)report:(const char *)phase done:(unsigned)done total:(unsigned)total{if(self.progress)self.progress(@{@"phase":[NSString stringWithUTF8String:phase],@"done":@(done),@"total":@(total)});}
- (BOOL)reset{return [self exchange:[NSData dataWithBytes:(uint8_t[]){0x83,0,0,0,0xe8,3,0,0} length:8] expected:2]!=nil;}
- (void)dealloc{IOUSBInterfaceInterface300 **i=_interface;if(i){(*i)->USBInterfaceClose(i);(*i)->Release(i);}IOUSBDeviceInterface300 **d=_device;if(d){(*d)->USBDeviceClose(d);(*d)->Release(d);}}
@end
static int readFlash(void *context,uint32_t address,uint8_t *bytes,size_t size){return [(__bridge FlowDFU *)context read:address bytes:bytes size:size];}
static int writePage(void *context,uint32_t address,const uint8_t *bytes){return [(__bridge FlowDFU *)context page:address bytes:bytes];}
static int saveFlash(void *context,const uint8_t *bytes,size_t size){return [(__bridge FlowDFU *)context save:bytes size:size];}
static void flashProgress(void *context,const char *phase,unsigned done,unsigned total){[(__bridge FlowDFU *)context report:phase done:done total:total];}

NSDictionary *FlowFirmwarePrepare(NSDictionary *selected,unsigned restoreMode,NSData *restoreImage,void (^progress)(NSDictionary *),NSError **error){
 BOOL restore=restoreMode!=0;
 if(restoreMode>4){firmwareError(error,@"Неизвестный режим восстановления");return nil;}
 NSDictionary *package=packageForDevice(selected,error);if(!package)return nil;
 if(restoreMode==2){unsigned model=flow_firmware_identify(restoreImage.bytes,restoreImage.length,NULL);
  if(!model||(![selected[@"bootloader"]boolValue]&&model!=(unsigned)[selected[@"model"]intValue])){firmwareError(error,@"Копия не соответствует модели клавиатуры. Запись не начата.");return nil;}
  package=catalogForModel(model,error);if(!package)return nil;
 }
 if(restoreMode==0&&![package[@"enabled"]boolValue]){firmwareError(error,@"Пакет модели недоступен. Запись заблокирована.");return nil;}
 NSString *chosenHash=restoreImage?sha256(restoreImage):nil;
 NSError *storageError=nil;
 if(![NSFileManager.defaultManager createDirectoryAtPath:backupRoot() withIntermediateDirectories:YES attributes:nil error:&storageError]){firmwareError(error,@"Не удалось подготовить папку резервных копий. Запись не начата.");return nil;}
 NSDictionary *storage=[NSFileManager.defaultManager attributesOfFileSystemForPath:backupRoot() error:&storageError];
 if(!storage||[storage[NSFileSystemFreeSize]unsignedLongLongValue]<8*1024*1024){firmwareError(error,@"Для резервных копий нужно минимум 8 МБ свободного места. Запись не начата.");return nil;}
 NSDictionary *device=nil;NSNumber *location=nil;
 if([selected[@"bootloader"]boolValue]){for(NSDictionary *d in FlowFirmwareDevices())if([d[@"id"]isEqual:selected[@"id"]])device=d;location=device[@"location"];}
 else{for(NSDictionary *d in FlowDevices())if([d[@"id"]isEqual:selected[@"id"]])device=d;}
 if(!device){firmwareError(error,@"Клавиатура отключена");return nil;}
 location=device[@"usbLocation"]?:device[@"location"];
 NSDictionary *recoveryRecord=recordForKey(@"firmwareRecoveryRecord",package,location);
 if(restoreMode==4){NSDictionary *record=recordForKey(@"oem14Rollback",package,location);chosenHash=record[@"beforeSHA256"];if(!chosenHash||![record[@"beforeImage"]isEqual:record[@"rollbackImage"]]){firmwareError(error,@"Проверенная копия перед 0.14 для этого USB-порта не найдена. Выберите before.bin через «Выбрать копию прошивки».");return nil;}restoreImage=record[@"rollbackImage"];}
 BOOL recovery=[device[@"bootloader"]boolValue];
 if(!recovery){
  if(![FlowFirmwareStatus(device)[@"canPrepare"]boolValue]||dfuServices().count){firmwareError(error,@"Нужно подключить выбранную Flow 2 кабелем в проводном режиме. Другие устройства восстановления должны быть отключены.");return nil;}
  unsigned wired=0;for(NSDictionary *d in FlowDevices())if([FlowFirmwareStatus(d)[@"canPrepare"]boolValue])wired++;
  if(wired!=1){firmwareError(error,@"На время подготовки оставьте одну проводную Flow 2.");return nil;}
  io_service_t service=IOServiceGetMatchingService(kIOMainPortDefault,IORegistryEntryIDMatching([device[@"id"]unsignedLongLongValue]));
  if(!service){firmwareError(error,@"Устройство отключено");return nil;}
  CFTypeRef loc=IORegistryEntrySearchCFProperty(service,kIOServicePlane,CFSTR("locationID"),kCFAllocatorDefault,kIORegistryIterateRecursively|kIORegistryIterateParents);
  if(!loc)loc=IORegistryEntrySearchCFProperty(service,kIOServicePlane,CFSTR("LocationID"),kCFAllocatorDefault,kIORegistryIterateRecursively|kIORegistryIterateParents);
  id inheritedLocation=CFBridgingRelease(loc);location=[device[@"usbLocation"]isKindOfClass:NSNumber.class]?device[@"usbLocation"]:inheritedLocation;IOHIDDeviceRef hid=IOHIDDeviceCreate(kCFAllocatorDefault,service);IOObjectRelease(service);
  if(![location isKindOfClass:NSNumber.class]||!hid){if(hid)CFRelease(hid);firmwareError(error,@"Не удалось подтвердить USB-порт устройства");return nil;}
  if(progress)progress(@{@"phase":@"entering",@"done":@0,@"total":@1});
  IOReturn result=IOHIDDeviceOpen(hid,kIOHIDOptionsTypeNone);if(!result){uint8_t command[32];memset(command,0xfe,32);command[0]=0x0b;result=IOHIDDeviceSetReport(hid,kIOHIDReportTypeOutput,0,command,32);IOHIDDeviceClose(hid,kIOHIDOptionsTypeNone);}CFRelease(hid);
  if(result){firmwareError(error,@"Не удалось начать подготовку. Закройте VIA и проверьте доступ к клавиатуре.");return nil;}
  for(unsigned n=0;n<60&&!dfuServices().count;n++)[NSThread sleepForTimeInterval:.25];
 }
 FlowDFU *dfu=[FlowDFU new];dfu.images=package[@"images"];dfu.labels=package[@"labels"];dfu.progress=progress;dfu.restore=restore;dfu.model=package[@"model"];dfu.pageOffsets=package[@"pages"];
 if(![dfu openLocation:location error:error])return nil;
 NSData *info=[dfu exchange:[NSData dataWithBytes:(uint8_t[]){1,0} length:2] expected:16];const uint8_t *ib=info.bytes;
 if(!info||ib[2]!=13||ib[3]!=4||get32(ib+4)!=0x3a50e980||get32(ib+8)!=FLOW_FLASH_SIZE||get32(ib+12)!=36864){firmwareError(error,@"Модель контроллера не подтверждена. Запись не выполнялась; устройство оставлено в режиме восстановления.");return nil;}dfu.chipVerified=YES;
 FlowFlashIO io={(__bridge void *)dfu,readFlash,writePage,saveFlash,flashProgress};
 NSMutableData *before=[NSMutableData dataWithLength:FLOW_FLASH_SIZE],*second=[NSMutableData dataWithLength:FLOW_FLASH_SIZE];
 if(!flow_flash_read_all(&io,before.mutableBytes,"reading")||!flow_flash_read_all(&io,second.mutableBytes,"checking-backup")||![before isEqual:second]){firmwareError(error,@"Две копии памяти не совпали или чтение прервано. Запись не выполнялась. Повторите проверку по USB.");return nil;}
 NSString *sourceHash=sha256(before);unsigned sourceRelease=0,sourceModel=flow_firmware_identify(before.bytes,before.length,&sourceRelease);
 unsigned model=(unsigned)[package[@"model"]intValue];BOOL intact=sourceModel==model;
 NSMutableDictionary *images=[package[@"images"]mutableCopy],*labels=[package[@"labels"]mutableCopy];
 if(restoreImage){images[chosenHash]=restoreImage;labels[chosenHash]=labels[chosenHash]?:@"Личная резервная копия";}
 NSData *recordSource=recoveryRecord[@"rollbackImage"],*recordTarget=recoveryRecord[@"targetImage"];
 unsigned recordPages[FLOW_FLASH_MAX_PAGES];size_t recordCount=recordSource&&recordTarget?flow_firmware_migration_pages(recordSource.bytes,recordTarget.bytes,recordSource.bytes,recordPages):0;
 BOOL interrupted=recovery&&recordCount&&![before isEqual:recordSource]&&![before isEqual:recordTarget]&&flow_flash_interrupted_matches(before.bytes,recordSource.bytes,recordTarget.bytes,recordPages,recordCount);
 if(interrupted)intact=NO;
 if(!intact&&!interrupted){BOOL snapshot=saveUnsupportedSnapshot(before,dfu.location);if(!recovery)[dfu reset];firmwareError(error,snapshot?@"Модель исходного образа не подтверждена или память повреждена. Снимок сохранён, запись не начата. Для прерванной записи используйте тот же USB-порт и сохранённые сведения восстановления.":@"Исходный образ не подтверждён. Запись не начата.");return nil;}
 if(interrupted&&!restore){firmwareError(error,@"Обнаружена прерванная запись. Сначала восстановите сохранённую прошивку.");return nil;}
 if(intact){images[sourceHash]=before;labels[sourceHash]=labels[sourceHash]?:[NSString stringWithFormat:@"Исходная Flow 2 %u · USB 0x%04x",model,sourceRelease];}
 else {images[recoveryRecord[@"rollbackSHA256"]]=recordSource;images[recoveryRecord[@"targetSHA256"]]=recordTarget;}
 NSString *desiredHash=restoreMode==1?package[@"factory"]:(restoreMode==2||restoreMode==4)?chosenHash:restoreMode==3?package[@"oem14"]:package[@"target"];
 NSData *desired=images[desiredHash];NSString *rollbackHash=intact?sourceHash:recoveryRecord[@"rollbackSHA256"];NSData *rollback=images[rollbackHash];
 if(desired.length!=FLOW_FLASH_SIZE||rollback.length!=FLOW_FLASH_SIZE||flow_firmware_identify(desired.bytes,desired.length,NULL)!=model||flow_firmware_identify(rollback.bytes,rollback.length,NULL)!=model){firmwareError(error,@"Модель образа восстановления не совпала. Запись не начата.");return nil;}
 NSMutableDictionary *transactionImages=[NSMutableDictionary dictionary];transactionImages[rollbackHash]=rollback;transactionImages[desiredHash]=desired;dfu.images=transactionImages;dfu.labels=labels;dfu.sourceRelease=sourceRelease;dfu.rollbackHash=rollbackHash;dfu.targetHash=desiredHash;
 dfu.operation=!restore&&![sourceHash isEqual:desiredHash]?@"prepare-v14":restore?@"restore":@"prepare";
 if(!restore&&!archiveInitial(before,package,dfu.location,error)){if(intact)[dfu reset];return nil;}
 if([before isEqual:desired]){if(![dfu save:before.bytes size:before.length]){if(intact)[dfu reset];firmwareError(error,dfu.lastError);return nil;}BOOL reset=[dfu reset];return @{@"verified":@YES,@"already":@YES,@"resetAcknowledged":@(reset),@"location":dfu.location,@"restored":@(restore)};}
 unsigned pageStorage[FLOW_FLASH_MAX_PAGES];size_t pageCount=flow_firmware_migration_pages(before.bytes,desired.bytes,rollback.bytes,pageStorage);const unsigned *pages=pageStorage;
 NSMutableArray *pageList=[NSMutableArray array];for(size_t i=0;i<pageCount;i++)[pageList addObject:@(pages[i])];dfu.pageOffsets=pageList;
 int status=flow_flash_transaction_bounded(&io,before.bytes,desired.bytes,rollback.bytes,pages,pageCount,pageCount);
 BOOL safe=status==FLOW_FLASH_OK||status==FLOW_FLASH_ALREADY||status==FLOW_FLASH_ROLLED_BACK||((status==FLOW_FLASH_BACKUP||status==FLOW_FLASH_INVALID||status==FLOW_FLASH_IO)&&intact);
 BOOL reset=safe&&[dfu reset];
 if(status!=FLOW_FLASH_OK&&status!=FLOW_FLASH_ALREADY){
  NSString *message=status==FLOW_FLASH_ROLLED_BACK?@"Подготовка не завершилась. Прежняя прошивка восстановлена и проверена.":status==FLOW_FLASH_UNSAFE?@"Связь прервалась. Не удалось подтвердить восстановление. Подключите клавиатуру по USB и выберите «Восстановить».":dfu.lastError?:@"Подготовка остановлена до записи.";
  firmwareError(error,message);return nil;
 }
 return @{@"verified":@YES,@"resetAcknowledged":@(reset),@"backup":dfu.folder?:@"",@"location":dfu.location,@"restored":@(restore)};
}
