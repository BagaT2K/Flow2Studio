#ifndef FLOW_PREFERENCES_H
#define FLOW_PREFERENCES_H
#import <Foundation/Foundation.h>

// Import only Studio's settings, once. Existing values in the new domain win.
// The old namespace is discovered by its app suffix, without embedding a publisher name.
static inline void FlowImportPreferences(NSUserDefaults *defaults,NSString *domain,NSDictionary<NSString *,NSDictionary *> *candidates){
 NSMutableDictionary *current=[[defaults persistentDomainForName:domain]mutableCopy]?:[NSMutableDictionary dictionary];
 if([current[@"preferencesNamespace.v1"]boolValue])return;
 NSArray *keys=@[@"theme",@"batteryStyle",@"autoCharge",@"editingConnection",@"keycaps",@"language",
                 @"initializedLayers.v1",@"verifiedCapabilities.v1",@"deferredSettings.v1"];
 NSMutableArray *sources=[NSMutableArray array];
 for(NSString *name in candidates){
  if([name isEqual:domain]||![name hasSuffix:@".flow2studio"])continue;
  NSDictionary *source=candidates[name];if(![source isKindOfClass:NSDictionary.class])continue;
  BOOL recognized=NO;for(NSString *key in keys)if(source[key]){recognized=YES;break;}
  if(recognized)[sources addObject:source];
 }
 // Do not choose arbitrarily between multiple independent installations.
 if(sources.count>1)return;
 if(sources.count==1)for(NSString *key in keys)if(!current[key]&&sources[0][key])current[key]=sources[0][key];
 current[@"preferencesNamespace.v1"]=@YES;
 [defaults setPersistentDomain:current forName:domain];
}

static inline void FlowMigratePreferences(void){
 NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;
 NSString *domain=NSBundle.mainBundle.bundleIdentifier;
 if(!domain.length||[defaults boolForKey:@"preferencesNamespace.v1"])return;
 NSURL *library=[NSFileManager.defaultManager URLsForDirectory:NSLibraryDirectory inDomains:NSUserDomainMask].firstObject;
 NSURL *directory=[library URLByAppendingPathComponent:@"Preferences" isDirectory:YES];
 NSArray *files=[NSFileManager.defaultManager contentsOfDirectoryAtURL:directory includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:NULL];
 NSMutableDictionary *candidates=[NSMutableDictionary dictionary];
 for(NSURL *file in files){
  if(![file.lastPathComponent hasSuffix:@".flow2studio.plist"])continue;
  NSString *name=file.lastPathComponent.stringByDeletingPathExtension;
  if([name isEqual:domain])continue;
  NSDictionary *values=[defaults persistentDomainForName:name];if(values)candidates[name]=values;
 }
 FlowImportPreferences(defaults,domain,candidates);
}
#endif
