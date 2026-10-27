#import "../mac/FlowDeferredStore.h"
#include <assert.h>
#include <stdio.h>
int main(void){@autoreleasepool{
 NSString *suite=[@"local.flow2studio.test." stringByAppendingString:NSUUID.UUID.UUIDString];NSUserDefaults *d=[[NSUserDefaults alloc]initWithSuiteName:suite];FlowDeferredStore *s=[[FlowDeferredStore alloc]initWithDefaults:d];
 NSDictionary *a=[s enqueue:@"lighting" arguments:@{@"brightness":@10,@"persist":@NO} deviceKey:@"rf-one"];
 [s enqueue:@"lighting" arguments:@{@"brightness":@70} deviceKey:@"rf-one"];
 [s complete:a[@"id"] deviceKey:@"rf-one"];assert([s jobs:@"rf-one"].count==1);assert([[[s jobs:@"rf-one"][0]objectForKey:@"args"][@"persist"]boolValue]);
 s=[[FlowDeferredStore alloc]initWithDefaults:d];assert([[[s jobs:@"rf-one"][0]objectForKey:@"args"][@"brightness"]intValue]==70);assert([s jobs:@"rf-two"].count==0);
 [s enqueue:@"setKey" arguments:@{@"layer":@0,@"row":@0,@"col":@0,@"code":@4} deviceKey:@"rf-one"];
 [s enqueue:@"setKey" arguments:@{@"layer":@0,@"row":@0,@"col":@1,@"code":@5} deviceKey:@"rf-one"];assert([s jobs:@"rf-one"].count==3);
 [s enqueue:@"saveMacros" arguments:@{@"expected":@"original",@"data":@"first"} deviceKey:@"rf-one"];
 [s enqueue:@"saveMacros" arguments:@{@"expected":@"first",@"data":@"latest"} deviceKey:@"rf-one"];assert([[[s jobs:@"rf-one"].lastObject objectForKey:@"args"][@"expected"]isEqual:@"original"]);
 [s block:[s jobs:@"rf-one"].firstObject[@"id"] error:@"unverified" deviceKey:@"rf-one"];s=[[FlowDeferredStore alloc]initWithDefaults:d];assert([s jobs:@"rf-one"].firstObject[@"error"]);
 [s enqueue:@"lighting" arguments:@{@"brightness":@30} deviceKey:@"rf-one"];assert(![s jobs:@"rf-one"].lastObject[@"error"]);
 [d setObject:@{@"legacy":@[@{@"id":@"old",@"slot":@"lighting",@"action":@"lighting",@"args":@{@"brightness":@73,@"effect":@3,@"persist":@YES}}]} forKey:@"deferredSettings.v1"];
 NSDictionary *migrated=[s jobs:@"legacy"].firstObject[@"args"];assert([migrated[@"brightness"]intValue]==73&&[migrated[@"effect"]intValue]==1&&[migrated[@"effectFamily"]isEqual:@"zones-v1"]);
 [s enqueue:@"lighting" arguments:@{@"brightness":@51,@"effect":@5,@"waveSpeed":@3,@"effectFamily":@"zones-v1"} deviceKey:@"new-waves"];
 NSDictionary *wave=[s jobs:@"new-waves"].firstObject[@"args"];assert([wave[@"effect"]intValue]==5&&[wave[@"waveSpeed"]intValue]==3);
 [s clear:@"rf-one"];NSMutableArray *base=[NSMutableArray array];for(unsigned i=0;i<75;i++)[base addObject:@4];NSMutableArray *expected=[base mutableCopy];expected[0]=@5;NSMutableArray *target=[base mutableCopy];target[0]=@6;
 [s enqueue:@"setKey" arguments:@{@"layer":@0,@"row":@0,@"col":@0,@"code":@5,@"previous":@4,@"expectedCode":@4} deviceKey:@"rf-one"];
 [s enqueue:@"setLayer" arguments:@{@"layer":@0,@"expected":expected,@"keys":target} deviceKey:@"rf-one"];assert([s jobs:@"rf-one"].count==1);NSDictionary *whole=[s jobs:@"rf-one"].firstObject;assert([whole[@"args"][@"expected"][0]intValue]==4);
 [s enqueue:@"setKey" arguments:@{@"layer":@0,@"row":@0,@"col":@1,@"code":@7,@"previous":@4} deviceKey:@"rf-one"];assert([s jobs:@"rf-one"].count==1);whole=[s jobs:@"rf-one"].firstObject;assert([whole[@"action"]isEqual:@"setLayer"]);assert([whole[@"args"][@"keys"][1]intValue]==7);assert([whole[@"args"][@"expected"][0]intValue]==4);
 for(NSNumber *count in @[@90,@108]){unsigned n=count.unsignedIntValue,cols=n==108?18:15;NSString *key=[NSString stringWithFormat:@"model-%u",n];NSMutableArray *baseModel=[NSMutableArray array];for(unsigned i=0;i<n;i++)[baseModel addObject:@4];
  [s enqueue:@"setLayer" arguments:@{@"layer":@5,@"expected":baseModel,@"keys":baseModel} deviceKey:key];
  [s enqueue:@"setKey" arguments:@{@"layer":@5,@"row":@5,@"col":@(cols-1),@"code":@7,@"previous":@4} deviceKey:key];
  NSDictionary *merged=[s jobs:key].firstObject;assert([s jobs:key].count==1);assert([merged[@"args"][@"keys"]count]==n);assert([merged[@"args"][@"keys"][n-1]intValue]==7);[s clear:key];
 }
 assert(![s enqueue:@"resetAll" arguments:@{} deviceKey:@"rf-one"]);[s clear:@"rf-one"];assert([s jobs:@"rf-one"].count==0);[d removePersistentDomainForName:suite];puts("Deferred store: coalescing, restart, device isolation, in-flight replacement and macro baseline passed.");return 0;
}}
