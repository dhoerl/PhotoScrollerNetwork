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

#define USE_VIMAGE 1

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
static const size_t tileDimension = TILE_SIZE;	// power of 2 only
static const size_t tileBytesPerRow = tileDimension * bytesPerPixel;
static const size_t tileSize = tileBytesPerRow * tileDimension;

static inline long offsetFromScale(CGFloat scale) { long s = lrintf(scale*1000.f); long idx = 0; while(s < 1000) s *= 2, ++idx; return idx; }
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
	unsigned char *addr;
	unsigned char *emptyAddr;
	size_t mappedSize;
	size_t height;
	size_t width;
	size_t bytesPerRow;			// expanded to full tile
	size_t emptyTileRowSize;
} mapper;

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

typedef struct {
	mapper map;

	// whole image
	size_t cols;
	size_t rows;

	// scale
	size_t index;
	
	// construction and tile prep
	size_t outLine;	
	
	// used by tiles and during construction
	size_t row;
	
	// tiling only
	size_t tileHeight;		
	size_t tileWidth;
	size_t col;

} imageMemory;

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

static void tileBuilder(imageMemory *im, BOOL useMMAP);

#ifdef LIBJPEG	

#define SCAN_LINE_MAX			1			// libjpeg docs imply this is the most you can get, but all I see is 1 at a time
#define INCREMENT_THRESHOLD		4096*8		// tuneable parameter - small is bad, very large is bad, so need something 8K to 64K. Did not really experiment

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
	struct jpeg_source_mgr				pub;
	struct jpeg_decompress_struct		cinfo;
	struct my_error_mgr					jerr;
	
	// input data management
	unsigned char						*data;
	size_t								data_length;
	size_t								consumed_data;		// where the next chunk of data should come from, offset into the NSData object
	size_t								writtenLines;
	boolean								start_of_stream;
	boolean								got_header;
	boolean								failed;
} co_jpeg_source_mgr;

#endif

@interface TiledImageBuilder ()

- (void)decodeImage:(NSURL *)url;
- (void)mapMemory:(mapper *)mapP; 
- (void)mapMemoryForIndex:(size_t)idx width:(size_t)w height:(size_t)h;
- (void)partialTile:(BOOL)final;

#ifdef LIBJPEG

- (void)jpegInitFile:(NSString *)path;
- (void)jpegInitNetwork;

#endif

@end

@implementation TiledImageBuilder
{
	NSString *imagePath;
	imageMemory ims[ZOOM_LEVELS];
	imageDecoder decoder;
	BOOL mapWholeFile;

#ifdef LIBJPEG
	// input
	FILE				*infile;
	NSUInteger			highWaterMark;
	co_jpeg_source_mgr	src_mgr;
	// output
	unsigned char		*scanLines[SCAN_LINE_MAX];
	size_t				pageSize;
	unsigned char		*oneLine;
#endif
}
@synthesize failed;
@dynamic image0BytesPerRow;

- (id)initWithImagePath:(NSString *)path withDecode:(imageDecoder)dec
{
	if((self = [super init])) {
		imagePath = path;
		decoder = dec;
#ifdef LIBJPEG
		if(decoder == libjpegIncremental) {
			pageSize = getpagesize();
			[self jpegInitFile:path];
			//[self run];
		} else
#endif		
		{
			mapWholeFile = YES;
			[self decodeImage:[NSURL fileURLWithPath:imagePath]];
	NSLog(@"RUNIT");
			[self run];
		}
		// NSLog(@"END");
	}
	return self;
}
#ifdef LIBJPEG
- (id)initForNetworkDownload
{
	if((self = [super init])) {
		decoder = libjpegIncremental;
		[self jpegInitNetwork];
	}
	return self;
}
#endif
- (void)dealloc
{
	if(!failed) {
		for(int idx=0; idx<ZOOM_LEVELS;++idx) {
			close(ims[idx].map.fd);
		}
	}
#ifdef LIBJPEG
	if(src_mgr.cinfo.src) jpeg_destroy_decompress(&src_mgr.cinfo);
	free(oneLine);
#endif
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
	if ((infile = fdopen(jfd, "r")) == NULL) {
		NSLog(@"Error: failed to fdopen input image file \"%s\" for reading (%d).", file, errno);
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
		jpeg_stdio_src(&src_mgr.cinfo, infile);

		/* Step 3: read file parameters with jpeg_read_header() */
		(void) jpeg_read_header(&src_mgr.cinfo, TRUE);

		src_mgr.cinfo.out_color_space =  JCS_EXT_ABGR;
	
		assert(src_mgr.cinfo.num_components == 3);
		assert(src_mgr.cinfo.image_width > 0 && src_mgr.cinfo.image_height > 0);
		//NSLog(@"WID=%d HEIGHT=%d", src_mgr.cinfo.image_width, src_mgr.cinfo.image_height);
		
		// Create files
		size_t scale = 1;
		for(size_t idx=0; idx<ZOOM_LEVELS; ++idx) {
			[self mapMemoryForIndex:idx width:src_mgr.cinfo.image_width/scale height:src_mgr.cinfo.image_height/scale];
			scale *= 2;
		}

		(void)jpeg_start_decompress(&src_mgr.cinfo);
		
		while(![self outputScanLines]) ;
		NSLog(@"WOW!");
	}
	jpeg_destroy_decompress(&src_mgr.cinfo);
	fclose(infile), infile = NULL;
}

