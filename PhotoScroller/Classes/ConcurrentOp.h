//
//  ConcurrentOp.h
//  Concurrent_NSOperation
//
//  Created by David Hoerl on 6/13/11.
//  Copyright 2011 David Hoerl. All rights reserved.
//

@class TiledImageBuilder;

@interface ConcurrentOp : NSOperation
@property (nonatomic, assign) NSUInteger index;
@property (nonatomic, strong) NSThread *thread;
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, strong) NSMutableData *webData;
@property (nonatomic, strong) TiledImageBuilder *imageBuilder;

//- (void)wakeUp;				// should be run on the operation's thread - could create a convenience method that does this then hide thread
- (void)finish;				// should be run on the operation's thread - could create a convenience method that does this then hide thread
- (void)runConnection;		// convenience method - messages using proper thread
- (void)cancel;				// subclassed convenience method

@end
