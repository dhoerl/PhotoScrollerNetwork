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
 * Copyright 2012-2014 David Hoerl All Rights Reserved.
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

/* Notes for future work
[[UIApplication sharedApplication] setStatusBarHidden:YES withAnimation:UIStatusBarAnimationFade]; //iOS4
[[self navigationController] setNavigationBarHidden:YES animated:YES];
barStyle  property UIBarStyleBlack
translucent  property YES/NO
*/

//#include <mach/mach.h>		// freeMemory
#include <mach/mach_time.h>		// time metrics

#import "PhotoViewController.h"
#import "ImageScrollView.h"
#import "TiledImageBuilder.h"
#import "AppDelegate.h"
#import "PhotoScrollerCommon.h"

// My Asynchronous Web Fetching Code
#import "OperationsRunner8.h"
#import "ORSessionDelegate.h"
#import "ConcurrentOp.h"

// Compliments to Rainer Brockerhoff
static uint64_t DeltaMAT(uint64_t then, uint64_t now);

@interface PhotoViewController () <OperationsRunnerProtocol>
@end

@implementation PhotoViewController
{
	IBOutlet UIActivityIndicatorView	*spinner;
	IBOutlet UIToolbar					*toolbar;

	OperationsRunner					*operationsRunner;
    UIScrollView						*pagingScrollView;
    
    NSMutableSet						*recycledPages;
    NSMutableSet						*visiblePages;

    // these values are stored off before we start rotation so we adjust our content offset appropriately during rotation
    int									firstVisiblePageIndexBeforeRotation;
    CGFloat								percentScrolledIntoFirstVisiblePage;

	NSMutableArray						*tileBuilders;
	
	uint64_t							startTime;
	__block uint32_t					milliSeconds;
	
	BOOL								ok2tile;
}

+ (void)initialize
{
	if(self == [PhotoViewController class]) {
	
		ORSessionDelegate *del = [ORSessionDelegate new];	// URSessionDelegate subclass
		
		NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
		config.URLCache = nil;
		config.HTTPShouldSetCookies = YES;
		config.HTTPShouldUsePipelining = YES;

		[OperationsRunner createSharedSessionWithConfiguration:config delegate:del];
	}
}

#pragma mark -
#pragma mark View loading and unloading

#ifdef IMAGE_ZOOMING
#error WHERE IS THIS FLAG SET ???
- (IBAction)userDidTap:(id)sender
{
	NSLog(@"userDidTap");
	NSUInteger index = NSNotFound;
	for(NSUInteger i=0; i<[self imageCount]; ++i) {
		if([self isDisplayingPageForIndex:i]) {
			NSLog(@"DISPLAYING %d", i);
			index = i;
			break;
		}
	}
	if(index != NSNotFound) {
		for (ImageScrollView *page in visiblePages) {
			if (page.tag == index) {
				
				CGRect r;
				
				r = [page.imageView convertRect:page.frame toView:nil];
				NSLog(@"FRAME->WINDOW %@", NSStringFromCGRect(r) );
				
				//r = [page.imageView convertRect:page.bounds toView:nil];
				//NSLog(@"BOUNDS->WINDOW %@", NSStringFromCGRect(r) );

				NSLog(@"offset=%@ size=%@", NSStringFromCGPoint(page.contentOffset), NSStringFromCGSize(page.contentSize) );
				
				UIImageView *iv = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"Lake.jpg"]];
				iv.frame = CGRectMake(0, r.origin.y, page.contentSize.width, page.contentSize.height);
				
				//UIWindow *window = self.view.window;
				//NSLog(@"windowFrame %@", NSStringFromCGRect(window.frame) );
				//[pagingScrollView removeFromSuperview];
				[self.view.window addSubview:iv];
				
				toolbar.alpha = 0;
				[self.view.window addSubview:toolbar];
				toolbar.frame = CGRectMake(0, 480 - 44, 320, 44);
				
				for(int i=2; i<5; ++i) {
					UIBarButtonItem *item = [toolbar.items objectAtIndex:i];
					UIActivityIndicatorView *spnr = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
					item.customView = spnr;
					[spnr startAnimating];
				}

				page.hidden = YES;
				
				r.origin.y = 0;
				r.origin.x = -160;
				r.size.height = 480;
				r.size.width = 640;
				[UIView animateWithDuration:0.25f animations:^
					{
						[[UIApplication sharedApplication] setStatusBarHidden:YES withAnimation:UIStatusBarAnimationFade]; //iOS4
						[self.navigationController setNavigationBarHidden:YES animated:YES];

						iv.frame = r;
						toolbar.alpha = 1.0;
					} ];


				//animateWithDuration:(NSTimeInterval)duration delay:(NSTimeInterval)delay options:(UIViewAnimationOptions)options animations:(void (^)(void))animations completion:(void (^)(BOOL finished))completion

				break;
			}
		}
	}
}
#endif // IMAGE_ZOOMING	

