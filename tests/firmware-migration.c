#include "../mac/FlowFirmwareMigration.h"
#include "../mac/FlowDFUWire.h"
_Static_assert(FLOW_FLASH_MAX_PAGES==1024,"Full flash migration capacity");
#include <assert.h>
#include <stdio.h>
typedef struct {uint8_t memory[FLOW_FLASH_SIZE];const uint8_t *source,*target;unsigned pages[FLOW_FLASH_MAX_PAGES];size_t count;int saved,fail,failed,deny;unsigned failOffset,writes;} Device;
static void put(uint8_t *p,uint32_t n){for(unsigned i=0;i<4;i++)p[i]=n>>(i*8);}
static int readPage(void *v,uint32_t a,uint8_t *b,size_t n){Device *d=v;assert(a>=FLOW_FLASH_BASE&&a-FLOW_FLASH_BASE+n<=FLOW_FLASH_SIZE);memcpy(b,d->memory+a-FLOW_FLASH_BASE,n);return 1;}
static int writePage(void *v,uint32_t a,const uint8_t *b){Device *d=v;unsigned o=a-FLOW_FLASH_BASE;assert(d->saved&&flow_flash_page_allowed(o,d->pages,d->count));const uint8_t *images[]={d->source,d->target};uint8_t packet[268]={0x6a};put(packet+4,a);put(packet+8,256);memcpy(packet+12,b,256);assert(flow_dfu_allowed(packet,268,2,1,images,2,d->pages,d->count));d->writes++;memset(d->memory+o,255,256);if(d->fail&&!d->failed&&o==d->failOffset){d->failed=1;memcpy(d->memory+o,b,73);if(d->fail==2){memcpy(d->memory+o,b,256);d->memory[o+131]^=1;return 1;}return 0;}memcpy(d->memory+o,b,256);return 1;}
static int backup(void *v,const uint8_t *b,size_t n){Device *d=v;assert(n==FLOW_FLASH_SIZE&&!memcmp(b,d->memory,n));if(d->deny)return 0;d->saved=1;return 1;}
static int run(Device *d,const uint8_t *s,const uint8_t *t,int fail,unsigned o,int deny){memcpy(d->memory,s,FLOW_FLASH_SIZE);d->source=s;d->target=t;d->count=flow_firmware_migration_pages(s,t,s,d->pages);d->saved=d->failed=d->writes=0;d->fail=fail;d->failOffset=o;d->deny=deny;FlowFlashIO io={d,readPage,writePage,backup,NULL};return flow_flash_transaction_bounded(&io,s,t,s,d->pages,d->count,FLOW_FLASH_MAX_PAGES);}
static uint8_t *load(const char *path){FILE *f=fopen(path,"rb");assert(f);uint8_t *b=malloc(FLOW_FLASH_SIZE);assert(b&&fread(b,1,FLOW_FLASH_SIZE,f)==FLOW_FLASH_SIZE&&fgetc(f)==EOF);fclose(f);return b;}
int main(int argc,char **argv){assert(argc==4);unsigned cases=0,models[]={68,84,100};Device *d=calloc(1,sizeof *d);assert(d);
 for(unsigned m=0;m<3;m++){uint8_t *target=load(argv[m+1]),*source=malloc(FLOW_FLASH_SIZE);assert(source);unsigned release=0;assert(flow_firmware_identify(target,FLOW_FLASH_SIZE,&release)==models[m]&&release==20);
  size_t descriptor=0;for(size_t i=0;i+18<=FLOW_FLASH_SIZE;i++)if(target[i]==18&&target[i+1]==1&&target[i+8]==0x8d&&target[i+9]==0x38)descriptor=i;assert(descriptor);
  /* Same model with versions absent from every catalog and changes in every page. */
  for(unsigned version=0;version<4;version++){unsigned releases[]={0,8,22,0xffff};memcpy(source,target,FLOW_FLASH_SIZE);for(unsigned o=0;o<FLOW_FLASH_SIZE;o+=256)source[o+200]^=0x5a;source[descriptor+12]=releases[version];source[descriptor+13]=releases[version]>>8;
   assert(flow_firmware_identify(source,FLOW_FLASH_SIZE,&release)==models[m]&&release==releases[version]);cases++;
   for(unsigned direction=0;direction<2;direction++){const uint8_t *s=direction?target:source,*t=direction?source:target;assert(run(d,s,t,0,0,0)==FLOW_FLASH_OK&&!memcmp(d->memory,t,FLOW_FLASH_SIZE));assert(d->count==1024);cases++;assert(run(d,s,t,0,0,1)==FLOW_FLASH_BACKUP&&!d->writes);cases++;
    /* Exhaust every changed-page failure for one unknown release, both directions. */
    if(version==1)for(unsigned o=0;o<FLOW_FLASH_SIZE;o+=256)for(int failure=1;failure<=2;failure++){assert(run(d,s,t,failure,o,0)==FLOW_FLASH_ROLLED_BACK&&!memcmp(d->memory,s,FLOW_FLASH_SIZE));cases++;}
   }
   unsigned pages[FLOW_FLASH_MAX_PAGES];size_t n=flow_firmware_migration_pages(source,target,source,pages);memcpy(d->memory,source,FLOW_FLASH_SIZE);memset(d->memory+0x23400,255,256);memcpy(d->memory+0x23400,target+0x23400,73);assert(flow_flash_interrupted_matches(d->memory,source,target,pages,n));d->memory[0x23401]=0x71;while(d->memory[0x23401]==source[0x23401]||d->memory[0x23401]==target[0x23401]||d->memory[0x23401]==255)d->memory[0x23401]++;assert(!flow_flash_interrupted_matches(d->memory,source,target,pages,n));cases+=2;
  }
  memcpy(source,target,FLOW_FLASH_SIZE);source[0]=1;assert(!flow_firmware_identify(source,FLOW_FLASH_SIZE,NULL));memcpy(source,target,FLOW_FLASH_SIZE);source[4]&=0xfe;assert(!flow_firmware_identify(source,FLOW_FLASH_SIZE,NULL));memcpy(source,target,FLOW_FLASH_SIZE);source[descriptor+10]=0x27;assert(!flow_firmware_identify(source,FLOW_FLASH_SIZE,NULL));memcpy(source,target,FLOW_FLASH_SIZE);memcpy(source+0x30000,source+descriptor,18);assert(!flow_firmware_identify(source,FLOW_FLASH_SIZE,NULL));assert(!flow_firmware_identify(target,FLOW_FLASH_SIZE-1,NULL));cases+=5;free(source);free(target);
 }
 printf("Passed: %u version-independent migration cases for 68/84/100; unknown releases, all 1024 pages, both-direction page failure rollback, backup refusal, partial images, invalid vectors/SKU/duplicate descriptors. Hardware not tested.\n",cases);free(d);return 0;}
