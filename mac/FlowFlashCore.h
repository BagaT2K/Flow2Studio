#ifndef FLOW_FLASH_CORE_H
#define FLOW_FLASH_CORE_H
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <stdlib.h>
#define FLOW_FLASH_SIZE 262144u
#define FLOW_PAGE_SIZE 256u
#define FLOW_FLASH_MAX_PAGES (FLOW_FLASH_SIZE/FLOW_PAGE_SIZE)
#define FLOW_FLASH_BASE 0x08000000u
/* No OS calls. All mutations go through a bounded page callback. */
typedef struct {
 void *context;
 int (*read)(void *,uint32_t,uint8_t *,size_t);
 int (*page)(void *,uint32_t,const uint8_t *);
 int (*backup)(void *,const uint8_t *,size_t);
 void (*progress)(void *,const char *,unsigned,unsigned);
} FlowFlashIO;
enum {FLOW_FLASH_OK=1,FLOW_FLASH_ALREADY=2,FLOW_FLASH_IO=-1,FLOW_FLASH_ROLLED_BACK=-2,FLOW_FLASH_UNSAFE=-3,FLOW_FLASH_INVALID=-4,FLOW_FLASH_BACKUP=-5};
static inline int flow_flash_page_allowed(unsigned offset,const unsigned *pages,size_t count){
 for(size_t i=0;i<count;i++)if(pages[i]==offset)return 1;
 return 0;
}
static inline int flow_flash_outside_matches(const uint8_t *image,const uint8_t *reference,const unsigned *pages,size_t count){
 for(unsigned offset=0;offset<FLOW_FLASH_SIZE;offset+=FLOW_PAGE_SIZE)
  if(!flow_flash_page_allowed(offset,pages,count)&&memcmp(image+offset,reference+offset,FLOW_PAGE_SIZE))return 0;
 return 1;
}
static inline int flow_flash_interrupted_matches(const uint8_t *current,const uint8_t *source,const uint8_t *target,const unsigned *pages,size_t count){
 if(!current||!source||!target||!pages||!count||count>FLOW_FLASH_MAX_PAGES)return 0;
 for(size_t p=0;p<count;p++)if(pages[p]%FLOW_PAGE_SIZE||pages[p]>FLOW_FLASH_SIZE-FLOW_PAGE_SIZE||(p&&pages[p]<=pages[p-1]))return 0;
 if(!flow_flash_outside_matches(current,source,pages,count)||!flow_flash_outside_matches(source,target,pages,count))return 0;
 for(size_t p=0;p<count;p++)for(unsigned i=0;i<FLOW_PAGE_SIZE;i++){unsigned o=pages[p]+i;uint8_t b=current[o];if(b!=source[o]&&b!=target[o]&&b!=255)return 0;}
 return 1;
}
static inline int flow_flash_read_all(FlowFlashIO *io,uint8_t *image,const char *phase){
 for(unsigned offset=0;offset<FLOW_FLASH_SIZE;offset+=FLOW_PAGE_SIZE){
  if(!io->read(io->context,FLOW_FLASH_BASE+offset,image+offset,FLOW_PAGE_SIZE))return 0;
  if(io->progress&&((offset+FLOW_PAGE_SIZE)%16384==0))io->progress(io->context,phase,offset+FLOW_PAGE_SIZE,FLOW_FLASH_SIZE);
 }
 return 1;
}
static inline int flow_flash_apply(FlowFlashIO *io,const uint8_t *target,const unsigned *pages,size_t count,const char *phase){
 uint8_t current[FLOW_PAGE_SIZE],zero[FLOW_PAGE_SIZE]={0};unsigned completed=0;
 /* Restore hooks before clearing removed stubs; install nonempty bodies before hooks. */
 for(unsigned stageIndex=0;stageIndex<3;stageIndex++)for(size_t n=count;n>0;n--){unsigned offset=pages[n-1];
  unsigned stage=offset>=0xf000u?(!memcmp(target+offset,zero,FLOW_PAGE_SIZE)?2u:0u):1u;
  if(stage!=stageIndex)continue;
  if(!io->read(io->context,FLOW_FLASH_BASE+offset,current,FLOW_PAGE_SIZE))return 0;
  if(memcmp(current,target+offset,FLOW_PAGE_SIZE)){
   if(!io->page(io->context,FLOW_FLASH_BASE+offset,target+offset))return 0;
   if(!io->read(io->context,FLOW_FLASH_BASE+offset,current,FLOW_PAGE_SIZE)||memcmp(current,target+offset,FLOW_PAGE_SIZE))return 0;
  }
  completed++;if(io->progress)io->progress(io->context,phase,completed,(unsigned)count);
 }

 return 1;
}
/* Host authenticates the packaged target and verified local source/backup before use. */
static inline int flow_flash_transaction_bounded(FlowFlashIO *io,const uint8_t *before,const uint8_t *desired,const uint8_t *rollback,const unsigned *pages,size_t count,size_t maximum){
 if(!io||!io->read||!io->page||!io->backup||!before||!desired||!rollback||!count||maximum>FLOW_FLASH_MAX_PAGES||count>maximum)return FLOW_FLASH_INVALID;
 for(size_t i=0;i<count;i++)if(pages[i]%FLOW_PAGE_SIZE||pages[i]+FLOW_PAGE_SIZE>FLOW_FLASH_SIZE||(i&&pages[i]<=pages[i-1]))return FLOW_FLASH_INVALID;
 if(!flow_flash_outside_matches(before,desired,pages,count)||!flow_flash_outside_matches(rollback,desired,pages,count))return FLOW_FLASH_INVALID;
 if(!io->backup(io->context,before,FLOW_FLASH_SIZE))return FLOW_FLASH_BACKUP;
 if(!memcmp(before,desired,FLOW_FLASH_SIZE))return FLOW_FLASH_ALREADY;
 uint8_t *verified=malloc(FLOW_FLASH_SIZE);if(!verified)return FLOW_FLASH_IO;
 int ok=flow_flash_apply(io,desired,pages,count,"writing")&&flow_flash_read_all(io,verified,"verifying")&&!memcmp(verified,desired,FLOW_FLASH_SIZE);
 if(ok){free(verified);return FLOW_FLASH_OK;}
 int restored=flow_flash_apply(io,rollback,pages,count,"rollback")&&flow_flash_read_all(io,verified,"rollback-verifying")&&!memcmp(verified,rollback,FLOW_FLASH_SIZE);
 free(verified);return restored?FLOW_FLASH_ROLLED_BACK:FLOW_FLASH_UNSAFE;
}
static inline int flow_flash_transaction(FlowFlashIO *io,const uint8_t *before,const uint8_t *desired,const uint8_t *rollback,const unsigned *pages,size_t count){
 return flow_flash_transaction_bounded(io,before,desired,rollback,pages,count,64);
}
#endif