- (void)viewDidLoad 
{
	[super viewDidLoad];

	[spinner startAnimating];
   
	pagingScrollView = (UIScrollView *)self.view;
    pagingScrollView.contentSize = [self contentSizeForPagingScrollView];

    // Step 2: prepare to createLevelsAndTile content
    recycledPages = [[NSMutableSet alloc] init];
    visiblePages  = [[NSMutableSet alloc] init];
	tileBuilders  = [[NSMutableArray alloc] init];
	if(_isWebTest) {
		operationsRunner = [[OperationsRunner alloc] initWithDelegate:self];
		[self fetchWebImages];
	} else {
		[self constructStaticImages];
	}

#ifdef IMAGE_ZOOMING	
	UITapGestureRecognizer *tgr = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(userDidTap:)];
	[pagingScrollView addGestureRecognizer:tgr];
#endif
}

- (void)dealloc
{
	[self cancelNow:nil];
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];

	NSLog(@"Yikes! PhotoViewController didReceiveMemoryWarning!");
}

- (IBAction)cancelNow:(id)sender
{
	[operationsRunner cancelOperations];
}

- (void)operationFinished:(FECWF_WEBFETCHER *)_op count:(NSUInteger)remainingOps
{
	// what you would want in real world situations below
	ConcurrentOp *op = (ConcurrentOp *)_op;
	
	// Note" probably a better strategy is to put the new images in their own array, then swap arrays when done
	if(op.imageBuilder) {
		[tileBuilders replaceObjectAtIndex:op.index withObject:op.imageBuilder];
	} else {
		NSLog(@"Never will show images! Just kill the app now!");
		// Real code should obviously deal with this! I had a network failure myself while testing.
		abort();
	}

	milliSeconds += op.milliSeconds;

	if(!remainingOps) {
		[spinner stopAnimating];
		
		[visiblePages removeAllObjects];	// seems like a good idea
		[recycledPages removeAllObjects];	// seems like a good idea
		ok2tile = YES;
		[self tilePages];
	
		uint64_t finishTime = mach_absolute_time();
		uint32_t ms = (uint32_t)DeltaMAT(startTime, finishTime);
		NSLog(@"ALL DONE: %u milliseconds", ms);

		self.navigationItem.title = [NSString stringWithFormat:@"DecodeTime: %u ms", ms];
	}
}

#pragma mark -
#pragma mark Tiling and page configuration

