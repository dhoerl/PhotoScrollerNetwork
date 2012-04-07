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

#import "TiledImageBuilder-Private.h"

static void my_error_exit(j_common_ptr cinfo);

static void init_source(j_decompress_ptr cinfo);
static boolean fill_input_buffer(j_decompress_ptr cinfo);
static void skip_input_data(j_decompress_ptr cinfo, long num_bytes);
static boolean resync_to_restart(j_decompress_ptr cinfo, int desired);
static void term_source(j_decompress_ptr cinfo);

#define SCAN_LINE_MAX			1			// libjpeg docs imply you could get 4 but all I see is 1 at a time, and now the logic wants just one

/*
 * Here's the routine that will replace the standard error_exit method:
 */

#if 0
@interface TiledImageBuilder (JPEG)

- (void)decodeImageData:(NSData *)data;
- (BOOL)partialTile:(BOOL)final;

- (void)jpegInitFile:(NSString *)path;
- (void)jpegInitNetwork;
- (BOOL)jpegOutputScanLines;	// return YES when done

@end
#endif

@implementation TiledImageBuilder (JPEG)

- (void)decodeImageData:(NSData *)data
{
	assert(self.decoder == libjpegTurboDecoder);
	
	tjhandle decompressor = tjInitDecompress();

	unsigned char *jpegBuf = (unsigned char *)[data bytes];
	unsigned long jpegSize = [data length];
	int jwidth, jheight, jpegSubsamp;
	self.failed = (BOOL)tjDecompressHeader2(decompressor,
		jpegBuf,
		jpegSize,
		&jwidth,
		&jheight,
		&jpegSubsamp 
		);
	if(!self.failed) {
		{
			CGImageSourceRef imageSourcRef = CGImageSourceCreateIncremental(NULL);
			CGImageSourceUpdateData(imageSourcRef, (__bridge CFDataRef)data, NO);

			CFDictionaryRef dict = CGImageSourceCopyPropertiesAtIndex(imageSourcRef, 0, NULL);
			if(dict) {
				CFShow(dict);
				self.properties = CFBridgingRelease(dict);
			}
			CFRelease(imageSourcRef);			
		}
	
		[self mapMemoryForIndex:0 width:jwidth height:jheight];

		self.failed = (BOOL)tjDecompress2(decompressor,
			jpegBuf,
			jpegSize,
			self.ims[0].map.addr,
			jwidth,
			self.ims[0].map.bytesPerRow,
			jheight,
			TJPF_BGRA,
			TJFLAG_NOREALLOC
			);
		tjDestroy(decompressor);
	}

	if(!self.failed) [self run];
}

- (BOOL)partialTile:(BOOL)final
{
	imageMemory *im = self.ims;
	for(size_t idx=0; idx<self.zoomLevels; ++idx, ++im) {
		// got enought to tile one row now?
		if(final || (im->outLine && !(im->outLine % TILE_SIZE))) {
			size_t rows = im->rows;		// cheat
			if(!final) im->rows = im->row + 1;		// just do one tile row
			self.failed = ![self tileBuilder:im useMMAP:YES];
			if(self.failed) {
				return NO;
			}
			++im->row;
			im->rows = rows;
		}
		if(final) {
			[self truncateEmptySpace:im];
			int fd = im->map.fd;
			assert(fd != -1);
			int32_t file_size = (int32_t)lseek(fd, 0, SEEK_END);
			OSAtomicAdd32Barrier(file_size, &ubc_usage);

			if(ubc_usage > self.ubc_threshold) {
				if(OSAtomicCompareAndSwap32(0, 1, &fileFlushGroupSuspended)) {
					// NSLog(@"SUSPEND==============================================================================");
					dispatch_suspend(fileFlushQueue);
					dispatch_group_async(fileFlushGroup, fileFlushQueue, ^{ NSLog(@"unblocked!"); } );
				}
			}
			dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^
				{
					// need to make sure file is kept open til we flush - who knows what will happen otherwise
					int ret = fcntl(fd,  F_FULLFSYNC);
					if(ret == -1) NSLog(@"ERROR: failed to sync fd=%d", fd);
					OSAtomicAdd32Barrier(-file_size, &ubc_usage);
					if(ubc_usage <= self.ubc_threshold) {
						if(OSAtomicCompareAndSwap32(1, 0, &fileFlushGroupSuspended)) {
							dispatch_resume(fileFlushQueue);
						}
					}
				} );
		}
	}
	return YES;
}

