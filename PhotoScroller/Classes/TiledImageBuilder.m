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

#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <sys/mount.h>
#include <sys/sysctl.h>

#define USE_VIMAGE 0

#if USE_VIMAGE == 1
#import <Accelerate/Accelerate.h>
#endif
#import <ImageIO/ImageIO.h>
#import <MobileCoreServices/MobileCoreServices.h> // kUTTypePNG

#import "TiledImageBuilder.h"

static const size_t bytesPerPixel = 4;
static const size_t bitsPerComponent = 8;
static const size_t tileDimension = TILE_SIZE;	// power of 2 only
static const size_t tileBytesPerRow = tileDimension * bytesPerPixel;
static const size_t tileSize = tileBytesPerRow * tileDimension;

static inline long offsetFromScale(CGFloat scale) { long s = lrintf(scale*1000.f); long idx = 0; while(s < 1000) s *= 2, ++idx; return idx; }
//static inline size_t calcBytesPerRow(size_t w) { return((bytesPerPixel * w) + 15) & ~15; }
static inline size_t calcDimension(size_t d) { return(d + (tileDimension-1)) & ~(tileDimension-1); }
static inline size_t calcBytesPerRow(size_t row) { return calcDimension(row) * bytesPerPixel; }

static size_t PhotoScrollerProviderGetBytesAtPosition (
    void *info,
    void *buffer,
    off_t position,
    size_t count
);
static void PhotoScrollerProviderReleaseInfoCallback (
    void *info
);

typedef struct {
	int fd;

	// needed early on
	size_t imageBytesPerRow;
	size_t mappedSpace;
	size_t slopSpace;

	// whole image
	size_t cols;
	size_t rows;
	size_t height;
	size_t width;

	// scale
	size_t index;
	
	// used by tiles
	size_t tileHeight;		
	size_t tileWidth;
	size_t col;
	size_t row;

} imageMemory;

static void tileBuilder(imageMemory *im, unsigned char *addr);

@interface TiledImageBuilder ()

- (void)mapMemory;

@end

@implementation TiledImageBuilder
{
	NSString *imagePath;
	imageMemory ims[ZOOM_LEVELS];
	
	// Used by the image building routines
	int fd;
	size_t width;
	size_t height;
	void *emptyAddr;
	void *addr;
	size_t bytesPerRow;
	size_t imageSize;
	size_t emptyTileRowSize;
	void *lastAddr;
	void *lastEmptyAddr;
}
@synthesize failed;
@dynamic image0BytesPerRow;

- (id)initWithImagePath:(NSString *)path
{
	if((self = [super init])) {
		imagePath = path;
		//NSLog(@"START");
		[self run];
		//NSLog(@"END");
	}
	return self;
}

- (void)dealloc
{
	if(!failed) {
		for(int idx=0; idx<ZOOM_LEVELS;++idx) {
			close(ims[idx].fd);
		}
	}
}

- (size_t)image0BytesPerRow
{
	return calcDimension(width) * bytesPerPixel;
}

- (CGSize)imageSize
{
	return CGSizeMake(ims[0].width, ims[0].height);
}

- (void *)scratchSpace
{
	return emptyAddr;
}

- (size_t)scratchRowBytes
{
	return calcBytesPerRow(width);
}

- (void *)mapMemoryForWidth:(size_t)w height:(size_t)h
{
	width = w;
	height = h;
	
	[self mapMemory];
	
	return addr;
}

- (void)mapMemory
{
	bytesPerRow = calcBytesPerRow(width);
	emptyTileRowSize = bytesPerRow * tileDimension;
	imageSize = bytesPerRow * calcDimension(height) + emptyTileRowSize;	// need temp space

	NSString *tmpFile = [NSString stringWithCString:tempnam([NSTemporaryDirectory() cStringUsingEncoding:NSUTF8StringEncoding], "ps") encoding:NSUTF8StringEncoding];
	const char *fileName = [tmpFile cStringUsingEncoding:NSUTF8StringEncoding];
	
	fd = open(fileName, O_CREAT | O_RDWR | O_TRUNC, 0777);
	if(fd == -1) NSLog(@"OPEN failed file %s %s", fileName, strerror(errno));
	assert(fd >= 0);

	// have to expand the file to correct size first
	lseek(fd, imageSize - 1, SEEK_SET);
	char tmp = 0;
	write(fd, &tmp, 1);
	unlink(fileName);	// so it goes away when the fd is closed or we on a crash

	lastAddr = addr;
	lastEmptyAddr = emptyAddr;

//NSLog(@"imageSize=%ld", imageSize);
	emptyAddr = mmap(NULL, imageSize, PROT_READ | PROT_WRITE, MAP_FILE | MAP_SHARED, fd, 0); //  | MAP_NOCACHE
	addr = (char *)emptyAddr + emptyTileRowSize;
	if(emptyAddr == MAP_FAILED) NSLog(@"errno=%s", strerror(errno) );
	assert(emptyAddr != MAP_FAILED);
}