- (void)constructStaticImages
{
	dispatch_group_t group = dispatch_group_create();
	dispatch_queue_t que = dispatch_queue_create("com.dfh.PhotoScroller", DISPATCH_QUEUE_SERIAL);

	NSUInteger multiCore = [[NSProcessInfo processInfo] processorCount] - 1;
	NSArray *imageArray;
	
	 if([self imageCount] == 1) {
		imageArray = [NSArray arrayWithObject:_singleName];
	} else {
		imageArray = [NSArray arrayWithObjects:@"Lake", @"Shed", @"Tree", nil];
	}

	for(NSUInteger idx=0; idx<[imageArray count]; ++idx) {
		dispatch_async(que, ^{ [self->tileBuilders addObject:@""]; });
		NSString *imageName = [imageArray objectAtIndex:idx];
		NSString *path = [[NSBundle mainBundle] pathForResource:imageName ofType:@"jpg"];

#if 1 // Normal Case
		// thread if we have multiple cores
		dispatch_group_async(group, multiCore ? dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0) : que, ^
			{
				TiledImageBuilder *tb = [[TiledImageBuilder alloc] initWithImagePath:path withDecode:self->_decoder size:CGSizeMake(320, 320) orientation:self->_orientation];
			dispatch_group_async(group, que, ^{ [self->tileBuilders replaceObjectAtIndex:idx withObject:tb]; self->milliSeconds += tb.milliSeconds; });
			} );
#else // You can now use temporary UIImageViews as placeholders while fetching or tiling the images. Test it below.
		UIImageView *iv = [[UIImageView alloc] initWithImage:[UIImage imageWithContentsOfFile:path]];
		dispatch_group_async(group, que, ^{ [tileBuilders replaceObjectAtIndex:idx withObject:iv]; });
#endif
	}
	uint32_t count = (uint32_t)[self imageCount];
	if(!count) count = 1;
	uint32_t ms = milliSeconds/count;
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^
		{
			dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
			dispatch_async(dispatch_get_main_queue(), ^
				{
					self.navigationItem.title = [NSString stringWithFormat:@"DecodeTime: %u ms", ms];
					[self->spinner stopAnimating];
					self->ok2tile = YES;
					[self tilePages];
				});
			//dispatch_release(group);
			//dispatch_release(que);
		} );
}

- (void)fetchWebImages
{
	startTime = mach_absolute_time();

	NSUInteger count = [self imageCount];
	for(NSUInteger idx=0; idx<count; ++idx) {
		[tileBuilders addObject:@""];
		
		NSString *imageName = count == 1 ? _singleName : [self imageNameAtIndex:idx];
		NSString *path;
		if([imageName isEqualToString: @"Lake"]) {
			path = @"https://www.dropbox.com/s/b337y2sn1597sry/Lake.jpg?dl=1";
		} else
		if([imageName isEqualToString: @"Shed"]) {
			path = @"https://www.dropbox.com/s/wq5ed0z4cwgu8xc/Shed.jpg?dl=1";
		} else
		if([imageName isEqualToString: @"Tree"]) {
			path = @"https://www.dropbox.com/s/r1vf3irfero2f04/Tree.jpg?dl=1";
		} else
		if([imageName isEqualToString: @"large_leaves_70mp"]) {
			path = @"https://www.dropbox.com/s/xv4ftt95ud937w4/large_leaves_70mp.jpg?dl=1";
		} else
		if([imageName isEqualToString: @"Space4"]) {
			path = @"https://www.dropbox.com/s/sbda3z1r0komm7g/Space4.jpg?dl=1";
		} else
		if([imageName isEqualToString: @"Space5"]) {
			path = @"https://www.dropbox.com/s/w0s5905cqkcy4ua/Space5.jpg?dl=1";
		} else
		if([imageName isEqualToString: @"Space6"]) {
			path = @"https://www.dropbox.com/s/yx63i2yf8eobrgt/Space6.jpg?dl=1";
		} else {
			abort();
		}
		// Old way that DropBox broke!
		// NSString *path = [[@"http://dl.dropbox.com/u/60414145" stringByAppendingPathComponent:imageName] stringByAppendingPathExtension:@"jpg"];

		ConcurrentOp *op = [ConcurrentOp new];
		op.urlStr = path;
		op.decoder = _decoder;
		op.index = idx;
		//op.zoomLevels = ZOOM_LEVELS;
		op.orientation = _orientation;

		[operationsRunner runOperation:op withMsg:path];
	}
}

