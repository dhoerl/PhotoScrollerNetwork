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

#include <mach/mach_time.h>	
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

#ifdef LIBJPEG	
#include <jpeglib.h>
#include <setjmp.h>
#endif

#ifdef LIBJPEG_TURBO
#include <turbojpeg.h>
#endif

#import <ImageIO/ImageIO.h>
#import <MobileCoreServices/MobileCoreServices.h> // kUTTypePNG

#import "TiledImageBuilder.h"

static const size_t bytesPerPixel = 4;
static const size_t bitsPerComponent = 8;
static const size_t tileDimension = TILE_SIZE;
static const size_t tileBytesPerRow = tileDimension * bytesPerPixel;
static const size_t tileSize = tileBytesPerRow * tileDimension;

static inline long		offsetFromScale(CGFloat scale) { long s = lrintf(scale*1000.f); long idx = 0; while(s < 1000) s *= 2, ++idx; return idx; }
static inline size_t	calcDimension(size_t d) { return(d + (tileDimension-1)) & ~(tileDimension-1); }
static inline size_t	calcBytesPerRow(size_t row) { return calcDimension(row) * bytesPerPixel; }

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
	unsigned char *addr;
	unsigned char *emptyAddr;
	size_t mappedSize;
	size_t height;
	size_t width;
	size_t bytesPerRow;
	size_t emptyTileRowSize;
} mapper;

#ifndef NDEBUG
static void dumpMapper(const char *str, mapper *m)
{
	printf("MAP: %s\n", str);
	printf(" fd = %d\n", m->fd);
	printf(" addr = %p\n", m->addr);
	printf(" emptyAddr = %p\n", m->emptyAddr);
	printf(" mappedSize = %lu\n", m->mappedSize);
	printf(" height = %lu\n", m->height);
	printf(" width = %lu\n", m->width);
	printf(" bytesPerRow = %lu\n", m->bytesPerRow);
	printf(" emptyTileRowSize = %lu\n", m->emptyTileRowSize);
	putchar('\n');
}
#endif

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
	size_t tileHeight;		
	size_t tileWidth;
	size_t col;

} imageMemory;

#ifndef NDEBUG
static void dumpIMS(const char *str, imageMemory *i)
{
	printf("IMS: %s\n", str);
	dumpMapper("map:", &i->map);

	printf(" idx = %ld\n", i->index);
	printf(" cols = %ld\n", i->cols);
	printf(" rows = %ld\n", i->rows);
	printf(" outline = %ld\n", i->outLine);
	printf(" col = %ld\n", i->col);
	printf(" row = %ld\n", i->row);
	putchar('\n');
}
#endif

static BOOL tileBuilder(imageMemory *im, BOOL useMMAP);
static void truncateEmptySpace(imageMemory *im);

#ifdef LIBJPEG	

#define SCAN_LINE_MAX			1			// libjpeg docs imply you could get 4 but all I see is 1 at a time, and now the logic wants just one

static void my_error_exit(j_common_ptr cinfo);

static void init_source(j_decompress_ptr cinfo);
static boolean fill_input_buffer(j_decompress_ptr cinfo);
static void skip_input_data(j_decompress_ptr cinfo, long num_bytes);
static boolean resync_to_restart(j_decompress_ptr cinfo, int desired);
static void term_source(j_decompress_ptr cinfo);

/*
 * Here's the routine that will replace the standard error_exit method:
 */
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

static CGColorSpaceRef colorSpace;

// Compliments to Rainer Brockerhoff
static uint64_t DeltaMAT(uint64_t then, uint64_t now)
{
	uint64_t delta = now - then;

	/* Get the timebase info */
	mach_timebase_info_data_t info;
	mach_timebase_info(&info);

	/* Convert to nanoseconds */
	delta *= info.numer;
	delta /= info.denom;

	return (uint64_t)((double)delta / 1e6); // ms
}

@interface TiledImageBuilder ()

- (void)decodeImage:(CGImageRef)image;
- (void)decodeImageURL:(NSURL *)url;
- (void)decodeImageData:(NSData *)data;

- (int)createTempFile:(BOOL)unlinkFile;
- (void)mapMemory:(mapper *)mapP; 
- (void)mapMemoryForIndex:(size_t)idx width:(size_t)w height:(size_t)h;
#ifdef LIBJPEG
- (BOOL)partialTile:(BOOL)final;
#endif
- (void)run;

