#import <Foundation/Foundation.h>

#import <stdlib.h>
#import <string.h>

#import "AMProjImportArchive.h"

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 5) return 2;
        NSURL *archiveURL = [NSURL fileURLWithPath:
            [NSString stringWithUTF8String:argv[1]]];
        NSURL *workURL = [NSURL fileURLWithPath:
            [NSString stringWithUTF8String:argv[2]] isDirectory:YES];
        BOOL expectSuccess = strcmp(argv[3], "ok") == 0 ||
            strcmp(argv[3], "multi") == 0 ||
            strcmp(argv[3], "manifest") == 0 ||
            strcmp(argv[3], "manifest-empty") == 0;
        BOOL multiXML = strcmp(argv[3], "multi") == 0;
        BOOL verifiedManifest = strcmp(argv[3], "manifest") == 0 || multiXML;
        BOOL emptyManifest = strcmp(argv[3], "manifest-empty") == 0;
        BOOL standardFixture = !multiXML && !emptyManifest;
        BOOL normalize = strcmp(argv[3], "normalize") == 0;
        NSUInteger expectedMissing = (NSUInteger)strtoull(argv[4], NULL, 10);

        NSURL *nativeXMLURL = nil;
        NSDictionary<NSString *, id> *metrics = nil;
        NSError *error = nil;
        NSURL *normalizedURL = [workURL URLByAppendingPathComponent:@"normalized.amproj"];
        BOOL success = normalize
            ? AMProjNormalizeProjectArchive(archiveURL, workURL, normalizedURL, &metrics, &error)
            : AMProjPrepareNativeImport(archiveURL, workURL, &nativeXMLURL, &metrics, &error);
        if (normalize) {
            if (!success || error || ![NSFileManager.defaultManager
                    fileExistsAtPath:normalizedURL.path] ||
                [metrics[@"missing_reference_count"] unsignedIntegerValue] != expectedMissing ||
                [metrics[@"input_manifest_count"] unsignedIntegerValue] > 1 ||
                [metrics[@"zip"][@"manifest_count"] unsignedIntegerValue] != 1) {
                NSLog(@"archive normalization failed: %@ %@", metrics, error);
                return 6;
            }
            return 0;
        }
        if (!expectSuccess) {
            if (success || error == nil) {
                NSLog(@"invalid archive unexpectedly succeeded: %@ %@", metrics, error);
                return 3;
            }
            return 0;
        }
        NSUInteger expectedXMLCount = multiXML ? 2 : 1;
        if (!success || !nativeXMLURL || error ||
            [metrics[@"xml_count"] unsignedIntegerValue] != expectedXMLCount ||
            [metrics[@"missing_reference_count"] unsignedIntegerValue] != expectedMissing ||
            (standardFixture && [metrics[@"reference_count"] unsignedIntegerValue] != 2) ||
            (standardFixture && [metrics[@"rewritten_reference_count"] unsignedIntegerValue] != 1) ||
            (verifiedManifest && ![metrics[@"manifest_verified"] boolValue]) ||
            (verifiedManifest && [metrics[@"resource_count"] unsignedIntegerValue] != 1) ||
            (verifiedManifest && [metrics[@"manifest_entry_count"] unsignedIntegerValue] != 1) ||
            (verifiedManifest && [metrics[@"manifest_verified_resource_count"] unsignedIntegerValue] != 1) ||
            (emptyManifest && ![metrics[@"manifest_verified"] boolValue]) ||
            (emptyManifest && [metrics[@"resource_count"] unsignedIntegerValue] != 0) ||
            (emptyManifest && [metrics[@"manifest_entry_count"] unsignedIntegerValue] != 0) ||
            (emptyManifest && [metrics[@"manifest_verified_resource_count"] unsignedIntegerValue] != 0) ||
            ![nativeXMLURL.lastPathComponent hasSuffix:@".native-import.xml"]) {
            NSLog(@"native import preparation failed: %@ %@ %@", nativeXMLURL, metrics, error);
            return 4;
        }

        NSString *xml = [NSString stringWithContentsOfURL:nativeXMLURL
                                                 encoding:NSUTF8StringEncoding
                                                    error:&error];
        NSData *rewrittenData = [xml dataUsingEncoding:NSUTF8StringEncoding];
        NSXMLParser *parser = [[NSXMLParser alloc] initWithData:rewrittenData ?: NSData.data];
        if (!xml || ![parser parse] ||
            (standardFixture && [xml containsString:@"amproj:asset%20&amp;%20one.bin"]) ||
            (standardFixture && ![xml containsString:@"file://"]) ||
            (standardFixture && ![xml containsString:@"amproj:missing.mp4"])) {
            NSLog(@"rewritten XML is incorrect: %@ error=%@", xml, error);
            return 5;
        }
        return 0;
    }
}
