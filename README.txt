PhotoScrollerNetwork Project
Latest v2.5 Jan 6, 2013

NOTE: Please use one of the 'Turbo' schemes to build - the older non-turbo schemes do not currently work

NOTE: At WWDC 2012, I talked to the OSX/IOS Kernel manager at a lab, and discussed the problem with memory pressure
that users had seen as well as my current solution. He actually said it was as good a way to deal with it on iOS as
can be done now with the current APIs. So, even though I had said I hacked a solution into this project, in the end
its actually pretty elegant!

This sample code:

- blazingly fast tile rendering - visually much much faster than Apple's code (which uses png files in the file system)
- you supply a single jpeg file or URL and this code does all the tiling for you, quickly and painlessly
- supports both drawLayer: and drawRect: (latter appears to be faster)
- builds on Apple's PhotoScroller project by addressing its deficiencies (mostly the pretiled images)
- provides the means to process very large images for use in a zoomable scrollview
- is backed by a CATiledLayer so that only those tiles needed for display consume memory
- each zoom level has one dedicated temp file rearranged into tiles for rapid tile access & rendering
- demonstrates how to use concurrent NSOperations to fetch several large images from the web or to process local image files
- provides two targets, one using just Apple APIs (CGImageRef and friends), and the other (Turbo) using libturbojpeg
- Turbo target lets you test with 3 techniques for both downloads and local file processing using CGImageSourceRef, libturbojpef, and incremental decode using libjpeg (turbo version)
- the incremental approach uses mmap, only maps small parts of the image at a time, and does its processing as the image downloads and can thus handle very large images
- averages the decode time for all 3 technologies
- production quality - all "PhotoScroller/Classes" source being used in an upcoming Lot18 app (except PhotoViewController, which was absorbed into another class)

Note: originally I tried to do as Apple does - receive a single jpeg file then create all the tiles on disk as pngs. This process took around a minute on the iPhone 4 and was thus rejected.

RECENT CHANGES:

v2.5:
- finally got libturbojpeg to build for armv7s, so this project is now SDK6 and armv7s friendly
- cleaned up some bogus references to /opt and elsewhere when looking for libturbojpeg library or headers

v2.4:
- when set to one image, downloads MASSIVE NASA images from the web - 18000 x 18000 dimensions - to show this app can deal with about anything you can throw at it
- JPEG orientations 6 and 8 were reversed (see comments at bottom of this page "http://sylvana.net/jpegcrop/exif_orientation.html")

v2.3:
- extracted out the Concurrent Operations control into a small helper class, Operations Runner. This makes PhotoViewController.m simpler, and puts all the tricky code in one place.

v2.2:
- project completely orientation away. 0 means use the JPEG tag info, 1 forces "normal" as in memory rendering, and you can use 2 through 8 to force an orientation.

v2.2b:
- Insure your PhotoViewController's scrollViewDidScroll: method delays sending tilePages, or you will get infrequent crashes! See code in this project.
- Changed TiledImageBuilder's initialization methods to use the targetted view size, not the number of levels (you can revert back if you want via an ifdef). See the notes in the interface file on how this works, and why this was an improvement for users of this class.
- Static images now properly deal with JPEG image file orientation (incremental in process).

v2.1a:
- grab and expose the CGImageSource "properties" dictionary for ALL images regardless of decoder (a property on TiledImageBuilder)
- above in preparation for added "orientation" correction
- refactor TiledImageBuilder.m into a bunch of TiledImageBuilder+ categores - the single .m was becoming unwieldy
- except for properties, not much of interest here. Lots of effort just to refactor (no class extension ivars, so had to use properties) 

