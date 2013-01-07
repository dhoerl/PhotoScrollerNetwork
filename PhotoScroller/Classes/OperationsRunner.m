// NSOperation-WebFetches-MadeEasy (TM)
// Copyright (C) 2012 by David Hoerl
// 
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
// 
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
// 
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.
//

#define LOG NSLog

#import "OperationsRunner.h"

#import "OperationsRunnerProtocol.h"

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
@synthesize msgDelOn;	// default is msgDelOnMainThread
@synthesize delegateThread;
@synthesize noDebugMsgs;

- (id)initWithDelegate:(id <OperationsRunnerProtocol>)del
{
    if((self = [super init])) {
		delegate	= del;
		queue		= [NSOperationQueue new];
		operations	= [NSMutableSet setWithCapacity:10];
		operationsQueue = dispatch_queue_create("com.operationsRunner.operationsQueue", DISPATCH_QUEUE_SERIAL);
		//[queue setMaxConcurrentOperationCount:THROTTLE_NUM];	// future feature
	}
	return self;
}

- (void)dealloc
{
	[self cancelOperations];

#warning NEEDED FOR 5.1
	// dispatch_release(operationsQueue);
}

- (void)runOperation:(NSOperation *)op withMsg:(NSString *)msg
{
	dispatch_async(operationsQueue, ^
		{
			[op addObserver:self forKeyPath:@"isFinished" options:0 context:opContext];	// First, observe isFinished
			[operations addObject:op];	// Second we retain and save a reference to the operation
		} );

	[queue addOperation:op];	// Lastly, lets get going!
}

-(void)cancelOperations
{
	//LOG(@"OP cancelOperations");
	// if user waited for all data, the operation queue will be empty.
	dispatch_sync(operationsQueue, ^
		{
			//[operations enumerateObjectsUsingBlock:^(id obj, BOOL *stop) { [obj removeObserver:self forKeyPath:@"isFinished" context:opContext]; }];
			[operations enumerateObjectsUsingBlock:^(NSOperation *op, BOOL *stop)
				{
					[op removeObserver:self forKeyPath:@"isFinished" context:opContext];
				}];
			[operations removeAllObjects];
		} );

	[queue cancelAllOperations];
	[queue waitUntilAllOperationsAreFinished];
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
	
	
	// User cancelled
	if(operation.isCancelled) return;

	//LOG(@"OP RUNNER GOT A MESSAGE %d for thread %@", msgDelOn, delegateThread);

	switch(msgDelOn) {
	case msgDelOnMainThread:
		//dispatch_async(dispatch_get_main_queue(), ^{ [delegate operationFinished:operation]; } );
		[self performSelectorOnMainThread:@selector(_operationFinished:) withObject:operation waitUntilDone:NO];
		break;

	case msgDelOnAnyThread:
		[self _operationFinished:operation];
		break;
	
	case msgOnSpecificThread:
		[self performSelector:@selector(_operationFinished:) onThread:delegateThread withObject:operation waitUntilDone:NO];
		break;
	}
}

- (void)operationFinished:(NSOperation *)op
{
	assert(!"Should never happen!");
}

- (void)_operationFinished:(NSOperation *)op
{
	dispatch_sync(operationsQueue, ^
		{
			// Need to see if while this sat in the designated thread, it was cancelled
			BOOL notCancelled = [operations containsObject:op];
			if(notCancelled) {
				// If we are in the queue, then we have to remove our stuff, and in all cases make sure no KVO enabled
				[op removeObserver:self forKeyPath:@"isFinished" context:opContext];
				[operations removeObject:op];
			}
		} );
	[delegate operationFinished:op];
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
			[self operationDidFinish:op];
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
