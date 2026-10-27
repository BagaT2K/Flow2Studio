#include <assert.h>
#include <stdio.h>
#include "../mac/FlowEditingPolicy.h"
static bool tick(FlowEditingPresence *p,double now,bool foreground){return flow_editing_presence_tick(p,now,true,foreground,true,false,false,true);}
int main(void){
 for(unsigned bits=0;bits<16;bits++){
  bool active=bits&1,key=bits&2,visible=bits&4,mini=bits&8;
  assert(flow_window_foreground(active,key,visible,mini)==(active&&key&&visible&&!mini));
 }
 FlowEditingPresence p={0};
 assert(!tick(&p,10,false)); // Startup in background cannot invent a grace period.
 for(unsigned now=100;now<=10000;now++)assert(tick(&p,now,true)); // No foreground idle limit.
 assert(!flow_editing_dark(159,100,60));assert(flow_editing_dark(160,100,60));
 assert(tick(&p,10001,false));assert(p.deadline==10601); // Leave foreground once.
 for(unsigned now=10002;now<10601;now++){assert(tick(&p,now,false));assert(p.deadline==10601);}
 assert(!tick(&p,10601,false));assert(!tick(&p,10602,false));assert(!tick(&p,99999,false));
 assert(tick(&p,100000,true));assert(tick(&p,100001,false));assert(p.deadline==100601);
 assert(tick(&p,100500,true));assert(!p.grace); // Return before expiry cancels countdown.
 assert(tick(&p,100510,false));assert(p.deadline==101110); // Next departure gets its own ten minutes.
 assert(tick(&p,101109.999,false));assert(!tick(&p,101110,false));
 // Disabled preference, closed window, system sleep, flashing/quit, or non-RF release immediately.
 for(unsigned condition=0;condition<5;condition++)for(unsigned background=0;background<2;background++){
  p=(FlowEditingPresence){0};assert(tick(&p,100,true));if(background)assert(tick(&p,101,false));
  assert(!flow_editing_presence_tick(&p,102,condition!=0,false,condition!=1,condition==2,condition==3,condition!=4));
  assert(!p.foreground&&!p.grace);assert(!tick(&p,103,false));
 }
 // Periodic charge reads do not extend the background deadline, even after expiry.
 p=(FlowEditingPresence){0};assert(tick(&p,100,true));assert(tick(&p,101,false));double last=100;
 for(unsigned now=101;now<=1001;now++){
  bool charge=flow_battery_poll_due(now,last,false,true,false);
  assert(charge==(now==400||now==700||now==1000));if(charge)last=now;
  assert(tick(&p,now,false)==(now<701));
 }
 assert(flow_battery_poll_interval(false,true)==300);assert(flow_battery_poll_interval(false,false)==300);
 assert(flow_battery_poll_interval(true,true)==2);assert(flow_battery_poll_interval(true,false)==5);
 assert(flow_battery_poll_due(101,100,false,false,true)); // Power/inventory change is immediate.
 for(unsigned timeout=0;timeout<=3600;timeout++){
  assert(!flow_editing_dark(100+timeout-0.01,100,timeout));
  assert(flow_editing_dark(100+timeout,100,timeout)==(timeout>0));
  assert(!flow_editing_dark(99,100,timeout));
 }
 assert(!flow_editing_dark(999999,100,0));
 assert(!flow_editing_event_activity(true,false,false,false,0));
 assert(!flow_editing_event_activity(false,true,false,false,0));
 assert(flow_editing_event_activity(true,true,false,false,0));
 for(unsigned key=0;key<128;key++){
  assert(flow_editing_event_activity(true,false,true,false,key));
  bool system=key==12||key==13||key==4||key==46||key==48;
  assert(flow_editing_event_activity(true,false,true,true,key)==!system);
 }
 puts("Passed: unlimited foreground lease; one 600-second grace per departure, return/cancel/restart, expiry without restart, immediate safety release; independent light timer; 300-second background battery polling never renews the grace.");
}