- (void)tilePages 
{
	if(!ok2tile) return;

    // Calculate which pages are visible
    CGRect visibleBounds = pagingScrollView.bounds;
    NSInteger firstNeededPageIndex = (NSInteger)lrint( floor(CGRectGetMinX(visibleBounds) / CGRectGetWidth(visibleBounds)) );
    NSInteger lastNeededPageIndex  = (NSInteger)lrint( floor((CGRectGetMaxX(visibleBounds)-1) / CGRectGetWidth(visibleBounds)) );
    firstNeededPageIndex = MAX(firstNeededPageIndex, 0);
    lastNeededPageIndex  = MIN(lastNeededPageIndex, [self imageCount] - 1);

    // Recycle no-longer-visible pages 
	[visiblePages enumerateObjectsUsingBlock:^(ImageScrollView *page, BOOL *stop)
		{
			if (page.tag < firstNeededPageIndex || page.tag > lastNeededPageIndex) {
				[recycledPages addObject:page];
				[page removeFromSuperview];
			}
		} ];
    [visiblePages minusSet:recycledPages];
	[recycledPages makeObjectsPerformSelector:@selector(removeFromSuperview)];
    
    // add missing pages
    for (NSInteger index = firstNeededPageIndex; index <= lastNeededPageIndex; index++) {
        if (![self isDisplayingPageForIndex:index]) {
			ImageScrollView *page = [recycledPages anyObject];
			if (page) {
				[recycledPages removeObject:page];
			} else {
                page = [ImageScrollView new];
				// If you want the image to FILL the view, not FIT into the view
				//((ImageScrollView *)page).aspectFill = YES;
            }
            [self configurePage:page forIndex:index];
            [visiblePages addObject:page];
            [pagingScrollView addSubview:page];
        }
    }
}

- (BOOL)isDisplayingPageForIndex:(NSUInteger)index
{
	__block BOOL foundPage = NO;
	
	[visiblePages enumerateObjectsUsingBlock:^(ImageScrollView *page, BOOL *stop)
		{
			if(page.tag == index) {
				*stop = YES;
				foundPage = YES;
			}
		} ];
    return foundPage;
}

- (void)configurePage:(ImageScrollView *)page forIndex:(NSUInteger)index
{
    page.tag = index;
    page.frame = [self frameForPageAtIndex:index];
    
    // Use tiled images
    [page displayObject:[tileBuilders objectAtIndex:index]];
}


#pragma mark -
#pragma mark ScrollView delegate methods

- (void)scrollViewDidScroll:(UIScrollView *)scrollView
{
	if(scrollView == pagingScrollView) {
		// dispatch fixes some recursive call to scrollViewDidScroll in tilePages (related to removeFromSuperView)
		// The reason can be found here: http://stackoverflow.com/questions/3854739
		dispatch_async(dispatch_get_main_queue(), ^{ [self tilePages]; });
	}
}

#if 0 // Deprecated
#pragma mark -
#pragma mark View controller rotation methods

- (void)willRotateToInterfaceOrientation:(UIInterfaceOrientation)toInterfaceOrientation duration:(NSTimeInterval)duration
{
    // here, our pagingScrollView bounds have not yet been updated for the new interface orientation. So this is a good
    // place to calculate the content offset that we will need in the new orientation
    CGFloat offset = pagingScrollView.contentOffset.x;
    CGFloat pageWidth = pagingScrollView.bounds.size.width;
    
    if (offset >= 0) {
        firstVisiblePageIndexBeforeRotation = lrintf( floorf(offset / pageWidth) );
        percentScrolledIntoFirstVisiblePage = (offset - (firstVisiblePageIndexBeforeRotation * pageWidth)) / pageWidth;
    } else {
        firstVisiblePageIndexBeforeRotation = 0;
        percentScrolledIntoFirstVisiblePage = offset / pageWidth;
    }    
}

