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

/* Notes for future work
[[UIApplication sharedApplication] setStatusBarHidden:YES withAnimation:UIStatusBarAnimationFade]; //iOS4
[[self navigationController] setNavigationBarHidden:YES animated:YES];
barStyle  property UIBarStyleBlack
translucent  property YES/NO
*/

#import "PhotoViewController.h"
#import "ImageScrollView.h"
#import "TiledImageBuilder.h"
#import "ConcurrentOp.h"
#import "AppDelegate.h"

static char *runnerContext = "runnerContext";

@interface PhotoViewController ()
@property (nonatomic, strong) NSOperationQueue *queue;
@property (nonatomic, strong) NSMutableSet *operations;

- (IBAction)cancelNow:(id)sender;

- (void)operationDidFinish:(ConcurrentOp *)operation;

- (void)configurePage:(ImageScrollView *)page forIndex:(NSUInteger)index;
- (BOOL)isDisplayingPageForIndex:(NSUInteger)index;

//- (CGRect)frameForPagingScrollView;
- (CGRect)frameForPageAtIndex:(NSUInteger)index;
- (CGSize)contentSizeForPagingScrollView;

- (void)tilePages;
- (ImageScrollView *)dequeueRecycledPage;

- (NSUInteger)imageCount;
- (NSString *)imageNameAtIndex:(NSUInteger)index;
- (CGSize)imageSizeAtIndex:(NSUInteger)index;
//- (UIImage *)imageAtIndex:(NSUInteger)index;

- (void)constructStaticImages;
- (void)fetchWebImages;

@end

@implementation PhotoViewController
{
	IBOutlet UIActivityIndicatorView *spinner;

    UIScrollView	*pagingScrollView;
    
    NSMutableSet	*recycledPages;
    NSMutableSet	*visiblePages;

    // these values are stored off before we start rotation so we adjust our content offset appropriately during rotation
    int				firstVisiblePageIndexBeforeRotation;
    CGFloat			percentScrolledIntoFirstVisiblePage;

	NSMutableArray	*tileBuilders;
	
	NSUInteger		milliSeconds;
}
@synthesize isWebTest;
@synthesize queue;
@synthesize operations;
@synthesize decoder;

#pragma mark -
#pragma mark View loading and unloading

- (void)viewDidLoad 
{
	[spinner startAnimating];

	self.operations = [NSMutableSet setWithCapacity:1];
	self.queue = [NSOperationQueue new];
   
	pagingScrollView = (UIScrollView *)self.view;
    pagingScrollView.contentSize = [self contentSizeForPagingScrollView];

    // Step 2: prepare to tile content
    recycledPages = [[NSMutableSet alloc] init];
    visiblePages  = [[NSMutableSet alloc] init];
	tileBuilders  = [[NSMutableArray alloc] init];
	if(isWebTest) {
		[self fetchWebImages];
	} else {
		[self constructStaticImages];
	}
}

- (void)viewDidUnload
{
	spinner = nil;
    [super viewDidUnload];

    pagingScrollView = nil;
    recycledPages = nil;
    visiblePages = nil;
	tileBuilders = nil;
}

- (void)dealloc
{
	[self cancelNow:nil];
}

- (IBAction)cancelNow:(id)sender
{
	[operations enumerateObjectsUsingBlock:^(id obj, BOOL *stop) { [obj removeObserver:self forKeyPath:@"isFinished"]; }];   
    [self.operations removeAllObjects];

	[queue cancelAllOperations];
	[queue waitUntilAllOperationsAreFinished];
	
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
	ConcurrentOp *op = object;
	if(context == runnerContext) {
		if(op.isFinished == YES) {
			// we get this on the operation's thread
			//[self performSelectorOnMainThread:@selector(operationDidFinish:) withObject:op waitUntilDone:NO];
			dispatch_async(dispatch_get_main_queue(), ^{ [self operationDidFinish:op]; } );
		} else {
			//NSLog(@"NSOperation starting to RUN!!!");
		}
	} else {
		if([object respondsToSelector:@selector(observeValueForKeyPath:ofObject:change:context:)])
			[super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
	}
}

- (void)operationDidFinish:(ConcurrentOp *)op
{

	// what you would want in real world situations below

	// if you cancel the operation when its in the set, will hit this case
	// since observeValueForKeyPath: queues this message on the main thread
	if(![self.operations containsObject:op]) return;
	
	// If we are in the queue, then we have to both remove our observation and queue membership
	[op removeObserver:self forKeyPath:@"isFinished"];
	[operations removeObject:op];
	
	// This would be the case if cancelled before we start running.
	if(op.isCancelled) return;
	
	// We either failed in setup or succeeded doing something.
	// NSLog(@"Operation Succeeded: index=%d", op.index);
	
	[tileBuilders replaceObjectAtIndex:op.index withObject:op.imageBuilder];
	milliSeconds += op.milliSeconds;

	if(![operations count]) {
		[spinner stopAnimating];
		[self tilePages];
		self.navigationItem.title = [NSString stringWithFormat:@"DecodeTime: %u ms", milliSeconds];
	}
}

#pragma mark -
#pragma mark Tiling and page configuration

- (void)constructStaticImages
{
	dispatch_group_t group = dispatch_group_create();
	dispatch_queue_t que = dispatch_queue_create("com.dfh.photoScroller", DISPATCH_QUEUE_SERIAL);
	
	NSUInteger multiCore = [[NSProcessInfo processInfo] processorCount] - 1;
	
	for(NSUInteger idx=0; idx<[self imageCount]; ++idx) {
		dispatch_async(que, ^{ [tileBuilders addObject:@""]; });
		NSString *imageName = [self imageNameAtIndex:idx];
		NSString *path = [[NSBundle mainBundle] pathForResource:imageName ofType:@"jpg"];

		// thread if we have multiple cores
		dispatch_group_async(group, multiCore ? dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0) : que, ^
			{
				TiledImageBuilder *tb = [[TiledImageBuilder alloc] initWithImagePath:path];
				dispatch_group_async(group, que, ^{ [tileBuilders replaceObjectAtIndex:idx withObject:tb]; NSLog(@"tilebuilder RETURNED"); });
			} );
	}
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^
		{
			dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
			dispatch_async(dispatch_get_main_queue(), ^
				{
					[spinner stopAnimating];
					[self tilePages];
				});
			dispatch_release(group);
			dispatch_release(que);
		} );
}

