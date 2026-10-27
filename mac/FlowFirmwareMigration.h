#ifndef FLOW_FIRMWARE_MIGRATION_H
#define FLOW_FIRMWARE_MIGRATION_H
#include "FlowFirmwareModel.h"
#include "FlowFlashCore.h"
/* Model identity is independent of bcdDevice/version and catalog membership. */
static inline unsigned flow_firmware_identify(const uint8_t *image,size_t size,unsigned *release){
 if(!image||size!=FLOW_FLASH_SIZE)return 0;
 uint32_t sp=(uint32_t)image[0]|(uint32_t)image[1]<<8|(uint32_t)image[2]<<16|(uint32_t)image[3]<<24;
 uint32_t pc=(uint32_t)image[4]|(uint32_t)image[5]<<8|(uint32_t)image[6]<<16|(uint32_t)image[7]<<24;
 if(sp<=0x20000000u||sp>0x20009000u||(sp&7)||!(pc&1)||pc<FLOW_FLASH_BASE||pc>=FLOW_FLASH_BASE+size)return 0;
 unsigned count=0,model=0,value=0;
 for(size_t n=0;n+18<=size;n++){const uint8_t *d=image+n;if(d[0]!=18||d[1]!=1||d[8]!=0x8d||d[9]!=0x38)continue;
  unsigned pid=(unsigned)d[10]|(unsigned)d[11]<<8;model=pid==1?68:pid==2?84:pid==3?100:0;value=(unsigned)d[12]|(unsigned)d[13]<<8;count++;
 }
 if(count!=1||!model)return 0;
 if(release)*release=value;
 return model;
}
/* Exact transaction-specific page union, not a blanket erase permission. */
static inline size_t flow_firmware_migration_pages(const uint8_t *before,const uint8_t *desired,const uint8_t *rollback,unsigned *pages){
 if(!before||!desired||!rollback||!pages)return 0;
 size_t count=0;
 for(unsigned o=0;o<FLOW_FLASH_SIZE;o+=FLOW_PAGE_SIZE)if(memcmp(before+o,desired+o,FLOW_PAGE_SIZE)||memcmp(rollback+o,desired+o,FLOW_PAGE_SIZE))pages[count++]=o;
 return count;
}
#endif
