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

#import "ORSessionDelegate.h"

#define CANCEL_ON_HTML_STATUS	1	// if not 200, then cancel. When set to 0, cancel only for >= 500.
									// Set to 0 to see if any data returned

#define DEBUGGING				0	// 0 == no debug, 1 == lots of mesages



#if DEBUGGING == 1
#define LOG(...) NSLog(__VA_ARGS__)
#else
#define LOG(...)
#endif

@implementation FECWF_SESSION_DELEGATE

// Overriding the super methods

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
                     willPerformHTTPRedirection:(NSHTTPURLResponse *)response
                                     newRequest:(NSURLRequest *)request
                              completionHandler:(void (^)(NSURLRequest *))completionHandler
{
	FECWF_WEBFETCHER *fetcher = [FECWF_OPERATIONSRUNNER fetcherForTask:task];

	LOG(@"YIKES: \"URLSession:willPerformHTTPRedirection:\"  resp=%@ newReq=%@ task=%@", response, request, fetcher.runMessage);

	if([[fetcher class] printDebugging]) LOG(@"Connection:willSendRequest %@ redirect %@", request, response);
	
	if(response) {
		LOG(@"RESP: status=%tu headers=%@", [response statusCode], [response allHeaderFields]);
	}
	completionHandler(request);
}


- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask
                                 didReceiveResponse:(NSURLResponse *)response
                                  completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler
{
	FECWF_WEBFETCHER *fetcher = [FECWF_OPERATIONSRUNNER fetcherForTask:dataTask];
LOG(@"YIKES: \"URLSession:didReceiveResponse:task:...\" fetcher=%@ response=%@", fetcher.runMessage, response);

	if(fetcher.isCancelled) {
		completionHandler(NSURLSessionResponseCancel);
#ifndef NDEBUG
		if([[self class] printDebugging]) LOG(@"Connection:cancelled!");
#endif
		return;
	}

	assert([response isKindOfClass:[NSHTTPURLResponse class]]);
	NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
	
	fetcher.htmlStatus = [httpResponse statusCode];
	BOOL err;
#if CANCEL_ON_HTML_STATUS
	err = fetcher.htmlStatus != 200;
#else
	err = fetcher.htmlStatus >= 500;
#endif
	if(err) {
		LOG(@"ERROR: server Response code %tu url=%@", fetcher.htmlStatus, fetcher.urlStr);
		NSString *msg = [NSString stringWithFormat:@"Network Error %zd %@",  fetcher.htmlStatus,[NSHTTPURLResponse localizedStringForStatusCode: fetcher.htmlStatus]];
		fetcher.error = [NSError errorWithDomain:@"com.dfh.orsd" code:fetcher.htmlStatus userInfo:@{NSLocalizedDescriptionKey : msg}];
		LOG(@"ERR: %@", fetcher.error);
	}

	NSUInteger responseLength = response.expectedContentLength == NSURLResponseUnknownLength ? 1024 : (NSUInteger)response.expectedContentLength;
#ifndef NDEBUG
	if([[fetcher class] printDebugging]) LOG(@"Connection:didReceiveResponse: response=%@ len=%tu", response, responseLength);
#endif

	// Must do this here, since we can get an error and still get data!
	fetcher.totalReceiveSize = responseLength;
	// LOG(@"EXPECT SIZE %u", responseLength);
	fetcher.currentReceiveSize = 0;
	dispatch_queue_t q	= dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
	fetcher.webData		= (NSData *)dispatch_data_create(NULL, 0, q, ^{});

	if(fetcher.error) {
		LOG(@"Cancel due to error: %@", fetcher.error);
		completionHandler(NSURLSessionResponseCancel);
	} else {
		//LOG(@"Proceed no error");
		completionHandler(NSURLSessionResponseAllow);
	}
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
                           didCompleteWithError:(NSError *)error
{
	FECWF_WEBFETCHER *fetcher = [FECWF_OPERATIONSRUNNER fetcherForTask:task];
	if(fetcher.isCancelled) {
		return;
	}

	if(error && !fetcher.error) {
		fetcher.error = error;
	}
	if(fetcher.error) {
		fetcher.errorMessage = [error localizedDescription];
	}
	
	LOG(@"YIKES: \"URLSession:didCompleteWithError:task:...\" fetcher=%@ error=%@", fetcher.runMessage, fetcher.error);
	fetcher.finalBlock(fetcher, fetcher.errorMessage ? NO : YES);
	fetcher.finalBlock = nil;
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask
                                     didReceiveData:(NSData *)data
{
	FECWF_WEBFETCHER *fetcher = [FECWF_OPERATIONSRUNNER fetcherForTask:dataTask];
	//LOG(@"YIKES: \"URLSession:didReceiveData:task:...\" fetcher=%@", fetcher.runMessage);

	fetcher.currentReceiveSize += [data length];
	fetcher.webData = (NSData *)dispatch_data_create_concat((dispatch_data_t)fetcher.webData, (dispatch_data_t)data);
}

@end
