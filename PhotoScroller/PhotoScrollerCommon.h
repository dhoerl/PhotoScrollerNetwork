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

typedef NS_ENUM(NSInteger, ImageDecoder) {
	cgimageDecoder=0,		// Use CGImage
	libjpegTurboDecoder,	// Use libjpeg-turbo, but not incrementally (used when loading a local file)
	libjpegIncremental		// Used when we download a file from the web, so we can process it a chunk at a time.
};

#define ZOOM_LEVELS			 4
#define TILE_SIZE			256		// could make larger or smaller, but power of 2
#define ANNOTATE_TILES		YES
