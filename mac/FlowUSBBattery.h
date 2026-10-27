#ifndef FLOW_USB_BATTERY_H
#define FLOW_USB_BATTERY_H
#include <stdbool.h>
#include "FlowProtocol.h"
typedef struct {
 void *context;
 bool (*exchange)(void *,const uint8_t[32],uint8_t[32]);
 void (*nonce)(void *,uint8_t[4]);
 void (*wait)(void *,unsigned);
} FlowUSBBatteryIO;
enum FlowUSBBatteryState { FlowUSBBatteryValid,FlowUSBBatteryRefreshFailed,FlowUSBBatteryNotWired,FlowUSBBatteryQueueFull,FlowUSBBatteryPending,FlowUSBBatteryReadFailed };
typedef struct {enum FlowUSBBatteryState state;bool requested;unsigned reads;} FlowUSBBatteryResult;
/* Caller has freshly verified the pinned 3.9 identity on the wired USB endpoint.
   One OEM request, at most five fresh status reads, no wake/configuration writes.
   The previous sample is replaced only by a nonce-validated status response. */
static inline FlowUSBBatteryResult flow_usb_battery_refresh(const FlowUSBBatteryIO *io,uint8_t status[32]){
 FlowUSBBatteryResult result={FlowUSBBatteryRefreshFailed,false,0};
 uint8_t p[32],r[32],nonce[4];
 io->nonce(io->context,nonce);flow_request(p,nonce);p[4]=2;
 if(!io->exchange(io->context,p,r)||flow_validate_command(r,32,nonce,2)!=1)return result;
 if(r[27]!=1){result.state=r[27]==2?FlowUSBBatteryNotWired:FlowUSBBatteryQueueFull;return result;}
 result.requested=true;result.state=FlowUSBBatteryPending;
 for(unsigned i=0;i<5;i++){
  io->wait(io->context,80);io->nonce(io->context,nonce);flow_request(p,nonce);result.reads++;
  if(!io->exchange(io->context,p,r)||flow_validate(r,32,nonce)!=1){result.state=FlowUSBBatteryReadFailed;return result;}
  memcpy(status,r,32);
  if((r[5]&1)&&r[6]<=100){result.state=FlowUSBBatteryValid;return result;}
 }
 return result;
}
#endif
