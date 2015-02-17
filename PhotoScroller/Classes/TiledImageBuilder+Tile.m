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

#import "TiledImageBuilder-Private.h"

#define LOG NSLog

@implementation TiledImageBuilder (Tile)

- (BOOL)tileBuilder:(imageMemory *)im useMMAP:(BOOL )useMMAP
{
	unsigned char *optr = im->map.emptyAddr;
	unsigned char *iptr = im->map.addr;
	
	// LOG(@"tile...");
	// Now, we are going to pre-tile the image in 256x256 tiles, so we can map in contigous chunks of memory
	for(size_t row=im->row; row<im->rows; ++row) {
		unsigned char *tileIptr;
		if(useMMAP) {
			im->map.mappedSize = im->map.emptyTileRowSize*2;	// two tile rows
			im->map.emptyAddr = mmap(NULL, im->map.mappedSize, PROT_READ | PROT_WRITE, MAP_FILE | MAP_SHARED, im->map.fd, row*im->map.emptyTileRowSize);  /*| MAP_NOCACHE */
			if(im->map.emptyAddr == MAP_FAILED) return NO;
#if MMAP_DEBUGGING == 1
			LOG(@"MMAP[%d]: addr=%p 0x%X bytes", im->map.fd, im->map.emptyAddr, (NSUInteger)im->map.mappedSize);
#endif	
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
			//int mret = msync(im->map.emptyAddr, im->map.mappedSize, MS_ASYNC);
			//assert(mret == 0);
			int ret = munmap(im->map.emptyAddr, im->map.mappedSize);
#if MMAP_DEBUGGING == 1
			LOG(@"UNMAP[%d]: addr=%p 0x%X bytes", im->map.fd, im->map.emptyAddr, (NSUInteger)im->map.mappedSize);
#endif
			assert(ret == 0);
			if(ret) self.failed = YES;
		} else {
			iptr = tileIptr + im->map.emptyTileRowSize;
		}
	}
	//LOG(@"...tile");

	if(!useMMAP) {
		// OK we're done with this memory now
		//int mret = msync(im->map.emptyAddr, im->map.mappedSize, MS_ASYNC);
		//assert(mret == 0);
		int ret = munmap(im->map.emptyAddr, im->map.mappedSize);
#if MMAP_DEBUGGING == 1
		LOG(@"UNMAP[%d]: addr=%p 0x%X bytes", im->map.fd, im->map.emptyAddr, (NSUInteger)im->map.mappedSize);
#endif
		assert(ret==0);
		if(ret) self.failed = YES;

		// don't need the scratch space now
		[self truncateEmptySpace:im];
	
		/*
		 * Best place I could find to flush dirty blocks to disk. Will flush whole file if doing full image decodes,
		 * but only partial files for incremental loader
		 */
		int fd = im->map.fd;
		assert(fd != -1);
		int32_t file_size = (int32_t)lseek(fd, 0, SEEK_END);
		OSAtomicAdd32Barrier(file_size, &ubc_usage);
		
		if(ubc_usage > self.ubc_threshold) {
			if(OSAtomicCompareAndSwap32(0, 1, &fileFlushGroupSuspended)) {
				// LOG(@"SUSPEND==========================================================usage=%d thresh=%d", ubc_usage, ubc_thresh);
				dispatch_suspend([TiledImageBuilder fileFlushQueue]);
				dispatch_group_async([TiledImageBuilder fileFlushGroup], [TiledImageBuilder fileFlushQueue], ^{ LOG(@"unblocked!"); } );
			}
[self freeMemory:[NSString stringWithFormat:@"Exceeded threshold: usage=%u thresh=%u", ubc_usage, self.ubc_threshold]];
		}
else [self freeMemory:[NSString stringWithFormat:@"Under threshold: usage=%u thresh=%u", ubc_usage, self.ubc_threshold]];

		dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^
			{
				// need to make sure file is kept open til we flush - who knows what will happen otherwise
				int ret2 = fcntl(fd,  F_FULLFSYNC);
				if(ret2 == -1) LOG(@"ERROR: failed to sync fd=%d", fd);
				OSAtomicAdd32Barrier(-file_size, &ubc_usage);				
				if(ubc_usage <= self.ubc_threshold) {
					if(OSAtomicCompareAndSwap32(1, 0, &fileFlushGroupSuspended)) {
						dispatch_resume([TiledImageBuilder fileFlushQueue]);
					}
				}
			} );

	}
	
	return YES;
}

- (void )truncateEmptySpace:(imageMemory *)im
{
	// don't need the scratch space now
	off_t properLen = lseek(im->map.fd, 0, SEEK_END) - im->map.emptyTileRowSize;
	int ret = ftruncate(im->map.fd, properLen);
	if(ret) {
		LOG(@"Failed to truncate file!");
		self.failed = YES;
	}
	im->map.mappedSize = 0;	// force errors if someone tries to use mmap now
}

- (void)createLevelsAndTile
{
	mapper *lastMap = NULL;
	mapper *currMap = NULL;

	for(NSUInteger idx=0; idx < self.zoomLevels; ++idx) {
		lastMap = currMap;	// unused first loop
		currMap = &self.ims[idx].map;
		if(idx) {
			[self mapMemoryForIndex:idx width:lastMap->width/2 height:lastMap->height/2];
			if(self.failed) return;

//dumpIMS("RUN", &ims[idx]);

#if USE_VIMAGE == 1
#error This code must be reconciled with that below due to orientation changes
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
			madvise(lastMap->addr, lastMap->mappedSize-lastMap->emptyTileRowSize, MADV_SEQUENTIAL);
			madvise(currMap->addr, currMap->mappedSize-currMap->emptyTileRowSize, MADV_SEQUENTIAL);

			{
				size_t oddColOffset = 0;
				size_t oddRowOffset = 0;
				if(lastMap->col0offset && (lastMap->width & 1)) oddColOffset = bytesPerPixel;			// so rightmost pixels the same
				if(lastMap->row0offset && (lastMap->height & 1)) oddRowOffset = lastMap->bytesPerRow;	// so we use the bottom row
				
				uint32_t *inPtr = (uint32_t *)(lastMap->addr + lastMap->col0offset + oddColOffset + lastMap->row0offset*lastMap->bytesPerRow + oddRowOffset);
				uint32_t *outPtr = (uint32_t *)(currMap->addr + currMap-> col0offset + currMap->row0offset*currMap->bytesPerRow);
				for(size_t row=0; row<currMap->height; ++row) {
					unsigned char *lastInPtr = (unsigned char *)inPtr;
					unsigned char *lastOutPtr = (unsigned char *)outPtr;
					for(size_t col = 0; col < currMap->width; ++col) {
						*outPtr++ = *inPtr;
						inPtr += 2;
					}
					inPtr = (uint32_t *)(lastInPtr + lastMap->bytesPerRow*2);
					outPtr = (uint32_t *)(lastOutPtr + currMap->bytesPerRow);
				}
			}

			madvise(lastMap->addr, lastMap->mappedSize-lastMap->emptyTileRowSize, MADV_FREE);
			madvise(currMap->addr, currMap->mappedSize-currMap->emptyTileRowSize, MADV_FREE);
#endif
			// make tiles
			BOOL ret = [self tileBuilder:&self.ims[idx-1] useMMAP:NO];
			if(!ret) goto eRR;
		}
	}
	assert(self.zoomLevels);
	self.failed = ![self tileBuilder:&self.ims[self.zoomLevels-1] useMMAP:NO];
	return;
	
  eRR:
	self.failed = YES;
	return;
}

@end
