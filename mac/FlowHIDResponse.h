#ifndef FLOW_HID_RESPONSE_H
#define FLOW_HID_RESPONSE_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include "FlowBluetooth.h"
#include "FlowProtocol.h"
#include "FlowControl.h"
/* Owned by Session for its entire lifetime, never a request's stack frame. */
typedef struct {
 uint8_t request[32],reply[32];int done;bool active,battery,ble;
 unsigned reports;ptrdiff_t lastLength;
} FlowHIDResponse;
static inline void flow_hid_response_begin(FlowHIDResponse *r,const uint8_t request[32],bool ble){
 memset(r,0,sizeof *r);memcpy(r->request,request,32);r->battery=request[0]==0x15;r->ble=ble;r->active=true;
}
static inline void flow_hid_response_end(FlowHIDResponse *r){r->active=false;}
static inline void flow_hid_response_accept(FlowHIDResponse *r,bool success,bool input,uint32_t reportID,const uint8_t *bytes,size_t length){
 if(!r||!r->active||!success||r->done||!input||!bytes)return;
 uint8_t normalized[32];
 if(r->ble){
  if(reportID!=3)return;
  r->reports++;r->lastLength=(ptrdiff_t)length;
  if(!flow_ble_decode(reportID,bytes,length,normalized))return;
  bytes=normalized;length=32;
 }
 if(length==33&&bytes[0]==0){bytes++;length--;}
 if(length!=32)return;
 if(r->request[0]==0x16){
  if(flow_control_match(r->request,bytes)){memcpy(r->reply,bytes,32);r->done=1;}
  else if(bytes[0]==0xff)r->done=-1;
  return;
 }
 if(r->battery){int valid=flow_validate_command(bytes,32,r->request+8,r->request[4]);if(valid==1){memcpy(r->reply,bytes,32);r->done=1;}else if(valid<0)r->done=valid;return;}
 if(bytes[0]==0xff&&!memcmp(bytes+1,r->request+1,3)){r->done=-1;return;}
 if(bytes[0]!=r->request[0])return;
 size_t prefix=1;
 switch(bytes[0]){case 7:case 8:prefix=3;break;case 4:case 5:case 0x12:case 0xe:case 0xf:case 0x13:prefix=4;break;default:break;}
 if(memcmp(bytes,r->request,prefix))return;
 memcpy(r->reply,bytes,32);r->done=1;
}
#endif