#ifdef LIBJPEG
- (void)jpegInitFile:(NSString *)path;
- (void)jpegInitNetwork;
- (BOOL)jpegOutputScanLines;	// return YES when done
#endif

- (uint64_t)timeStamp;

@end

@implementation TiledImageBuilder
{
	NSString *imagePath;
	FILE *imageFile;

	size_t pageSize;
	imageMemory *ims;
	imageDecoder decoder;
	BOOL mapWholeFile;
	BOOL deleteImageFile;

#ifdef LIBJPEG
	// input
	co_jpeg_source_mgr	src_mgr;

	// output
	unsigned char		*scanLines[SCAN_LINE_MAX];
#endif
}
@synthesize zoomLevels;
@synthesize failed;
@synthesize startTime;
@synthesize finishTime;
@synthesize milliSeconds;

+ (void)initialize
{
	if(self == [TiledImageBuilder class]) {
		colorSpace = CGColorSpaceCreateDeviceRGB();
	}
}

- (id)initWithImage:(CGImageRef)image levels:(NSUInteger)levels
{
	if((self = [super init])) {
		startTime = [self timeStamp];

		zoomLevels = levels;
		ims = calloc(zoomLevels, sizeof(imageMemory));
		decoder = cgimageDecoder;
		pageSize = getpagesize();
		{
			mapWholeFile = YES;
			[self decodeImage:image];
		}
		finishTime = [self timeStamp];
		milliSeconds = (uint32_t)DeltaMAT(startTime, finishTime);

#ifndef NDEBUG
		NSLog(@"FINISH: %u milliseconds", milliSeconds);
#endif
	}
	return self;
}

- (id)initWithImagePath:(NSString *)path withDecode:(imageDecoder)dec levels:(NSUInteger)levels
{
	if((self = [super init])) {
		startTime = [self timeStamp];

		zoomLevels = levels;
		ims = calloc(zoomLevels, sizeof(imageMemory));
		decoder = dec;
		pageSize = getpagesize();
#ifdef LIBJPEG
		if(decoder == libjpegIncremental) {
			[self jpegInitFile:path];
		} else
#endif		
		{
			mapWholeFile = YES;
			[self decodeImageURL:[NSURL fileURLWithPath:path]];
		}
		finishTime = [self timeStamp];
		milliSeconds = (uint32_t)DeltaMAT(startTime, finishTime);

#ifndef NDEBUG
		NSLog(@"FINISH: %u milliseconds", milliSeconds);
#endif
	}
	return self;
}
- (id)initForNetworkDownloadWithDecoder:(imageDecoder)dec levels:(NSUInteger)levels
{
	if((self = [super init])) {
		zoomLevels = levels;
		ims = calloc(zoomLevels, sizeof(imageMemory));
		decoder = dec;
		pageSize = getpagesize();
#ifdef LIBJPEG
		if(decoder == libjpegIncremental) {
			[self jpegInitNetwork];
		} else 
#endif
		{
			mapWholeFile = YES;
			[self createImageFile];
		}
	}
	return self;
}
- (void)dealloc
{
	for(NSUInteger idx=0; idx<zoomLevels;++idx) {
		int fd = ims[idx].map.fd;
		if(fd>0) close(fd);
	}
	free(ims);

	if(imageFile) fclose(imageFile);
	if(imagePath) unlink([imagePath fileSystemRepresentation]);
#ifdef LIBJPEG
	if(src_mgr.cinfo.src) jpeg_destroy_decompress(&src_mgr.cinfo);
#endif
}

- (uint64_t)timeStamp
{
	return mach_absolute_time();
}

- (void)appendToImageFile:(NSData *)data
{
	if(!failed) {
		fwrite([data bytes], [data length], 1, imageFile);
	}
}

- (void)dataFinished
{
	if(!failed) {
		startTime = [self timeStamp];

		fclose(imageFile), imageFile = NULL;
		[self decodeImageURL:[NSURL fileURLWithPath:imagePath]];
		unlink([imagePath fileSystemRepresentation]), imagePath = NULL;
		
		finishTime = [self timeStamp];
		milliSeconds = (uint32_t)DeltaMAT(startTime, finishTime);
#ifndef NDEBUG
		NSLog(@"FINISH: %u milliseconds", milliSeconds);
#endif
	}
}

