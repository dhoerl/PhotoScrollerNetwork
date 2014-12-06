//
// FastEasyConcurrentWebFetches (TM)
// Copyright (C) 2012-2013 by David Hoerl
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

#import "WebFetcher8.h"

#if defined(UNIT_TESTING)
#import "ORSessionDelegate.h"
#endif

#if 0	// 0 == no debug, 1 == lots of mesages
#define LOG(...) NSLog(__VA_ARGS__)
#else
#define LOG(...)
#endif

// If you have some means to report progress
#define PROGRESS_OFFSET 0.25f
#define PROGRESS_UPDATE(x) ( ((x)*.75f)/(responseLength) + PROGRESS_OFFSET)

@interface FECWF_WEBFETCHER ()
@property (atomic, assign, readwrite) BOOL isCancelled;
@property (atomic, assign, readwrite) BOOL isExecuting;
@property (atomic, assign, readwrite) BOOL isFinished;

@end

@implementation FECWF_WEBFETCHER
{
	NSUInteger responseLength;
}

+ (void)initialize
{
	NSURLCache *cache = [NSURLCache sharedURLCache];

	[cache setDiskCapacity:0];
	[cache setMemoryCapacity:0];
}

+ (BOOL)persistentConnection { return YES; }
+ (NSUInteger)timeout { return 60; }
+ (BOOL)printDebugging { return NO; }

// Only sent by OperationsRunner
- (BOOL)_OR_cancel:(NSUInteger)millisecondDelay
{
	BOOL ret = !self.isCancelled;
	if(ret) {
		[self cancel];
	}
	return YES;
}

- (void)cancel
{
	LOG(@"%@: got CANCEL", self);
	self.isFinished = YES;
	self.isCancelled = YES;
	[self.task cancel], self.task = nil;
}

- (NSMutableURLRequest *)setup
{
	Class class = [self class];

#if defined(UNIT_TESTING)	// lets us force errors in code
	self.urlStr = @"http://www.apple.com/";
#endif

	NSURL *url = [NSURL URLWithString:_urlStr];
	NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:[class timeout]];
	if([class persistentConnection]) {
		[request setValue:@"Keep-Alive" forHTTPHeaderField:@"Connection"];
		[request setHTTPShouldUsePipelining:YES];
	}
	return request;
}

- (BOOL)start:(NSMutableURLRequest *)request __attribute__((unused))
{
	NSURLSessionTask *task = _task;	// weak to strong to avoid warnings (and its the right thing to do)
	self.isExecuting = YES;

#ifndef NDEBUG
	//LOG(@"%@ Start", self.runMessage);
	if([[self class] printDebugging]) LOG(@"URLSTRING1=%@", [task.originalRequest URL]);
#endif
	assert(task.originalRequest);


#if ! defined(UNIT_TESTING)	// lets us force errors in code
	[task resume];
#else
	switch(self.forceAction) {
	case forceSuccess:
	{
		__weak __typeof__(self) weakSelf = self;
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^
			{
				__typeof__(self) strongSelf = weakSelf;
				strongSelf.htmlStatus = 200;
				strongSelf.webData = [NSMutableData dataWithCapacity:256];
				[(FECWF_SESSION_DELEGATE *)strongSelf.urlSession.delegate URLSession:self.urlSession task:self.task didCompleteWithError:nil];
			} );
		return YES;
	}	break;

	case forceFailure:
	{
		__weak __typeof__(self) weakSelf = self;
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^
			{
				__typeof__(self) strongSelf = weakSelf;
				strongSelf.htmlStatus = 400;
				NSString *msg = [NSString stringWithFormat:@"Network Error %tu",  strongSelf.htmlStatus];
				NSError *err = = [NSError errorWithDomain:@"com.dfh.orsd" code:strongSelf.htmlStatus userInfo:@{NSLocalizedDescriptionKey : msg}];
				[(FECWF_SESSION_DELEGATE *)strongSelf.urlSession.delegate URLSession:self.urlSession task:self.task didCompleteWithError:err];
			} );
		return YES;
	} break;
	
	case forceRetry:
	{
		__weak __typeof__(self) weakSelf = self;
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^
			{
				__typeof__(self) strongSelf = weakSelf;
				strongSelf.htmlStatus = 400;
				NSError *err = [NSError errorWithDomain:@"NSURLErrorDomain" code:-1001 userInfo:@{ NSLocalizedDescriptionKey : @"timed out" }];	// Timeout
				[(FECWF_SESSION_DELEGATE *)strongSelf.urlSession.delegate URLSession:self.urlSession task:self.task didCompleteWithError:err];
			} );
		return YES;
	} break;

	default:
		break;
	}
	return YES;
#endif

	return self.task ? YES : NO;
}

- (void)completed // subclasses to override then finally call super
{
#ifndef NDEBUG
	if([[self class] printDebugging]) LOG(@"WF: completed");
#endif
	// we need a tad delay to let the completed return before the KVO message kicks in
//LOG(@"WF: completed");
	[self finish];
}

- (void)failed // subclasses to override then finally call super
{
#ifndef NDEBUG
	if([[self class] printDebugging]) LOG(@"WF: failed");
#endif

//LOG(@"WF: failed");
	[self finish];
}

- (void)finish
{
#ifndef NDEBUG
	if([[self class] printDebugging]) LOG(@"WF: finish");
#endif
//LOG(@"WF: finish");
	self.isFinished = YES;
	self.isExecuting = NO;
}

- (void)dealloc
{
#ifndef NDEBUG
	if([[self class] printDebugging]) LOG(@"%@ Dealloc: isExecuting=%d isFinished=%d isCancelled=%d", _runMessage, _isExecuting, _isFinished, _isCancelled);
#endif
#ifdef VERIFY_DEALLOC
	if(_deallocBlock) {
		_deallocBlock();
	}
#endif
}

- (NSString *)description
{
	return [NSString stringWithFormat:@"WF[\"%@\"] isEx=%d ixFin=%d isCan=%d", _runMessage, _isExecuting, _isFinished, _isCancelled];
}

@end
