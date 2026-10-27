#include <assert.h>
#include <stdio.h>
#include "../mac/FlowControl.h"
int main(void){
 uint8_t p[32],r[32],nonce[]={1,7,3,9};unsigned models[]={68,84,100};
 flow_control_request(p,1,0,0,0,nonce);
 for(unsigned i=0;i<3;i++){
  memcpy(r,p,32);r[4]=0x81;r[5]=0;r[10]=255;r[11]=3;r[24]=100;r[25]=20;r[26]=1;r[28]=0x35;
  memcpy(r+16,"F2S1",4);r[20]=models[i];r[21]=0;r[22]=9;r[23]=20;
  assert(flow_control_match(p,r)&&flow_control_generation(r)==19&&flow_control_model_matches(r,models[i]));
  assert(!flow_control_model_matches(r,models[(i+1)%3]));
  r[28]=0x36;assert(!flow_control_match(p,r));r[28]=0x45;assert(!flow_control_match(p,r));r[28]=0x35;
  r[25]=101;assert(!flow_control_match(p,r));r[25]=20;r[26]=2;assert(!flow_control_match(p,r));r[26]=1;
  r[12]^=1;assert(!flow_control_match(p,r));r[12]^=1;
  r[22]=10;assert(!flow_control_match(p,r));r[22]=9;
  r[23]=0;assert(!flow_control_match(p,r));r[23]=20;
  r[21]=3;r[22]=19;assert(flow_control_match(p,r)&&flow_control_generation(r)==19);
 }
 puts("Passed: release 0.9 and legacy 3.19 for 68/84/100; model isolation, nonce, base and advanced bounds.");
}
