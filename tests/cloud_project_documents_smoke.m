// 猫鹤 AM · 验证云端 XML 原字节、旧包兼容边界与下载重试策略。
#import <Foundation/Foundation.h>
#include <stdio.h>
#import "AMProjImportArchive.h"
#import "AMProjZIPWriter.h"

static NSURL *testRoot;
static uint64_t testAuthGeneration = 1;
static NSURL *amproj_directExportRoot(void) { return testRoot; }
static NSURL *AMCloudProjectDownloadRootURL(void) { return testRoot; }
static BOOL AMCloudAuthMatches(NSString *token, uint64_t generation) {
    return generation == testAuthGeneration && [token isEqualToString:@"account-A"];
}
static NSString *amproj_safeFilename(NSString *title, NSString *fallback) {
    return title.length ? title : fallback;
}

// AMPROJ_PRODUCTION_DOCUMENT_FUNCTIONS

#define CHECK(condition) do { if (!(condition)) { NSLog(@"Failed at line %d", __LINE__); return 1; } } while (0)

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        CHECK(argc == 2);
        testRoot = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]] isDirectory:YES];
        NSData *XML = [@"<scene type=\"project\" title=\"Test\"><media uri=\"amproj:missing.png\"/></scene>"
            dataUsingEncoding:NSUTF8StringEncoding];
        NSError *error = nil;
        NSURL *document = amproj_writeProjectOnlyXML(XML, @"测试工程", &error);
        CHECK(document && !error && [document.pathExtension isEqualToString:@"xml"]);
        CHECK([[NSData dataWithContentsOfURL:document] isEqualToData:XML]);
        CHECK(![NSFileManager.defaultManager fileExistsAtPath:
            [document.URLByDeletingPathExtension URLByAppendingPathExtension:@"amproj"].path]);
        CHECK([AMCloudSafeFilename(@"测试工程.xml") isEqualToString:@"测试工程.xml"]);
        CHECK([AMCloudSafeFilename(@"PROJECT.XML") isEqualToString:@"PROJECT.XML"]);
        CHECK([AMCloudSafeFilename(@"a.amproj") isEqualToString:@"a.amproj"]);
        CHECK([AMCloudUploadHeaderFilename(@"测试工程.xml") isEqualToString:@"project.xml"]);
        CHECK([AMCloudUploadHeaderFilename(@"测试工程.amproj") isEqualToString:@"project.amproj"]);
        CHECK([AMCloudProjectFormat(@{@"filename": @"new.XML", @"sizeBytes": @15000}) isEqualToString:@"XML"]);
        CHECK([AMCloudProjectFormat(@{@"filename": @"old.amproj", @"sizeBytes": @15000}) isEqualToString:@"AMPROJ"]);
        CHECK([AMCloudProjectFormat(@{@"filename": @"full.amproj", @"sizeBytes": @125383680}) isEqualToString:@"AMPROJ"]);
        CHECK([AMCloudProjectFormat(@{@"filename": @"unknown.zip"}) isEqualToString:@"备份"]);
        CHECK([AMCloudProjectDownloadTitle(@{@"currentVersion": @{@"filename": @"工程.XML"}})
            isEqualToString:@"正在下载 XML"]);
        CHECK([AMCloudProjectDownloadTitle(@{@"currentVersion": @{@"filename": @"old.amproj", @"sizeBytes": @15000}})
            isEqualToString:@"正在下载项目包"]);
        CHECK([AMCloudProjectDownloadTitle(@{@"currentVersion": @{@"filename": @"unknown.zip"}})
            isEqualToString:@"正在下载备份"]);
        CHECK([AMCloudProjectDownloadTitle(@{@"currentVersion": NSNull.null}) isEqualToString:@"正在下载备份"]);
        CHECK([AMCloudProjectDownloadTitle(@{}) isEqualToString:@"正在下载备份"]);

        NSURL *legacy = [testRoot URLByAppendingPathComponent:@"legacy.amproj"];
        CHECK(AMProjZIPWriteProjectArchive(legacy, XML, @{}, NULL, &error));
        NSDictionary *metrics = nil;
        NSURL *nativeXML = nil;
        CHECK(AMProjPrepareNativeImport(legacy, testRoot, &nativeXML, &metrics, &error));
        CHECK(amproj_isLegacyCloudXMLBackup(@"cloud_download_865", metrics));
        CHECK([metrics[@"missing_media_signature_count"] unsignedIntegerValue] == 1);
        NSURL *original = [[NSURL fileURLWithPath:metrics[@"extraction_directory"] isDirectory:YES]
            URLByAppendingPathComponent:[metrics[@"xml_names"] firstObject]];
        CHECK([[NSData dataWithContentsOfURL:original] isEqualToData:XML]);
        CHECK(!amproj_isLegacyCloudXMLBackup(@"document_picker", metrics));
        CHECK(!amproj_isLegacyCloudXMLBackup(@"cloud_download_865", nil));
        NSDictionary *invalid = @{@"manifest_verified": @NO, @"manifest_count": @1,
            @"xml_count": @1, @"resource_count": @0, @"manifest_entry_count": @0};
        CHECK(!amproj_isLegacyCloudXMLBackup(@"cloud_download_865", invalid));
        for (NSString *key in @[@"resource_count", @"manifest_entry_count", @"xml_count", @"manifest_count"]) {
            NSMutableDictionary *changed = [metrics mutableCopy];
            changed[key] = [key hasSuffix:@"count"] && [key hasPrefix:@"xml"] ? @2 : @1;
            if ([key isEqualToString:@"manifest_count"]) changed[key] = @2;
            CHECK(!amproj_isLegacyCloudXMLBackup(@"cloud_download_865", changed));
        }
        NSURL *vectorArchive = [testRoot URLByAppendingPathComponent:@"valid-vector-project.amproj"];
        NSData *vectorXML = [@"<scene type=\"project\" title=\"Vectors\"/>"
            dataUsingEncoding:NSUTF8StringEncoding];
        CHECK(AMProjZIPWriteProjectArchive(vectorArchive, vectorXML, @{}, NULL, &error));
        NSDictionary *vectorMetrics = nil;
        CHECK(AMProjPrepareNativeImport(vectorArchive, testRoot, NULL, &vectorMetrics, &error));
        CHECK([vectorMetrics[@"manifest_verified"] boolValue]);
        CHECK([vectorMetrics[@"missing_reference_count"] unsignedIntegerValue] == 0);
        CHECK([vectorMetrics[@"missing_media_signature_count"] unsignedIntegerValue] == 0);
        CHECK(!amproj_isLegacyCloudXMLBackup(@"cloud_download_865", vectorMetrics));
        for (NSNumber *code in @[@(NSURLErrorNetworkConnectionLost), @(NSURLErrorTimedOut)]) {
            NSError *network = [NSError errorWithDomain:NSURLErrorDomain code:code.integerValue userInfo:nil];
            CHECK(AMCloudShouldRetryProjectDownload(network, 0));
            CHECK(!AMCloudShouldRetryProjectDownload(network, 1));
        }
        for (NSNumber *code in @[@(NSURLErrorCancelled), @(NSURLErrorNotConnectedToInternet), @401]) {
            CHECK(!AMCloudShouldRetryProjectDownload([NSError errorWithDomain:NSURLErrorDomain
                code:code.integerValue userInfo:nil], 0));
        }
        CHECK(!AMCloudShouldRetryProjectDownload([NSError errorWithDomain:@"integrity"
            code:NSURLErrorNetworkConnectionLost userInfo:nil], 0));
        CHECK(!AMCloudShouldRetryProjectDownload(nil, 0));
        NSURL *download = [testRoot URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
        CHECK([NSFileManager.defaultManager createDirectoryAtURL:download
            withIntermediateDirectories:YES attributes:nil error:&error]);
        NSDictionary *downloadResult = @{@"cleanupURL": download};
        CHECK(AMCloudValidateProjectDownloadContext(downloadResult, @"account-A", 1));
        CHECK([NSFileManager.defaultManager fileExistsAtPath:download.path]);
        // 网络已成功，但散列/主队列延迟期间切号，不得继续交接旧下载。
        testAuthGeneration = 2;
        CHECK(!AMCloudValidateProjectDownloadContext(downloadResult, @"account-A", 1));
        CHECK(![NSFileManager.defaultManager fileExistsAtPath:download.path]);
        CHECK(!AMCloudValidateProjectDownloadContext(@{@"cleanupURL": document}, @"account-A", 1));
        CHECK([NSFileManager.defaultManager fileExistsAtPath:document.path]);
        testRoot = document;
        error = nil;
        CHECK(!amproj_writeProjectOnlyXML(XML, @"blocked", &error) && error);
        puts("CLOUD_PROJECT_DOCUMENTS_PASS");
    }
    return 0;
}
