#ifndef FLOW_LAYER_IO_H
#define FLOW_LAYER_IO_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
typedef struct {void *context;bool (*read)(void *,unsigned,uint8_t *,size_t);bool (*write)(void *,unsigned,const uint8_t *,size_t);} FlowLayerIO;
static inline bool flow_layer_write_verify_sized(FlowLayerIO *io,unsigned layer,const uint8_t *data,size_t length,size_t layerBytes){
 if(!io||!io->read||!io->write||layer>=6||!data||(layerBytes!=150&&layerBytes!=180&&layerBytes!=216)||length!=layerBytes)return false;
 for(unsigned n=0;n<layerBytes;){unsigned count=(unsigned)layerBytes-n;if(count>28)count=28;if(!io->write(io->context,layer*layerBytes+n,data+n,count))return false;n+=count;}
 uint8_t actual[216];return io->read(io->context,layer*layerBytes,actual,layerBytes)&&!memcmp(actual,data,layerBytes);
}
static inline bool flow_layer_write_verify(FlowLayerIO *io,unsigned layer,const uint8_t *data,size_t length){return flow_layer_write_verify_sized(io,layer,data,length,150);}
#endif
