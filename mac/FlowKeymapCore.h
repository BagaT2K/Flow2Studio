#ifndef FLOW_KEYMAP_CORE_H
#define FLOW_KEYMAP_CORE_H
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include "FlowFactory.h"
static inline bool flow_layer_valid(unsigned layer){return layer<6;}
static inline bool flow_layer_fn(unsigned layer){return layer==1||layer==3;}
static inline void flow_layer_default(unsigned layer,uint8_t out[150]){
 unsigned base=(layer==2||layer==3)?2:0;
 memcpy(out,flow_factory_keys+base*150,150);
 // Preserve manufacturer service shortcuts on auxiliary layers while filling
 // transparent/basic positions from the ordinary layout. Fn banks stay OEM.
 if(flow_layer_fn(layer)){memcpy(out,flow_factory_keys+layer*150,150);return;}
 if(layer>=4)for(unsigned i=0;i<75;i++){const uint8_t *p=flow_factory_keys+layer*150+i*2;if(p[0]){out[i*2]=p[0];out[i*2+1]=p[1];}}
}
static inline bool flow_layer_initializable(unsigned layer,const uint8_t current[150]){
 if(!flow_layer_valid(layer)||flow_layer_fn(layer))return false;
 if(!memcmp(current,flow_factory_keys+layer*150,150))return true;
 for(unsigned i=0;i<75;i++)if(current[i*2]||current[i*2+1]!=1)return false;
 return true;
}
static inline bool flow_fn_template(unsigned layer,bool functionKeys,uint8_t out[150]){
 if(!flow_layer_fn(layer))return false;
 memcpy(out,flow_factory_keys+layer*150,150);
 if(functionKeys)for(unsigned col=1;col<=12;col++){out[col*2]=0;out[col*2+1]=(uint8_t)(57+col);}
 return true;
}
#endif