#ifdef LIBJPEG
- (void)jpegInitFile:(NSString *)path
{
	const char *file = [path fileSystemRepresentation];
	int jfd = open(file, O_RDONLY, 0);
	if(jfd <= 0) {
		NSLog(@"Error: failed to open input image file \"%s\" for reading (%d).\n", file, errno);
		failed = YES;
		return;
	}
	int ret = fcntl(jfd, F_NOCACHE, 1);	// don't clog up the system's disk cache
	if(ret == -1) {
		NSLog(@"Warning: cannot turn off cacheing for input file (errno %d).", errno);
	}
	if ((imageFile = fdopen(jfd, "r")) == NULL) {
		NSLog(@"Error: failed to fdopen input image file \"%s\" for reading (%d).", file, errno);
		jpeg_destroy_decompress(&src_mgr.cinfo);
		close(jfd);
		failed = YES;
		return;
	}

	/* Step 1: allocate and initialize JPEG decompression object */

	/* We set up the normal JPEG error routines, then override error_exit. */
	src_mgr.cinfo.err = jpeg_std_error(&src_mgr.jerr.pub);
	src_mgr.jerr.pub.error_exit = my_error_exit;
	/* Establish the setjmp return context for my_error_exit to use. */
	if (setjmp(src_mgr.jerr.setjmp_buffer)) {
	/* If we get here, the JPEG code has signaled an error.
	 * We need to clean up the JPEG object, close the input file, and return.
	 */
		failed = YES;
	} else {
		/* Now we can initialize the JPEG decompression object. */
		jpeg_create_decompress(&src_mgr.cinfo);

		/* Step 2: specify data source (eg, a file) */
		jpeg_stdio_src(&src_mgr.cinfo, imageFile);

		/* Step 3: read file parameters with jpeg_read_header() */
		(void) jpeg_read_header(&src_mgr.cinfo, TRUE);

		src_mgr.cinfo.out_color_space =  JCS_EXT_ABGR;
	
		assert(src_mgr.cinfo.num_components == 3);
		assert(src_mgr.cinfo.image_width > 0 && src_mgr.cinfo.image_height > 0);
		//NSLog(@"WID=%d HEIGHT=%d", src_mgr.cinfo.image_width, src_mgr.cinfo.image_height);
		
		// Create files
		size_t scale = 1;
		for(size_t idx=0; idx<zoomLevels; ++idx) {
			[self mapMemoryForIndex:idx width:src_mgr.cinfo.image_width/scale height:src_mgr.cinfo.image_height/scale];
			if(failed) break;
			scale *= 2;
		}
		if(!failed) {
			(void)jpeg_start_decompress(&src_mgr.cinfo);
			
			while(![self jpegOutputScanLines]) ;
		}
	}
	jpeg_destroy_decompress(&src_mgr.cinfo);
	src_mgr.cinfo.src = NULL;	// dealloc tests

	fclose(imageFile), imageFile = NULL;
}