- (void)fetchWebImages
{		
	for(NSUInteger idx=0; idx<[self imageCount]; ++idx) {
		[tileBuilders addObject:@""];
		
		NSString *imageName = [self imageNameAtIndex:idx];
		NSString *path = [[@"http://dl.dropbox.com/u/60414145" stringByAppendingPathComponent:imageName] stringByAppendingPathExtension:@"jpg"];

		ConcurrentOp *op = [ConcurrentOp new];
		op.url = [NSURL URLWithString:path];
		op.decoder = decoder;
		op.index = idx;

		// Order is important here
		[op addObserver:self forKeyPath:@"isFinished" options:0 context:runnerContext];	// First, observe isFinished

		[operations addObject:op];	// Second we retain and save a reference to the operation
		[queue addOperation:op];	// Lastly, lets get going!
	}
}

- (void)tilePages 
{
    // Calculate which pages are visible
    CGRect visibleBounds = pagingScrollView.bounds;
    int firstNeededPageIndex = floorf(CGRectGetMinX(visibleBounds) / CGRectGetWidth(visibleBounds));
    int lastNeededPageIndex  = floorf((CGRectGetMaxX(visibleBounds)-1) / CGRectGetWidth(visibleBounds));
    firstNeededPageIndex = MAX(firstNeededPageIndex, 0);
    lastNeededPageIndex  = MIN(lastNeededPageIndex, [self imageCount] - 1);
    
    // Recycle no-longer-visible pages 
    for (ImageScrollView *page in visiblePages) {
        if (page.index < firstNeededPageIndex || page.index > lastNeededPageIndex) {
            [recycledPages addObject:page];
            [page removeFromSuperview];
        }
    }
    [visiblePages minusSet:recycledPages];
    
    // add missing pages
    for (int index = firstNeededPageIndex; index <= lastNeededPageIndex; index++) {
        if (![self isDisplayingPageForIndex:index]) {
            ImageScrollView *page = [self dequeueRecycledPage];
            if (page == nil) {
                page = [[ImageScrollView alloc] init];
            }
            [self configurePage:page forIndex:index];
            [pagingScrollView addSubview:page];
            [visiblePages addObject:page];
        }
    }    
}

- (ImageScrollView *)dequeueRecycledPage
{
    ImageScrollView *page = [recycledPages anyObject];
    if (page) {
        [recycledPages removeObject:page];
    }
    return page;
}

- (BOOL)isDisplayingPageForIndex:(NSUInteger)index
{
    BOOL foundPage = NO;
    for (ImageScrollView *page in visiblePages) {
        if (page.index == index) {
            foundPage = YES;
            break;
        }
    }
    return foundPage;
}

- (void)configurePage:(ImageScrollView *)page forIndex:(NSUInteger)index
{
    page.index = index;
    page.frame = [self frameForPageAtIndex:index];
    
    // Use tiled images
    [page displayTiledImage:[tileBuilders objectAtIndex:index]];
    
    // To use full images instead of tiled images, replace the "displayTiledImageNamed:" call
    // above by the following line:
    // [page displayImage:[self imageAtIndex:index]];
}


#pragma mark -
#pragma mark ScrollView delegate methods

