/* Included after Session implementation. Requests are serialized by Studio. */
static BOOL touchArguments(NSDictionary *v){
 if(![v isKindOfClass:NSDictionary.class])return NO;
 for(NSString *name in @[@"count",@"b1",@"b2"])if(![v[name]isKindOfClass:NSNumber.class])return NO;
 int count=[v[@"count"]intValue],b1=[v[@"b1"]intValue],b2=[v[@"b2"]intValue];
 if(count<1||count>3||b1<15||b1>85||b2<30||b2>85||(count==3&&b2<b1+15))return NO;
 NSArray *modes=v[@"actions"];if(![modes isKindOfClass:NSArray.class]||modes.count!=2)return NO;
 for(id mode in modes){if(![mode isKindOfClass:NSArray.class]||[mode count]!=9)return NO;for(id value in mode){if(![value isKindOfClass:NSNumber.class])return NO;int n=[value intValue];if(n<0||!flow_touch_action((unsigned)n))return NO;}}
 return YES;
}
static NSDictionary *touchReply(const uint8_t r[32]){
 NSMutableArray *actions=[NSMutableArray array];for(unsigned i=0;i<9;i++)[actions addObject:@(flow_touch_bits(r+10,i))];
 return @{@"count":@(r[7]),@"b1":@(r[8]),@"b2":@(r[9]),@"mode":@(r[6]),@"actions":actions};
}
static BOOL touchExchange(Session *s,unsigned op,unsigned mode,unsigned slot,NSDictionary *config,uint32_t token,uint8_t out[32],NSError **error){
 uint8_t p[32]={0};memcpy(p,"\x18LFT\x02",5);p[5]=(uint8_t)op;p[6]=(uint8_t)mode;p[7]=(uint8_t)slot;
 if(config){p[7]=[config[@"count"]unsignedCharValue];p[8]=[config[@"b1"]unsignedCharValue];p[9]=[config[@"b2"]unsignedCharValue];for(unsigned i=0;i<9;i++)flow_touch_pack(p+10,i,[config[@"actions"][mode][i]unsignedIntValue]);}
 p[21]=[s.device[@"model"]intValue];arc4random_buf(p+22,4);memcpy(p+26,&token,4);
 if(![s packet:p response:out error:error])return NO;
 if(flow_touch_match(p,out)&&out[5]==3){fail(error,@"Touch Bar: could not save settings to the keyboard. The previous assignment is still active.");return NO;}
 if(!flow_touch_match(p,out)||out[5]){fail(error,@"Touch Bar: the keyboard did not confirm the settings. Check the connection and try again.");return NO;}
 return YES;
}
static NSDictionary *touchReadConfig(Session *s,unsigned slot,unsigned known,NSError **error){
 uint8_t a[32],b[32];unsigned op=slot?3:0;
 if(!touchExchange(s,op,0,slot,nil,0,a,error))return nil;
 if(known&&known==a[7])return @{@"count":@(known)};
 if(!touchExchange(s,op,1,slot,nil,0,b,error))return nil;
 NSDictionary *first=touchReply(a),*second=touchReply(b);
 NSMutableDictionary *v=[@{@"count":first[@"count"],@"b1":first[@"b1"],@"b2":first[@"b2"],@"actions":@[first[@"actions"],second[@"actions"]]}mutableCopy];
 if(a[26]<=7&&a[26]==b[26])v[@"savedProfiles"]=@(a[26]);
 if((slot&&a[7]!=slot)||a[7]!=b[7]||a[8]!=b[8]||a[9]!=b[9]||!touchArguments(v)){fail(error,@"Touch Bar: invalid device response.");return nil;}return v;
}
static NSDictionary *touchReadProfile(Session *s,unsigned slot,NSError **error){return touchReadConfig(s,slot,0,error);}
static NSDictionary *touchRead(Session *s,NSError **error){return touchReadProfile(s,0,error);}
static NSDictionary *touchSelect(Session *s,NSDictionary *arguments,NSError **error){
 NSNumber *count=arguments[@"count"];int slot=[count isKindOfClass:NSNumber.class]?count.intValue:0;uint8_t r[32];
 if(slot<1||slot>3){fail(error,@"Touch Bar: invalid zones or assignments.");return nil;}
 if(!touchExchange(s,4,0,(unsigned)slot,nil,0,r,error))return nil;
 NSDictionary *value=touchRead(s,error);
 if(value&&[value[@"count"]intValue]!=slot){fail(error,@"Touch Bar: retrieved settings differ from the settings sent.");return nil;}
 return value;
}
static NSDictionary *touchSet(Session *s,NSDictionary *config,NSError **error){
 if(!touchArguments(config)){fail(error,@"Touch Bar: invalid zones or assignments.");return nil;}
 uint32_t token;arc4random_buf(&token,sizeof token);uint8_t r[32];
 BOOL keepActive=[config[@"keepActive"] isEqual:@YES];
 if(!touchExchange(s,1,0,0,config,token,r,error)||!touchExchange(s,1,1,0,config,token,r,error)||!touchExchange(s,keepActive?5:2,0,0,nil,token,r,error))return nil;
 NSDictionary *v=touchReadProfile(s,keepActive?[config[@"count"]unsignedIntValue]:0,error);if(!v)return nil;
 for(NSString *key in @[@"count",@"b1",@"b2",@"actions"])if(![v[key]isEqual:config[key]]){fail(error,@"Touch Bar: retrieved settings differ from the settings sent.");return nil;}return v;
}
