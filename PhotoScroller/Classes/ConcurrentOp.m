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

#import "ConcurrentOp.h"

#import "TiledImageBuilder.h"

#if ! __has_feature(objc_arc)
#error THIS CODE MUST BE COMPILED WITH ARC ENABLED!
#endif

@interface ConcurrentOp ()
@property (nonatomic, assign) BOOL executing, finished;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) NSURLConnection *connection;

- (BOOL)setup;
- (void)timer:(NSTimer *)timer;

@end

@interface ConcurrentOp (NSURLConnectionDelegate)

@end

@implementation ConcurrentOp
@synthesize index;
@dynamic milliSeconds;
@synthesize thread;
@synthesize executing, finished;
@synthesize timer;
@synthesize connection;
@synthesize webData;
@synthesize url;
@synthesize imageBuilder;
@synthesize decoder;
@synthesize orientation;
@synthesize zoomLevels;

- (BOOL)isConcurrent { return YES; }
- (BOOL)isExecuting { return executing; }
- (BOOL)isFinished { return finished; }

- (void)start
{
	if([self isCancelled]) {
		//LTLog(@"OP: cancelled before I even started!");
		[self willChangeValueForKey:@"isFinished"];
		finished = YES;
		[self didChangeValueForKey:@"isFinished"];
		return;
	}
#ifndef NDEBUG
	//LTLog(@"OP: start");
#endif
	@autoreleasepool
	{
		self.thread	= [NSThread currentThread];	// do this first, to enable future messaging
		// makes runloop functional
		self.timer	= [NSTimer scheduledTimerWithTimeInterval:60*60 target:self selector:@selector(timer:) userInfo:nil repeats:NO];
		
		[self willChangeValueForKey:@"isExecuting"];
		executing = YES;
		[self didChangeValueForKey:@"isExecuting"];
			
		BOOL allOK = [self setup];

		if(allOK) {
			while(![self isFinished]) {
				assert([NSThread currentThread] == thread);
				//BOOL ret = 
				[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]];
				//assert(ret && "first assert"); // could remove this - its here to convince myself all is well
			}
			//LTLog(@"OP: finished - %@", [self isCancelled] ? @"was canceled" : @"normal completion");
		} else {
			[self finish];

#ifndef NDEBUG
			//LTLog(@"OP: finished - setup failed");
#endif
		}
		// Objects retaining us
		[timer invalidate], self.timer = nil;
		[connection cancel], self.connection = nil;
	}
}

- (void)dealloc
{
	//LTLog(@"OP: dealloc"); // didn't always see this message :-)

	[timer invalidate], timer = nil;
	[connection cancel], connection = nil;
}

- (BOOL)setup
{
#ifndef NDEBUG
	//LTLog(@"OP: setup");
#endif
	NSURLRequest *request = [NSURLRequest requestWithURL:url];
	self.connection =  [[NSURLConnection alloc] initWithRequest:request delegate:self];

	[thread setName:@"ConcurrentOp"];
	return YES;
}

- (void)runConnection
{
	[connection performSelector:@selector(start) onThread:thread withObject:nil waitUntilDone:NO];
}

- (void)cancel
{
	[super cancel];
	
	[connection cancel];

	if([self isExecuting]) {
		[self performSelector:@selector(finish) onThread:thread withObject:nil waitUntilDone:NO];
	}
}

- (void)finish
{
	// This order per the Concurrency Guide - some authors switch the didChangeValueForKey order.
	[self willChangeValueForKey:@"isFinished"];
	[self willChangeValueForKey:@"isExecuting"];

	executing = NO;
	finished = YES;

	[self didChangeValueForKey:@"isExecuting"];
    [self didChangeValueForKey:@"isFinished"];
}

- (void)timer:(NSTimer *)timer
{
}

- (uint32_t)milliSeconds
{
	return imageBuilder.milliSeconds;
}

@end

@implementation ConcurrentOp (NSURLConnectionDelegate)

- (void)connection:(NSURLConnection *)conn didReceiveResponse:(NSURLResponse *)response
{	
	if([super isCancelled]) {
		[connection cancel];
		return;
	}

	// Useful way to get maximum data, but not needed here
	//NSUInteger responseLength = response.expectedContentLength == NSURLResponseUnknownLength ? 1024*1000 : response.expectedContentLength;

#ifndef NDEBUG
	//LTLog(@"ConcurrentOp: response=%@ len=%lu", response, (unsigned long)responseLength);
#endif

#ifdef LIBJPEG
	if(decoder == libjpegIncremental) {
		// data may build up - the decoder consumes large chunks infrequently, we can then release the older not needed data
		self.webData = [NSMutableData dataWithCapacity:10000];	// appears to be about right
	}
#endif
	
	imageBuilder = [[TiledImageBuilder alloc] initForNetworkDownloadWithDecoder:decoder size:CGSizeMake(320, 320) orientation:orientation];
}

- (void)connection:(NSURLConnection *)conn didReceiveData:(NSData *)data
{
#ifndef NDEBUG
	//NSLog(@"WEB SERVICE: got Data len=%u cancelled=%d", [data length], [super isCancelled]);
#endif
	if([super isCancelled]) {
		[connection cancel];
		return;
	}
#ifdef LIBJPEG
	if(decoder == libjpegIncremental) {
		[webData appendData:data];
		[imageBuilder jpegAdvance:webData];
	} else
#endif
	{
		[imageBuilder appendToImageFile:data];
	}
}

- (void)connection:(NSURLConnection *)conn didFailWithError:(NSError *)error
{
#ifndef NDEBUG
	NSLog(@"ConcurrentOp: error: %@", [error description]);
#endif
	self.webData = nil;
	self.imageBuilder = nil;

    [connection cancel];

	[self finish];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)conn
{

	if([super isCancelled]) {
		[connection cancel];
		return;
	}
#ifndef NDEBUG
	//NSLog(@"ConcurrentOp FINISHED LOADING WITH Received Bytes: %u", [webData length]);
#endif

	if(decoder == libjpegIncremental) {
		if(imageBuilder.failed) {
			NSLog(@"FAILED!");
			imageBuilder = nil;
		}
	} else {
		[imageBuilder dataFinished];
		//[imageBuilder decodeImageData:webData];
	}
	[self finish];
}

@end
