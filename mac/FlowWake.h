#ifndef FLOW_WAKE_H
#define FLOW_WAKE_H
#include <stdbool.h>
#include "FlowControl.h"
/* One scope per explicit operation; no background scheduler or persistent setting. */
typedef struct { bool active; double renewed_at; } FlowWakeScope;
typedef bool (*FlowWakeExchange)(void *,const uint8_t[32],uint8_t[32]);
static inline bool flow_wake_send(bool active,const uint8_t nonce[4],FlowWakeExchange exchange,void *context){
 uint8_t p[32],r[32]={0};flow_control_request(p,6,active?1:0,0,0,nonce);
 return exchange(context,p,r)&&flow_control_match(p,r)&&r[5]==0;
}
static inline bool flow_wake_begin(FlowWakeScope *s,double now,const uint8_t nonce[4],FlowWakeExchange exchange,void *context){
 s->active=flow_wake_send(true,nonce,exchange,context);s->renewed_at=now;return s->active;
}
static inline bool flow_wake_due(const FlowWakeScope *s,double now){return s->active&&(now<s->renewed_at||now-s->renewed_at>=5);}
static inline bool flow_wake_refresh(FlowWakeScope *s,double now,const uint8_t nonce[4],FlowWakeExchange exchange,void *context){
 if(!flow_wake_due(s,now))return true;
 if(!flow_wake_send(true,nonce,exchange,context))return false;
 s->renewed_at=now;return true;
}
static inline bool flow_wake_end(FlowWakeScope *s,const uint8_t nonce[4],FlowWakeExchange exchange,void *context){
 if(!s->active)return true;
 s->active=false;return flow_wake_send(false,nonce,exchange,context);
}
/* One raw release; do not renew a lease while trying to end it. */
static inline bool flow_wake_release_editing(FlowWakeScope *s,const uint8_t nonce[4],FlowWakeExchange exchange,void *context){
 s->active=false;
 uint8_t p[32],r[32]={0};flow_control_request(p,8,0,0,0,nonce);
 return exchange(context,p,r)&&flow_control_match(p,r)&&r[5]==0;
}
#endif
