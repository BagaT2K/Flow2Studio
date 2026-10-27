#include "../mac/FlowKeymapCore.h"
#include "../mac/FlowLayerIO.h"
#include "../mac/FlowMacroKeys.h"
#include <assert.h>
#include <stdio.h>
typedef struct {uint8_t bytes[900];unsigned writes,layer;int fail,badRead;} Fake;
static bool readLayer(void *ctx,unsigned offset,uint8_t *out,size_t length){Fake *f=ctx;assert(offset==f->layer*150&&length==150);memcpy(out,f->bytes+offset,length);if(f->badRead)out[0]^=1;return true;}
static bool writeLayer(void *ctx,unsigned offset,const uint8_t *bytes,size_t length){Fake *f=ctx;assert(offset>=f->layer*150&&offset+length<=f->layer*150+150&&length<=28);f->writes++;if(f->fail&&(int)f->writes==f->fail){memcpy(f->bytes+offset,bytes,1);return false;}memcpy(f->bytes+offset,bytes,length);return true;}
int main(void){
 uint8_t data[150],fn[150];
 for(unsigned layer=0;layer<6;layer++){
  flow_layer_default(layer,data);assert(flow_layer_initializable(layer,flow_factory_keys+layer*150)==!flow_layer_fn(layer));
  if(flow_layer_fn(layer))assert(!memcmp(data,flow_factory_keys+layer*150,150));
  else{assert(data[2]==0&&data[3]==30);uint8_t custom[150];memcpy(custom,data,150);custom[0]=0x77;custom[1]=0;assert(!flow_layer_initializable(layer,custom));}
  if(layer>=4)for(unsigned pos=0;pos<75;pos++)if(flow_factory_keys[layer*150+pos*2])assert(!memcmp(data+pos*2,flow_factory_keys+layer*150+pos*2,2));
 }
 memset(data,0,150);assert(!flow_layer_initializable(4,data));for(unsigned i=0;i<75;i++)data[i*2+1]=1;assert(flow_layer_initializable(4,data));
 assert(flow_fn_template(1,true,fn));for(unsigned col=1;col<=12;col++)assert(fn[col*2]==0&&fn[col*2+1]==57+col);assert(!flow_fn_template(0,true,fn));
 for(unsigned layer=0;layer<6;layer++)for(int failure=0;failure<=6;failure++){
  Fake f={.layer=layer,.fail=failure};memset(f.bytes,0xa5,900);uint8_t original[900];memcpy(original,f.bytes,900);flow_layer_default(layer,data);FlowLayerIO io={&f,readLayer,writeLayer};bool ok=flow_layer_write_verify(&io,layer,data,150);assert(ok==(failure==0));
  assert(!memcmp(f.bytes,original,layer*150));assert(!memcmp(f.bytes+(layer+1)*150,original+(layer+1)*150,900-(layer+1)*150));
  if(failure){f.fail=0;assert(flow_layer_write_verify(&io,layer,original+layer*150,150));assert(!memcmp(f.bytes,original,900));}
  f.badRead=1;assert(!flow_layer_write_verify(&io,layer,data,150));
 }
 Fake f={0};FlowLayerIO io={&f,readLayer,writeLayer};assert(!flow_layer_write_verify(&io,6,data,150));assert(!flow_layer_write_verify(&io,0,data,149));assert(!f.writes);
 assert(flow_macro_mac_key(0)==4&&flow_macro_mac_key(55)==227&&flow_macro_mac_key(54)==231&&flow_macro_mac_key(56)==225&&flow_macro_mac_key(60)==229);
 assert(flow_macro_mac_key(122)==58&&flow_macro_mac_key(111)==69&&flow_macro_mac_key(123)==80&&flow_macro_mac_key(63)==0&&flow_macro_mac_key(128)==0);
 puts("Passed: ordinary layer defaults, preserved Fn/service codes, custom layouts unchanged; bounded single-layer writes, partial failure rollback, readback mismatch; Mac physical-key mapping.");
}
