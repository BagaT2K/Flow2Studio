#ifndef FLOW_DFU_WIRE_H
#define FLOW_DFU_WIRE_H
#include "FlowFlashCore.h"
static inline uint32_t flow_dfu_u32(const uint8_t *b){return (uint32_t)b[0]|((uint32_t)b[1]<<8)|((uint32_t)b[2]<<16)|((uint32_t)b[3]<<24);}
static inline int flow_dfu_allowed(const uint8_t *b,size_t n,unsigned expected,int chipVerified,const uint8_t *const *images,size_t imageCount,const unsigned *pages,size_t pageCount){
 if(!b||n<2)return 0;
 if(n==2&&b[0]==1&&b[1]==0)return expected==16;
 const uint8_t reset[]={0x83,0,0,0,0xe8,3,0,0};if(n==8&&!memcmp(b,reset,8))return expected==2;
 if(!chipVerified||n<10||b[1]||b[2]||b[3])return 0;
 uint32_t address=flow_dfu_u32(b+4);
 if(n==10&&b[0]==0x72){unsigned count=b[8]|(b[9]<<8);return count>0&&count<=256&&address>=FLOW_FLASH_BASE&&address<=FLOW_FLASH_BASE+FLOW_FLASH_SIZE-count&&expected==count+2;}
 if(expected!=2||(n!=12&&n!=268)||address<FLOW_FLASH_BASE||!flow_flash_page_allowed(address-FLOW_FLASH_BASE,pages,pageCount))return 0;
 uint32_t count=flow_dfu_u32(b+8);
 if(n==12&&b[0]==0x5e)return count==1;
 if(n==268&&b[0]==0x6a&&count==256){for(size_t i=0;i<imageCount;i++)if(images[i]&&!memcmp(b+12,images[i]+address-FLOW_FLASH_BASE,256))return 1;}
 return 0;
}
#endif
