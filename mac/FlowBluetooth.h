#ifndef FLOW_BLUETOOTH_H
#define FLOW_BLUETOOTH_H
#include <stdint.h>
#include <stddef.h>
#include <string.h>

/* Accept only the vendor report shape present in the verified BLE descriptor.
 * Keyboard, pointer, consumer and LED reports are never configuration input.
 */
static inline int flow_ble_descriptor(const uint8_t *p,size_t length) {
    struct globals {uint32_t page,size,count,id;} g={0},stack[8];
    size_t depth=0;uint32_t input=0,output=0,vinput=0,voutput=0;
    for(size_t pos=0;pos<length;){
        uint8_t prefix=p[pos++];
        if(prefix==0xfe){if(pos+2>length)return 0;size_t n=p[pos];pos+=2;if(n>length-pos)return 0;pos+=n;continue;}
        unsigned n=prefix&3;n=n==3?4:n;if(n>length-pos)return 0;
        uint32_t v=0;for(unsigned i=0;i<n;i++)v|=(uint32_t)p[pos++]<<(8*i);
        unsigned type=(prefix>>2)&3,tag=prefix>>4;
        if(type==1){
            switch(tag){case 0:g.page=v;break;case 7:g.size=v;break;case 8:g.id=v;break;case 9:g.count=v;break;
            case 10:if(depth==8)return 0;stack[depth++]=g;break;
            case 11:if(!depth)return 0;g=stack[--depth];break;default:break;}
        }else if(type==0&&g.id==3&&(tag==8||tag==9)){
            if(g.size>32||g.count>4096)return 0;
            uint32_t bits=g.size*g.count;
            if(tag==8){input+=bits;if(g.page==0xff00)vinput+=bits;}
            else{output+=bits;if(g.page==0xff00)voutput+=bits;}
            if(input>248||output>248)return 0;
        }
    }
    return depth==0&&input==248&&output==248&&vinput==248&&voutput==248;
}
/* IOKit requires the numbered report ID both as the argument and byte zero.
 * Only zero padding may be omitted. Never truncate meaningful request data.
 */
static inline int flow_ble_encode(const uint8_t request[32],uint8_t wire[32]) {
    if(request[31])return 0;
    wire[0]=3;memcpy(wire+1,request,31);return 1;
}
static inline int flow_ble_decode(uint32_t reportID,const uint8_t *bytes,size_t length,uint8_t response[32]) {
    if(reportID!=3)return 0;
    if(length==32&&bytes[0]==3){bytes++;length--;}
    if(length!=31)return 0;
    memcpy(response,bytes,31);response[31]=0;return 1;
}
static inline unsigned flow_read_chunk(int ble){return ble?27:28;}
#endif
