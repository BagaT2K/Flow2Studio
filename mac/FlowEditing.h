#ifndef FLOW_EDITING_H
#define FLOW_EDITING_H
#include <stdint.h>
#include <stddef.h>
/* Exact old send_string encoding verified in this device at 0x08008A9C. */
static inline int flow_macros_valid_sized(const uint8_t *b,size_t n,size_t capacity){
 if(!b||n!=capacity||(capacity!=3156&&capacity!=2976&&capacity!=2760)||b[n-1])return 0;
 size_t i=0;unsigned slots=0;
 while(i<n&&slots<16){uint8_t c=b[i++];if(!c){slots++;continue;}if(c!=1)continue;
  if(i>=n)return 0;
  unsigned command=b[i++];
  if(command>=1&&command<=3){if(i>=n||!b[i++])return 0;}
  else if(command==4){unsigned digits=0,value=0;while(i<n&&b[i]>='0'&&b[i]<='9'){if(++digits>5)return 0;value=value*10+b[i++]-'0';}if(!digits||value>60000||i>=n||b[i++]!='|')return 0;}
  else return 0;
 }
 return slots==16;
}
static inline int flow_macros_valid(const uint8_t *b,size_t n){return flow_macros_valid_sized(b,n,3156);}
#endif
