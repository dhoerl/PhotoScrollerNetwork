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

#define LOG		NSLog

#import "OperationsRunner.h"

#define kIsFinished		@"isFinished"	// NSOperations
#define kIsExecuting	@"isExecuting"	// NSOperations

static char *opContext = "opContext";

@interface OperationsRunner ()

- (void)operationDidFinish:(NSOperation *)operation;

@end

@implementation OperationsRunner
{
	NSOperationQueue *queue;
	NSMutableSet *operations;
	dispatch_queue_t operationsQueue;
	__weak id <OperationsRunnerProtocol> delegate;
}
@synthesize anyThreadOK;
@synthesize noDebugMsgs;

- (id)initWithDelegate:(id <OperationsRunnerProtocol>)del
{
    if((self = [super init])) {
		delegate	= del;
		queue		= [NSOperationQueue new];
		operations	= [NSMutableSet setWithCapacity:10];
		operationsQueue = dispatch_queue_create("com.lot18.operationsQueue", DISPATCH_QUEUE_CONCURRENT);
	}
	return self;
}

- (void)dealloc
{
	[self cancelOperations];
}

- (void)runOperation:(NSOperation *)op withMsg:(NSString *)msg
{
#ifndef NDEBUG
	if(!noDebugMsgs) LOG(@"Run Operation: %@", msg);
#endif

	[op addObserver:self forKeyPath:kIsFinished options:0 context:opContext];	// First, observe isFinished
	dispatch_barrier_async(operationsQueue, ^
		{
			[operations addObject:op];	// Second we retain and save a reference to the operation
		} );

	[queue addOperation:op];	// Lastly, lets get going!
}

-(void)cancelOperations
{
	//LOG(@"OP cancelOperations");

	// if user waited for all data, the operation queue will be empty.
	dispatch_barrier_sync(operationsQueue, ^
		{
			[operations enumerateObjectsUsingBlock:^(id obj, BOOL *stop) { [obj removeObserver:self forKeyPath:@"isFinished"]; }];   
			[operations removeAllObjects];
		} );

	[queue cancelAllOperations];
	[queue waitUntilAllOperationsAreFinished];

	delegate = nil;
}

- (void)enumerateOperations:(void(^)(NSOperation *op))b
{
	//LOG(@"OP enumerateOperations");
	dispatch_sync(operationsQueue, ^
		{
			[operations enumerateObjectsUsingBlock:^(NSOperation *operation, BOOL *stop)
				{
					b(operation);
				}];   
		} );
}

- (void)operationDidFinish:(NSOperation *)operation
{
	//LOG(@"OP operationDidFinish");

	// if you cancel the operation when its in the set, will hit this case
	// since observeValueForKeyPath: queues this message on the main thread
	__block BOOL containsObject;
	dispatch_sync(operationsQueue, ^
		{
            containsObject = [operations containsObject:operation];
        } );
	if(!containsObject) return;
	
	// If we are in the queue, then we have to both remove our observation and queue membership
	[operation removeObserver:self forKeyPath:@"isFinished"];
	dispatch_barrier_async(operationsQueue, ^
		{
			[operations removeObject:operation];
		} );
	
	// User cancelled
	if(operation.isCancelled) return;
	
	// We either failed in setup or succeeded doing something.
	[delegate operationFinished:operation];
}

// Done on the main thread
- (void)operationFinished:(NSOperation *)op
{
	assert(!"Should never happen!");
}

- (NSSet *)operationsSet
{
	__block NSSet *set;
	dispatch_sync(operationsQueue, ^
		{
            set = [NSSet setWithSet:operations];
        } );
	return set;
}
- (NSUInteger)operationsCount
{
	__block NSUInteger count;
	dispatch_sync(operationsQueue, ^
		{
            count = [operations count];
        } );
	return count;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
	//LOT(@"observeValueForKeyPath %s %@", context, self);
	NSOperation *op = object;
	if(context == opContext) {
		//LOG(@"KVO: isFinished=%d %@ op=%@", op.isFinished, NSStringFromClass([self class]), NSStringFromClass([op class]));
		if(op.isFinished == YES) {
			// we get this on the operation's thread
			// [self performSelectorOnMainThread:@selector(operationDidFinish:) withObject:op waitUntilDone:YES];
			if(anyThreadOK) {
				[self operationDidFinish:op];
			} else {
				dispatch_async(dispatch_get_main_queue(), ^{ [self operationDidFinish:op]; } );
			}
			//LOG(@"DONE!!!");
		} else {
			//LOG(@"NSOperation starting to RUN!!!");
		}
	} else {
		if([super respondsToSelector:@selector(observeValueForKeyPath:ofObject:change:context:)])
			[super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
	}
}

@end
