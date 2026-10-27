#import <Foundation/Foundation.h>
NSComparisonResult FlowCompareVersions(NSString *left, NSString *right);
void FlowCheckUpdates(BOOL force, void (^completion)(NSDictionary *, NSString *));
BOOL FlowOpenUpdate(void);