- (void)drawImage:(CGImageRef)image
{
	if(image) {
	assert(addr);
		CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
		CGContextRef context = CGBitmapContextCreate(addr, width, height, bitsPerComponent, bytesPerRow, colorSpace, kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Little);	// BRGA flipped (little Endian)
		assert(context);
		CGRect rect = CGRectMake(0, 0, width, height);
		CGContextDrawImage(context, rect, image);

		CGColorSpaceRelease(colorSpace);
		CGContextRelease(context);
		CGImageRelease(image);
	}
}

- (void)run
{
	size_t lastWidth = 0;
	size_t lastHeight = 0;
	size_t lastBytesPerRow = 0;
	
	//void *emptyAddr = NULL;
	//void *addr = NULL;

	for(size_t idx=0; idx < ZOOM_LEVELS; ++idx) {
NSLog(@"idx=%ld", idx);

		if(idx == 0) {
			if(addr) {
				// already did the first image
			} else {
				NSURL *url = [NSURL fileURLWithPath:imagePath];
				CGImageSourceRef imageSourcRef = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
assert(imageSourcRef);
				CGImageRef image = CGImageSourceCreateImageAtIndex(imageSourcRef, 0, NULL);
assert(image);

				width = CGImageGetWidth(image);
				height = CGImageGetHeight(image);
				bytesPerRow = calcBytesPerRow(width);
				CFRelease(imageSourcRef), imageSourcRef = NULL;
				[self mapMemory];
				[self drawImage:image]; // releases
			}
		} else {
			lastWidth = width;
			lastHeight = height;
			lastBytesPerRow = bytesPerRow;

			width /= 2;
			height /= 2;
			[self mapMemory];
		}
#if 0
		bytesPerRow = calcBytesPerRow(width);
		emptyTileRowSize = bytesPerRow * tileDimension;
		imageSize = bytesPerRow * calcDimension(height) + emptyTileRowSize;	// need temp space

		// have to expand the file to correct size first
		NSString *tmpFile = [NSString stringWithCString:tempnam([NSTemporaryDirectory() cStringUsingEncoding:NSUTF8StringEncoding], "ps") encoding:NSUTF8StringEncoding];
		const char *fileName = [tmpFile cStringUsingEncoding:NSUTF8StringEncoding];
		
		int fd = open(fileName, O_CREAT | O_RDWR | O_TRUNC, 0777);
		if(fd == -1) NSLog(@"OPEN failed file %s %s", fileName, strerror(errno));
		assert(fd >= 0);

		lseek(fd, imageSize - 1, SEEK_SET);
		char tmp = 0;
		write(fd, &tmp, 1);
		unlink(fileName);	// so it goes away when the fd is closed or we on a crash

		void *lastAddr = addr;
		void *lastEmptyAddr = emptyAddr;

		emptyAddr = mmap(NULL, imageSize, PROT_READ | PROT_WRITE, MAP_FILE | MAP_SHARED, fd, 0); //  | MAP_NOCACHE
		addr = (char *)emptyAddr + emptyTileRowSize;
		if(emptyAddr == MAP_FAILED) NSLog(@"errno=%s", strerror(errno) );
		assert(emptyAddr != MAP_FAILED);
#endif

		if(idx == 0) {
//NSLog(@"img");

#if 0
			CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
			CGContextRef context = CGBitmapContextCreate(addr, width, height, bitsPerComponent, bytesPerRow, colorSpace, kCGImageAlphaNoneSkipFirst /* |  kCGBitmapByteOrder32Host*/);
			assert(context);
			CGRect rect = CGRectMake(0, 0, width, height);
			CGContextDrawImage(context, rect, image);

			CGColorSpaceRelease(colorSpace);
			CGContextRelease(context);
			CGImageRelease(image), image=NULL;
#endif
//NSLog(@"img done");
		} else {
#if USE_VIMAGE == 1
		   vImage_Buffer src = {
				.data = lastAddr,
				.height = lastHeight,
				.width = lastWidth,
				.rowBytes = lastBytesPerRow
			};
			
		   vImage_Buffer dest = {
				.data = addr,
				.height = height,
				.width = width,
				.rowBytes = bytesPerRow
			};

			vImage_Error err = vImageScale_ARGB8888 (
			   &src,
			   &dest,
			   NULL,
			   0 // kvImageHighQualityResampling 
			);
			assert(err == kvImageNoError);
#else	
//NSLog(@"boom: lastBPR=%ld bpr=%ld last=%p addr=%p", lastBytesPerRow, bytesPerRow, lastAddr, addr);		
			{
				uint32_t *inPtr = (uint32_t *)lastAddr;
				uint32_t *outPtr = (uint32_t *)addr;
				for(size_t row=0; row<height; ++row) {
					char *lastInPtr = (char *)inPtr;
					char *lastOutPtr = (char *)outPtr;
					for(size_t col = 0; col < width; ++col) {
						*outPtr++ = *inPtr;
						inPtr += 2;
					}
					inPtr = (uint32_t *)(lastInPtr + lastBytesPerRow*2);
					outPtr = (uint32_t *)(lastOutPtr + bytesPerRow);
				}
			}
#endif
			// make tiles
			tileBuilder(&ims[idx-1], lastEmptyAddr);
		}

		ims[idx].fd = fd;
		ims[idx].index = idx;
		ims[idx].height = height;
		ims[idx].width = width;
		ims[idx].rows = calcDimension(height)/tileDimension;
		ims[idx].cols = calcDimension(width)/tileDimension;
		ims[idx].mappedSpace = imageSize;
		ims[idx].imageBytesPerRow = bytesPerRow;
		ims[idx].slopSpace = emptyTileRowSize;
	}

	tileBuilder(&ims[ZOOM_LEVELS-1], emptyAddr);
	return;
	
  eRR:
	failed = YES;
	return;
}

