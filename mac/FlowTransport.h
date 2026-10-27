#import <Foundation/Foundation.h>
NSArray<NSDictionary *> *FlowDevices(void);
NSDictionary *FlowPerform(NSDictionary *device, NSString *action, NSDictionary *arguments, NSError **error);
// Call only from the same serial worker as FlowPerform.
NSDictionary *FlowEditingTick(NSDictionary *device, double idleSeconds, NSError **error);
void FlowEditingEnd(void);
