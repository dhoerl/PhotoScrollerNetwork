/* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * *
 *
 * This file is part of PhotoScrollerNetwork -- An iOS project that smoothly and efficiently
 * renders large images in progressively smaller ones for display in a CATiledLayer backed view.
 * Images can either be local, or more interestingly, downloaded from the internet.
 * Images can be rendered by an iOS CGImageSource, libjpeg-turbo, or incrmentally by
 * libjpeg (the turbo version) - the latter gives the best speed.
 *
 * Parts taken with minor changes from Apple's PhotoScroller sample code, the
 * ConcurrentOp from my ConcurrentOperations github sample code, and TiledImageBuilder
 * was completely original source code developed by me.
 *
 * Copyright 2012-2014 David Hoerl All Rights Reserved.
 *
 *
 * Redistribution and use in source and binary forms, with or without modification, are
 * permitted provided that the following conditions are met:
 *
 *    1. Redistributions of source code must retain the above copyright notice, this list of
 *       conditions and the following disclaimer.
 *
 *    2. Redistributions in binary form must reproduce the above copyright notice, this list
 *       of conditions and the following disclaimer in the documentation and/or other materials
 *       provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY David Hoerl ''AS IS'' AND ANY EXPRESS OR IMPLIED
 * WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND
 * FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL David Hoerl OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
 * ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
 * NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
 * ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */
 
#import <QuartzCore/CATiledLayer.h>

#import "TilingView.h"
#import "TiledImageBuilder.h"

#define LOG NSLog

#if !__has_feature(objc_arc)
#error THIS CODE MUST BE COMPILED WITH ARC ENABLED!
#endif


@interface FastCATiledLayer : CATiledLayer
@end

@implementation FastCATiledLayer

+ (CFTimeInterval)fadeDuration
{
  return 0;
}

@end

@implementation TilingView
{
	TiledImageBuilder *tb;
}

+ (Class)layerClass
{
	return [FastCATiledLayer class];
}

- (id)initWithImageBuilder:(TiledImageBuilder *)imageBuilder
{
	CGRect rect = { CGPointMake(0, 0), [imageBuilder imageSize] };
	
    if ((self = [super initWithFrame:rect])) {
        tb = imageBuilder;

        CATiledLayer *tiledLayer = (CATiledLayer *)[self layer];
        tiledLayer.levelsOfDetail = imageBuilder.zoomLevels;
		
		self.opaque = YES;
		self.clearsContextBeforeDrawing = NO;
    }
    return self;
}

//static inline long offsetFromScale(CGFloat scale) { long s = lrintf(1/scale); long idx = 0; while(s > 1) s /= 2.0f, ++idx; return idx; }

- (void)drawLayer:(CALayer*)layer inContext:(CGContextRef)context
{
	if(tb.failed) return;

    CGFloat scale = CGContextGetCTM(context).a;

	// Fetch clip box in *view* space; context's CTM is preconfigured for view space->tile space transform
	CGRect box = CGContextGetClipBoundingBox(context);

	// Calculate tile index
	CGSize tileSize = [(CATiledLayer*)layer tileSize];
	CGFloat col = (CGFloat)rint(box.origin.x * scale / tileSize.width);
	CGFloat row = (CGFloat)rint(box.origin.y * scale / tileSize.height);

	//LOG(@"scale=%f 1/scale=%f levelsOfDetail=%ld levelsOfDetailBias=%ld row=%f col=%f offsetFromScale=%ld", scale, 1/scale, ((CATiledLayer *)layer).levelsOfDetail, ((CATiledLayer *)layer).levelsOfDetailBias, row, col, offsetFromScale(scale));


	CGImageRef image = [tb newImageForScale:scale location:CGPointMake(col, row) box:box];

#if 0 // had this happen, think its fixed
if(!image) {
	LOG(@"YIKES! No Image!!! row=%f col=%f", row, col);
	return;
}
if(CGImageGetWidth(image) == 0 || CGImageGetHeight(image) == 0) {
	LOG(@"Yikes! Image has a zero dimension! row=%f col=%f", row, col);
	return;
}
#endif

	assert(image);

	CGContextTranslateCTM(context, box.origin.x, box.origin.y + box.size.height);
	CGContextScaleCTM(context, 1.0, -1.0);
	box.origin.x = 0;
	box.origin.y = 0;
	//LOG(@"Draw: scale=%f row=%d col=%d", scale, (int)row, (int)col);

	CGAffineTransform transform = [tb transformForRect:box /* scale:scale */];
	CGContextConcatCTM(context, transform);

	// Detect Rotation
	if(isnormal(transform.b) && isnormal(transform.c)) {
		CGSize s = box.size;
		box.size = CGSizeMake(s.height, s.width);
	}

	// LOG(@"BOX: %@", NSStringFromCGRect(box));

	CGContextSetBlendMode(context, kCGBlendModeCopy);	// no blending! from QA 1708
//if(row==0 && col==0)	
	CGContextDrawImage(context, box, image);
	CFRelease(image);

	if(self.annotates) {
		CGContextSetStrokeColorWithColor(context, [[UIColor whiteColor] CGColor]);
		CGContextSetLineWidth(context, 6.0f / scale);
		CGContextStrokeRect(context, box);
	}
}

