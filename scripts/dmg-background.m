#import <AppKit/AppKit.h>
static void text(NSString *value,NSPoint point,CGFloat size,NSColor *color,NSFontWeight weight){
 [value drawAtPoint:point withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:size weight:weight],NSForegroundColorAttributeName:color}];
}
int main(int argc,const char *argv[]){@autoreleasepool{
 if(argc!=2)return 1;
 NSBitmapImageRep *bitmap=[[NSBitmapImageRep alloc]initWithBitmapDataPlanes:NULL pixelsWide:560 pixelsHigh:340 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
 [NSGraphicsContext saveGraphicsState];NSGraphicsContext.currentContext=[NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
 [NSColor.whiteColor setFill];NSRectFill(NSMakeRect(0,0,560,340));
 NSColor *accent=[NSColor colorWithCalibratedWhite:.20 alpha:1];
 text(@"Flow2Studio",NSMakePoint(32,292),23,accent,NSFontWeightSemibold);
 NSBezierPath *arrow=[NSBezierPath bezierPath];[arrow moveToPoint:NSMakePoint(246,190)];[arrow lineToPoint:NSMakePoint(314,190)];[arrow moveToPoint:NSMakePoint(297,207)];[arrow lineToPoint:NSMakePoint(314,190)];[arrow lineToPoint:NSMakePoint(297,173)];
 arrow.lineWidth=4;arrow.lineCapStyle=NSLineCapStyleRound;arrow.lineJoinStyle=NSLineJoinStyleRound;[accent setStroke];[arrow stroke];
 NSString *hint=@"Drag Flow2Studio into Applications";
 NSDictionary *hintStyle=@{NSFontAttributeName:[NSFont systemFontOfSize:13],NSForegroundColorAttributeName:[NSColor colorWithCalibratedWhite:.42 alpha:1]};
 CGFloat hintWidth=[hint sizeWithAttributes:hintStyle].width;
 [hint drawAtPoint:NSMakePoint((560-hintWidth)/2,44) withAttributes:hintStyle];
 [NSGraphicsContext restoreGraphicsState];
 NSData *png=[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
 return [png writeToFile:[NSString stringWithUTF8String:argv[1]] atomically:YES]?0:1;
}}
