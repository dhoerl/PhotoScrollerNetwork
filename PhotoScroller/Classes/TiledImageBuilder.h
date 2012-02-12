
#define TILE_SIZE	256
#define ZOOM_LEVELS 4

@interface TiledImageBuilder : NSObject
@property (nonatomic, assign, readonly) BOOL failed;
@property (nonatomic, assign, readonly) size_t image0BytesPerRow;

// For use with image files (probably in the bundle)
- (id)initWithImagePath:(NSString *)path;

// For use with downloaded images
- (void *)mapMemoryForWidth:(size_t)w height:(size_t)h;
- (void)drawImage:(CGImageRef)image;
- (void)run;

- (CGSize)imageSize;
- (UIImage *)tileForScale:(CGFloat)scale row:(int)row col:(int)col;

// For turbo-jpeg
- (void *)scratchSpace;
- (size_t)scratchRowBytes;

@end

