#ifndef FLOW_FIRMWARE_MODEL_H
#define FLOW_FIRMWARE_MODEL_H
#include "FlowModels.h"
#include <stddef.h>
static inline bool flow_firmware_model_matches(const uint8_t *image,size_t size,unsigned model,unsigned release){
 FlowModel shape=flow_model(model);if(!image||size!=262144||!shape.model||(release!=9&&release!=20))return false;
 unsigned matches=0;for(size_t n=0;n+18<=size;n++){const uint8_t *d=image+n;if(d[0]==18&&d[1]==1&&d[8]==0x8d&&d[9]==0x38){if(((unsigned)d[10]|(unsigned)d[11]<<8)!=shape.pid||((unsigned)d[12]|(unsigned)d[13]<<8)!=release)return false;matches++;}}
 return matches==1;
}
#endif