- (void)jpegInitNetwork
{
	src_mgr.pub.next_input_byte		= NULL;
	src_mgr.pub.bytes_in_buffer		= 0;
	src_mgr.pub.init_source			= init_source;
	src_mgr.pub.fill_input_buffer	= fill_input_buffer;
	src_mgr.pub.skip_input_data		= skip_input_data;
	src_mgr.pub.resync_to_restart	= resync_to_restart;
	src_mgr.pub.term_source			= term_source;
	
	src_mgr.consumed_data			= 0;
	src_mgr.start_of_stream			= TRUE;

	/* We set up the normal JPEG error routines, then override error_exit. */
	src_mgr.cinfo.err = jpeg_std_error(&src_mgr.jerr.pub);
	src_mgr.jerr.pub.error_exit = my_error_exit;
	/* Establish the setjmp return context for my_error_exit to use. */
	if (setjmp(src_mgr.jerr.setjmp_buffer)) {
		/* If we get here, the JPEG code has signaled an error.
		 * We need to clean up the JPEG object, close the input file, and return.
		 */
		//NSLog(@"YIKES! SETJUMP");
		failed = YES;
		//[self cancel];
	} else {
		/* Now we can initialize the JPEG decompression object. */
		jpeg_create_decompress(&src_mgr.cinfo);
		src_mgr.cinfo.src = &src_mgr.pub; // MUST be after the jpeg_create_decompress - ask me how I know this :-)
		//src_mgr.pub.bytes_in_buffer = 0; /* forces fill_input_buffer on first read */
		//src_mgr.pub.next_input_byte = NULL; /* until buffer loaded */
	}
}
- (void)jpegAdvance:(NSMutableData *)webData
{
	unsigned char *dataPtr = (unsigned char *)[webData mutableBytes];

	// mutable data bytes pointer can change invocation to invocation
	size_t diff					= src_mgr.pub.next_input_byte - src_mgr.data;
	src_mgr.pub.next_input_byte	= dataPtr + diff;
	src_mgr.data				= dataPtr;
	src_mgr.data_length			= [webData length];

	//NSLog(@"s1=%ld s2=%d", src_mgr.data_length, highWaterMark);
	if (setjmp(src_mgr.jerr.setjmp_buffer)) {
		/* If we get here, the JPEG code has signaled an error.
		 * We need to clean up the JPEG object, close the input file, and return.
		 */
		NSLog(@"YIKES! SETJUMP");
		failed = YES;
		return;
	}
	if(src_mgr.jpegFailed) failed = YES;

	if(!failed) {
		if(!src_mgr.got_header) {
			/* Step 3: read file parameters with jpeg_read_header() */
			int jret = jpeg_read_header(&src_mgr.cinfo, FALSE);
			if(jret == JPEG_SUSPENDED || jret != JPEG_HEADER_OK) return;
			//NSLog(@"GOT header");
			src_mgr.got_header = YES;
			src_mgr.start_of_stream = NO;
			src_mgr.cinfo.out_color_space =  JCS_EXT_ABGR;

			assert(src_mgr.cinfo.num_components == 3);
			assert(src_mgr.cinfo.image_width > 0 && src_mgr.cinfo.image_height > 0);
			//NSLog(@"WID=%d HEIGHT=%d", src_mgr.cinfo.image_width, src_mgr.cinfo.image_height);

			[self mapMemoryForIndex:0 width:src_mgr.cinfo.image_width height:src_mgr.cinfo.image_height];
			unsigned char *scratch = ims[0].map.emptyAddr;
			//NSLog(@"Scratch=%p rowBytes=%ld", scratch, rowBytes);
			for(int i=0; i<SCAN_LINE_MAX; ++i) {
				scanLines[i] = scratch;
				scratch += ims[0].map.bytesPerRow;
			}
			(void)jpeg_start_decompress(&src_mgr.cinfo);

			// Create files
			size_t scale = 1;
			for(size_t idx=0; idx<zoomLevels; ++idx) {
				[self mapMemoryForIndex:idx width:src_mgr.cinfo.image_width/scale height:src_mgr.cinfo.image_height/scale];
				scale *= 2;
			}
			if(src_mgr.jpegFailed) failed = YES;
		}
		if(src_mgr.got_header && !failed) {
			[self jpegOutputScanLines];
			
			// When we consume all the data in the web buffer, safe to free it up for the system to resuse
			if(src_mgr.pub.bytes_in_buffer == 0) {
				src_mgr.deleted_data += [webData length];
				[webData setLength:0];
			}
		}
	}
}

