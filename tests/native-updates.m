#import "../mac/FlowUpdates.h"
#include <assert.h>
int main(void){@autoreleasepool{
 assert(FlowCompareVersions(@"0.9.6",@"0.9.0")==NSOrderedDescending);
 assert(FlowCompareVersions(@"0.10.0",@"0.9.9")==NSOrderedDescending);
 assert(FlowCompareVersions(@"v1.0.0",@"0.99.99")==NSOrderedDescending);
 assert(FlowCompareVersions(@"1.0",@"1.0.0")==NSOrderedSame);
 assert(FlowCompareVersions(@"0.9.0",@"0.9.6")==NSOrderedAscending);
 assert(FlowCompareVersions(@"0.9.6-preview",@"0.9.0")==NSOrderedSame);
 assert(FlowCompareVersions((id)NSNull.null,@"0.9.0")==NSOrderedSame);
 assert(!FlowOpenUpdate());
 puts("Passed: numeric release comparison, optional v prefix, invalid tag rejection and no unverified update link.");
}return 0;}
