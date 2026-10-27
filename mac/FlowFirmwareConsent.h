#ifndef FLOW_FIRMWARE_CONSENT_H
#define FLOW_FIRMWARE_CONSENT_H
#include <stdbool.h>
#include <stdint.h>
#include <math.h>
static inline bool flow_firmware_consent_valid(double now,double deadline,uint64_t generation,uint64_t expectedGeneration,bool tokenMatches,bool deviceAndActionMatch){
 return tokenMatches&&deviceAndActionMatch&&generation==expectedGeneration&&isfinite(now)&&isfinite(deadline)&&now>=0&&deadline>now&&deadline-now<=120;
}
/* Only explicit file restore carries a chosen backup. Other operations must
   ignore the empty dictionary used in stored confirmation proposals. */
static inline bool flow_firmware_backup_selection_valid(unsigned mode,bool bootloader,unsigned backupModel,unsigned selectedModel,bool hasImage){
 if(mode!=2)return true;
 if(!hasImage||(backupModel!=68&&backupModel!=84&&backupModel!=100))return false;
 return bootloader||backupModel==selectedModel;
}
#endif
