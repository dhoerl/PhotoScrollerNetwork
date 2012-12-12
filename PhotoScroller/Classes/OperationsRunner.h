
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

@protocol OperationsRunnerProtocol;

typedef enum { msgDelOnMainThread, msgDelOnAnyThread, msgOnSpecificThread } msgType;

@interface OperationsRunner : NSObject
@property (nonatomic, assign) msgType msgDelOn;			// how to message delegate
@property (nonatomic, assign) NSThread *delegateThread;	// how to message delegate
@property (nonatomic, assign) BOOL noDebugMsgs;			// suppress debug messages

- (id)initWithDelegate:(id <OperationsRunnerProtocol>)del;

- (void)runOperation:(NSOperation *)op withMsg:(NSString *)msg;	// all messages must be sent from the same thread

- (NSSet *)operationsSet;
- (NSUInteger)operationsCount;

- (void)cancelOperations;
- (void)enumerateOperations:(void(^)(NSOperation *op)) b;

@end

#if 0 

// 1) Add either a property or an ivar to the implementation file
OperationsRunner *operationsRunner;

// 2) Add the protocol to the class extension interface (often in the interface file)
@interface MyClass () <OperationsRunnerProtocol>

// 3) Add the header to the implementation file
#import "OperationsRunner.h"

// 4) Add this method to the implementation file (I put it at the bottom, could go into a category too)
- (id)forwardingTargetForSelector:(SEL)sel
{
	if(
		sel == @selector(runOperation:withMsg:)	|| 
		sel == @selector(operationsSet)			|| 
		sel == @selector(operationsCount)		||
		sel == @selector(enumerateOperations:)
	) {
		if(!operationsRunner) {
			// Object only created if needed
			operationsRunner = [[OperationsRunner alloc] initWithDelegate:self];
		}
		return operationsRunner;
	} else {
		return [super forwardingTargetForSelector:sel];
	}
}

// 5) Add the cancel to your dealloc (or the whole dealloc if you have none now)
- (void)dealloc
{
	[operationsRunner cancelOperations];
}

// 6) Declare a category with these methods in the interface or implementation file (change MyClass to your class)
@interface MyClass (OperationsRunner)
- (void)runOperation:(NSOperation *)op withMsg:(NSString *)msg;

- (NSSet *)operationsSet;
- (NSUInteger)operationsCount;

- (void)enumerateOperations:(void(^)(NSOperation *op))b;

@end

#endif