- (void)jpegInitFile:(NSString *)path
{
	const char *file = [path fileSystemRepresentation];
	int jfd = open(file, O_RDONLY, 0);
	if(jfd <= 0) {
		NSLog(@"Error: failed to open input image file \"%s\" for reading (%d).\n", file, errno);
		self.failed = YES;
		return;
	}
	int ret = fcntl(jfd, F_NOCACHE, 1);	// don't clog up the system's disk cache
	if(ret == -1) {
		NSLog(@"Warning: cannot turn off cacheing for input file (errno %d).", errno);
	}
	if ((self.imageFile = fdopen(jfd, "r")) == NULL) {
		NSLog(@"Error: failed to fdopen input image file \"%s\" for reading (%d).", file, errno);
		jpeg_destroy_decompress(&self.src_mgr->cinfo);
		close(jfd);
		self.failed = YES;
		return;
	}

	/* Step 1: allocate and initialize JPEG decompression object */

	/* We set up the normal JPEG error routines, then override error_exit. */
	self.src_mgr->cinfo.err = jpeg_std_error(&self.src_mgr->jerr.pub);
	self.src_mgr->jerr.pub.error_exit = my_error_exit;
	/* Establish the setjmp return context for my_error_exit to use. */
	if (setjmp(self.src_mgr->jerr.setjmp_buffer)) {
	/* If we get here, the JPEG code has signaled an error.
	 * We need to clean up the JPEG object, close the input file, and return.
	 */
		self.failed = YES;
	} else {
		/* Now we can initialize the JPEG decompression object. */
		jpeg_create_decompress(&self.src_mgr->cinfo);

		/* Step 2: specify data source (eg, a file) */
		jpeg_stdio_src(&self.src_mgr->cinfo, self.imageFile);

		/* Step 3: read file parameters with jpeg_read_header() */
		(void) jpeg_read_header(&self.src_mgr->cinfo, TRUE);

		{
			long foo = ftell(self.imageFile);
			rewind(self.imageFile);
			NSMutableData *t = [NSMutableData dataWithLength:(NSUInteger)foo];

			size_t len = fread([t mutableBytes], foo, 1, self.imageFile);
			assert(len == 1);

			//CGImageSourceRef imageSourcRef = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
			CGImageSourceRef imageSourcRef = CGImageSourceCreateIncremental(NULL);
			CGImageSourceUpdateData(imageSourcRef, (__bridge CFDataRef)t, NO);

			CFDictionaryRef dict = CGImageSourceCopyPropertiesAtIndex(imageSourcRef, 0, NULL);
			if(dict) {
				CFShow(dict);
				self.properties = CFBridgingRelease(dict);
			}
			CFRelease(imageSourcRef);			
		}

		self.src_mgr->cinfo.out_color_space = JCS_EXT_BGRA; // (using JCS_EXT_ABGR below)
		// Tried: JCS_EXT_ABGR JCS_EXT_ARGB JCS_EXT_RGBA JCS_EXT_BGRA
		
		assert(self.src_mgr->cinfo.num_components == 3);
		assert(self.src_mgr->cinfo.image_width > 0 && self.src_mgr->cinfo.image_height > 0);
		//NSLog(@"WID=%d HEIGHT=%d", self.src_mgr->cinfo.image_width, self.src_mgr->cinfo.image_height);
		
		// Create files
		size_t scale = 1;
		for(size_t idx=0; idx<self.zoomLevels; ++idx) {
			[self mapMemoryForIndex:idx width:self.src_mgr->cinfo.image_width/scale height:self.src_mgr->cinfo.image_height/scale];
			if(self.failed) break;
			scale *= 2;
		}
		if(!self.failed) {
			(void)jpeg_start_decompress(&self.src_mgr->cinfo);
			
			while(![self jpegOutputScanLines]) ;
		}
	}
	jpeg_destroy_decompress(&self.src_mgr->cinfo);
	self.src_mgr->cinfo.src = NULL;	// dealloc tests

	fclose(self.imageFile), self.imageFile = NULL;
}

