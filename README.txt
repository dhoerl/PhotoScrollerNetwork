PhotoScrollerNetwork Project

This sample code:

- builds on Apple's PhotoScroller project by addressing its deficiencies
- provides the means to process large images for use in a zoomable scrollview
- is backed by a CATiledLayer so that only those tiles needed for display consume memory
- tiles the files backing the CATiledLayer for rapid tile rendering
- demonstrates how to use concurrent NSOperations to fetch several large images concurrently
- measure the time from when the first image starts decoding til the last one finished for 3 technologies

 * * *

So, you want to use a scrolling view with zoomable images in an iOS device. You discover that Apple has this really nice sample project called "PhotoScroller", so you download and run it.

It looks really nice and seems to be exactly what you need! And you see three jpeg images with the three images you see in the UIScrollView. But, you dig deeper, and with a growing pit in your stomach, you discover that the project is a facade - it only works since those beautiful three jpegs are pre-tiled into 800 or so small png tiles, prepared to meet the needs of the CATiledLayer backing the scrollview.

Fear not! Now you have PhotoScrollerNetwork to the rescue! Not only does this project solve the problem of using a single image in an efficient and elegant manner, but it also shows you how to fetch images from the network using Concurrent NSOperations, and then how to efficiently decode and re-format them for rapid display by the CATiledLayer. Note that for single core processors like the 3GS and 4, the decode time is additive. I challenge anyone to make this faster!

This code leverages my github Concurrent_NSOperations project (https://github.com/dhoerl/Concurrent_NSOperations), as image fetching is done using Concurrent NSOperations. The images were uploaded to my public Dropbox folder - you will see the URL if you look around.

The included Xcode 4 project has two targets, one using just Apple APIs, and the second using libjpeg-turbo, both explained below.

KNOWN BUGS:
- if you quit the project with the scroll view showing, you get a crash
- the jpeg error handler is not yet setup properly

TODO:
- instead of using drawRect: and UIImages, use drawLayer: and CGImageRefs directly
- fix the zoom problem that appears sometime when zooming an image close to a boundary of another image (I suspect this is in the original Apple code)


PhotoScollerNetwork Target: FAST AND EFFICIENT TILING

This target does exactly what the PhotoScroller does, but it only needs a single jpeg per view, and it dynamically creates all the tiles as sections of a larger file instead of using individual files.

Process:

- obtain a complete image as a file URL or as a NSData object

- create a tmp file what is the same or larger having dimension modulo 256 with a prepended scratch space of one row of tiles

- once opened, unlink the file so it will actually disappear when the file descriptor is closed (old unix trick)

- mmap the complete file for reading and writing

- use the address returned from mmap with a CGBitmapContext, and use CGContextDrawImage to populate the bits

- for each zoom out level, create a similar file half the size, and efficiently (or with vImage) populate it

- for each file, rearrange the image so that each 256x256 area maps exactly into one tile, in the same col/row order that the CATiledLayer draws

- when the view requests a tile, provide it with an image that uses CGDataProviderCreateDirect, which knows how to mmap the image file and provide the data in a single memcpy, mapping the smallerst possbile number of pages.

In the end, you have n files, each containing image tiles which can be memcpy'd efficiently with adjacent mmap areas (each tile consists of a contiguous block of memory pages). If the app crashes, the files go away so no cleanup. Once the images are created and go out of scope, they are unmapped. When the scrollview needs images, only those pages needed to populate the required tiles get mapped.

This solution scales to huge images. The limiting factor is the amount of file space. That said, you may need to tweak the mmap strategy if you have threads mapping in several huge images. [That is, in this case you would not map the whole file, but only rows of tiles as required.]




PhotoScollerNetworkTURBO Target: INCREMENTAL DECODING (see http://sourceforge.net/projects/libjpeg-turbo)

When you download jpegs from the internet, the processor is idling waiting for the complete image to arrive, after which it decodes the image. If it were possible to have CGImageSourceCreateIncremental incrementally decode the image as it arrives (and you feed it this data), then my job would have been done. Alas, it does not do that, and my DTS event to find out some way to cajole it to do so was wasted. Thus, you will not find CGImageSourceCreateIncremental used in this project - in no case could it be used to make the process any faster than it is.

So, when using a highly compressed images and a fast WIFI connection, a large component of the total time between starting the image fetches and their display is the decode time. Decode time is the duration of decompressing a encoded image blob into a bit map in memory.

Fortunately, libjpeg provides the mechanism to incrementally decode jpegs (well, it cannot do this for progressive images so be aware of the type). There are scant examples of this on the web so I had to spend quite a bit of timed getting it to work. While I could have used libjpeg, I tripped over the libjpeg-turbo open source library. If your have to use an external library, might as well use one that has accelleration for the ARM chips used by iOS devices. It has the added benefit that once linked into your project, you can use it for faster decoding of on-file images.

To use this feature, you have to have the libturbojpeg.a libray (and headers). You have three options:

1) use the installer for 1.2.0 from http://sourceforge.net/projects/libjpeg-turbo. I have not yet tested this but it should work.

2) download my libjpeg-turbo-builder project and do a "Build" (it uses svn to pull the source). You'll need the latest autoconfig etc tools in this case. This way you can build either latest svn or a tagged release.

3) Use the libturbojpeg.a file I've included in this project (it's 1.2.0 that I build myself using the Xcode project as described above).


Process:

- the download starts, so allocate a jpeg decoder

- when web data appears, first get the header, then allocate the full file needed to hold the image

- as data arrives, the jpeg decoder supplies lines of decoded image using the file scratch space area, and from there are mapped appropriately to the real image area on file

- when the very last chunk of data arrives, the final few scan lines are processed, and the operation completes - a process taking only a few milliseconds.

Using an iPhone 4 running iOS 5, the sample images take around a second each to decode using CGContextDrawImage. But using incremental decoding, that time is spread out during the download (effectively loading the processor with work during a time it's normally idling), taking that final second of delay down to effectively 0 seconds.

For this networked code, a time metric that measures the time from when the first image starts to decode til the last one finishes. This would seem to be the best possible metric as it more accurately represents the time from when the first image finishes downloading until the user gets control of the scrollview. On my iphone 4, the this delay is halved by the incremental decoder relative to the CGContextDrawImage based code. I would have thought it would be quicker, but there is a lot going on in this single core device. Bet it really hums on the iPhone 4S.

