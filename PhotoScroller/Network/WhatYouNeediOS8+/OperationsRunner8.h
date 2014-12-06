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

#import <objc/runtime.h>
#import <Foundation/Foundation.h>

#import "OperationsRunnerProtocol8.h"

@protocol FECWF_OPSRUNNER_PROTOCOL;
@class  FECWF_SESSION_DELEGATE;

// DEFAULTS
#define DEFAULT_MAX_OPS					4						// Apple suggests a number like 4 for iOS, would not exceed 10, as each is a NSThread
#define DEFAULT_PRIORITY	DISPATCH_QUEUE_PRIORITY_DEFAULT		// both dispatch queues use this
#define DEFAULT_MILLI_SEC_CANCEL_DELAY	100

// how do you want the return message delivered
typedef enum { msgDelOnMainThread=0, msgDelOnAnyThread, msgOnSpecificThread, msgOnSpecificQueue } msgType;

@interface FECWF_OPERATIONSRUNNER : NSObject
@property (nonatomic, assign) msgType msgDelOn;					// how to message delegate, defaults to MainThread
@property (nonatomic, weak) NSThread *delegateThread;			// where to message delegate, sets msgDelOn->msgOnSpecificThread
@property (nonatomic, assign) dispatch_queue_t delegateQueue;	// where to message delegate, sets msgDelOn->msgOnSpecificQueue
@property (nonatomic, assign) dispatch_group_t delegateGroup;	// if set, use dispatch_group_async()
@property (nonatomic, assign) BOOL noDebugMsgs;					// suppress debug messages
@property (nonatomic, assign) long priority;					// targets the internal GCD queue doleing out the operations
@property (nonatomic, assign) NSUInteger maxOps;				// set the NSOperationQueue's maxConcurrentOperationCount
@property (nonatomic, assign) NSUInteger mSecCancelDelay;		// set the NSOperationQueue's maxConcurrentOperationCount

// Optionally share one session between every instance of OperationsRunner (if you create this all future operations will use it
+ (void)createSharedSessionWithConfiguration:(NSURLSessionConfiguration *)config delegate:(id <NSURLSessionDataDelegate>) delegate;

// Given the task, get the fetcher (needed by the Session Delegate)
+ (FECWF_WEBFETCHER *)fetcherForTask:(NSURLSessionTask *)task;

// These methods are for direct messaging. The reason cancelOperations is here is to prevent the creation of an object, just to cancel it.
- (id)initWithDelegate:(id <FECWF_OPSRUNNER_PROTOCOL>)del;		// designated initializer

- (void)runOperation:(FECWF_WEBFETCHER *)op withMsg:(NSString *)msg;	// to submit an operation
- (BOOL)runOperations:(NSOrderedSet *)operations;	// Set of FECWF_WEBFETCHER objects with their runMessage set (or not)
- (NSUInteger)operationsCount;						// returns the total number of outstanding operations, use wisely, some finished ops already queued count until delivered
- (BOOL)cancelOperations;							// stop all work, will not get any more delegate calls after it returns, returns YES if everything torn down properly

// Uncommon in user code
- (BOOL)restartOperations;							// restart things (primarily for Unit Testing
- (BOOL)disposeOperations;							// dealloc the OperationsRunner (only needed for special cases where you really want to get rid of all helper objects)

@end

#if 0 

// 1) Set these by changing "My" to some previx these if using OperationsRunner in a library (to avoid collisions with app usage).
// In Swift, you can set them in the Project Settings, Pre-Processor Macros area. In Swift code itself, use the value not the Macro.

	#define FECWF_WEBFETCHER				MyWebFetcher
	#define FECWF_OPERATIONSRUNNER			MyOperationsRunner
	#define FECWF_OPSRUNNER_PROTOCOL		MyOperationsRunnerProtocol
	#define FECWF_SESSION_DELEGATE			MySessionDelegate

	The defaults are:

	#define FECWF_WEBFETCHER				ORWebFetcher
	#define FECWF_OPERATIONSRUNNER			OperationsRunner
	#define FECWF_OPSRUNNER_PROTOCOL		OperationsRunnerProtocol
	#define FECWF_SESSION_DELEGATE			ORSessionDelegate

// 2) Add the protocol to the class extension interface (often in the implementation file)
	@interface MyClass () <FECWF_OPSRUNNER_PROTOCOL> // In Swift, use the value of the Macro, ie OperationsRunnerProtocol


// 3) Add the header to the implementation file (or to your bridging header in Swift)
	#import "OperationsRunner8.h"
	#import "WebFetche87.h"

// 4) Add an ivar to your class
	FECWF_OPERATIONSRUNNER	*opRunner; // You'll need to either create it immediately, or test a flag on all usages

   	// in Swift this can be lazily instantiated. Technique from mmalc: https://devforums.apple.com/message/979742#979742
	lazy var opRunner: OperationsRunner = { self.isOpRunner = true; return OperationsRunner(delegate: self); }()
	var isOpRunner = false


// 5) In "dealloc" send the object "cancelAllOperations", in Swift test if the optional var is set, if so send it the same message in "deinit"
	- (void)dealloc { ... ; [opRunner cancelAllOperations]; }

	// In Swioft
	deinit {
		if isOpRunner { opr.cancelAllOperations() }
	}

// 6) Either implement the two delegate methods that return a configuration and delegate object, or
//    create one for your app/project in some class initializer, or in appDelegate when you launch, or in Swift use a class function
//    called by appDelegate.

	+ (void)initialize // AppDelegate, someother class
	{
		...
		
		MySessionDelegate *del = [MySessionDelegate new];	// URSessionDelegate subclass
		
		NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
		config.URLCache = nil;
		config.HTTPShouldSetCookies = YES;
		config.HTTPShouldUsePipelining = YES;
		...

		[FECWF_OPERATIONSRUNNER createSharedSessionWithConfiguration:config delegate:del];
	}

	// In Swift, you can use the delegate methods...
	func urlSessionConfig () -> NSURLSessionConfiguration {
		let config = NSURLSessionConfiguration.defaultSessionConfiguration();
		config.URLCache = nil
		config.HTTPShouldSetCookies = true
		config.HTTPShouldUsePipelining = true
	}
	func urlSessionDelegate () -> SessionDelegate {
		return SessionDelegate()
	}

	// ... or you can provide a shared delegate somewhere

    someFunc {
        ...

		let del = SessionDelegate()	// URSessionDelegate subclass
	
		let config = NSURLSessionConfiguration.defaultSessionConfiguration();
		config.URLCache = nil
		config.HTTPShouldSetCookies = true
		config.HTTPShouldUsePipelining = true;

		OperationsRunner.createSharedSessionWithConfiguration(config, delegate:del)
		
		...
	}

#endif
