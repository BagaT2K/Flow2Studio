#include "FlowControl.h"
#ifndef FLOW_SERIAL_PROTOCOL_H
#define FLOW_SERIAL_PROTOCOL_H
#include "FlowProtocol.h"
/* Confirmed on the owner's Freqchip 0.2.6 by a nonce-matched 34-byte reply. */
/* Recovered from public radio v028; owner v026 compatibility requires hardware check.
   This is a radio-level wake, not a VIA setter. */
static inline int flow_serial_needs_radio_wake(const uint8_t p[32]){
    return !memcmp(p,"\x16LFC\x03\x06\x01",7);
}
static inline void flow_serial_radio_wake(uint8_t p[4]){
    p[0]=0xaa;p[1]=3;p[2]=0xa2;p[3]=1;
}
static inline void flow_serial_wrap(const uint8_t request[32],uint8_t wire[35]){
    wire[0]=0xaa;wire[1]=0x22;wire[2]=0xa1;memcpy(wire+3,request,32);
}
static inline int flow_serial_unwrap(const uint8_t *wire,size_t length,uint8_t reply[32]){
    if(length!=34||wire[0]!=5||wire[1]!=0xaf)return 0;
    memcpy(reply,wire+2,32);return 1;
}
/* 1: matching reply; -1: unsupported command; 0: unrelated. No retries. */
static inline int flow_serial_match(const uint8_t request[32],const uint8_t reply[32]){
    if(request[0]==0x16)return flow_control_match(request,reply)?1:(reply[0]==0xff?-1:0);
    if(request[0]==0x15)return flow_validate(reply,32,request+8)==1?1:0;
    if(reply[0]==0xff&&!memcmp(reply+1,request+1,3))return -1;
    if(reply[0]!=request[0])return 0;
    size_t prefix=1;
    switch(request[0]){case 7:case 8:prefix=3;break;case 4:case 5:case 0x12:case 0xe:case 0xf:case 0x13:prefix=4;break;default:break;}
    return !memcmp(reply,request,prefix);
}
#endif
