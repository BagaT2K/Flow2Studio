#import <Foundation/Foundation.h>
// Called on Studio's serial HID worker; delegates and state run on main queue.
NSData *FlowBLEExchange(NSDictionary *device,NSData *request,NSError **error);
// Called on main queue when selection, connection or sleep state changes.
void FlowBLESerialReset(void);
