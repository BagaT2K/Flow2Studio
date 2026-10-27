#ifndef FLOW_EDITING_POLICY_H
#define FLOW_EDITING_POLICY_H
#include <stdbool.h>
/* Presence has its own clock. User inactivity only controls light, never the
   foreground lease or the deadline after leaving the window. */
typedef struct {bool foreground;bool grace;double deadline;} FlowEditingPresence;
static inline bool flow_window_foreground(bool active,bool key,bool visible,bool mini){return active&&key&&visible&&!mini;}
static inline bool flow_editing_presence_tick(FlowEditingPresence *p,double now,bool enabled,bool foreground,bool open,bool sleeping,bool busy,bool rf){
 if(!enabled||!open||sleeping||busy||!rf){*p=(FlowEditingPresence){0};return false;}
 if(foreground){p->foreground=true;p->grace=false;p->deadline=0;return true;}
 if(p->foreground){p->foreground=false;p->grace=true;p->deadline=now+600.0;}
 if(p->grace&&now<p->deadline)return true;
 p->grace=false;return false;
}
static inline unsigned flow_battery_poll_interval(bool foreground,bool automatic){return foreground?(automatic?2:5):300;}
static inline bool flow_battery_poll_due(double now,double last,bool foreground,bool automatic,bool changed){return changed||(now>=last&&now-last>=flow_battery_poll_interval(foreground,automatic));}
static inline bool flow_editing_dark(double now,double activity,unsigned timeout){return timeout>0&&now>=activity&&now-activity>=timeout;}
/* Use only an aggregate keyboard-event count and age, never event contents.
   Ignore the departure event itself so Cmd-Tab/H/M does not flash the light. */
static inline double flow_editing_keyboard_activity(double now,double activity,bool changed,bool departed,double keyboardIdle){
 if(!changed||departed||!(keyboardIdle>=0&&keyboardIdle<=now))return activity;
 double latest=now-keyboardIdle;
 return latest>activity?latest:activity;
}
/* macOS virtual key codes: Q=12, W=13, H=4, M=46, Tab=48.
   Window/app actions should not wake light just before losing focus. */
static inline bool flow_editing_event_activity(bool mainWindow,bool content,bool keyDown,bool command,unsigned keyCode){
 bool windowAction=keyDown&&command&&(keyCode==12||keyCode==13||keyCode==4||keyCode==46||keyCode==48);
 return mainWindow&&(keyDown||content)&&!windowAction;
}
#endif
