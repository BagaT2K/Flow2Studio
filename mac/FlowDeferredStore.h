#import <Foundation/Foundation.h>
@interface FlowDeferredStore:NSObject
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults;
- (NSArray<NSDictionary *> *)jobs:(NSString *)deviceKey;
- (NSDictionary *)enqueue:(NSString *)action arguments:(NSDictionary *)arguments deviceKey:(NSString *)key;
- (void)complete:(NSString *)jobID deviceKey:(NSString *)key;
- (void)block:(NSString *)jobID error:(NSString *)message deviceKey:(NSString *)key;
- (void)clear:(NSString *)key;
+ (BOOL)accepts:(NSString *)action;
@end
