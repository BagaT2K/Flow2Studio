#import "FlowLocalization.h"
#import <dispatch/dispatch.h>
BOOL FlowLanguageSupported(NSString *language){return [@[@"en",@"zh",@"ja",@"ko",@"es",@"de",@"ru"]containsObject:language?:@""];}
NSString *FlowCurrentLanguage(void){NSString *language=[NSUserDefaults.standardUserDefaults stringForKey:@"language"];return FlowLanguageSupported(language)?language:@"en";}
NSString *FlowLocalized(NSString *source){
 if(!source.length)return source;
 static NSDictionary *catalog,*reverse;static NSArray *keys;static dispatch_once_t once;
 dispatch_once(&once,^{NSURL *url=[NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"ui/locales.json"];NSData *data=[NSData dataWithContentsOfURL:url];catalog=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]:@{};
  if(![catalog isKindOfClass:NSDictionary.class])catalog=@{};
  keys=[catalog.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a,NSString *b){return a.length>b.length?NSOrderedAscending:a.length<b.length?NSOrderedDescending:[a compare:b];}];
  NSMutableDictionary *map=[NSMutableDictionary dictionary];for(NSString *key in keys)for(NSString *value in [catalog[key]allValues])if(!map[value])map[value]=key;reverse=map;
 });
 NSString *language=FlowCurrentLanguage(),*key=catalog[source]?source:reverse[source];if(key)return catalog[key][language]?:catalog[key][@"en"]?:source;
 NSMutableString *out=[source mutableCopy];
 /* Protect replacements from being translated again by scanning the source once. */
 NSMutableString *result=[NSMutableString string];NSUInteger offset=0;
 while(offset<out.length){NSRange best=NSMakeRange(NSNotFound,0);NSString *found=nil;
  for(NSString *candidate in keys){NSRange range=[out rangeOfString:candidate options:0 range:NSMakeRange(offset,out.length-offset)];if(range.location!=NSNotFound&&(best.location==NSNotFound||range.location<best.location||(range.location==best.location&&range.length>best.length))){best=range;found=candidate;}}
  if(!found){[result appendString:[out substringFromIndex:offset]];break;}
  [result appendString:[out substringWithRange:NSMakeRange(offset,best.location-offset)]];[result appendString:catalog[found][language]?:catalog[found][@"en"]?:found];offset=NSMaxRange(best);
 }return result;
}
