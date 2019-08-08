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
 * Copyright 2012-2019 David Hoerl All Rights Reserved.
 *
 * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

#import "WebFetcher8.h"

#import "PhotoScrollerCommon.h"

@class TiledImageBuilder;

@interface ConcurrentOp : FECWF_WEBFETCHER
@property (nonatomic, assign) ImageDecoder decoder;					// type of operation to perform
@property (nonatomic, assign) NSUInteger orientation;				// 0 == automatic, or force one using 1-8
@property (nonatomic, assign) NSUInteger zoomLevels;				// type of operation to perform
@property (nonatomic, assign) NSUInteger index;						// if multiple operations, what index am i
@property (nonatomic, assign, readonly) uint32_t milliSeconds;		// time it takes to decode the image
@property (nonatomic, strong) TiledImageBuilder *imageBuilder;		// controller for the bit maps used to provide CATiles

@end