- (BOOL)jpegOutputScanLines
{
	if(failed) return YES;

	while(src_mgr.cinfo.output_scanline <  src_mgr.cinfo.image_height) {
	
		unsigned char *scanPtr;
		{
			size_t tmpMapSize = ims[0].map.bytesPerRow;
			size_t offset = src_mgr.writtenLines*ims[0].map.bytesPerRow+ims[0].map.emptyTileRowSize;
			size_t over = offset % pageSize;
			offset -= over;
			tmpMapSize += over;
			
			ims[0].map.mappedSize = tmpMapSize;
			ims[0].map.addr = mmap(NULL, ims[0].map.mappedSize, PROT_READ | PROT_WRITE, MAP_FILE | MAP_SHARED, ims[0].map.fd, offset);
			if(ims[0].map.addr == MAP_FAILED) {
				NSLog(@"errno1=%s", strerror(errno) );
				failed = YES;
				ims[0].map.addr = NULL;
				ims[0].map.mappedSize = 0;
				return YES;
			}
			scanPtr = ims[0].map.addr + over;
		}
	
		scanLines[0] = scanPtr;
		int lines = jpeg_read_scanlines(&src_mgr.cinfo, scanLines, SCAN_LINE_MAX);
		if(lines <= 0) {
			munmap(ims[0].map.addr, ims[0].map.mappedSize);
			break;
		}
		ims[0].outLine = src_mgr.writtenLines;

		// on even numbers try to update the lower resolution scans
		if(!(src_mgr.writtenLines & 1)) {
			size_t scale = 2;
			imageMemory *im = &ims[1];
			for(size_t idx=1; idx<zoomLevels; ++idx, scale *= 2, ++im) {
				if(src_mgr.writtenLines & (scale-1)) break;

				im->outLine = src_mgr.writtenLines/scale;
				
				size_t tmpMapSize = im->map.bytesPerRow;
				size_t offset = im->outLine*tmpMapSize+im->map.emptyTileRowSize;
				size_t over = offset % pageSize;
				offset -= over;
				tmpMapSize += over;
				
				im->map.mappedSize = tmpMapSize;
				im->map.addr = mmap(NULL, im->map.mappedSize, PROT_WRITE, MAP_FILE | MAP_SHARED, im->map.fd, offset); // write only 
				if(im->map.addr == MAP_FAILED) {
					NSLog(@"errno2=%s", strerror(errno) );
					failed = YES;
					im->map.addr = NULL;
					im->map.mappedSize = 0;
					return YES;
				}
		
				uint32_t *outPtr = (uint32_t *)(im->map.addr + over);
				uint32_t *inPtr  = (uint32_t *)scanPtr;
				
				for(size_t col=0; col<ims[0].map.width; col += scale) {
					*outPtr++ = *inPtr;
					inPtr += scale;
				}
				munmap(im->map.addr, im->map.mappedSize);
			}
		}
		munmap(ims[0].map.addr, ims[0].map.mappedSize);

		// tile all images as we get full rows of tiles
		if(ims[0].outLine && !(ims[0].outLine % TILE_SIZE)) {
			failed = ![self partialTile:NO];
			if(failed) break;
		}
		src_mgr.writtenLines += lines;
	}
	//NSLog(@"END LINES: me=%ld jpeg=%ld", src_mgr.writtenLines, src_mgr.cinfo.output_scanline);
	BOOL ret = (src_mgr.cinfo.output_scanline == src_mgr.cinfo.image_height) || failed;
	
	if(ret) {
		jpeg_finish_decompress(&src_mgr.cinfo);
		if(!failed) {
			assert(jpeg_input_complete(&src_mgr.cinfo));
			ret = [self partialTile:YES];
		}
	}
	return ret;
}

- (BOOL)partialTile:(BOOL)final
{
	imageMemory *im = ims;
	for(size_t idx=0; idx<zoomLevels; ++idx, ++im) {
		// got enought to tile one row now?
		if(final || (im->outLine && !(im->outLine % TILE_SIZE))) {
			size_t rows = im->rows;		// cheat
			if(!final) im->rows = im->row + 1;		// just do one tile row
			failed = !tileBuilder(im, YES);
			if(failed) {
				return NO;
			}
			++im->row;
			im->rows = rows;
		}
		if(final) truncateEmptySpace(im);
	}
	return YES;
}
#endif

- (void)decodeImageURL:(NSURL *)url
{
	//NSLog(@"URL=%@", url);
#ifdef LIBJPEG_TURBO
	if(decoder == libjpegTurboDecoder) {
		NSData *data = [NSData dataWithContentsOfURL:url];
		[self decodeImageData:data];
	} else
#endif
	if(decoder == cgimageDecoder) {
		failed = YES;
		CGImageSourceRef imageSourcRef = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
		if(imageSourcRef) {
			CGImageRef image = CGImageSourceCreateImageAtIndex(imageSourcRef, 0, NULL);
			CFRelease(imageSourcRef), imageSourcRef = NULL;
			if(image) {
				failed = NO;
				[self decodeImage:image];
				CGImageRelease(image);
			}
		}
	}
}

- (void)decodeImage:(CGImageRef)image
{
	if(decoder == cgimageDecoder) {
		[self mapMemoryForIndex:0 width:CGImageGetWidth(image) height:CGImageGetHeight(image)];

		[self drawImage:image];
		if(!failed) [self run];
	}
}

- (void)decodeImageData:(NSData *)data
{
#ifdef LIBJPEG_TURBO
	if(decoder == libjpegTurboDecoder) {
		tjhandle decompressor = tjInitDecompress();

		unsigned char *jpegBuf = (unsigned char *)[data bytes];
		unsigned long jpegSize = [data length];
		int jwidth, jheight, jpegSubsamp;
		failed = tjDecompressHeader2(decompressor,
			jpegBuf,
			jpegSize,
			&jwidth,
			&jheight,
			&jpegSubsamp 
			);
		if(!failed) {
			[self mapMemoryForIndex:0 width:jwidth height:jheight];

			failed = tjDecompress2(decompressor,
				jpegBuf,
				jpegSize,
				ims[0].map.addr,
				jwidth,
				ims[0].map.bytesPerRow,
				jheight,
				TJPF_ABGR,
				TJFLAG_NOREALLOC
				);
			tjDestroy(decompressor);
		}
	} else
#endif
	{
		assert(0);
	}

	if(!failed) [self run];
}

