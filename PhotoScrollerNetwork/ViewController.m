//
//  ViewController.m
//  PhotoScrollerNetwork
//
//  Created by David Hoerl on 2/3/12.
//  Copyright (c) 2012 __MyCompanyName__. All rights reserved.
//

#import "ViewController.h"
#import "PhotoViewController.h"

@implementation ViewController
{
	IBOutlet UIButton *runButton;
	IBOutlet UIActivityIndicatorView *spinner;
	IBOutlet UISegmentedControl *technology;
	IBOutlet UISwitch *useInternet;
}

- (IBAction)button:(id)sender
{
	PhotoViewController *pvc = [[PhotoViewController alloc] initWithNibName:@"PhotoViewController" bundle:nil];
	pvc.isWebTest = YES;
	[self.navigationController pushViewController:pvc animated:YES];
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Release any cached data, images, etc that aren't in use.
}

#pragma mark - View lifecycle

- (void)viewDidLoad
{
    [super viewDidLoad];
	// Do any additional setup after loading the view, typically from a nib.
}

- (void)viewDidUnload
{
	runButton = nil;
	spinner = nil;
	technology = nil;
	useInternet = nil;
    [super viewDidUnload];
    // Release any retained subviews of the main view.
    // e.g. self.myOutlet = nil;
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
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
