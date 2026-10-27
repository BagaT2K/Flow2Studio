#import "FlowUpdates.h"
#import <AppKit/AppKit.h>

static NSURL *releaseURL;
static NSDictionary *cachedResult;
static NSDate *lastCheck;
static BOOL checking;
static NSMutableArray *waiters;
static NSArray *parts(NSString *value){
 if(![value isKindOfClass:NSString.class])return nil;
 if([value hasPrefix:@"v"])value=[value substringFromIndex:1];
 NSArray *items=[value componentsSeparatedByString:@"."];
 if(items.count<2||items.count>3)return nil;
 for(NSString *item in items){
  if(!item.length||item.length>6||[item rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789"].invertedSet].location!=NSNotFound)return nil;
 }
 return items;
}
NSComparisonResult FlowCompareVersions(NSString *left,NSString *right){
 NSArray *a=parts(left),*b=parts(right);if(!a||!b)return NSOrderedSame;
 for(unsigned i=0;i<3;i++){NSInteger x=i<a.count?[a[i]integerValue]:0,y=i<b.count?[b[i]integerValue]:0;if(x!=y)return x>y?NSOrderedDescending:NSOrderedAscending;}
 return NSOrderedSame;
}
static void finish(NSDictionary *result,NSString *error){
 dispatch_async(dispatch_get_main_queue(),^{
  checking=NO;if(result){cachedResult=result;lastCheck=NSDate.date;}
  NSArray *callbacks=[waiters copy];[waiters removeAllObjects];
  for(void (^callback)(NSDictionary *,NSString *) in callbacks)callback(result,error);
 });
}
void FlowCheckUpdates(BOOL force,void (^completion)(NSDictionary *,NSString *)){
 // Called on the main queue. Release checks use the bundled repository configuration.
 if(!force&&cachedResult&&-[lastCheck timeIntervalSinceNow]<21600){completion(cachedResult,nil);return;}
 if(!waiters)waiters=[NSMutableArray array];[waiters addObject:[completion copy]];
 if(checking)return;checking=YES;
 NSURL *file=[NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"ui/update-config.json"];
 NSData *raw=[NSData dataWithContentsOfURL:file];NSDictionary *config=raw?[NSJSONSerialization JSONObjectWithData:raw options:0 error:NULL]:nil;
 if(![config isKindOfClass:NSDictionary.class])config=@{};
 NSString *repo=[config[@"repository"]isKindOfClass:NSString.class]?config[@"repository"]:@"";
 NSArray *components=[repo componentsSeparatedByString:@"/"];
 NSCharacterSet *allowed=[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_."];
 BOOL valid=components.count==2;
 for(NSString *component in components)valid=valid&&component.length&&![component hasPrefix:@"."]&&[component rangeOfCharacterFromSet:allowed.invertedSet].location==NSNotFound;
 if(!valid){finish(@{@"configured":@NO,@"preview":@([config[@"preview"]boolValue])},nil);return;}
 NSURL *url=[NSURL URLWithString:[NSString stringWithFormat:@"https://api.github.com/repos/%@/releases?per_page=20",repo]];
 NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15];
 [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
 [request setValue:@"Flow2Studio" forHTTPHeaderField:@"User-Agent"];
 NSURLSessionConfiguration *sessionConfig=NSURLSessionConfiguration.ephemeralSessionConfiguration;
 sessionConfig.timeoutIntervalForResource=20;sessionConfig.HTTPShouldSetCookies=NO;
 NSURLSession *session=[NSURLSession sessionWithConfiguration:sessionConfig];
 [[session dataTaskWithRequest:request completionHandler:^(NSData *data,NSURLResponse *response,NSError *error){
  [session finishTasksAndInvalidate];
  if(error||!data||data.length>2*1024*1024||![response isKindOfClass:NSHTTPURLResponse.class]||[(NSHTTPURLResponse *)response statusCode]!=200){finish(nil,@"Не удалось проверить обновления. Попробуйте позже.");return;}
  id payload=[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
  if(![payload isKindOfClass:NSArray.class]){finish(nil,@"Не удалось проверить обновления. Попробуйте позже.");return;}
  NSString *current=[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"]?:@"0.9.7",*latest=current,*tag=nil;
  for(id item in payload){
   if(![item isKindOfClass:NSDictionary.class]||![item[@"draft"]isKindOfClass:NSNumber.class]||![item[@"prerelease"]isKindOfClass:NSNumber.class])continue;
   if([item[@"draft"]boolValue]||([item[@"prerelease"]boolValue]&&![config[@"channel"]isEqual:@"prerelease"]))continue;
   NSString *version=item[@"tag_name"];
   if(parts(version)&&FlowCompareVersions(version,latest)==NSOrderedDescending){latest=[version hasPrefix:@"v"]?[version substringFromIndex:1]:version;tag=version;}
  }
  // Construct the browser link from the configured repository, never from remote release text.
  NSURLComponents *destination=[NSURLComponents componentsWithString:[@"https://github.com/" stringByAppendingString:repo]];
  destination.path=[NSString stringWithFormat:@"/%@/releases%@",repo,tag?[@"/tag/" stringByAppendingString:tag]:@""];
  NSDictionary *result=@{@"configured":@YES,@"available":@(tag!=nil),@"version":latest,@"preview":@NO};
  dispatch_async(dispatch_get_main_queue(),^{releaseURL=destination.URL;finish(result,nil);});
 }]resume];
}
BOOL FlowOpenUpdate(void){return [cachedResult[@"available"]boolValue]&&releaseURL&&[NSWorkspace.sharedWorkspace openURL:releaseURL];}