- (CGSize)imageSize
{
	return CGSizeMake(ims[0].map.width, ims[0].map.height);
}

- (BOOL)createImageFile
{
	BOOL success;
	int fd = [self createTempFile:NO];
	if(fd == -1) {
		failed = YES;
		success = NO;
	} else {

		int ret = fcntl(fd, F_NOCACHE, 1);	// don't clog up the system's disk cache
		if(ret == -1) {
			NSLog(@"Warning: cannot turn off cacheing for input file (errno %d).", errno);
		}
		if ((imageFile = fdopen(fd, "r+")) == NULL) {
			NSLog(@"Error: failed to fdopen image file \"%@\" for \"r+\" (%d).", imagePath, errno);
			close(fd);
			failed = YES;
			success = NO;
		} else {
			success = YES;
		}
	}
	return success;
}

- (int)createTempFile:(BOOL)unlinkFile
{
	char *template = strdup([[NSTemporaryDirectory() stringByAppendingPathComponent:@"psXXXXXX"] fileSystemRepresentation]);
	int fd = mkstemp(template);
	if(fd == -1) {
		failed = YES;
		NSLog(@"OPEN failed file %s %s", template, strerror(errno));
	} else {
		if(unlinkFile) {
			unlink(template);	// so it goes away when the fd is closed or on a crash
		} else {
			imagePath = [NSString stringWithCString:template encoding:NSASCIIStringEncoding];
		}
	}
	free(template);

	return fd;
}
- (void)mapMemoryForIndex:(size_t)idx width:(size_t)w height:(size_t)h
{
	imageMemory *imsP = &ims[idx];
	
	imsP->map.width = w;
	imsP->map.height = h;
	
	imsP->index = idx;
	imsP->rows = calcDimension(imsP->map.height)/tileDimension;
	imsP->cols = calcDimension(imsP->map.width)/tileDimension;
	
	[self mapMemory:&imsP->map];
}

- (void)mapMemory:(mapper *)mapP
{
	mapP->bytesPerRow = calcBytesPerRow(mapP->width);
	mapP->emptyTileRowSize = mapP->bytesPerRow * tileDimension;
	mapP->mappedSize = mapP->bytesPerRow * calcDimension(mapP->height) + mapP->emptyTileRowSize;	// may need temp space

	if(mapP->fd <= 0) {
		mapP->fd = [self createTempFile:YES];
		if(mapP->fd == -1) return;

		// have to expand the file to correct size first
		lseek(mapP->fd, mapP->mappedSize - 1, SEEK_SET);
		char tmp = 0;
		write(mapP->fd, &tmp, 1);
	}

	// NSLog(@"imageSize=%ld", imageSize);
	if(mapWholeFile && !mapP->emptyAddr) {
		mapP->emptyAddr = mmap(NULL, mapP->mappedSize, PROT_READ | PROT_WRITE, MAP_FILE | MAP_SHARED, mapP->fd, 0); //  | MAP_NOCACHE
		mapP->addr = mapP->emptyAddr + mapP->emptyTileRowSize;
		if(mapP->emptyAddr == MAP_FAILED) {
			failed = YES;
			NSLog(@"errno3=%s", strerror(errno) );
			mapP->emptyAddr = NULL;
			mapP->addr = NULL;
			mapP->mappedSize = 0;
		}
	}
}

- (void)drawImage:(CGImageRef)image
{
	if(image && !failed) {
		assert(ims[0].map.addr);
		CGContextRef context = CGBitmapContextCreate(ims[0].map.addr, ims[0].map.width, ims[0].map.height, bitsPerComponent, ims[0].map.bytesPerRow, colorSpace, kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Little);	// BRGA flipped (little Endian)
		assert(context);
		CGRect rect = CGRectMake(0, 0, ims[0].map.width, ims[0].map.height);
		CGContextDrawImage(context, rect, image);

		CGContextRelease(context);
	}
}

