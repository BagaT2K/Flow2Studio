#ifndef FLOW_TOUCH_PROTOCOL_H
#define FLOW_TOUCH_PROTOCOL_H
#include <stdint.h>
#include <string.h>
static inline unsigned flow_touch_bits(const uint8_t *p,unsigned i){unsigned bit=i*9,byte=bit/8;return ((unsigned)p[byte]|(unsigned)p[byte+1]<<8)>>(bit%8)&511;}
static inline void flow_touch_pack(uint8_t *p,unsigned i,unsigned value){for(unsigned j=0;j<9;j++){unsigned bit=i*9+j,mask=1u<<(bit%8);p[bit/8]=(p[bit/8]&~mask)|((value>>j&1)?mask:0);}}
static inline int flow_touch_action(unsigned id){return (id<=10&&id!=8)||(id>=68&&id<=179)||(id>=288&&id<=295)||(id>=320&&id<=339);}
static inline int flow_touch_match(const uint8_t p[32],const uint8_t r[32]){
 return !memcmp(p,"\x18LFT\x02",5)&&!memcmp(r,"\x18LFT\x81",5)&&!memcmp(p+22,r+22,4)&&p[6]==r[6]&&r[5]<=3&&r[27]==3&&(p[21]==68||p[21]==84||p[21]==100)&&r[21]==p[21]&&!memcmp(r+28,"TC2",4);
}
static inline unsigned flow_touch_live_position(const uint8_t *packet,size_t length,unsigned model,uint32_t token){
 if(length!=32||!token||memcmp(packet,"\x18LFT\x82",5)||packet[21]!=model||packet[27]!=3||memcmp(packet+28,"TC2",4))return 0;
 uint32_t received=(uint32_t)packet[22]|(uint32_t)packet[23]<<8|(uint32_t)packet[24]<<16|(uint32_t)packet[25]<<24;
 return received==token&&packet[7]>=1&&packet[7]<=50?packet[7]:0;
}
#endif
