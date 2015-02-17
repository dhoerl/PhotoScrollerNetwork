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

#define TIMING_STATS			1		// set to 1 if you want to see how long things take
#define MEMORY_DEBUGGING		1		// set to 1 if you want to see how memory changes when images are processed
#define MMAP_DEBUGGING			0		// set to 1 to see how mmap/munmap working
#define MAPPING_IMAGES			0		// set to 1 to use MMAP for image tile retrieval - if 0 use pread
#define USE_VIMAGE				0		// set to 1 if you want vImage to downsize images (slightly better quality, much much slower)
#define LEVELS_INIT				0		// set to 1 if you want to specify the levels in the init method instead of using the target view size

#include <libkern/OSAtomic.h>

#include <mach/mach.h>			// freeMemory
#include <mach/mach_host.h>		// freeMemory
#include <mach/mach_time.h>		// time metrics
#include <mach/task_info.h>		// task metrics

#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <sys/mount.h>
#include <sys/sysctl.h>
#include <sys/stat.h>

//#import "UTCoreTypes.h"

#if USE_VIMAGE == 1
#import <Accelerate/Accelerate.h>
#endif

#ifdef LIBJPEG	
#include "jpeglib.h"
#include "turbojpeg.h"
#include <setjmp.h>
#endif

#import <ImageIO/ImageIO.h>

#import "TiledImageBuilder.h"

static const size_t bytesPerPixel = 4;
static const size_t bitsPerComponent = 8;
static const size_t tileDimension = TILE_SIZE;
static const size_t tileBytesPerRow = tileDimension * bytesPerPixel;
static const size_t tileSize = tileBytesPerRow * tileDimension;

typedef struct {
	int fd;
	unsigned char *addr;		// address == emptyAddr + emptyTileRowSize
	unsigned char *emptyAddr;	// first address of allocated space
	size_t mappedSize;			// all space from emptyAddr to end of file
	size_t height;				// image
	size_t width;				// image
	size_t bytesPerRow;			// mapped space, rounded to next full tile
	size_t emptyTileRowSize;	// free space at the beginning of the file

	// used for orientations other than "1"
	size_t col0offset;
	size_t row0offset;
} mapper;

typedef struct {
	mapper map;

	// whole image
	size_t cols;
	size_t rows;

	// scale
	size_t index;
	
	// construction and tile prep
	size_t outLine;	
	
	// used by tiling and during construction
	size_t row;
	
	// tiling only
	size_t col;
	size_t tileHeight;		
	size_t tileWidth;
	
	// drawing
	BOOL rotated;

} imageMemory;

// Internal struct to keep values of interest when probing the system
typedef struct {
	size_t freeMemory;
	size_t usedMemory;
	size_t totlMemory;
	size_t resident_size;
	size_t virtual_size;
} freeMemory;

#import "TiledImageBuilder.h"

#ifdef LIBJPEG

struct my_error_mgr {
  struct jpeg_error_mgr pub;		/* "public" fields */
  jmp_buf setjmp_buffer;			/* for return to caller */
};
typedef struct my_error_mgr * my_error_ptr;

typedef struct {
	struct jpeg_source_mgr			pub;
	struct jpeg_decompress_struct	cinfo;
	struct my_error_mgr				jerr;
	
	// input data management
	unsigned char					*data;
	size_t							data_length;
	size_t							consumed_data;		// where the next chunk of data should come from, offset into the NSData object
	size_t							deleted_data;		// removed from the NSData object
	size_t							writtenLines;
	boolean							start_of_stream;
	boolean							got_header;
	boolean							jpegFailed;
} co_jpeg_source_mgr;

#endif

/* Will figure out a way to make these static again
extern dispatch_queue_t		fileFlushQueue;
extern dispatch_group_t		fileFlushGroup;
extern float				ubc_threshold_ratio;
*/
extern volatile	int32_t		fileFlushGroupSuspended;
extern volatile int32_t		ubc_usage;					// rough idea of what our buffer cache usage is

@interface TiledImageBuilder ()
@property (nonatomic, assign) imageDecoder decoder;
@property (nonatomic, strong, readwrite) NSDictionary *properties;
@property (nonatomic, assign, readwrite) BOOL failed;				// global Error flags
@property (nonatomic, assign) imageMemory *ims;
@property (nonatomic, assign) FILE *imageFile;
@property (nonatomic, assign) size_t pageSize;
@property (nonatomic, assign) CGSize size;

#ifdef LIBJPEG
@property (nonatomic, assign) co_jpeg_source_mgr *src_mgr;			// input
#endif

+ (CGColorSpaceRef)colorSpace;
+ (dispatch_group_t)fileFlushGroup;
+ (dispatch_queue_t)fileFlushQueue;

- (void)mapMemoryForIndex:(size_t)idx width:(size_t)w height:(size_t)h;

- (uint64_t)timeStamp;
- (uint64_t)freeDiskspace;
- (freeMemory)freeMemory:(NSString *)msg;

- (NSUInteger)zoomLevelsForSize:(CGSize)imageSize;

@end

@interface TiledImageBuilder (Tile)

- (BOOL)tileBuilder:(imageMemory *)im useMMAP:(BOOL )useMMAP;
- (void )truncateEmptySpace:(imageMemory *)im;
- (void)createLevelsAndTile;

@end

#ifdef LIBJPEG

@interface TiledImageBuilder (JPEG)

- (void)decodeImageData:(NSData *)data;
- (BOOL)partialTile:(BOOL)final;

- (void)jpegInitFile:(NSString *)path;
- (void)jpegInitNetwork;
- (BOOL)jpegOutputScanLines;	// return YES when done

@end

#endif