- (BOOL)outputScanLines
{
	//NSLog(@"START LINES: %ld width=%d", src_mgr.writtenLines, src_mgr.cinfo.output_width);
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
			scanPtr = ims[0].map.addr + over;
		
			if(ims[0].map.addr == MAP_FAILED) NSLog(@"errno=%s", strerror(errno) );
			assert(ims[0].map.addr != MAP_FAILED);
			
		}
	
		scanLines[0] = scanPtr;
		int lines = jpeg_read_scanlines(&src_mgr.cinfo, scanLines, SCAN_LINE_MAX);
		if(lines <= 0) {
			munmap(ims[0].map.addr, ims[0].map.mappedSize);
			break;
		}
		ims[0].outLine = src_mgr.writtenLines;

		// if even number need to dup it
		if(!(src_mgr.writtenLines & 1)) {
			size_t scale = 2;
			imageMemory *im = &ims[1];
			for(size_t idx=1; idx<ZOOM_LEVELS; ++idx, scale *= 2, ++im) {
				if(src_mgr.writtenLines & (scale-1)) break;

				im->outLine = src_mgr.writtenLines/scale;
				
				size_t tmpMapSize = im->map.bytesPerRow;
				size_t offset = im->outLine*tmpMapSize+im->map.emptyTileRowSize;
				size_t over = offset % pageSize;
				offset -= over;
				tmpMapSize += over;
				
				im->map.mappedSize = tmpMapSize;
				im->map.addr = mmap(NULL, im->map.mappedSize, PROT_READ | PROT_WRITE, MAP_FILE | MAP_SHARED, im->map.fd, offset);
				if(ims[0].map.addr == MAP_FAILED) NSLog(@"errno=%s", strerror(errno) );
				assert(ims[0].map.addr != MAP_FAILED);

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

		// try to increase tile if we can
		if(ims[0].outLine && !(ims[0].outLine % TILE_SIZE)) {
			[self partialTile:NO];
		}
		src_mgr.writtenLines += lines;
	}
	//NSLog(@"END LINES: me=%ld jpeg=%ld", src_mgr.writtenLines, src_mgr.cinfo.output_scanline);
	BOOL ret = src_mgr.cinfo.output_scanline == src_mgr.cinfo.image_height;
	
	if(ret) {
		[self partialTile:YES];
	}
	return ret;
}

