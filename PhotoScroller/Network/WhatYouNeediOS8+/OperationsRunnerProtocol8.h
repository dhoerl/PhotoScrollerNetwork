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
#import "ORSessionDelegate.h"	// FECWF_SESSION_DELEGATE

@class FECWF_SESSION_DELEGATE;

#ifndef FECWF_OPSRUNNER_PROTOCOL
#define FECWF_OPSRUNNER_PROTOCOL OperationsRunnerProtocol
#endif

#ifndef FECWF_OPERATIONSRUNNER
#define FECWF_OPERATIONSRUNNER OperationsRunner
#endif


@protocol FECWF_OPSRUNNER_PROTOCOL <NSObject>

// can get this on main thread (default), a specific thread you request, or anyThread
 - (void)operationFinished:(FECWF_WEBFETCHER *)op count:(NSUInteger)remainingOps;

@optional // Must be provided if you do not use the shared session

// Subclass that provides your specific values. Sent on the same thread as the first message
// causing the OperationsRunner to instantiate. The returned object is retained.
- (NSURLSessionConfiguration *)urlSessionConfig;

// Object to respond to NSURLSession delegate messages. Sent on the same thread as the first message
// causing the OperationsRunner to instantiate. The returned object is retained.
- (FECWF_SESSION_DELEGATE *)urlSessionDelegate;

@end
