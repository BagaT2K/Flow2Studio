#import <Foundation/Foundation.h>

// Main-thread only. Reads 180F/2A19 from an already connected, uniquely named
// peripheral. Never scans, pairs, writes a characteristic, or changes firmware.
@interface FlowBLEBattery : NSObject
- (void)readDevice:(NSDictionary *)device completion:(void (^)(NSDictionary *, NSError *))completion;
- (void)cancel;
@end