- (void)run
{
	mapper *lastMap = NULL;
	mapper *currMap = NULL;

	for(NSUInteger idx=0; idx < zoomLevels; ++idx) {
		lastMap = currMap;	// unused first loop
		currMap = &ims[idx].map;
		if(idx) {
			[self mapMemoryForIndex:idx width:lastMap->width/2 height:lastMap->height/2];
			if(failed) return;

//dumpIMS("RUN", &ims[idx]);

#if USE_VIMAGE == 1
		   vImage_Buffer src = {
				.data = lastMap->addr,
				.height = lastMap->height,
				.width = lastMap->width,
				.rowBytes = lastMap->bytesPerRow
			};
			
		   vImage_Buffer dest = {
				.data = currMap->addr,
				.height = currMap->height,
				.width = currMap->width,
				.rowBytes = currMap->bytesPerRow
			};

			vImage_Error err = vImageScale_ARGB8888 (
			   &src,
			   &dest,
			   NULL,
			   0 // kvImageHighQualityResampling 
			);
			assert(err == kvImageNoError);
#else	
			// Take every other pixel, every other row, to "down sample" the image. This is fast but has known problems.
			// Got a better idea? Submit a pull request.
			uint32_t *inPtr = (uint32_t *)lastMap->addr;
			uint32_t *outPtr = (uint32_t *)currMap->addr;
			for(size_t row=0; row<currMap->height; ++row) {
				char *lastInPtr = (char *)inPtr;
				char *lastOutPtr = (char *)outPtr;
				for(size_t col = 0; col < currMap->width; ++col) {
					*outPtr++ = *inPtr;
					inPtr += 2;
				}
				inPtr = (uint32_t *)(lastInPtr + lastMap->bytesPerRow*2);
				outPtr = (uint32_t *)(lastOutPtr + currMap->bytesPerRow);
			}
#endif
			// make tiles
			BOOL ret = tileBuilder(&ims[idx-1], NO);
			if(!ret) goto eRR;
		}
	}
assert(zoomLevels == 4);
	failed = !tileBuilder(&ims[zoomLevels-1], NO);
	return;
	
  eRR:
	failed = YES;
	return;
}

- (UIImage *)tileForScale:(CGFloat)scale row:(int)row col:(int)col
{
	CGImageRef image = [self newImageForScale:scale row:row col:col];
	UIImage *img = [UIImage imageWithCGImage:image];
	CGImageRelease(image);
	return img;
}
- (CGImageRef)newImageForScale:(CGFloat)scale row:(int)row col:(int)col
{
	if(failed) return nil;

	long idx = offsetFromScale(scale);
	imageMemory *im = (imageMemory *)malloc(sizeof(imageMemory));
	memcpy(im, &ims[idx], sizeof(imageMemory));
	im->col = col;
	im->row = row;

	size_t x = col * tileDimension;
	size_t y = row * tileDimension;
	
	im->tileWidth = MIN(im->map.width-x, tileDimension);
	im->tileHeight = MIN(im->map.height-y, tileDimension);

	size_t imgSize = tileBytesPerRow*im->tileHeight;
	struct CGDataProviderDirectCallbacks callBacks = { 0, 0, 0, PhotoScrollerProviderGetBytesAtPosition, PhotoScrollerProviderReleaseInfoCallback};
	CGDataProviderRef dataProvider = CGDataProviderCreateDirect(im, imgSize, &callBacks);
	
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
	CGDataProviderRelease(dataProvider);
	return image;
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
	// Don't think caching here would help but didn't test myself.
	unsigned char *startPtr = mmap(NULL, mapSize, PROT_READ, MAP_FILE | MAP_SHARED | MAP_NOCACHE, im->map.fd, (im->row*im->cols + im->col) * mapSize);  /*| MAP_NOCACHE */
	if(startPtr == MAP_FAILED) {
		NSLog(@"errno4=%s", strerror(errno) );
		return 0;
	}

	memcpy(buffer, startPtr+position, origCount);	// blit the image, then quit. How nice is that!
	munmap(startPtr, mapSize);

	return origCount;
}

static void PhotoScrollerProviderReleaseInfoCallback (
    void *info
) {
	free(info);
}


