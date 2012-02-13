PhotoScrollerNetwork Project

So, you want to use a scrolling view with zoomable images in an iOS device. You discover that Apple has this really nice sample project called "PhotoScroller", so you download and run it.

It looks really nice and seems to be exactly what you need! And you see three jpeg images with the three images you see in the UIScrollView. But, you dig deeper, and with a growing pit in your stomach, you discover that the project is a facade - it only works since those beautiful three jpegs are pre-tiles into 800 or so small png tiles, prepared to meet the needs of the CATiledLayer backing the scrollview.

This code leverages my github ConcurrentNSOperations project, as image fetching is done using Concurrent Operations.

The included Xcode 4 project has two targets, one using just Apple APIs, and the second using libjpeg-turbo as explained below.

PhotoScollerNetwork Target: FAST AND EFFICIENT TILING

Fear not! Now you have PhotoScrollerNetwork to the rescue! Not only does this project solve the problem of how to get those 800 tiles in an efficient and elegant manner, but it also shows you how to fetch images from the network using Concurrent NSOperations, then efficiently decode and re-format them for rapid display by the CATiledLayer. I challenge anyone to make this faster!

Process:

- obtain a complete image as a file URL or as a NSData object

- create a tmp file what is the same or larger having dimension modulo 256 with a prepended scratch space of one row of tiles

- once opened, unlink the file so it will actually disappear when the file descriptor is closed (old unix trick)

- mmap the complete file for reading and writing

- use the address returned from mmap with a CGBitmapContext, and use CGContextDrawImage to populate the bits

- for each zoom out level, create a similar file half the size, and efficiently (or with vImage) populate it

- for each file, rearrange the image so that each 256x256 area maps exactly into one tile, in the same col/row order that the CATiledLayer draws

In the end, you have n files, each containing image tiles which can be memcpy'd efficiently with adjacent mmap areas (each tile consists of a contiguous block of memory pages). If the app crashes, the files go away so no cleanup. Once the images are created and go out of scope, they are unmapped. When the scrollview needs images, only those pages needed to populate the required tiles get mapped.

This solution scales to huge images. The limiting factor is the amount of file space. That said, you may need to tweak the mmap strategy if you have threads mapping in several huge images.


PhotoScollerNetworkTURBO Target: INCREMENTAL DECODING

When you download jpegs from the internet, the processor is idling waiting for the complete image to arrive, after which it decodes the image. If it were possible to have CGImageSourceCreateIncremental incrementally decode the image as it arrives (and you feed it more data), then my job would have been done. Alas, it does not do that, and my DTS event to find out some way to cajole it to do so was wasted. Thus, you will not find CGImageSourceCreateIncremental used in this project - in no case could it be used to make the process any faster than it is.

So, when using a highly compressed images and a fast WIFI connection, a large component of the total time between starting the image fetches and their display is the decode time. Decode time is the duration of decompressing a encoded image blob into a bit map in memory.

Fortunately, libjpeg provides the mechanism to incrementally decode jpegs (well, it cannot do this for progressive images so be aware of the type). There are scant examples of this on the web so I had to spend quite a bit of timed getting it to work. While I could have used libjpeg, I tripped over the libjpeg-turbo open source library. If your have to use an external library, might as well use one that has accelleration for the ARM chips used by iOS devices. It has the added benefit that once linked into your project, you can use it for faster decoding of on-file images.

Process:

- the download starts, so allocate a jpeg decoder

- when web data appears, first get the header, then allocate the full file needed to hold the image

- as data arrives, the jpeg decoder supplies lines of decoded image using the file scratch space area, and from there are mapped appropriately to the real image area on file

- when the very last chunk of data arrives, the final few scan lines are processed, and the operation completes - a process taking only a few milliseconds.

Using an iPhone 4 running iOS 5, the sample images take around a second each to decode using CGContextDrawImage. But using incremental decoding, that time is spread out during the download (effectively loading the processor with work during a time it's normally idling), taking that final second of delay down to effectively 0 seconds.