- (void)willAnimateRotationToInterfaceOrientation:(UIInterfaceOrientation)toInterfaceOrientation duration:(NSTimeInterval)duration
{
    // recalculate contentSize based on current orientation
    pagingScrollView.contentSize = [self contentSizeForPagingScrollView];
    
    // adjust frames and configuration of each visible page
	[visiblePages enumerateObjectsUsingBlock:^(ImageScrollView *page, BOOL *stop)
		{
			CGPoint restorePoint = [page pointToCenterAfterRotation];
			CGFloat restoreScale = [page scaleToRestoreAfterRotation];
//NSLog(@"ROTATE: 0 page bounds %@ view bounds %@", NSStringFromCGRect(page.bounds) , NSStringFromCGRect([[page.subviews lastObject] bounds]) );
			page.frame = [self frameForPageAtIndex:page.tag];
//NSLog(@"ROTATE: 1 page bounds %@ view bounds %@", NSStringFromCGRect(page.bounds) , NSStringFromCGRect([[page.subviews lastObject] bounds]) );
			[page setMaxMinZoomScalesForCurrentBounds];
//NSLog(@"ROTATE: 2 page bounds %@ view bounds %@", NSStringFromCGRect(page.bounds) , NSStringFromCGRect([[page.subviews lastObject] bounds]) );
			[page restoreCenterPoint:restorePoint scale:restoreScale];
//NSLog(@"ROTATE: 3 page bounds %@ view bounds %@", NSStringFromCGRect(page.bounds) , NSStringFromCGRect([[page.subviews lastObject] bounds]) );
		} ];
    
    // adjust contentOffset to preserve page location based on values collected prior to location
    CGFloat pageWidth = pagingScrollView.bounds.size.width;
    CGFloat newOffset = (firstVisiblePageIndexBeforeRotation * pageWidth) + (percentScrolledIntoFirstVisiblePage * pageWidth);
    pagingScrollView.contentOffset = CGPointMake(newOffset, 0);
}
#endif

#pragma mark -
#pragma mark  Frame calculations

- (CGRect)frameForPageAtIndex:(NSUInteger)index
{
    // We have to use our paging scroll view's bounds, not frame, to calculate the page placement. When the device is in
    // landscape orientation, the frame will still be in portrait because the pagingScrollView is the root view controller's
    // view, so its frame is in window coordinate space, which is never rotated. Its bounds, however, will be in landscape
    // because it has a rotation transform applied.
    CGRect bounds = pagingScrollView.bounds;
    CGRect pageFrame = bounds;
    pageFrame.origin.x = (bounds.size.width * index);
    return pageFrame;
}

- (CGSize)contentSizeForPagingScrollView {
    // We have to use the paging scroll view's bounds to calculate the contentSize, for the same reason outlined above.
    CGRect bounds = pagingScrollView.bounds;
    return CGSizeMake(bounds.size.width * [self imageCount], bounds.size.height);
}


#pragma mark -
#pragma mark Image wrangling

- (NSArray *)imageData
{
    static NSArray *__imageData = nil; // only load the imageData array once
    if (__imageData == nil) {
        // read the filenames/sizes out of a plist in the app bundle
        NSString *path = [[NSBundle mainBundle] pathForResource:@"ImageData" ofType:@"plist"];
        NSData *plistData = [NSData dataWithContentsOfFile:path];
        __autoreleasing NSError *error; NSPropertyListFormat format;
        __imageData = [NSPropertyListSerialization propertyListWithData:plistData
												   options:NSPropertyListImmutable
                                                   format:&format
												   error:&error];
        if (!__imageData) {
            NSLog(@"Failed to read image names. Error: %@", error);
        }
    }
    return __imageData;
}

- (NSString *)imageNameAtIndex:(NSUInteger)index
{
    NSString *name = nil;
    if (index < [self imageCount]) {
        NSDictionary *data = [[self imageData] objectAtIndex:index];
        name = [data valueForKey:@"name"];
    }
    return name;
}

- (NSUInteger)imageCount
{
    return _justDoOneImage ? 1 : [[self imageData] count];
}

@end

static uint64_t DeltaMAT(uint64_t then, uint64_t now)
{
	uint64_t delta = now - then;

	/* Get the timebase info */
	mach_timebase_info_data_t info;
	mach_timebase_info(&info);

	/* Convert to nanoseconds */
	delta *= info.numer;
	delta /= info.denom;

	return (uint64_t)((double)delta / 1e6); // ms
}