v2.0:
- iPad1 and iPhone3GS (with only 256M of memory) were getting killed with no OS warning. So, created an upper limit on cdisk cache usage, and flush files (to free up memory) when the threshold is hit. Crashes went away.
- tweaked the way images are created and then drawn (in TiledImageView) to cut down on un-necessary Quartz conversions.
- fixed a nasty bug in scrolling. "-scrollViewDidScroll" was calling tilePages, which changed the scrollview bounds, which infrequently caused a new "-scrollViewDidScroll" messaage [Apple's code, not mine!]
- more files now test for ARC
- now using libjpeg-turbo library installed by the library downloader: https://sourceforge.net/projects/libjpeg-turbo/. Had to do this since Xcode 4.3.1 broke my libjpegturbo-builder project.
- new flag lets you try the image creation used by TileView using "pread" or "mmap/memcpy". While I suspect the former is quicker I really don't know. The default not is pread.
- added iPad targets

v1.7:
- renamed Common.h to PhotoScrollerCommon.h, moved it up one directory, makes it easier to just include the PhotoScroller Classes in other projects, in which case you create your own PhotoScrollerCommon.h with customized data

v1.6:
- set the blend mode on the context as Apple does in QA1708

v1.5:
- zoomLevels is now a run time value - set it to 1 if you have a low-resolution image, then replace the TileView with a real zooming level later
- name change so Xcode 4.3 "Analyze" doesn't complain

v 1.4:
- cgimageref and libturbojpeg fetchers write incoming data to a file, cgimageref decodes from a URL and for turbo data loaded into a NSData object then decoded
- timing for all operations aggregates only the decode times (and averages) - there was just too much variation in network fetch times to make including that useful
- added a single image load option. Useful if testing on 3G or a slow WIFI connection

v 1.3:
- added a drawLayer:, which is smaller and appears to make the tiling quicker.

v 1.2:
- lots of churn

v 1.1:
- original release

 * * *

So, you want to use a scrolling view with zoomable images in an iOS device. You discover that Apple has this really nice sample project called "PhotoScroller", so you download and run it.

It looks really nice and seems to be exactly what you need! And you see three jpeg images with the three images you see in the UIScrollView. But, you dig deeper, and with a growing pit in your stomach, you discover that the project is a facade - it only works since those beautiful three jpegs are pre-tiled into 800 or so small png tiles, prepared to meet the needs of the CATiledLayer backing the scrollview.

Fear not! Now you have PhotoScrollerNetwork to the rescue! Not only does this project solve the problem of using a single image in an efficient and elegant manner, but it also shows you how to fetch images from the network using Concurrent NSOperations, and then how to efficiently decode and re-format them for rapid display by the CATiledLayer. Note that for single core processors like the 3GS and 4, the decode time is additive. I challenge anyone to make this faster!

This code leverages my github Concurrent_NSOperations project (https://github.com/dhoerl/Concurrent_NSOperations), as image fetching is done using Concurrent NSOperations. The images were uploaded to my public Dropbox folder - you will see the URL if you look around.

The included Xcode 4 project has two targets, one using just Apple APIs, and the second using libjpeg-turbo, both explained below.

KNOWN BUGS:
- if you stop the executable with the scroll view showing in the Simulator, you often get a crash (haven't seen this in April)

TODO:
- TiledImageBuilder does error checking and sets the "failed" flag, but my testing of this mechanism has been brief and not exhaustive!
- if an image is truly huge, then incrementally create tiles instead of having to map in two rows of tiles (may not be needed)


PhotoScollerNetwork Target: FAST AND EFFICIENT TILING USING A CGIMAGESOURCE

This target does exactly what the PhotoScroller does, but it only needs a single jpeg per view, and it dynamically creates all the tiles as sections of a larger file instead of using individual files.

Process:

- obtain a complete image as a file URL or as a NSData object

- create a tmp file what is the same or larger having dimension modulo 256 with a prepended scratch space of one row of tiles

- once opened, unlink the file so it will actually disappear when the file descriptor is closed (old unix trick)

- mmap the complete file for reading and writing (cgimageref and turbo modes), or just two rows of tiles (libjpegincrmental)

- non-incrmental methods use the address returned from mmap with a CGBitmapContext, and use CGContextDrawImage to populate the bits

- for each zoom out level, create a similar file half the size, and efficiently (or with vImage) draw it

- for each file, rearrange the image so that continguous 256x256*4 memory chunks map exactly into one tile, in the same col/row order that the CATiledLayer draws

- when the view requests a tile, provide it with an image that uses CGDataProviderCreateDirect, which knows how to mmap the image file and provide the data in a single memcpy, mapping the smallerst possbile number of pages.

In the end, you have n files, each containing image tiles which can be memcpy'd efficiently (each tile consists of a contiguous block of memory pages). If the app crashes, the files go away so no cleanup. Once the images are created and go out of scope, they are unmapped. When the scrollview needs images, only those pages needed to populate the required tiles get mapped, and only long enought to memcpy the bits.

This solution scales to huge images. The limiting factor is the amount of file space. That said, you may need to tweak the mmap strategy if you have threads mapping in several huge images. For instance, you might use a serial queue to only allows one mmap to occur at a time if you have many downloads going at once.



PhotoScollerNetworkTURBO Target: INCREMENTAL DECODING (see http://sourceforge.net/projects/libjpeg-turbo)

When you download jpegs from the internet, the processor is idling waiting for the complete image to arrive, after which it decodes the image. If it were possible to have CGImageSourceCreateIncremental incrementally decode the image as it arrives (and you feed it this data), then my job would have been done. Alas, it does not do that, and my DTS event to find out some way to cajole it to do so was wasted. Thus, you will not find CGImageSourceCreateIncremental used in this project - in no case could it be used to make the process any faster than it is.

So, when using a highly compressed images and a fast WIFI connection, a large component of the total time between starting the image fetches and their display is the decode time. Decode time is the duration of decompressing a encoded image data object into a bit map in memory.

Fortunately, libjpeg provides the mechanism to incrementally decode jpegs (well, it cannot do this for progressive images so be aware of the type). There are scant examples of this on the web so I had to spend quite a bit of timed getting it to work. While I could have used libjpeg, I tripped over the libjpeg-turbo open source library. If your have to use an external library, might as well use one that has accelleration for the ARM chips used by iOS devices. It has the added benefit that once linked into your project, you can use it for faster decoding of on-file images.

To use this feature, you have to have the libturbojpeg.a libray (and headers). You have three options:

1) use the installer for 1.2.0 from http://sourceforge.net/projects/libjpeg-turbo. I have not yet tested this but it should work.

2) download my libjpeg-turbo-builder project and do a "Build" (it uses svn to pull the source). You'll need the latest autoconfig etc tools in this case. This way you can build either latest svn or a tagged release.

3) Use the libturbojpeg.a file I've included in this project (it's 1.2.0 that I build myself using the Xcode project as described above).


Process:

- the download starts, so allocate a jpeg decoder

- when web data appears, first get the header, then allocate the full file needed to hold the image

- as data arrives, the jpeg decoder:
  * writes lines of decoded image into a file
  * it write compressed lines into the other zoomable levels
  * when it gets a set of lines modulo the tile size, it processes one chunk of the image into tiles, ditto for the other zoomable levels
  * when the final chunk of memory arrives from the network, virtually all of the image processing work is done, and the images can be rendered immediately

Using an iPhone 4 running iOS 5, the sample images take around a second each to decode using CGContextDrawImage. But using incremental decoding, that time is spread out during the download (effectively loading the processor with work during a time it's normally idling), taking that final second of delay down to effectively 0 seconds.

For this networked code, a time metric that measures the time from when the first image starts to download til the last one finishes. 

