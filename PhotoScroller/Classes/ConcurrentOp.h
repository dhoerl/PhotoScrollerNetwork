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

#import "PhotoScrollerCommon.h"

@class TiledImageBuilder;

@interface ConcurrentOp : NSOperation
@property (nonatomic, assign) imageDecoder decoder;					// type of operation to perform
@property (nonatomic, assign) NSUInteger orientation;				// 0 == automatic, or force one using 1-8
@property (nonatomic, assign) NSUInteger zoomLevels;				// type of operation to perform
@property (nonatomic, assign) NSUInteger index;						// if multiple operations, what index am i
@property (nonatomic, assign, readonly) NSUInteger milliSeconds;	// time it takes to decode the image
@property (nonatomic, strong) NSThread *thread;						// convenience method for the curious
@property (nonatomic, strong) NSURL *url;							// passed in - where to get the image
@property (nonatomic, strong) NSMutableData *webData;				// could be private, but sometimes useful. Where the URL cvonnection saves data
@property (nonatomic, strong) TiledImageBuilder *imageBuilder;		// controller for the bit maps used to provide CATiles

- (void)finish;				// should be run on the operation's thread - could create a convenience method that does this then hide thread
- (void)runConnection;		// convenience method - messages using proper thread
- (void)cancel;				// subclassed convenience method

@end