- (void)jpegInitNetwork
{
	self.src_mgr->pub.next_input_byte		= NULL;
	self.src_mgr->pub.bytes_in_buffer		= 0;
	self.src_mgr->pub.init_source			= init_source;
	self.src_mgr->pub.fill_input_buffer	= fill_input_buffer;
	self.src_mgr->pub.skip_input_data		= skip_input_data;
	self.src_mgr->pub.resync_to_restart	= resync_to_restart;
	self.src_mgr->pub.term_source			= term_source;
	
	self.src_mgr->consumed_data			= 0;
	self.src_mgr->start_of_stream			= TRUE;

	/* We set up the normal JPEG error routines, then override error_exit. */
	self.src_mgr->cinfo.err = jpeg_std_error(&self.src_mgr->jerr.pub);
	self.src_mgr->jerr.pub.error_exit = my_error_exit;
	/* Establish the setjmp return context for my_error_exit to use. */
	if (setjmp(self.src_mgr->jerr.setjmp_buffer)) {
		/* If we get here, the JPEG code has signaled an error.
		 * We need to clean up the JPEG object, close the input file, and return.
		 */
		//NSLog(@"YIKES! SETJUMP");
		self.failed = YES;
		//[self cancel];
	} else {
		/* Now we can initialize the JPEG decompression object. */
		jpeg_create_decompress(&self.src_mgr->cinfo);
		self.src_mgr->cinfo.src = &self.src_mgr->pub; // MUST be after the jpeg_create_decompress - ask me how I know this :-)
		//self.src_mgr->pub.bytes_in_buffer = 0; /* forces fill_input_buffer on first read */
		//self.src_mgr->pub.next_input_byte = NULL; /* until buffer loaded */
	}
}

