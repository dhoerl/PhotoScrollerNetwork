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
 * Copyright 2012 David Hoerl All Rights Reserved.
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

@interface FastCATiledLayer : CATiledLayer
@end

@implementation FastCATiledLayer

+ (CFTimeInterval)fadeDuration
{
  return 0.0;
}

@end

@implementation TilingView
{
	TiledImageBuilder *tb;
}
@synthesize annotates;

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
        tiledLayer.levelsOfDetail = ZOOM_LEVELS;
    }
    return self;
}

#if 1
- (void)drawLayer:(CALayer*)layer inContext:(CGContextRef)context
{
	if(tb.failed) return;
	
    CGFloat scale = CGContextGetCTM(context).a;

	// Fetch clip box in *view* space; context's CTM is preconfigured for view space->tile space transform
	CGRect box = CGContextGetClipBoundingBox(context);

	CGContextTranslateCTM(context, 0, box.origin.y + box.size.height);
	CGContextScaleCTM(context, 1.0, -1.0);

	// Calculate tile index
	CGSize tileSize = [(CATiledLayer*)layer tileSize];
	CGFloat col = box.origin.x * scale / tileSize.width;
	CGFloat row = box.origin.y * scale / tileSize.height;

	CGImageRef image = [tb imageForScale:scale row:lrintf(row) col:lrintf(col)];
	box.origin.y = 0;
	CGContextDrawImage(context, box, image);
	CFRelease(image);

	if(self.annotates) {
		CGContextSetStrokeColorWithColor(context, [[UIColor whiteColor] CGColor]);
		CGContextSetLineWidth(context, 6.0 / scale);
		CGContextStrokeRect(context, box);
	}
}

#else

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
			if(!tileRect.size.width || !tileRect.size.height) { NSLog(@"WTF"); continue; }
			
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

@end