- (void)partialTile:(BOOL)final
{
	imageMemory *im = ims;
	for(size_t idx=0; idx<ZOOM_LEVELS; ++idx, ++im) {
		// got enought to tile one row now?
		if(final || (im->outLine && !(im->outLine % TILE_SIZE))) {
			size_t rows = im->rows;		// cheat
			if(!final) im->rows = im->row + 1;		// just do one tile
		
//NSLog(@"DO A TILE");
			tileBuilder(im, YES);
			++im->row;
			im->rows = rows;
		}
	}
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
	src_mgr.failed					= FALSE;

	/* We set up the normal JPEG error routines, then override error_exit. */
	src_mgr.cinfo.err = jpeg_std_error(&src_mgr.jerr.pub);
	src_mgr.jerr.pub.error_exit = my_error_exit;
	/* Establish the setjmp return context for my_error_exit to use. */
	if (setjmp(src_mgr.jerr.setjmp_buffer)) {
		/* If we get here, the JPEG code has signaled an error.
		 * We need to clean up the JPEG object, close the input file, and return.
		 */
NSLog(@"YIKES! SETJUMP");
		src_mgr.failed = YES;
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
#if 0
	unsigned char *oldDataPtr = (unsigned char *)[webData mutableBytes];
	[webData appendData:data];
	unsigned char *newDataPtr = (unsigned char *)[webData mutableBytes];
	if(oldDataPtr != newDataPtr) {
		// NSLog(@"CHANGED!"); // I never saw it, probably could happen
		size_t diff = src_mgr.pub.next_input_byte - src_mgr.data;
		src_mgr.pub.next_input_byte = newDataPtr + diff;
	}
	src_mgr.data = newDataPtr;
	src_mgr.data_length = [webData length];

	//NSLog(@"s1=%ld s2=%d", src_mgr.data_length, highWaterMark);
	if (setjmp(src_mgr.jerr.setjmp_buffer)) {
		/* If we get here, the JPEG code has signaled an error.
		 * We need to clean up the JPEG object, close the input file, and return.
		 */
NSLog(@"YIKES! SETJUMP");
		src_mgr.failed = YES;
		return;
	}
#endif
	if(src_mgr.data_length > highWaterMark && !src_mgr.failed) {
		highWaterMark += INCREMENT_THRESHOLD;	// update_levels added in so the final chunk is deferred to the end
		//NSLog(@"len=%u high=%u", [webData length], highWaterMark);

		if(!src_mgr.got_header) {
			/* Step 3: read file parameters with jpeg_read_header() */
			int jret = jpeg_read_header(&src_mgr.cinfo, FALSE);
			if(jret == JPEG_SUSPENDED || jret != JPEG_HEADER_OK) return;
			//NSLog(@"GOT header");
			src_mgr.got_header = YES;
			src_mgr.start_of_stream = NO;

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
		}
		if(src_mgr.got_header && !src_mgr.failed) {
			[self outputScanLines];
		}
	}
}


#endif


- (void)decodeImage:(NSURL *)url
{
NSLog(@"URL=%@", url);
#ifdef LIBJPEG_TURBO
	if(decoder == libjpegTurboDecoder) {
		tjhandle decompressor = tjInitDecompress();

		NSData *data = [NSData dataWithContentsOfURL:url];
		unsigned char *jpegBuf = (unsigned char *)[data bytes]; // const ???
		unsigned long jpegSize = [data length];
		int jwidth, jheight, jpegSubsamp;
		int ret = tjDecompressHeader2(decompressor,
			jpegBuf,
			jpegSize,
			&jwidth,
			&jheight,
			&jpegSubsamp 
			);
		assert(ret == 0);
		
		[self mapMemoryForIndex:0 width:jwidth height:jheight];

		// NSLog(@"HEADER w%d bpr%ld h%d", width, imageBuilder.image0BytesPerRow, height);	
		ret = tjDecompress2(decompressor,
			jpegBuf,
			jpegSize,
			ims[0].map.addr,
			jwidth,
			ims[0].map.bytesPerRow,
			jheight,
			TJPF_ABGR,
			TJFLAG_NOREALLOC
			);	
		assert(ret == 0);

		tjDestroy(decompressor);
	} else
#endif
	{
		CGImageSourceRef imageSourcRef = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
assert(imageSourcRef);
		CGImageRef image = CGImageSourceCreateImageAtIndex(imageSourcRef, 0, NULL);
assert(image);

		CFRelease(imageSourcRef), imageSourcRef = NULL;
		// NSLog(@"MAP MEMORY");
		[self mapMemoryForIndex:0 width:CGImageGetWidth(image) height:CGImageGetHeight(image)];
		// NSLog(@"DRAW IMAGE");
		[self drawImage:image];
		CGImageRelease(image);
		// NSLog(@"RUN");
	}
}


- (size_t)image0BytesPerRow
{
assert(0);
	return 0; // calcDimension(map.width) * bytesPerPixel;
}

- (CGSize)imageSize
{
	return CGSizeMake(ims[0].map.width, ims[0].map.height);
}

- (void *)scratchSpace
{
assert(0);
	return 0; // map.emptyAddr;
}

- (size_t)scratchRowBytes
{
assert(0);
	return 0; // calcBytesPerRow(map.width);
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

	if(!mapP->fd) {
#warning Need a better routine here - "man tempnam" says there are race conditions. TBD
		const char *fileName = tempnam([NSTemporaryDirectory() fileSystemRepresentation], "ps");
		
		mapP->fd = open(fileName, O_CREAT | O_RDWR | O_TRUNC, 0777);
		if(mapP->fd == -1) NSLog(@"OPEN failed file %s %s", fileName, strerror(errno));
		assert(mapP->fd >= 0);

		// have to expand the file to correct size first
		lseek(mapP->fd, mapP->mappedSize - 1, SEEK_SET);
		char tmp = 0;
		write(mapP->fd, &tmp, 1);
		unlink(fileName);	// so it goes away when the fd is closed or on a crash
	}

	// NSLog(@"imageSize=%ld", imageSize);
	if(mapWholeFile && !mapP->emptyAddr) {
		mapP->emptyAddr = mmap(NULL, mapP->mappedSize, PROT_READ | PROT_WRITE, MAP_FILE | MAP_SHARED, mapP->fd, 0); //  | MAP_NOCACHE
		mapP->addr = mapP->emptyAddr + mapP->emptyTileRowSize;
		if(mapP->emptyAddr == MAP_FAILED) NSLog(@"errno=%s", strerror(errno) );
		assert(mapP->emptyAddr != MAP_FAILED);
	}
}

- (void)drawImage:(CGImageRef)image
{
	if(image) {
	assert(ims[0].map.addr);
		CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
		CGContextRef context = CGBitmapContextCreate(ims[0].map.addr, ims[0].map.width, ims[0].map.height, bitsPerComponent, ims[0].map.bytesPerRow, colorSpace, kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Little);	// BRGA flipped (little Endian)
		assert(context);
		CGRect rect = CGRectMake(0, 0, ims[0].map.width, ims[0].map.height);
		CGContextDrawImage(context, rect, image);

		CGColorSpaceRelease(colorSpace);
		CGContextRelease(context);
	}
}

- (void)run
{
	mapper *lastMap = NULL;
	mapper *currMap = NULL;

	for(size_t idx=0; idx < ZOOM_LEVELS; ++idx) {
		lastMap = currMap;	// unused first loop
		currMap = &ims[idx].map;
		if(idx) {
			[self mapMemoryForIndex:idx width:lastMap->width/2 height:lastMap->height/2];
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
//dumpMapper("Last Map", lastMap);
//dumpMapper("Curr Map", currMap);
			// Take every other pixel, every other row, to "down sample" the image. This is fast but has known problems.
			// Got a better idea? Submit a pull request.
			uint32_t *inPtr = (uint32_t *)lastMap->addr;
			uint32_t *outPtr = (uint32_t *)currMap->addr;
			for(size_t row=0; row<currMap->height; ++row) {
				char *lastInPtr = (char *)inPtr;
				char *lastOutPtr = (char *)outPtr;
				for(size_t col = 0; col < currMap->width; ++col) {

#if 0
assert(inPtr < (uint32_t *)(lastMap->addr + lastMap->mappedSize - lastMap->emptyTileRowSize) && inPtr >= (uint32_t *)(lastMap->addr));
if(!(outPtr < (uint32_t *)(currMap->addr + currMap->mappedSize - currMap->emptyTileRowSize) && outPtr >= (uint32_t *)(currMap->addr))) {
NSLog(@"col=%ld row=%ld", col, row);
}
assert(outPtr < (uint32_t *)(currMap->addr + currMap->mappedSize - currMap->emptyTileRowSize) && outPtr >= (uint32_t *)(currMap->addr));
#endif
					*outPtr++ = *inPtr;
					inPtr += 2;
				}
				inPtr = (uint32_t *)(lastInPtr + lastMap->bytesPerRow*2);
				outPtr = (uint32_t *)(lastOutPtr + currMap->bytesPerRow);
			}
#endif
			// make tiles
			tileBuilder(&ims[idx-1], NO);
		}
	}
	tileBuilder(&ims[ZOOM_LEVELS-1], NO);
NSLog(@"SUCCESS!");
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
	
	im->tileWidth = MIN(im->map.width-x, tileDimension);
	im->tileHeight = MIN(im->map.height-y, tileDimension);

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
	// Don't think caching here would help but didn't test myself.
	unsigned char *startPtr = mmap(NULL, mapSize, PROT_READ, MAP_FILE | MAP_SHARED /*| MAP_NOCACHE */, im->map.fd, (im->row*im->cols + im->col) * mapSize);

	memcpy(buffer, startPtr+position, origCount);	// blit the image, then quit. How nice is that!
	munmap(startPtr, mapSize);

	return origCount;
}

static void PhotoScrollerProviderReleaseInfoCallback (
    void *info
) {
	free(info);
}


static void tileBuilder(imageMemory *im, BOOL useMMAP)
{
	unsigned char *optr = im->map.emptyAddr;
	unsigned char *iptr = im->map.addr;
	
	//NSLog(@"tile...");
	// Now, we are going to pre-tile the image in 256x256 tiles, so we can map in contigous chunks of memory
	for(size_t row=im->row; row<im->rows; ++row) {
		unsigned char *tileIptr;
		if(useMMAP) {
			im->map.mappedSize = im->map.emptyTileRowSize*2;	// two tile rows
			im->map.emptyAddr = mmap(NULL, im->map.mappedSize, PROT_READ | PROT_WRITE, MAP_FILE | MAP_SHARED /*| MAP_NOCACHE */, im->map.fd, row*im->map.emptyTileRowSize);
			assert(im->map.emptyAddr != MAP_FAILED);
			im->map.addr = im->map.emptyAddr + im->map.emptyTileRowSize;
			
			iptr = im->map.addr;
			optr = im->map.emptyAddr;
			tileIptr = im->map.emptyAddr;
		} else {
			tileIptr = iptr;
		}
		for(int col=0; col<im->cols; ++col) {
			unsigned char *lastIptr = iptr;
			for(int i=0; i<tileDimension; ++i) {
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
		off_t properLen = im->map.mappedSize - im->map.emptyTileRowSize;
		ftruncate(im->map.fd, properLen);
		im->map.mappedSize = 0;
	}
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

	size_t unreadLen = src->data_length - src->consumed_data;
//NSLog(@"unreadLen=%ld", unreadLen);
	if((long)unreadLen <= 0) {
		return FALSE;
	}
	
	src->pub.next_input_byte = src->data + src->consumed_data;
	src->consumed_data = src->data_length;

	src->pub.bytes_in_buffer = unreadLen;
	src->start_of_stream = FALSE;
//NSLog(@"returning %ld bytes consumed=%ld this_offset=%ld", unreadLen, src->consumed_data, src->this_offset);

	return TRUE;
}

static void skip_input_data(j_decompress_ptr cinfo, long num_bytes)
{
	co_jpeg_source_mgr *src = (co_jpeg_source_mgr *)cinfo->src;

//NSLog(@"SKIPPER: %ld", num_bytes);

	if (num_bytes > 0) {
//NSLog(@"HAVE: %ld skip=%ld", src->pub.bytes_in_buffer, num_bytes);
		if(num_bytes <= src->pub.bytes_in_buffer) {
			src->pub.next_input_byte += (size_t)num_bytes;
			src->pub.bytes_in_buffer -= (size_t)num_bytes;
		} else {
			src->consumed_data			+= num_bytes - src->pub.bytes_in_buffer;
			src->pub.bytes_in_buffer	= 0;
		}
	}
}

static boolean resync_to_restart(j_decompress_ptr cinfo, int desired)
{
	co_jpeg_source_mgr *src = (co_jpeg_source_mgr *)cinfo->src;

	NSLog(@"YIKES: resync_to_restart!!!");

	src->failed = TRUE;
	return FALSE;
}

static void term_source(j_decompress_ptr cinfo)
{
}

#endif