- (BOOL)jpegOutputScanLines
{
	if(self.failed) return YES;

	while(self.src_mgr->cinfo.output_scanline <  self.src_mgr->cinfo.image_height) {
		unsigned char *scanPtr;
		{
			size_t tmpMapSize = self.ims[0].map.bytesPerRow;
			size_t offset = self.src_mgr->writtenLines*self.ims[0].map.bytesPerRow+self.ims[0].map.emptyTileRowSize;
			size_t over = offset % self.pageSize;
			offset -= over;
			tmpMapSize += over;
			
			self.ims[0].map.mappedSize = tmpMapSize;
			self.ims[0].map.addr = mmap(NULL, self.ims[0].map.mappedSize, PROT_READ | PROT_WRITE, MAP_FILE | MAP_SHARED, self.ims[0].map.fd, offset);	//  | MAP_NOCACHE
			if(self.ims[0].map.addr == MAP_FAILED) {
				NSLog(@"errno1=%s", strerror(errno) );
				self.failed = YES;
				self.ims[0].map.addr = NULL;
				self.ims[0].map.mappedSize = 0;
				return YES;
			}
#if MMAP_DEBUGGING == 1
			NSLog(@"MMAP[%d]: addr=%p 0x%X bytes", self.ims[0].map.fd, self.ims[0].map.addr, (NSUInteger)self.ims[0].map.mappedSize);
#endif
			scanPtr = self.ims[0].map.addr + over;
		}
	
		unsigned char *scanLines[SCAN_LINE_MAX];
		scanLines[0] = scanPtr;
		int lines = jpeg_read_scanlines(&self.src_mgr->cinfo, scanLines, SCAN_LINE_MAX);
		if(lines <= 0) {
			//int mret = msync(self.ims[0].map.addr, self.ims[0].map.mappedSize, MS_ASYNC);
			//assert(mret == 0);
			int ret = munmap(self.ims[0].map.addr, self.ims[0].map.mappedSize);
#if MMAP_DEBUGGING == 1
			NSLog(@"UNMAP[%d]: addr=%p 0x%X bytes", self.ims[0].map.fd, self.ims[0].map.addr, (NSUInteger)self.ims[0].map.mappedSize);
#endif
			assert(ret == 0);
			break;
		}
		self.ims[0].outLine = self.src_mgr->writtenLines;

		// on even numbers try to update the lower resolution scans
		if(!(self.src_mgr->writtenLines & 1)) {
			size_t scale = 2;
			imageMemory *im = &self.ims[1];
			for(size_t idx=1; idx<self.zoomLevels; ++idx, scale *= 2, ++im) {
				if(self.src_mgr->writtenLines & (scale-1)) break;

				im->outLine = self.src_mgr->writtenLines/scale;
				
				size_t tmpMapSize = im->map.bytesPerRow;
				size_t offset = im->outLine*tmpMapSize+im->map.emptyTileRowSize;
				size_t over = offset % self.pageSize;
				offset -= over;
				tmpMapSize += over;
				
				im->map.mappedSize = tmpMapSize;
				im->map.addr = mmap(NULL, im->map.mappedSize, PROT_WRITE, MAP_FILE | MAP_SHARED, im->map.fd, offset);		// write only  | MAP_NOCACHE
				if(im->map.addr == MAP_FAILED) {
					NSLog(@"errno2=%s", strerror(errno) );
					self.failed = YES;
					im->map.addr = NULL;
					im->map.mappedSize = 0;
					return YES;
				}
#if MMAP_DEBUGGING == 1
				NSLog(@"MMAP[%d]: addr=%p 0x%X bytes", im->map.fd, im->map.addr, (NSUInteger)im->map.mappedSize);
#endif
		
				uint32_t *outPtr = (uint32_t *)(im->map.addr + over);
				uint32_t *inPtr  = (uint32_t *)scanPtr;
				
				for(size_t col=0; col<self.ims[0].map.width; col += scale) {
					*outPtr++ = *inPtr;
					inPtr += scale;
				}
				//int mret = msync(im->map.addr, im->map.mappedSize, MS_ASYNC);
				//assert(mret == 0);
				int ret = munmap(im->map.addr, im->map.mappedSize);
#if MMAP_DEBUGGING == 1
				NSLog(@"UNMAP[%d]: addr=%p 0x%X bytes", im->map.fd, im->map.addr, (NSUInteger)im->map.mappedSize);
#endif
				assert(ret == 0);
			}
		}
		//int mret = msync(self.ims[0].map.addr, self.ims[0].map.mappedSize, MS_ASYNC);
		//assert(mret == 0);
		int ret = munmap(self.ims[0].map.addr, self.ims[0].map.mappedSize);
#if MMAP_DEBUGGING == 1
		NSLog(@"UNMAP[%d]: addr=%p 0x%X bytes", self.ims[0].map.fd, self.ims[0].map.addr, (NSUInteger)self.ims[0].map.mappedSize);
#endif
		assert(ret == 0);

		// tile all images as we get full rows of tiles
		if(self.ims[0].outLine && !(self.ims[0].outLine % TILE_SIZE)) {
			self.failed = ![self partialTile:NO];
			if(self.failed) break;
		}
		self.src_mgr->writtenLines += lines;
	}
	//NSLog(@"END LINES: me=%ld jpeg=%ld", self.src_mgr->writtenLines, self.src_mgr->cinfo.output_scanline);
	BOOL ret = (self.src_mgr->cinfo.output_scanline == self.src_mgr->cinfo.image_height) || self.failed;
	
	if(ret) {
		jpeg_finish_decompress(&self.src_mgr->cinfo);
		if(!self.failed) {
			assert(jpeg_input_complete(&self.src_mgr->cinfo));
			ret = [self partialTile:YES];
		}
	}
	return ret;
}

