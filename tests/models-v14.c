#include "../mac/FlowModels.h"
#include "../mac/FlowPackets.h"
#include "../mac/FlowEditing.h"
#include "../mac/FlowFirmwareConsent.h"
#include "../mac/FlowFirmwareModel.h"
#include "../mac/FlowLayerIO.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
typedef struct {uint8_t memory[1296];unsigned size,writes;bool corrupt;} Memory;
static bool readLayer(void *v,unsigned o,uint8_t *b,size_t n){Memory *m=v;assert(o+n<=m->size);memcpy(b,m->memory+o,n);if(m->corrupt&&n)b[n-1]^=1;return true;}
static bool writeLayer(void *v,unsigned o,const uint8_t *b,size_t n){Memory *m=v;assert(n<=28&&o+n<=m->size);memcpy(m->memory+o,b,n);m->writes++;return true;}
int main(int argc,char **argv){assert(argc==4);unsigned models[]={68,84,100},cases=0;
 for(unsigned j=0;j<3;j++){FlowModel s=flow_model(models[j]);assert(s.positions==s.rows*s.cols&&s.layerBytes==s.positions*2&&s.keyBytes==s.layerBytes*6);uint8_t out[216],packet[32];Memory m={.size=s.keyBytes};FlowLayerIO io={&m,readLayer,writeLayer};
  for(unsigned layer=0;layer<6;layer++){assert(flow_model_default(s,true,layer,out));assert(flow_layer_write_verify_sized(&io,layer,out,s.layerBytes,s.layerBytes));assert(!memcmp(m.memory+layer*s.layerBytes,out,s.layerBytes));cases++;}
  m.corrupt=true;assert(!flow_layer_write_verify_sized(&io,5,out,s.layerBytes,s.layerBytes));m.corrupt=false;assert(!flow_layer_write_verify_sized(&io,6,out,s.layerBytes,s.layerBytes));
  for(unsigned row=0;row<=s.rows;row++)for(unsigned col=0;col<=s.cols;col++){bool valid=row<s.rows&&col<s.cols;assert(flow_key_request_sized(packet,1,0,row,col,4,s.rows,s.cols)==valid);cases++;}
  uint8_t *macro=calloc(1,s.macroBytes);assert(macro&&flow_macros_valid_sized(macro,s.macroBytes,s.macroBytes));macro[s.macroBytes-1]=1;assert(!flow_macros_valid_sized(macro,s.macroBytes,s.macroBytes));assert(!flow_macros_valid_sized(macro,s.macroBytes-1,s.macroBytes));free(macro);cases+=5;
  FILE *f=fopen(argv[j+1],"rb");assert(f);uint8_t *image=malloc(262144);assert(image&&fread(image,1,262144,f)==262144);fclose(f);for(unsigned k=0;k<3;k++){assert(flow_firmware_model_matches(image,262144,models[k],20)==(j==k));cases++;}assert(!flow_firmware_model_matches(image,262143,models[j],20));free(image);
 }
 assert(flow_firmware_consent_valid(10,120,5,5,true,true));assert(!flow_firmware_consent_valid(120,120,5,5,true,true));assert(!flow_firmware_consent_valid(10,120,4,5,true,true));assert(!flow_firmware_consent_valid(10,120,5,5,false,true));assert(!flow_firmware_consent_valid(10,120,5,5,true,false));assert(!flow_firmware_consent_valid(NAN,120,5,5,true,true));assert(!flow_firmware_consent_valid(0,121,5,5,true,true));cases+=7;
 /* A stored empty dictionary must not be treated as a backup on commit. */
 for(unsigned mode=0;mode<=4;mode++)for(unsigned model=68;model<=100;model+=16){
  if(mode!=2){assert(flow_firmware_backup_selection_valid(mode,false,0,model,false));assert(flow_firmware_backup_selection_valid(mode,false,84,model,true));cases+=2;}
  else{assert(flow_firmware_backup_selection_valid(mode,false,model,model,true));assert(!flow_firmware_backup_selection_valid(mode,false,model,model,false));assert(!flow_firmware_backup_selection_valid(mode,false,model==68?84:68,model,true));assert(flow_firmware_backup_selection_valid(mode,true,model,0,true));assert(!flow_firmware_backup_selection_valid(mode,true,0,0,false));cases+=5;}
 }
 printf("Passed: %u model/consent cases; all three layer dimensions, chunk offsets and boundaries, macro guard capacities, OEM descriptor SKU checks, expired/reused-selection/foreign-action consent rejected; empty backup on ordinary update/factory restore ignored, explicit missing/foreign-model file rejected. Hardware not tested.\n",cases);return 0;}