- (void)scrollViewDidScroll:(UIScrollView *)scrollView
{
    [self tilePages];
}

#pragma mark -
#pragma mark View controller rotation methods

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)toInterfaceOrientation 
{
    return YES;
}

- (void)willRotateToInterfaceOrientation:(UIInterfaceOrientation)toInterfaceOrientation duration:(NSTimeInterval)duration
{
    // here, our pagingScrollView bounds have not yet been updated for the new interface orientation. So this is a good
    // place to calculate the content offset that we will need in the new orientation
    CGFloat offset = pagingScrollView.contentOffset.x;
    CGFloat pageWidth = pagingScrollView.bounds.size.width;
    
    if (offset >= 0) {
        firstVisiblePageIndexBeforeRotation = floorf(offset / pageWidth);
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
    for (ImageScrollView *page in visiblePages) {
        CGPoint restorePoint = [page pointToCenterAfterRotation];
        CGFloat restoreScale = [page scaleToRestoreAfterRotation];
        page.frame = [self frameForPageAtIndex:page.index];
        [page setMaxMinZoomScalesForCurrentBounds];
        [page restoreCenterPoint:restorePoint scale:restoreScale];
        
    }
    
    // adjust contentOffset to preserve page location based on values collected prior to location
    CGFloat pageWidth = pagingScrollView.bounds.size.width;
    CGFloat newOffset = (firstVisiblePageIndexBeforeRotation * pageWidth) + (percentScrolledIntoFirstVisiblePage * pageWidth);
    pagingScrollView.contentOffset = CGPointMake(newOffset, 0);
}

#pragma mark -
#pragma mark  Frame calculations

#if 0
#define PADDING  10

- (CGRect)frameForPagingScrollView {
    CGRect frame = [[UIScreen mainScreen] bounds];
    frame.origin.x -= PADDING;
    frame.size.width += (2 * PADDING);
    return frame;
}
- (CGRect)frameForPageAtIndex:(NSUInteger)index {
    // We have to use our paging scroll view's bounds, not frame, to calculate the page placement. When the device is in
    // landscape orientation, the frame will still be in portrait because the pagingScrollView is the root view controller's
    // view, so its frame is in window coordinate space, which is never rotated. Its bounds, however, will be in landscape
    // because it has a rotation transform applied.
    CGRect bounds = pagingScrollView.bounds;
    CGRect pageFrame = bounds;
    pageFrame.size.width -= (2 * PADDING);
    pageFrame.origin.x = (bounds.size.width * index) + PADDING;
    return pageFrame;
}
#endif

#define PADDING  0
- (CGRect)frameForPageAtIndex:(NSUInteger)index
{
    // We have to use our paging scroll view's bounds, not frame, to calculate the page placement. When the device is in
    // landscape orientation, the frame will still be in portrait because the pagingScrollView is the root view controller's
    // view, so its frame is in window coordinate space, which is never rotated. Its bounds, however, will be in landscape
    // because it has a rotation transform applied.
    CGRect bounds = pagingScrollView.bounds;
    CGRect pageFrame = bounds;
    pageFrame.size.width -= (2 * PADDING);
    pageFrame.origin.x = (bounds.size.width * index) + PADDING;
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
        NSString *error; NSPropertyListFormat format;
        __imageData = [NSPropertyListSerialization propertyListFromData:plistData
                                                        mutabilityOption:NSPropertyListImmutable
                                                                  format:&format
                                                        errorDescription:&error];
        if (!__imageData) {
            NSLog(@"Failed to read image names. Error: %@", error);
        }
    }
    return __imageData;
}

/*
- (UIImage *)imageAtIndex:(NSUInteger)index {
    // use "imageWithContentsOfFile:" instead of "imageNamed:" here to avoid caching our images
    NSString *imageName = [self imageNameAtIndex:index];
    NSString *path = [[NSBundle mainBundle] pathForResource:imageName ofType:@"jp2"];
    return [UIImage imageWithContentsOfFile:path];    
}
*/

- (NSString *)imageNameAtIndex:(NSUInteger)index
{
    NSString *name = nil;
    if (index < [self imageCount]) {
        NSDictionary *data = [[self imageData] objectAtIndex:index];
        name = [data valueForKey:@"name"];
    }
    return name;
}

- (CGSize)imageSizeAtIndex:(NSUInteger)index
{
    CGSize size = CGSizeZero;
    if (index < [self imageCount]) {
        NSDictionary *data = [[self imageData] objectAtIndex:index];
        size.width = [[data valueForKey:@"width"] floatValue];
        size.height = [[data valueForKey:@"height"] floatValue];
    }
    return size;
}

- (NSUInteger)imageCount
{
    static NSUInteger __count = NSNotFound;  // only count the images once
    if (__count == NSNotFound) {
        __count = [[self imageData] count];
    }
    return __count;
}


@end