static BOOL tileBuilder(imageMemory *im, BOOL useMMAP)
{
	unsigned char *optr = im->map.emptyAddr;
	unsigned char *iptr = im->map.addr;
	
	// NSLog(@"tile...");
	// Now, we are going to pre-tile the image in 256x256 tiles, so we can map in contigous chunks of memory
	for(size_t row=im->row; row<im->rows; ++row) {
		unsigned char *tileIptr;
		if(useMMAP) {
			im->map.mappedSize = im->map.emptyTileRowSize*2;	// two tile rows
			im->map.emptyAddr = mmap(NULL, im->map.mappedSize, PROT_READ | PROT_WRITE, MAP_FILE | MAP_SHARED, im->map.fd, row*im->map.emptyTileRowSize);  /*| MAP_NOCACHE */
			if(im->map.emptyAddr == MAP_FAILED) return NO;
	
			im->map.addr = im->map.emptyAddr + im->map.emptyTileRowSize;
			
			iptr = im->map.addr;
			optr = im->map.emptyAddr;
			tileIptr = im->map.emptyAddr;
		} else {
			tileIptr = iptr;
		}
		for(size_t col=0; col<im->cols; ++col) {
			unsigned char *lastIptr = iptr;
			for(size_t i=0; i<tileDimension; ++i) {
				memcpy(optr, iptr, tileBytesPerRow);
				iptr += im->map.bytesPerRow;
				optr += tileBytesPerRow;
			}
			iptr = lastIptr + tileBytesPerRow;	// move to the next image
		}
		if(useMMAP) {
			munmap(im->map.emptyAddr, im->map.mappedSize);
		} else {
			iptr = tileIptr + im->map.emptyTileRowSize;
		}
	}
	//NSLog(@"...tile");

	if(!useMMAP) {
		// OK we're done with this memory now
		munmap(im->map.emptyAddr, im->map.mappedSize);

		// don't need the scratch space now
		truncateEmptySpace(im);
	}
	return YES;
}

static void truncateEmptySpace(imageMemory *im)
{
	// don't need the scratch space now
	off_t properLen = lseek(im->map.fd, 0, SEEK_END) - im->map.emptyTileRowSize;
	ftruncate(im->map.fd, properLen);
	im->map.mappedSize = 0;
}

#ifdef LIBJPEG
static void my_error_exit(j_common_ptr cinfo)
{
  /* cinfo->err really points to a my_error_mgr struct, so coerce pointer */
  my_error_ptr myerr = (my_error_ptr) cinfo->err;

  /* Always display the message. */
  /* We could postpone this until after returning, if we chose. */
  (*cinfo->err->output_message) (cinfo);

  /* Return control to the setjmp point */
  longjmp(myerr->setjmp_buffer, 1);
}

static void init_source(j_decompress_ptr cinfo)
{
	co_jpeg_source_mgr *src = (co_jpeg_source_mgr *)cinfo->src;
	src->start_of_stream = TRUE;
}

static boolean fill_input_buffer(j_decompress_ptr cinfo)
{
	co_jpeg_source_mgr *src = (co_jpeg_source_mgr *)cinfo->src;

	size_t diff = src->consumed_data - src->deleted_data;
	size_t unreadLen = src->data_length - diff;
	//NSLog(@"unreadLen=%ld", unreadLen);
	if((long)unreadLen <= 0) {
		return FALSE;
	}
	src->pub.bytes_in_buffer = unreadLen;
	
	src->pub.next_input_byte = src->data + diff;
	src->consumed_data = src->data_length + src->deleted_data;

	src->start_of_stream = FALSE;
	//NSLog(@"returning %ld bytes consumed_data=%ld data_length=%ld deleted_data=%ld", unreadLen, src->consumed_data, src->data_length, src->deleted_data);

	return TRUE;
}

static void skip_input_data(j_decompress_ptr cinfo, long num_bytes)
{
	co_jpeg_source_mgr *src = (co_jpeg_source_mgr *)cinfo->src;

	if (num_bytes > 0) {
		if(num_bytes <= src->pub.bytes_in_buffer) {
			//NSLog(@"SKIPPER1: %ld", num_bytes);
			src->pub.next_input_byte += (size_t)num_bytes;
			src->pub.bytes_in_buffer -= (size_t)num_bytes;
		} else {
			//NSLog(@"SKIPPER2: %ld", num_bytes);
			src->consumed_data			+= num_bytes - src->pub.bytes_in_buffer;
			src->pub.bytes_in_buffer	= 0;
		}
	}
}

static boolean resync_to_restart(j_decompress_ptr cinfo, int desired)
{
	co_jpeg_source_mgr *src = (co_jpeg_source_mgr *)cinfo->src;
	// NSLog(@"YIKES: resync_to_restart!!!");

	src->jpegFailed = TRUE;
	return FALSE;
}

static void term_source(j_decompress_ptr cinfo)
{
}

#endif

