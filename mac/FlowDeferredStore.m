#import "FlowDeferredStore.h"
@interface FlowDeferredStore ()
@property(nonatomic,strong) NSUserDefaults *defaults;
- (void)save:(NSArray *)jobs key:(NSString *)key;
@end
static NSDictionary *normalizedLighting(NSDictionary *args){
 if([args[@"effectFamily"]isEqual:@"zones-v1"])return args;
 NSMutableDictionary *safe=[args mutableCopy];if([safe[@"effect"]unsignedIntValue]>1)safe[@"effect"]=@1;
 safe[@"waveSpeed"]=@1;safe[@"effectFamily"]=@"zones-v1";return safe;
}
@implementation FlowDeferredStore
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults {if((self=[super init]))_defaults=defaults;return self;}
+ (BOOL)accepts:(NSString *)action {return [@[@"lighting",@"profile",@"advanced",@"setKey",@"setLayer",@"saveMacros"]containsObject:action];}
- (NSArray<NSDictionary *> *)jobs:(NSString *)key {
 id v=[self.defaults dictionaryForKey:@"deferredSettings.v1"][key];if(![v isKindOfClass:NSArray.class])return @[];
 NSMutableArray *jobs=[v mutableCopy];BOOL changed=NO;
 for(NSUInteger i=0;i<jobs.count;i++){NSDictionary *job=jobs[i];if([job[@"action"]isEqual:@"lighting"]&&![job[@"args"][@"effectFamily"]isEqual:@"zones-v1"]){NSMutableDictionary *m=[job mutableCopy];m[@"args"]=normalizedLighting(job[@"args"]);jobs[i]=m;changed=YES;}}
 if(changed)[self save:jobs key:key];return jobs;
}
- (void)save:(NSArray *)jobs key:(NSString *)key {NSMutableDictionary *all=[[self.defaults dictionaryForKey:@"deferredSettings.v1"]mutableCopy]?:[NSMutableDictionary dictionary];if(jobs.count)all[key]=jobs;else [all removeObjectForKey:key];[self.defaults setObject:all forKey:@"deferredSettings.v1"];}
- (NSDictionary *)enqueue:(NSString *)action arguments:(NSDictionary *)arguments deviceKey:(NSString *)key {
    if(!key.length||![FlowDeferredStore accepts:action])return nil;
    NSMutableDictionary *args=[([action isEqual:@"lighting"]?normalizedLighting(arguments):arguments) mutableCopy];if([@[@"lighting",@"profile",@"advanced"]containsObject:action])args[@"persist"]=@YES;
    NSMutableArray *jobs=[[self jobs:key]mutableCopy];
    NSString *slot=[action isEqual:@"setKey"]?[NSString stringWithFormat:@"key:%@:%@:%@",args[@"layer"],args[@"row"],args[@"col"]]:[action isEqual:@"setLayer"]?[NSString stringWithFormat:@"layer:%@",args[@"layer"]]:action;
    if([action isEqual:@"setKey"]){
        for(NSDictionary *old in jobs)if(!old[@"error"]&&[old[@"action"]isEqual:@"setLayer"]&&[old[@"args"][@"layer"]isEqual:args[@"layer"]]){
            NSMutableDictionary *merged=[old[@"args"]mutableCopy];NSMutableArray *keys=[merged[@"keys"]mutableCopy];unsigned cols=keys.count==108?18:15;unsigned rows=(unsigned)keys.count/cols;
            if(keys.count!=75&&keys.count!=90&&keys.count!=108)continue;
            int row=[args[@"row"]intValue],col=[args[@"col"]intValue];if(row<0||col<0||row>=(int)rows||col>=(int)cols)continue;
            unsigned pos=(unsigned)row*cols+(unsigned)col;keys[pos]=args[@"code"];merged[@"keys"]=keys;args=merged;action=@"setLayer";slot=old[@"slot"];break;
        }
    }
    if([action isEqual:@"saveMacros"])for(NSDictionary *old in jobs)if(!old[@"error"]&&[old[@"slot"]isEqual:slot])args[@"expected"]=old[@"args"][@"expected"];
    if([action isEqual:@"setKey"])for(NSDictionary *old in jobs)if(!old[@"error"]&&[old[@"slot"]isEqual:slot]){if(old[@"args"][@"previous"])args[@"previous"]=old[@"args"][@"previous"];if(old[@"args"][@"expectedCode"])args[@"expectedCode"]=old[@"args"][@"expectedCode"];}
    if([action isEqual:@"setLayer"]){
        NSMutableArray *expected=[args[@"expected"]mutableCopy];
        for(NSDictionary *old in jobs)if(!old[@"error"]&&[old[@"args"][@"layer"]isEqual:args[@"layer"]]){
            if([old[@"action"]isEqual:@"setLayer"]){expected=[old[@"args"][@"expected"]mutableCopy];break;}
            if([old[@"action"]isEqual:@"setKey"]&&(expected.count==75||expected.count==90||expected.count==108)){unsigned cols=expected.count==108?18:15;unsigned pos=[old[@"args"][@"row"]unsignedIntValue]*cols+[old[@"args"][@"col"]unsignedIntValue];if(pos<expected.count&&old[@"args"][@"previous"]&&[expected[pos]isEqual:old[@"args"][@"code"]])expected[pos]=old[@"args"][@"previous"];}
        }
        if(expected)args[@"expected"]=expected;
    }
    NSIndexSet *old=[jobs indexesOfObjectsPassingTest:^BOOL(NSDictionary *job,NSUInteger idx,BOOL *stop){(void)idx;(void)stop;return [job[@"slot"]isEqual:slot]||([action isEqual:@"setLayer"]&&[job[@"action"]isEqual:@"setKey"]&&[job[@"args"][@"layer"]isEqual:args[@"layer"]]);}];[jobs removeObjectsAtIndexes:old];
    NSDictionary *job=@{@"id":NSUUID.UUID.UUIDString,@"action":action,@"slot":slot,@"args":[args copy]};[jobs addObject:job];[self save:jobs key:key];return job;
}
- (void)complete:(NSString *)jobID deviceKey:(NSString *)key {NSMutableArray *jobs=[[self jobs:key]mutableCopy];NSIndexSet *done=[jobs indexesOfObjectsPassingTest:^BOOL(NSDictionary *job,NSUInteger idx,BOOL *stop){(void)idx;(void)stop;return [job[@"id"]isEqual:jobID];}];[jobs removeObjectsAtIndexes:done];[self save:jobs key:key];}
- (void)block:(NSString *)jobID error:(NSString *)message deviceKey:(NSString *)key {
    NSMutableArray *jobs=[[self jobs:key]mutableCopy];for(NSUInteger i=0;i<jobs.count;i++){NSDictionary *job=jobs[i];if([job[@"id"]isEqual:jobID]){NSMutableDictionary *blocked=[job mutableCopy];blocked[@"error"]=message?:@"Изменение не подтверждено";jobs[i]=blocked;break;}}[self save:jobs key:key];
}
- (void)clear:(NSString *)key {[self save:@[] key:key];}
@end
