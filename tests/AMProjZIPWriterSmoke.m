#import <Foundation/Foundation.h>

#import "AMProjArchiveWriter.h"

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) return 2;

        NSString *outputPath = [NSString stringWithUTF8String:argv[1]];
        if (!outputPath.length) return 2;
        NSURL *outputURL = [NSURL fileURLWithPath:outputPath];
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
            [metrics[@"xml_count"] unsignedIntegerValue] != 1) {
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
        return 0;
    }
}
