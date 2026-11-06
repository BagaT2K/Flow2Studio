/* The 84 has 72 protected bytes. All three profile records share a redo journal. */
static const u8 holes[HOLES_COUNT]={HOLES_VALUES};
static int nv_index(u32 offset){
 if(offset<40||offset>=40+POSITIONS*12)return -1;
 u32 relative=offset-40,layer=relative/(POSITIONS*2),position=(relative%(POSITIONS*2))/2;
 for(u32 i=0;i<HOLES_COUNT;i++)if(position==holes[i]){u32 index=(layer*HOLES_COUNT+i)*2+(relative&1);return index<NV_PROTECTED?(int)index:-1;}return -1;
}
static u32 nv_offset(u32 index){u32 cell=index/2;return 40+(cell/HOLES_COUNT)*POSITIONS*2+holes[cell%HOLES_COUNT]*2+(index&1);}
static int raw_read(void *buffer,u32 offset,u32 length){return FN(A_RAW_READ,int,(u32,void *,u32))(offset,buffer,length);}
static int raw_write(const void *buffer,u32 offset,u32 length){return FN(A_RAW_WRITE,int,(u32,const void *,u32))(offset,buffer,length);}
__attribute__((used)) int touch_eeprom_read(void *buffer,u32 offset,u32 length){
 if(offset>4096||length>4096-offset)return 0;
 int ok=raw_read(buffer,offset,length);if(ok)for(u32 i=0;i<length;i++)if(nv_index(offset+i)>=0)((u8 *)buffer)[i]=0;return ok;
}
__attribute__((used)) int touch_eeprom_write(const void *buffer,u32 offset,u32 length){
 if(offset>4096||length>4096-offset)return 0;
 u32 i=0;while(i<length){if(nv_index(offset+i)>=0){i++;continue;}u32 start=i;while(i<length&&nv_index(offset+i)<0)i++;
  if(!raw_write((const u8 *)buffer+start,offset+start,i-start))return 0;
 }return 1;
}
static u32 checksum(const u8 *bytes,u32 size){u32 crc=~0u;for(u32 i=0;i<size;i++){crc^=bytes[i];for(u32 bit=0;bit<8;bit++)crc=(crc>>1)^((0u-(crc&1))&0xedb88320u);}return ~crc;}
static int packed_valid(const u8 *p){
 if(p[0]<1||p[0]>3||p[1]<15||p[1]>85||p[2]<30||p[2]>85||(p[0]==3&&p[2]<p[1]+15))return 0;
 for(u32 i=0;i<18;i++)if(!action_valid(bit_read(p+3,i)))return 0;return 1;
}
static void unpack(volatile Config *c,const u8 *p){c->count=p[0];c->b1=p[1];c->b2=p[2];for(u32 m=0;m<2;m++)for(u32 i=0;i<9;i++)c->actions[m][i]=bit_read(p+3,m*9+i);}
static int record_read(u32 bank,u8 *out){
 for(u32 i=0;i<36;i+=2)if(!raw_read(out+i,nv_offset(bank*NV_STRIDE+i),2))return 0;
 return out[0]=='F'&&out[1]=='T'&&out[2]==3&&out[3]==MODEL&&out[34]=='O'&&out[35]=='K'&&read32(out+30)==checksum(out,30)&&packed_valid(out+6);
}
static int legacy_load(void){
 u8 a[40],b[40];int va=record_read(0,a),vb=record_read(1,b);
 if(va||vb){u32 bank=vb&&(!va||(short)((b[4]|b[5]<<8)-(a[4]|a[5]<<8))>0);u8 *record=bank?b:a;unpack(&T.config,record+6);T.nvSequence=record[4]|record[5]<<8;T.nvBank=bank;T.nvSchema=3;return 1;}
#if MODEL == 68
 /* Migrate 0.11 without overwriting its current bank during the first save. */
 int valid[2]={0,0};u8 *records[2]={a,b};
 for(u32 bank=0;bank<2;bank++){
  u8 *r=records[bank];int readOK=1;for(u32 i=0;i<40;i+=2)if(!raw_read(r+i,nv_offset(bank*40+i),2))readOK=0;
  valid[bank]=readOK&&read32(r)==0x32543246&&read32(r+36)==0x32544b4f&&read32(r+32)==checksum(r,32)&&r[8]>=1&&r[8]<=3&&r[9]>=15&&r[9]<=85&&r[10]>=30&&r[10]<=85&&(r[8]!=3||r[10]>=r[9]+15);
  for(u32 i=11;i<29;i++)if(r[i]>14||r[i]==11||r[i]==12)valid[bank]=0;
 }
 if(valid[0]||valid[1]){u32 bank=valid[1]&&(!valid[0]||(int)(read32(b+4)-read32(a+4))>0);u8 *r=records[bank];T.config.count=r[8];T.config.b1=r[9];T.config.b2=r[10];for(u32 m=0;m<2;m++)for(u32 i=0;i<9;i++){u8 id=r[11+m*9+i];T.config.actions[m][i]=(id==8||id==13||id==14)?7:id;}T.nvSequence=read32(r+4);T.nvBank=bank;T.nvSchema=2;return 1;}
#endif
 return 0;
}
enum { PROFILE_STATE=0, PROFILE_JOURNAL=48, PROFILE_COMMIT=70, PROFILE_MAGIC=0xa400 };
_Static_assert(NV_PROTECTED>=72,"Touch profile journal exceeds protected memory");
static const u8 profile_offset[]={2,10,26};
static const u8 profile_size[]={8,16,22};
static int nv_read_bytes(u8 *out,u32 offset,u32 length){
 for(u32 i=0;i<length;i+=2)if(!raw_read(out+i,nv_offset(offset+i),2))return 0;
 return 1;
}
static int nv_write_bytes(const u8 *bytes,u32 offset,u32 length){
 for(u32 i=0;i<length;i+=2){
  u8 previous[2];u32 address=nv_offset(offset+i);
  if(raw_read(previous,address,2)&&previous[0]==bytes[i]&&previous[1]==bytes[i+1])continue;
  if(!raw_write(bytes+i,address,2)||!raw_read(previous,address,2)||previous[0]!=bytes[i]||previous[1]!=bytes[i+1])return 0;
 }
 return 1;
}
static int nv_word(u32 offset,u32 value){
 u8 bytes[2]={(u8)value,(u8)(value>>8)};
 return nv_write_bytes(bytes,offset,2);
}
static u32 nv_state(void){
 u8 state[2];
 if(!nv_read_bytes(state,PROFILE_STATE,2)||state[1]!=(PROFILE_MAGIC>>8)||(state[0]&0xe0)||(state[0]&3)>2)return 0;
 return PROFILE_MAGIC|state[0];
}
static u8 compact_action(u32 id){
 if(id<=10)return id;
 if(id<=179)return id-57;
 if(id<=295)return id-165;
 return id-189;
}
static u32 expand_action(u8 value){
 if(value<=10)return value;
 if(value<=122)return value+57;
 if(value<=130)return value+165;
 if(value<=150)return value+189;
 return 0xffff;
}
static void profile_pack(const volatile Config *config,u8 bytes[22]){
 u32 count=config->count,n=0;
 for(u32 i=0;i<22;i++)bytes[i]=0;
 for(u32 mode=0;mode<2;mode++)for(u32 i=0;i<count*3;i++)bytes[n++]=compact_action(config->actions[mode][i]);
 if(count>1)bytes[n++]=config->b1;
 if(count>2)bytes[n++]=config->b2;
 u32 size=profile_size[count-1],crc=checksum(bytes,size-2);
 bytes[size-2]=crc;bytes[size-1]=crc>>8;
}
static int profile_unpack(volatile Config *config,u32 slot,const u8 *bytes){
 u32 count=slot+1,size=profile_size[slot],n=0;
 if((checksum(bytes,size-2)&65535)!=(u32)(bytes[size-2]|bytes[size-1]<<8))return 0;
 for(u32 i=0;i<count*6;i++)if(!action_valid(expand_action(bytes[i])))return 0;
 u32 b1=count>1?bytes[count*6]:33,b2=count>2?bytes[count*6+1]:count==2?75:67;
 if(b1<15||b1>85||b2<30||b2>85||(count==3&&b2<b1+15))return 0;
 defaults(config,count);config->b1=b1;config->b2=b2;
 for(u32 mode=0;mode<2;mode++)for(u32 i=0;i<count*3;i++)config->actions[mode][i]=expand_action(bytes[n++]);
 return 1;
}
static u32 journal_tag(const u8 *bytes,u32 slot,int activate){
 u32 meta=(activate?4:0)|slot;
 return 0x8000|(((checksum(bytes,22)^(meta*0x2c1u))&0xfff)<<3)|meta;
}
static int replay(u32 *state){
 u8 marker[2],bytes[22];
 if(!nv_read_bytes(marker,PROFILE_COMMIT,2))return 0;
 u32 tag=marker[0]|marker[1]<<8;
 if(!(tag&0x8000))return 1;
 u32 slot=tag&3;int activate=(tag&4)!=0;
 Config check;
 if(slot>2)return 1;
 if(!nv_read_bytes(bytes,PROFILE_JOURNAL,22))return 0;
 if(journal_tag(bytes,slot,activate)!=tag||!profile_unpack(&check,slot,bytes))return 1;
 if(!nv_write_bytes(bytes,profile_offset[slot],profile_size[slot]))return 0;
 u32 next=(*state?*state:PROFILE_MAGIC)|(4u<<slot);
 if(activate)next=(next&~3u)|slot;
 if(!nv_word(PROFILE_STATE,next))return 0;
 *state=next;
 return nv_word(PROFILE_COMMIT,0);
}
static int nv_load(void){
 u32 state=nv_state();
 if(!replay(&state))return 0;
 if(state){
  for(u32 slot=0;slot<3;slot++){
   if(!(state&(4u<<slot)))continue;
   u8 bytes[22];
   if(nv_read_bytes(bytes,profile_offset[slot],profile_size[slot])&&profile_unpack(&T.profiles[slot],slot,bytes))T.savedProfiles|=1u<<slot;
  }
  copy_config(&T.config,&T.profiles[state&3]);T.nvSchema=4;
  return 1;
 }
 if(legacy_load()){
  copy_config(&T.profiles[T.config.count-1],&T.config);
  T.savedProfiles=1u<<(T.config.count-1);
  return 1;
 }
 return 0;
}
static int store_profile(const volatile Config *config,int activate,u32 *state){
 u32 slot=config->count-1;
 u8 bytes[22];profile_pack(config,bytes);
 if(!nv_word(PROFILE_COMMIT,0)||!nv_write_bytes(bytes,PROFILE_JOURNAL,22)||
    !nv_word(PROFILE_COMMIT,journal_tag(bytes,slot,activate)))return 0;
 return replay(state);
}
static int migrate(u32 *state){
 if(!replay(state))return 0;
 if(*state||!T.nvSchema)return 1;
 /* Keep one recoverable old record outside the new journal until it commits. */
 if(T.nvBank){
  u8 old[40];u32 size=T.nvSchema==2?40:36;
  if(!nv_read_bytes(old,T.nvSchema==2?40:NV_STRIDE,size)||
     !nv_word(size-2,0)||!nv_write_bytes(old,0,size-2)||!nv_write_bytes(old+size-2,size-2,2))return 0;
  T.nvBank=0;
 }
 return store_profile(&T.config,1,state);
}
static int nv_save(const volatile Config *config,int activate){
 u32 state=nv_state();
 if(!migrate(&state))return 0;
 u32 slot=config->count-1;
 u8 old[22],next[22];
 profile_pack(config,next);
 if((state&(4u<<slot))&&nv_read_bytes(old,profile_offset[slot],profile_size[slot])){
  u32 i=0;while(i<profile_size[slot]&&old[i]==next[i])i++;
  if(i==profile_size[slot]&&(!activate||(state&3)==slot))return 1;
 }
 if(!store_profile(config,activate,&state))return 0;
 T.savedProfiles=(state>>2)&7;T.nvSchema=4;
 return 1;
}
static int nv_select(u32 count){
 u32 state=nv_state();
 if(!migrate(&state))return 0;
 if(!state)state=PROFILE_MAGIC;
 if(!nv_word(PROFILE_STATE,(state&~3u)|(count-1)))return 0;
 T.savedProfiles=(state>>2)&7;T.nvSchema=4;
 return 1;
}
