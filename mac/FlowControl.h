#ifndef FLOW_CONTROL_H
#define FLOW_CONTROL_H
#include <stdint.h>
#include <string.h>
static inline void flow_control_request(uint8_t p[32],unsigned op,unsigned flags,unsigned brightness,unsigned seconds,const uint8_t nonce[4]){
 memset(p,0,32);p[0]=0x16;p[1]='L';p[2]='F';p[3]='C';p[4]=3;p[5]=op;p[6]=flags;p[7]=brightness;p[8]=seconds>>8;p[9]=seconds;memcpy(p+12,nonce,4);
}
/* Public release numbers are independent of the legacy feature-generation counter. */
static inline unsigned flow_control_generation(const uint8_t r[32]){
 if(r[21]==0&&r[22]==9&&r[23]==0x14)return 19;
 return r[21]==3?r[22]:0;
}
static inline int flow_control_model_matches(const uint8_t r[32],unsigned model){
 unsigned generation=flow_control_generation(r);
 return generation==19?r[20]==model:model==68;
}
static inline int flow_control_match(const uint8_t p[32],const uint8_t r[32]){
 unsigned version=flow_control_generation(r);
 int supported=(r[10]==127&&!memcmp(r+16,"F2S1\x44\x03\x02\x00",8))||(r[10]==255&&(!memcmp(r+16,"F2S1\x44\x03\x03\x00",8)||!memcmp(r+16,"F2S1\x44\x03\x04\x00",8)||!memcmp(r+16,"F2S1\x44\x03\x05\x00",8)||!memcmp(r+16,"F2S1\x44\x03\x06\x00",8)||!memcmp(r+16,"F2S1\x44\x03\x07\x00",8)||!memcmp(r+16,"F2S1\x44\x03\x08\x00",8)||!memcmp(r+16,"F2S1\x44\x03\x09\x00",8)||!memcmp(r+16,"F2S1\x44\x03\x0a\x00",8)||!memcmp(r+16,"F2S1\x44\x03\x0b\x00",8)||!memcmp(r+16,"F2S1\x44\x03\x0c\x00",8)||!memcmp(r+16,"F2S1\x44\x03\x0d\x00",8)||!memcmp(r+16,"F2S1\x44\x03\x0e\x00",8)||!memcmp(r+16,"F2S1\x44\x03\x0f\x00",8)||!memcmp(r+16,"F2S1\x44\x03\x10\x00",8)||!memcmp(r+16,"F2S1\x44\x03\x11\x00",8)||!memcmp(r+16,"F2S1\x44\x03\x12\x00",8)));
 supported=supported||(r[10]==255&&!memcmp(r+16,"F2S1",4)&&(r[20]==68||r[20]==84||r[20]==100)&&((r[21]==3&&r[22]==19)||(r[21]==0&&r[22]==9))&&r[23]==0x14);
 return !memcmp(p,r,4)&&r[4]==0x81&&!memcmp(p+12,r+12,4)&&r[5]<=2&&r[6]<=15&&((r[8]<<8)|r[9])<=3600&&supported&&r[11]==3&&r[24]<=100&&(version<8||(r[25]<=100&&r[26]<=1))&&(version<10||(version<15?r[28]<=3:((r[28]&15)<=(version>=16?5:4)&&(r[28]>>4)<=3)));
}
#endif
