#import <Foundation/Foundation.h>
NSArray<NSDictionary *> *FlowDevices(void);
NSDictionary *FlowPerform(NSDictionary *device, NSString *action, NSDictionary *arguments, NSError **error);
// Call only from the same serial worker as FlowPerform.
NSDictionary *FlowEditingTick(NSDictionary *device, double idleSeconds, NSError **error);
void FlowEditingEnd(void);
BOOL FlowTouchLiveStart(NSDictionary *device,void (^point)(unsigned),NSError **error);
void FlowTouchLiveEnd(void);
BOOL FlowTouchTestStop(NSError **error);
