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

#import "ViewController.h"
#import "PhotoViewController.h"
#import "ConcurrentOp.h"
#import "TiledImageBuilder.h"
#import "TilingView.h"

@interface ViewController ()

- (IBAction)segmentChanged:(id)sender;
- (IBAction)stepperStepped:(id)sender;
- (IBAction)makeImage:(id)sender;

@end

@implementation ViewController
{
	IBOutlet UIButton *runButton;
	IBOutlet UISegmentedControl *technology;
	IBOutlet UISwitch *useInternet;
	IBOutlet UISwitch *justOneImage;
	IBOutlet UILabel *orientationValue;
	IBOutlet UIImageView *imageView;
}

- (IBAction)segmentChanged:(id)sender
{
#if 0
	if(technology.selectedSegmentIndex == 2) {
		useInternet.on = YES;
		useInternet.enabled = NO;
	} else {
		useInternet.enabled = YES;
	}
#endif
}

- (IBAction)stepperStepped:(id)sender
{
	UIStepper *stepper = (UIStepper *)sender;
	
	orientationValue.text = [NSString stringWithFormat:@"%ld", lrint(stepper.value)];
}

#if 0 // does not work
- (IBAction)makeImage:(id)sender
{
	NSString *path = [[NSBundle mainBundle] pathForResource:@"Shed" ofType:@"jpg"];
	assert(path);
	
	// 320 just shows we don't need to size it to what our desired size is
	TiledImageBuilder *tb = [[TiledImageBuilder alloc] initWithImagePath:path withDecode:cgimageDecoder size:CGSizeMake(320, 320) orientation:1];
	assert(tb);
	TilingView *tv = [[TilingView alloc] initWithImageBuilder:tb];
	assert(tv);
	tv.frame = CGRectMake(0, 0, imageView.bounds.size.width, imageView.bounds.size.height);
	
	UIImage *image = [tv image];
	assert(image);
	
	imageView.image = image;
}
#endif

- (IBAction)button:(id)sender
{
	PhotoViewController *pvc = [[PhotoViewController alloc] initWithNibName:@"PhotoViewController" bundle:nil];
	pvc.isWebTest = useInternet.on;
	pvc.decoder = technology.selectedSegmentIndex;
	pvc.justDoOneImage = justOneImage.on;
	pvc.orientation = [orientationValue.text integerValue];

	UIBarButtonItem *temporaryBarButtonItem = [UIBarButtonItem new];
	[temporaryBarButtonItem setTitle:@"Back"];
	self.navigationItem.backBarButtonItem = temporaryBarButtonItem;

	[self.navigationController pushViewController:pvc animated:YES];
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];

	NSLog(@"Yikes! ViewController didReceiveMemoryWarning!");
}

#pragma mark - View lifecycle

- (void)viewDidLoad
{
    [super viewDidLoad];

#if defined(LIBJPEG)
	technology.hidden = NO;
#else
	technology.hidden = YES;
#endif
	self.navigationItem.title = @"PhotoScrollerNetwork";
}

- (void)viewDidUnload
{
	orientationValue = nil;
	imageView = nil;
    [super viewDidUnload];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
	
	self.navigationItem.backBarButtonItem = nil;
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
}

- (void)viewWillDisappear:(BOOL)animated
{
	[super viewWillDisappear:animated];
}

- (void)viewDidDisappear:(BOOL)animated
{
	[super viewDidDisappear:animated];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)interfaceOrientation
{
    // Return YES for supported orientations
	return (interfaceOrientation != UIInterfaceOrientationPortraitUpsideDown);
}

@end