#if 0 // Out of date - will not handle rotations - you could try to apply the affine transform used above
- (void)drawRect:(CGRect)rect
{
	if(tb.failed) return;

 	CGContextRef context = UIGraphicsGetCurrentContext();
    
    // get the scale from the context by getting the current transform matrix, then asking for
    // its "a" component, which is one of the two scale components. We could also ask for "d".
    // This assumes (safely) that the view is being scaled equally in both dimensions.
    CGFloat scale = CGContextGetCTM(context).a;
    CATiledLayer *tiledLayer = (CATiledLayer *)[self layer];
    CGSize tileSize = tiledLayer.tileSize;
    
    // Even at scales lower than 100%, we are drawing into a rect in the coordinate system of the full
    // image. One tile at 50% covers the width (in original image coordinates) of two tiles at 100%. 
    // So at 50% we need to stretch our tiles to double the width and height; at 25% we need to stretch 
    // them to quadruple the width and height; and so on.
    // (Note that this means that we are drawing very blurry images as the scale gets low. At 12.5%, 
    // our lowest scale, we are stretching about 6 small tiles to fill the entire original image area. 
    // But this is okay, because the big blurry image we're drawing here will be scaled way down before 
    // it is displayed.)
    tileSize.width /= scale;
    tileSize.height /= scale;
    
    // calculate the rows and columns of tiles that intersect the rect we have been asked to draw
    int firstCol = floorf(CGRectGetMinX(rect) / tileSize.width);
    int lastCol = floorf((CGRectGetMaxX(rect)-1) / tileSize.width);
    int firstRow = floorf(CGRectGetMinY(rect) / tileSize.height);
    int lastRow = floorf((CGRectGetMaxY(rect)-1) / tileSize.height);

    for (int row = firstRow; row <= lastRow; row++) {
        for (int col = firstCol; col <= lastCol; col++) {
            CGRect tileRect = CGRectMake(tileSize.width * col, tileSize.height * row,
                                         tileSize.width, tileSize.height);
            // if the tile would stick outside of our bounds, we need to truncate it so as to avoid
            // stretching out the partial tiles at the right and bottom edges
            tileRect = CGRectIntersection(self.bounds, tileRect);
			if(!tileRect.size.width || !tileRect.size.height) { LOG(@"WTF"); continue; }
			
            UIImage *tile = [tb tileForScale:scale row:row col:col];
            [tile drawInRect:tileRect];
            
            if (self.annotates) {
                [[UIColor whiteColor] set];
                CGContextSetLineWidth(context, 6.0 / scale);
                CGContextStrokeRect(context, tileRect);
            }
        }
    }
}
#endif

- (CGSize)imageSize
{
	return [tb imageSize];
}

-(UIColor *)getColorAtPosition:(CGPoint)pt
{
	CATiledLayer *tiledLayer = (CATiledLayer *)[self layer];
	CGSize tileSize = tiledLayer.tileSize;

	UIGraphicsBeginImageContextWithOptions(tileSize, YES, 0);

#if __LP64__
	long col = lrint( floor(pt.x / tileSize.width) );
	long row = lrint( floor(pt.y / tileSize.height) );
	CGPoint offsetPt = CGPointMake( round(pt.x - col * tileSize.width), round(  (pt.y - row * tileSize.height) ) );
#else
	long col = lrintf( floorf(pt.x / tileSize.width) );
	long row = lrintf( floorf(pt.y / tileSize.height) );
	CGPoint offsetPt = CGPointMake( roundf(pt.x - col * tileSize.width), roundf(  (pt.y - row * tileSize.height) ) );
#endif

	CGRect tileRect = CGRectMake(0, 0, tileSize.width, tileSize.height);
	UIImage *tile = [tb tileForScale:1 location:CGPointMake(col, row)];
	[tile drawInRect:tileRect];
	UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
	
	UIGraphicsEndImageContext();

	CGRect sourceRect = CGRectMake(offsetPt.x, offsetPt.y, 1, 1);
	CGImageRef imageRef = CGImageCreateWithImageInRect(image.CGImage, sourceRect);

	CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
	unsigned char *buffer = malloc(4);
	CGBitmapInfo bitmapInfo = kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big;
	CGContextRef context = CGBitmapContextCreate(buffer, 1, 1, 8, 4, colorSpace, bitmapInfo);
	CGColorSpaceRelease(colorSpace);
	CGContextDrawImage(context, CGRectMake(0, 0, 1, 1), imageRef);
	CGImageRelease(imageRef);
	CGContextRelease(context);

	CGFloat d = 255;
	CGFloat r = buffer[0] / d;
	CGFloat g = buffer[1] / d;
	CGFloat b = buffer[2] / d;
	CGFloat a = buffer[3] / d;

	free(buffer);
		
    return [UIColor colorWithRed:r green:g blue:b alpha:a];
}

#if 0 

// How to render it http://stackoverflow.com/questions/5526545/render-large-catiledlayer-into-smaller-area

- (UIImage *)image
{
    UIGraphicsBeginImageContextWithOptions(self.bounds.size, YES, 0);
	
    [self.layer renderInContext:UIGraphicsGetCurrentContext()];

    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();

    UIGraphicsEndImageContext();

    return img;
}
#endif

@end
