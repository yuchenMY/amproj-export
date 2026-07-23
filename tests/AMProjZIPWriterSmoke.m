#import <Foundation/Foundation.h>

#import "AMProjArchiveWriter.h"

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3) return 2;

        NSString *outputPath = [NSString stringWithUTF8String:argv[1]];
        NSString *emptyOutputPath = [NSString stringWithUTF8String:argv[2]];
        if (!outputPath.length || !emptyOutputPath.length) return 2;
        NSURL *outputURL = [NSURL fileURLWithPath:outputPath];
        NSURL *emptyOutputURL = [NSURL fileURLWithPath:emptyOutputPath];
        NSURL *resourceURL = [[outputURL URLByDeletingLastPathComponent]
            URLByAppendingPathComponent:@"amproj-writer-resource.bin"];
        NSMutableData *resource = [NSMutableData dataWithLength:200000];
        uint8_t *bytes = resource.mutableBytes;
        for (NSUInteger index = 0; index < resource.length; index++) {
            bytes[index] = (uint8_t)((index * 31) & 0xff);
        }
        NSError *error = nil;
        if (![resource writeToURL:resourceURL options:NSDataWritingAtomic error:&error]) {
            NSLog(@"resource write failed: %@", error);
            return 3;
        }

        NSData *xml = [@"<?xml version=\"1.0\"?><scene title=\"smoke\"></scene>"
            dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary<NSString *, NSNumber *> *metrics = nil;
        BOOL written = AMProjZIPWriteProjectArchive(
            outputURL, xml, @{@"resource.bin": resourceURL}, &metrics, &error);
        if (!written || ![metrics[@"crc_verified"] boolValue] ||
            ![metrics[@"manifest_verified"] boolValue] ||
            [metrics[@"xml_count"] unsignedIntegerValue] != 1 ||
            [metrics[@"manifest_count"] unsignedIntegerValue] != 1 ||
            [metrics[@"entry_count"] unsignedIntegerValue] != 3) {
            NSLog(@"archive write failed: %@ metrics=%@", error, metrics);
            return 4;
        }

        error = nil;
        if (!AMProjWriteArchive(outputURL, xml, @"scene.xml",
                                @{@"resource.bin": resourceURL}, &error)) {
            NSLog(@"archive replacement failed: %@", error);
            return 5;
        }

        error = nil;
        if (AMProjZIPWriteProjectArchive(outputURL, xml,
                                         @{@"second.xml": resourceURL}, nil, &error) ||
            error.code != AMProjZIPErrorInvalidEntry) {
            NSLog(@"second XML was not rejected: %@", error);
            return 6;
        }

        error = nil;
        NSDictionary<NSString *, NSNumber *> *emptyMetrics = nil;
        if (!AMProjZIPWriteProjectArchive(emptyOutputURL, xml, @{},
                                          &emptyMetrics, &error) ||
            ![emptyMetrics[@"crc_verified"] boolValue] ||
            ![emptyMetrics[@"manifest_verified"] boolValue] ||
            [emptyMetrics[@"xml_count"] unsignedIntegerValue] != 1 ||
            [emptyMetrics[@"manifest_count"] unsignedIntegerValue] != 1 ||
            [emptyMetrics[@"entry_count"] unsignedIntegerValue] != 2) {
            NSLog(@"empty manifest archive write failed: %@ metrics=%@",
                  error, emptyMetrics);
            return 7;
        }
        return 0;
    }
}
