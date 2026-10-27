#ifndef FLOW_PACKETS_H
#define FLOW_PACKETS_H
#include <stdint.h>
#include <string.h>
static inline unsigned flow_brightness_level(unsigned value){return value<=255?(value*4+127)/255:5;}
static inline unsigned flow_brightness_byte(unsigned level){return level<=4?(level*255+3)/4:256;}
static inline int flow_buffer_request(uint8_t p[32],int macro,unsigned offset,unsigned count){
    if(!count||count>28||offset>65535||offset+count>65536)return 0;
    memset(p,0,32);p[0]=macro?0x0e:0x12;p[1]=offset>>8;p[2]=offset;p[3]=count;return 1;
}
static inline int flow_key_request_sized(uint8_t p[32],int write,unsigned layer,unsigned row,unsigned col,unsigned code,unsigned rows,unsigned cols){
    if(layer>=16||!rows||rows>6||!cols||cols>18||row>=rows||col>=cols||code>65535)return 0;
    memset(p,0,32);p[0]=write?5:4;p[1]=layer;p[2]=row;p[3]=col;
    if(write){p[4]=code>>8;p[5]=code;}return 1;
}
static inline int flow_key_request(uint8_t p[32],int write,unsigned layer,unsigned row,unsigned col,unsigned code){return flow_key_request_sized(p,write,layer,row,col,code,5,15);}
#endif
