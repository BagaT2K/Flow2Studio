#include "../mac/FlowUSBBattery.h"
#include "../mac/FlowHIDResponse.h"
#include <assert.h>
#include <stdio.h>
typedef struct {unsigned nonce,calls,waits,validAt,queue,failAt,badNonceAt;uint8_t percent;} Fixture;
static void nonce(void *c,uint8_t n[4]){Fixture *f=c;unsigned value=++f->nonce;memcpy(n,&value,4);}
static void wait(void *c,unsigned ms){Fixture *f=c;assert(ms==80);f->waits++;}
static bool exchange(void *c,const uint8_t p[32],uint8_t r[32]){
 Fixture *f=c;f->calls++;assert(p[0]==0x15&&p[4]==(f->calls==1?2:1));
 if(f->calls==f->failAt)return false;
 memcpy(r,p,32);r[4]|=0x80;r[5]=2;r[6]=255;r[27]=f->queue;
 if(f->calls>1&&f->calls-1>=f->validAt){r[5]=3;r[6]=f->percent;}
 if(f->calls==f->badNonceAt)r[8]^=1;
 return true;
}
int main(void){unsigned cases=0;for(unsigned pct=0;pct<=100;pct++)for(unsigned ready=1;ready<=6;ready++){
 Fixture f={.validAt=ready,.queue=1,.percent=(uint8_t)pct};FlowUSBBatteryIO io={&f,exchange,nonce,wait};uint8_t r[32]={0};r[6]=255;
 FlowUSBBatteryResult got=flow_usb_battery_refresh(&io,r);assert(got.requested);assert(got.reads==(ready<=5?ready:5));assert(f.calls==got.reads+1&&f.waits==got.reads&&f.nonce==f.calls);
 if(ready<=5){assert(got.state==FlowUSBBatteryValid&&r[6]==pct&&(r[5]&1));}else assert(got.state==FlowUSBBatteryPending&&r[6]==255&&!(r[5]&1));cases++;
 }
 for(unsigned queue=0;queue<=3;queue++)if(queue!=1){Fixture f={.queue=queue};FlowUSBBatteryIO io={&f,exchange,nonce,wait};uint8_t r[32]={0};r[6]=38;FlowUSBBatteryResult got=flow_usb_battery_refresh(&io,r);assert(!got.requested&&f.calls==1&&!f.waits&&r[6]==38);assert(got.state==(queue==2?FlowUSBBatteryNotWired:FlowUSBBatteryQueueFull));cases++;}
 for(unsigned failed=1;failed<=6;failed++)for(unsigned stale=0;stale<2;stale++){
 Fixture f={.validAt=6,.queue=1,.failAt=stale?0:failed,.badNonceAt=stale?failed:0};FlowUSBBatteryIO io={&f,exchange,nonce,wait};uint8_t r[32]={0};r[6]=38;FlowUSBBatteryResult got=flow_usb_battery_refresh(&io,r);assert(f.calls==failed);assert(got.state==(failed==1?FlowUSBBatteryRefreshFailed:FlowUSBBatteryReadFailed));assert(got.requested==(failed>1));assert(r[6]==(failed>2?255:38));cases++;
 }
 // Real Session response collector must distinguish LFB/1 from LFB/2, not
 // accept any response merely because its nonce matches.
 uint8_t p[32],r[32],n[4]={1,2,3,4};flow_request(p,n);p[4]=2;memcpy(r,p,32);r[4]=0x81;r[5]=2;r[6]=255;FlowHIDResponse response;flow_hid_response_begin(&response,p,false);flow_hid_response_accept(&response,true,true,0,r,32);assert(!response.done);r[4]=0x82;flow_hid_response_accept(&response,true,true,0,r,32);assert(response.done==1);flow_hid_response_end(&response);cases++;
 printf("USB battery: %u cases passed; one refresh, bounded nonce-correlated reads, failures retain honest status.\n",cases);return 0;
}
