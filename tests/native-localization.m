#import <Foundation/Foundation.h>
#import "../mac/FlowLocalization.h"
#include <assert.h>
#include <stdio.h>
int main(void){@autoreleasepool{
 NSArray *languages=@[@"en",@"zh",@"ja",@"ko",@"es",@"de",@"ru"],*brightness=@[@"Brightness",@"亮度",@"明るさ",@"밝기",@"Brillo",@"Helligkeit",@"Яркость"];
 assert(!FlowLanguageSupported(@"xx"));
 NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;
 [defaults setVolatileDomain:@{@"language":@"xx"}forName:NSArgumentDomain];assert([FlowCurrentLanguage()isEqual:@"en"]);
 for(NSUInteger i=0;i<languages.count;i++){
  [defaults setVolatileDomain:@{@"language":languages[i]}forName:NSArgumentDomain];assert([FlowCurrentLanguage()isEqual:languages[i]]);assert([FlowLocalized(@"Яркость")isEqual:brightness[i]]);
  NSString *title=[NSString stringWithFormat:FlowLocalized(@"Вернуть заводские назначения слоя %d?"),2];assert([title containsString:@"2"]);
  NSString *path=@"/Users/test/Слой.bin";assert([FlowLocalized(path)isKindOfClass:NSString.class]);
 }
 [defaults removeVolatileDomainForName:NSArgumentDomain];puts("Native localization: seven languages, English fallback and formatted dialogs passed; no persistent preferences changed.");
}return 0;}
