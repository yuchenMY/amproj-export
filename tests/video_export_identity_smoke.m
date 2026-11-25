// 猫鹤 AM · 回归当前导出来源、小体积成片及跨次导出隔离。
#import <Foundation/Foundation.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>

@interface UIViewController : NSObject @end
@implementation UIViewController @end
@interface AVURLAsset : NSObject
@property(nonatomic, strong) NSURL *URL;
@end
@implementation AVURLAsset @end
@interface Completion : UIViewController
@property(nonatomic, strong) id outputURL;
@property(nonatomic, strong) id videoURL;
@property(nonatomic, strong) id url;
@property(nonatomic, strong) id fileURL;
@property(nonatomic, strong) id sourceVideoURL;
@end
@implementation Completion @end

static NSDictionary *AMProjReplicaLastVideoResolution;
static NSString *lastEventName;
static NSDictionary *lastEventFields;
static void amproj_logCriticalEvent(NSString *name, NSDictionary *fields) {
    lastEventName = name;
    lastEventFields = fields;
}
// AMPROJ_PRODUCTION_VIDEO_IDENTITY

static NSURL *writeFile(NSString *root, NSString *name, NSUInteger length) {
    NSURL *URL = [NSURL fileURLWithPath:[root stringByAppendingPathComponent:name]];
    NSMutableData *data = [NSMutableData dataWithLength:length];
    if (length >= 12) memcpy((uint8_t *)data.mutableBytes + 4, "ftypisom", 8);
    assert([data writeToURL:URL atomically:YES]);
    return URL;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        assert(argc == 2);
        NSString *root = [NSURL fileURLWithPath:@(argv[1])].URLByResolvingSymlinksInPath.path;
        NSFileManager *files = NSFileManager.defaultManager;
        NSString *cache = [root stringByAppendingPathComponent:@"Library/Caches/export/old-project"];
        assert([files createDirectoryAtPath:cache withIntermediateDirectories:YES attributes:nil error:nil]);
        NSURL *oldVideo = writeFile(cache, @"previous.mp4", 140000);
        NSData *meta = [NSJSONSerialization dataWithJSONObject:@{
            @"shareDates": @[@([NSDate date].timeIntervalSince1970)],
            @"exportDate": @([NSDate date].timeIntervalSince1970 - 60)
        } options:0 error:nil];
        assert([meta writeToFile:[cache stringByAppendingPathComponent:@"meta.json"] atomically:YES]);
        Completion *page = [Completion new];
        assert(AMProjReplicaVideoURLFromController(page) == nil);
        page.url = oldVideo; page.fileURL = oldVideo; page.sourceVideoURL = oldVideo;
        assert(AMProjReplicaVideoURLFromController(page) == nil);

        // 纯色短片可小于旧的 64 KB 门槛，不能被历史大文件替代。
        NSURL *current = writeFile(root, @"current-gray.mp4", 2048);
        assert([files setAttributes:@{NSFileModificationDate: [NSDate dateWithTimeIntervalSince1970:1]}
                      ofItemAtPath:current.path error:nil]);
        page.outputURL = current;
        assert([AMProjReplicaVideoURLFromController(page) isEqual:current]);
        assert([AMProjReplicaLastVideoResolution[@"source"] isEqual:@"controller_output"]);
        assert([lastEventName isEqual:@"share.replica_video_source"]);
        assert([lastEventFields[@"source"] isEqual:@"controller_output"]);
        page.videoURL = current;
        assert([AMProjReplicaVideoURLFromController(page) isEqual:current]);
        page.videoURL = oldVideo;
        assert(AMProjReplicaVideoURLFromController(page) == nil);
        assert([AMProjReplicaLastVideoResolution[@"reason"] isEqual:@"ambiguous_output"]);
        assert([lastEventFields[@"reason"] isEqual:@"ambiguous_output"]);
        page.videoURL = nil;

        // 新完成页没有明确输出时，不能继承上一次已解析的地址。
        assert(AMProjReplicaVideoURLFromController([Completion new]) == nil);
        assert([AMProjReplicaLastVideoResolution[@"file"] isEqual:@""]);
        page.outputURL = [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"missing.mp4"]];
        assert(AMProjReplicaVideoURLFromController(page) == nil);
        page.outputURL = writeFile(root, @"empty.mp4", 0);
        assert(AMProjReplicaVideoURLFromController(page) == nil);
        NSString *directory = [root stringByAppendingPathComponent:@"directory.mp4"];
        assert([files createDirectoryAtPath:directory withIntermediateDirectories:NO attributes:nil error:nil]);
        page.outputURL = [NSURL fileURLWithPath:directory];
        assert(AMProjReplicaVideoURLFromController(page) == nil);
        page.outputURL = [NSURL URLWithString:@"https://example.invalid/video.mp4"];
        assert(AMProjReplicaVideoURLFromController(page) == nil);
        page.outputURL = @"current-gray.mp4";
        assert(AMProjReplicaVideoURLFromController(page) == nil);

        AVURLAsset *asset = [AVURLAsset new];
        asset.URL = writeFile(root, @"current.Mp4", 1024);
        page.outputURL = asset;
        assert([AMProjReplicaVideoURLFromController(page) isEqual:asset.URL]);
        page.outputURL = writeFile(root, @"temporary-without-extension", 32);
        assert([AMProjReplicaVideoURLFromController(page) isEqual:page.outputURL]);
        NSURL *notVideo = [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"not-video"]];
        assert([[@"not a video" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:notVideo atomically:YES]);
        page.outputURL = notVideo;
        assert(AMProjReplicaVideoURLFromController(page) == nil);
        assert(AMProjReplicaVideoURLFromController(nil) == nil);
        puts("VIDEO_EXPORT_IDENTITY_PASS");
    }
}
