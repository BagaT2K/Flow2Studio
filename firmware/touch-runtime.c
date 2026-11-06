/* Flow2 OEM14 overlay, separately pinned for 68/84/100. Settings use the OEM EEPROM journal.
 * All OEM entry points below are pinned to the included exact base image. */
typedef unsigned char u8;
typedef unsigned int u32;
typedef unsigned short u16;
#ifndef TOUCH_MODEL_HEADER
#define TOUCH_MODEL_HEADER "touch-model-68.h"
#endif
#include TOUCH_MODEL_HEADER
typedef struct {u8 count,b1,b2;u16 actions[2][9];} Config;
enum { CONTACT_GAP=45, SCROLL_INTERVAL=20, SCROLL_UNITS_PER_STEP=3, SCROLL_QUEUE_LIMIT=4*SCROLL_UNITS_PER_STEP,
       PROFILE_FIRST=336, PROFILE_NEXT=339, PROFILE_KEY_FIRST=0x7e30,
       TOUCH_LIVE_START=7, TOUCH_LIVE_STOP=8,
       TOUCH_TEST_START=9, TOUCH_LIVE_INTERVAL=32, TOUCH_TEST_TIMEOUT=60000 };
typedef struct {
 u32 magic,start,last,stepAt,token,stageAt,nvSequence;
 Config config,pending,profiles[3];
 u8 staged,active,zone,fn,anchor,min,max,previous,swiping,fired,ready,blocked,nvBank,history[4],historyIndex;
 u32 historyTime[4],scrollAt;int scrollQueued;u16 pendingMacro;u8 nvSchema;
 u32 liveToken,liveDriver,liveAt,testAt,testLast;
 u8 testing,testContact,savedProfiles,switchContact;
 u32 switchLast;
} Touch;
#define T (*(volatile Touch *)TOUCH_RAM)
_Static_assert(sizeof(Touch)<=TOUCH_RAM_END-TOUCH_RAM,"Touch RAM reservation too small");
#define BYTE(a) (*(volatile u8 *)(a))
#define FN(a,ret,args) ((ret (*)args)((a)|1))
static u32 clock_now(void){return FN(A_TIMER,u32,(void))();}
static u32 read32(const u8 *p){return (u32)p[0]|(u32)p[1]<<8|(u32)p[2]<<16|(u32)p[3]<<24;}
static void write32(u8 *p,u32 v){for(u32 i=0;i<4;i++)p[i]=(u8)(v>>(8*i));}
static u32 active_driver(void){return *(volatile u32 *)DRIVER_ADDRESS;}
static void update_test(u32 now){
 if(T.liveToken&&(active_driver()!=T.liveDriver||(T.testing&&now-T.testAt>=TOUCH_TEST_TIMEOUT))){
  T.liveToken=0;
  T.testing=0;
 }
 if(T.testContact&&now-T.testLast>CONTACT_GAP)T.testContact=0;
}
static void publish_position(u32 now,u8 position){
 if(!T.liveToken)return;
 if(now-T.liveAt<TOUCH_LIVE_INTERVAL)return;
 T.liveAt=now;
 u8 report[32];
 for(u32 i=0;i<32;i++)report[i]=0;
 report[0]=0x18;report[1]='L';report[2]='F';report[3]='T';report[4]=0x82;
 report[7]=position;report[21]=MODEL;
 write32(report+22,T.liveToken);report[27]=3;write32(report+28,0x00324354);
 FN(A_SEND,void,(u8 *,u32))(report,32);
}
static u32 bit_read(const u8 *p,u32 index){u32 bit=index*9,byte=bit/8;return ((u32)p[byte]|(u32)p[byte+1]<<8)>>(bit%8)&511;}
static void bit_write(u8 *p,u32 index,u32 value){for(u32 i=0;i<9;i++){u32 bit=index*9+i,mask=1u<<(bit%8);p[bit/8]=(p[bit/8]&~mask)|((value>>i&1)?mask:0);}}
static int action_valid(u32 id){return id<=10&&id!=8||id>=68&&id<=179||id>=288&&id<=295||id>=320&&id<=PROFILE_NEXT;}
static void cancel(void){T.active=0;T.swiping=0;T.fired=0;T.scrollQueued=0;T.pendingMacro=0;}
static void defaults(volatile Config *config,u32 count){
 config->count=count;config->b1=count==3?25:count==2?50:33;config->b2=count>1?75:67;
 for(u32 m=0;m<2;m++)for(u32 z=0;z<3;z++){
  config->actions[m][z*3]=m?9:1;config->actions[m][z*3+1]=0;config->actions[m][z*3+2]=m?10:2;
 }
}
static void copy_config(volatile Config *dst,const volatile Config *src){
 dst->count=src->count;dst->b1=src->b1;dst->b2=src->b2;
 for(u32 m=0;m<2;m++)for(u32 i=0;i<9;i++)dst->actions[m][i]=src->actions[m][i];
}
static int nv_load(void);
static int nv_save(const volatile Config *config,int activate);
static int nv_select(u32 count);
static void initialize(void){
 if(T.magic==0x31544348)return;
 T.magic=0x31544348;
 for(u32 i=0;i<3;i++)defaults(&T.profiles[i],i+1);
 copy_config(&T.config,&T.profiles[0]);
 T.staged=0;T.ready=1;T.blocked=0;T.nvSequence=0;T.nvBank=1;T.nvSchema=0;T.savedProfiles=0;
 nv_load();cancel();
}
static void apply_profile(const volatile Config *config){
 u32 mask;
 __asm__ volatile("mrs %0, primask\n cpsid i":"=r"(mask)::"memory");
 copy_config(&T.config,config);cancel();
 __asm__ volatile("msr primask, %0"::"r"(mask):"memory");
}
static int select_profile(u32 count){
 if(count<1||count>3||T.blocked)return 0;
 if(T.config.count==count)return 1;
 T.blocked=1;int saved=nv_select(count);
 if(saved){
  if(T.active){T.switchContact=1;T.switchLast=clock_now();}
  apply_profile(&T.profiles[count-1]);
 }
 T.blocked=0;
 return saved;
}
static void choose_profile(u32 action){
 select_profile(action==PROFILE_NEXT?(T.config.count==3?1:T.config.count+1):action-PROFILE_FIRST+1);
}
__attribute__((used)) u32 touch_key_event(u32 code,const u8 *record){
 if(code<PROFILE_KEY_FIRST||code>PROFILE_KEY_FIRST+PROFILE_NEXT-PROFILE_FIRST)return FN(0x08014f40,u32,(u32,const u8 *))(code,record);
 if(record&&record[5]){initialize();choose_profile(code-PROFILE_KEY_FIRST+PROFILE_FIRST);}
 return 0;
}
static int awake(void){return BYTE(0x200022c5)<=1 && !BYTE(0x20002464) && (BYTE(CONFIG_ADDRESS)&8);}
static u8 selected_fn(void){u8 mask=BYTE(LAYER_ADDRESS);u8 layer=0;while(mask>>1){mask>>=1;layer++;}return layer==1||layer==3;}
static u8 repeatable(u32 id){return id==1||id==2||id==7||id==9||id==10;}
static void emit(u32 id){
 static const u8 keys[]={0,0xa9,0xaa,0xa8,0xae,0xab,0xac,0,0,0xbd,0xbe};
 if(!id||!action_valid(id))return;
 if(id>=PROFILE_FIRST){choose_profile(id);return;}
 if(id>=320){if(T.active){if(!T.pendingMacro)T.pendingMacro=id;}else FN(A_MACRO,void,(u32))(id-320);return;}
 if(id>=64){FN(A_TAP,void,(u32))(id-64);return;}
 if(id<=6||id==9||id==10){FN(A_TAP,void,(u32))(keys[id]);return;}
 /* Six-byte OEM mouse report: ID, buttons, X, Y, wheel, horizontal pan.
  * Use the active host driver, not a guessed RF/BLE envelope. */
 if(id==7){
  u32 driver=*(volatile u32 *)DRIVER_ADDRESS;
  if(!((driver>=0x08000000&&driver<=0x0803ffe8)||(driver>=0x20000400&&driver<=0x20004998))||(driver&3))return;
  u32 callback=*(const u32 *)(driver+12);if(callback<0x08000001||callback>=0x08040000||!(callback&1))return;
  u8 report[6]={2,0,0,0,1,0};FN(A_MOUSE,void,(u8 *))(report);return;
 }
 /* Lighting service keycodes use the OEM full-key event path, not the
  * 8-bit Consumer tap helper. Deliberately unavailable in this first test. */
}
static void scroll_flush(u32 now){
 if((u32)(now-T.scrollAt)<SCROLL_INTERVAL||
    (T.scrollQueued<SCROLL_UNITS_PER_STEP&&T.scrollQueued>-SCROLL_UNITS_PER_STEP))return;
 int up=T.scrollQueued>0;u8 report[6]={2,0,0,0,0,0};report[4]=up?1:255;
 u32 driver=*(volatile u32 *)DRIVER_ADDRESS;
 if(!((driver>=0x08000000&&driver<=0x0803ffe8)||(driver>=0x20000400&&driver<=0x20004998))||(driver&3)){T.scrollQueued=0;return;}
 u32 callback=*(const u32 *)(driver+12);if(callback<0x08000001||callback>=0x08040000||!(callback&1)){T.scrollQueued=0;return;}
 FN(A_MOUSE,void,(u8 *))(report);T.scrollQueued+=up?-SCROLL_UNITS_PER_STEP:SCROLL_UNITS_PER_STEP;T.scrollAt=now;
}
static void finish_contact(void){
 u32 duration=T.last-T.start;
 u32 tap=T.config.actions[T.fn][T.zone*3+1],macro=T.pendingMacro;
 u8 result=T.swiping?2:duration<20?3:duration>650?4:1;
 cancel();
 if(result==1&&tap!=7)emit(tap);
 else if(macro)emit(macro);
}
__attribute__((used)) void touch_position(u32 position){
 initialize();
 /* Run unchanged OEM wake/activity logic; its dispatcher is intercepted below. */
 FN(0x08014f00,void,(u32))(position);
 u32 now=clock_now();
 if(T.blocked||!awake()||position<1||position>50){T.switchContact=0;cancel();return;}
 u8 p=(u8)position;
 update_test(now);
 publish_position(now,p);
 if(T.testing||T.testContact){
  T.testContact=1;
  T.testLast=now;
  return;
 }
 if(T.switchContact){
  if(now-T.switchLast<=CONTACT_GAP){T.switchLast=now;return;}
  T.switchContact=0;
 }
 if(T.active&&now-T.last>CONTACT_GAP)finish_contact();
 if(!T.active){
  T.active=1;T.start=now;T.last=now;T.stepAt=now;T.anchor=p;T.previous=p;T.min=p;T.max=p;T.fn=selected_fn();
  T.historyIndex=0;for(u32 i=0;i<4;i++){T.history[i]=p;T.historyTime[i]=now;}
  u32 percent=((u32)p-1)*100/49;
  T.zone=T.config.count<2?0:T.config.count==2?(percent<T.config.b1?0:1):(percent<T.config.b1?0:percent<T.config.b2?1:2);
  return;
 }
 T.last=now;if(p<T.min)T.min=p;if(p>T.max)T.max=p;
 /* Reject measured tap drift of up to seven coordinate units peak-to-peak.
  * Eight-unit range
  * permanently cancels tap recognition even after direction reversal. */
 int delta=(int)p-(int)T.anchor;
 u8 hi=T.historyIndex;int speedDelta=(int)p-(int)T.history[hi];u32 speedTime=now-T.historyTime[hi];
 T.history[hi]=p;T.historyTime[hi]=now;T.historyIndex=(hi+1)%3;
 u8 wasSwiping=T.swiping;
 if(!T.swiping&&(((int)T.max-(int)T.min>=8)||((int)T.max-(int)T.min>=5&&speedTime>=20&&speedTime<=50&&(speedDelta>=5||speedDelta<=-5)))){T.swiping=1;}
 if(T.swiping&&delta){
  u8 direction=delta<0?0:2;u32 id=T.config.actions[T.fn][T.zone*3+direction];
  if(id==7){
   if((delta<0&&T.scrollQueued<0)||(delta>0&&T.scrollQueued>0))T.scrollQueued=0;
   // On recognition, send one step and keep only the sub-step remainder.
   if(!wasSwiping)delta=(delta<0?-SCROLL_UNITS_PER_STEP:SCROLL_UNITS_PER_STEP)+delta%SCROLL_UNITS_PER_STEP;
   T.scrollQueued-=delta;
   if(T.scrollQueued>SCROLL_QUEUE_LIMIT)T.scrollQueued=SCROLL_QUEUE_LIMIT;
   if(T.scrollQueued< -SCROLL_QUEUE_LIMIT)T.scrollQueued=-SCROLL_QUEUE_LIMIT;
   T.anchor=p;
  }
  else if((delta>=3||delta<=-3)&&(u32)(now-T.stepAt)>=35){
  T.scrollQueued=0;
  if(repeatable(id)||!(T.fired&(1u<<direction))){emit(id);if(!T.active)return;T.fired|=(1u<<direction);}
  T.anchor=p;T.stepAt=now;
  }
 }
 T.previous=p;
}
__attribute__((used)) void touch_dispatch(u32 direction){(void)direction;if(!(BYTE(CONFIG_ADDRESS)&8))FN(A_DISABLE,void,(void))();/* New recognizer owns all actions. */}
__attribute__((used)) void touch_tick(void){
 FN(A_PARSER,void,(void))();initialize();
 u32 now=clock_now();
 update_test(now);
 if(!T.active)return;
 if(T.blocked||!awake()){cancel();return;}
 if(now-T.last>CONTACT_GAP)finish_contact();
 else scroll_flush(now);
}
#include "touch-storage.inc"
static int valid(u8 *p){
 if(p[6]>1||p[7]<1||p[7]>3||p[8]<15||p[8]>85||p[9]<30||p[9]>85||(p[7]==3&&p[9]<p[8]+15))return 0;
 for(u32 i=0;i<9;i++)if(!action_valid(bit_read(p+10,i)))return 0;return 1;
}
__attribute__((used)) u32 touch_packet(u8 *p,u32 length){
 if(length!=32||p[0]!=0x18||p[1]!='L'||p[2]!='F'||p[3]!='T'||p[4]!=2)return FN(0x08012700,u32,(u8 *,u32))(p,length);
 initialize();u8 status=0,op=p[5],mode=p[6],slot=p[7];u32 now=clock_now(),token=read32(p+26);
 if(p[21]!=MODEL){status=1;mode=0;goto respond;}
 if(mode>1){status=1;mode=0;}
 else if(op==TOUCH_LIVE_START||op==TOUCH_LIVE_STOP||op==TOUCH_TEST_START){
  if(mode||!token)status=1;
  else if(op==TOUCH_LIVE_STOP){
   if(T.liveToken==token){T.liveToken=0;T.testing=0;}
  }else if(op==TOUCH_LIVE_START&&T.testing)status=2;
  else{
   if(op==TOUCH_TEST_START){
    if(T.active){T.testContact=1;T.testLast=T.last;}
    cancel();
    T.testing=1;T.testAt=now;
   }
   T.liveDriver=active_driver();T.liveAt=now-TOUCH_LIVE_INTERVAL;T.liveToken=token;
  }
 }
 else if(op==1){
  if(!valid(p))status=1;
  else {
   if(T.token!=token||(u32)(now-T.stageAt)>2000){T.staged=0;T.token=token;T.stageAt=now;}
   if(T.staged&&(T.pending.count!=p[7]||T.pending.b1!=p[8]||T.pending.b2!=p[9]))status=1;
   else {T.pending.count=p[7];T.pending.b1=p[8];T.pending.b2=p[9];for(u32 i=0;i<9;i++)T.pending.actions[mode][i]=bit_read(p+10,i);T.staged|=1u<<mode;}
  }
 }else if(op==2||op==5){
  if(T.staged!=3||T.token!=token||(u32)(now-T.stageAt)>2000)status=2;
  else {
   T.blocked=1;int activate=op==2||T.config.count==T.pending.count;
   if(!nv_save(&T.pending,activate))status=3;
   else {
    copy_config(&T.profiles[T.pending.count-1],&T.pending);
    if(activate)apply_profile(&T.pending);
    T.staged=0;
   }
   T.blocked=0;
  }
 }else if(op==3||op==4){
  if(slot<1||slot>3||(op==4&&mode))status=1;
  else if(op==4&&!select_profile(slot))status=3;
 }else if(op!=0)status=1;
respond:;
 const volatile Config *config=op==3&&!status?&T.profiles[slot-1]:&T.config;
 p[4]=0x81;p[5]=status;p[6]=mode;p[7]=config->count;p[8]=config->b1;p[9]=config->b2;
 for(u32 i=10;i<=20;i++)p[i]=0;for(u32 i=0;i<9;i++)bit_write(p+10,i,config->actions[mode][i]);p[21]=MODEL;
 p[26]=T.savedProfiles;p[27]=3;write32(p+28,0x00324354);
 FN(A_SEND,void,(u8 *,u32))(p,32);return 1;
}
