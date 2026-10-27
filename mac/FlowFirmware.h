#import <Foundation/Foundation.h>
NSArray<NSDictionary *> *FlowFirmwareDevices(void);
NSDictionary *FlowFirmwareStatus(NSDictionary *device);
NSDictionary *FlowFirmwareReadBackup(NSURL *url,NSError **error);
NSDictionary *FlowFirmwarePrepare(NSDictionary *device,unsigned restoreMode,NSData *restoreImage,void (^progress)(NSDictionary *),NSError **error);