@end

@implementation TiledImageBuilder (JPEG_PUB)

- (void)jpegAdvance:(NSMutableData *)webData
{
	unsigned char *dataPtr = (unsigned char *)[webData mutableBytes];

	// mutable data bytes pointer can change invocation to invocation
	size_t diff					= self.src_mgr->pub.next_input_byte - self.src_mgr->data;
	self.src_mgr->pub.next_input_byte	= dataPtr + diff;
	self.src_mgr->data				= dataPtr;
	self.src_mgr->data_length			= [webData length];

	//NSLog(@"s1=%ld s2=%d", self.src_mgr->data_length, highWaterMark);
	if (setjmp(self.src_mgr->jerr.setjmp_buffer)) {
		/* If we get here, the JPEG code has signaled an error.
		 * We need to clean up the JPEG object, close the input file, and return.
		 */
		NSLog(@"YIKES! SETJUMP");
		self.failed = YES;
		return;
	}
	if(self.src_mgr->jpegFailed) self.failed = YES;

	if(!self.failed) {
		if(!self.src_mgr->got_header) {
			/* Step 3: read file parameters with jpeg_read_header() */
			int jret = jpeg_read_header(&self.src_mgr->cinfo, FALSE);
			if(jret == JPEG_SUSPENDED || jret != JPEG_HEADER_OK) return;

			{
				CGImageSourceRef imageSourcRef = CGImageSourceCreateIncremental(NULL);
				CGImageSourceUpdateData(imageSourcRef, (__bridge CFDataRef)webData, NO);

				CFDictionaryRef dict = CGImageSourceCopyPropertiesAtIndex(imageSourcRef, 0, NULL);
				if(dict) {
					CFShow(dict);
					self.properties = CFBridgingRelease(dict);
				}
				CFRelease(imageSourcRef);			
			}

			//NSLog(@"GOT header");
			self.src_mgr->got_header = YES;
			self.src_mgr->start_of_stream = NO;
			self.src_mgr->cinfo.out_color_space = JCS_EXT_BGRA;

			assert(self.src_mgr->cinfo.num_components == 3);
			assert(self.src_mgr->cinfo.image_width > 0 && self.src_mgr->cinfo.image_height > 0);
			//NSLog(@"WID=%d HEIGHT=%d", self.src_mgr->cinfo.image_width, self.src_mgr->cinfo.image_height);

			[self mapMemoryForIndex:0 width:self.src_mgr->cinfo.image_width height:self.src_mgr->cinfo.image_height];
#if 0
unsigned char *scratch = self.ims[0].map.emptyAddr;
//NSLog(@"Scratch=%p rowBytes=%ld", scratch, rowBytes);
for(int i=0; i<SCAN_LINE_MAX; ++i) {
	self.scanLines[i] = scratch;
	scratch += self.ims[0].map.bytesPerRow;
}
#endif
			(void)jpeg_start_decompress(&self.src_mgr->cinfo);

			// Create files
			size_t scale = 1;
			for(size_t idx=0; idx<self.zoomLevels; ++idx) {
				[self mapMemoryForIndex:idx width:self.src_mgr->cinfo.image_width/scale height:self.src_mgr->cinfo.image_height/scale];
				scale *= 2;
			}
			if(self.src_mgr->jpegFailed) self.failed = YES;
		}
		if(self.src_mgr->got_header && !self.failed) {
			[self jpegOutputScanLines];
			
			// When we consume all the data in the web buffer, safe to free it up for the system to resuse
			if(self.src_mgr->pub.bytes_in_buffer == 0) {
				self.src_mgr->deleted_data += [webData length];
				[webData setLength:0];
			}
		}
	}
}

@end

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
		if(num_bytes <= (long)src->pub.bytes_in_buffer) {
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