- (UIImage *)tileForScale:(CGFloat)scale row:(int)row col:(int)col
{
	long idx = offsetFromScale(scale);
	imageMemory *im = (imageMemory *)malloc(sizeof(imageMemory));
	memcpy(im, &ims[idx], sizeof(imageMemory));
	im->col = col;
	im->row = row;

	size_t x = col * tileDimension;
	size_t y = row * tileDimension;
	
	im->tileWidth = MIN(im->width-x, tileDimension);
	im->tileHeight = MIN(im->height-y, tileDimension);

	size_t imgSize = tileBytesPerRow*im->tileHeight;
	struct CGDataProviderDirectCallbacks callBacks = { 0, 0, 0, PhotoScrollerProviderGetBytesAtPosition, PhotoScrollerProviderReleaseInfoCallback};
	CGDataProviderRef dataProvider = CGDataProviderCreateDirect(im, imgSize, &callBacks);
	
	CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
	CGImageRef image = CGImageCreate (
	   im->tileWidth,
	   im->tileHeight,
	   bitsPerComponent,
	   4*bitsPerComponent,
	   tileBytesPerRow,
	   colorSpace,
	   kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Little,
	   dataProvider,
	   NULL,
	   false,
	   kCGRenderingIntentPerceptual
	);
	CGColorSpaceRelease(colorSpace);
	CGDataProviderRelease(dataProvider);
	UIImage *img = [UIImage imageWithCGImage:image];
	CGImageRelease(image);
	
	return img;
}

@end

static size_t PhotoScrollerProviderGetBytesAtPosition (
    void *info,
    void *buffer,
    off_t position,
    size_t origCount
) {
	imageMemory *im = (imageMemory *)info;

	size_t mapSize = tileDimension*tileBytesPerRow;
	unsigned char *startPtr = mmap(NULL, mapSize, PROT_READ, MAP_FILE | MAP_SHARED /*| MAP_NOCACHE */, im->fd, (im->row*im->cols + im->col) * mapSize);

	memcpy(buffer, startPtr+position, origCount);
	munmap(startPtr, mapSize);

	return origCount;
}

static void PhotoScrollerProviderReleaseInfoCallback (
    void *info
) {
	free(info);
}


static void tileBuilder(imageMemory *im, unsigned char *addr)
{
	unsigned char *optr = addr;
	unsigned char *iptr = addr + im->slopSpace;
	
	//NSLog(@"tile...");
	// Now, we are going to pre-tile the image, so we can map in contigous chunks of memory
	for(int row=0; row<im->rows; ++row) {
		unsigned char *tileIptr = iptr;
		for(int col=0; col<im->cols; ++col) {
			unsigned char *lastIptr = iptr;
			for(int i=0; i<tileDimension; ++i) {
				memcpy(optr, iptr, tileBytesPerRow);
				iptr += im->imageBytesPerRow;
				optr += tileBytesPerRow;
			}
			iptr = lastIptr + tileBytesPerRow;	// move to the next image
		}
		iptr = tileIptr + im->slopSpace;
	}
	//NSLog(@"...tile");

	// OK we're done with this memory now
	munmap(addr, im->mappedSpace);

	// don't need the scratch space now
	off_t properLen = im->mappedSpace - im->slopSpace;
	ftruncate(im->fd, properLen);
}
