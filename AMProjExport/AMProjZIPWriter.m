#import "AMProjArchiveWriter.h"

#import <errno.h>
#import <fcntl.h>
#import <limits.h>
#import <sys/stat.h>
#import <unistd.h>
#import <zlib.h>

NSString *const AMProjZIPErrorDomain = @"com.amproj.export.zip";

static const size_t kAMProjZIPBufferSize = 64 * 1024;
static const uint64_t kAMProjZIPSpaceReserve = 8 * 1024 * 1024;
static const uint16_t kAMProjZIPUTF8Flag = 0x0800;

@interface AMProjZIPEntry : NSObject
@property(nonatomic, copy) NSString *name;
@property(nonatomic, strong) NSData *nameData;
@property(nonatomic, strong, nullable) NSData *data;
@property(nonatomic, strong, nullable) NSURL *sourceURL;
@property(nonatomic) uint64_t sourceLength;
@property(nonatomic) uint32_t localOffset;
@property(nonatomic) uint32_t payloadOffset;
@property(nonatomic) uint32_t crc;
@property(nonatomic) uint32_t compressedSize;
@property(nonatomic) uint32_t uncompressedSize;
@end

@implementation AMProjZIPEntry
@end

static BOOL AMProjZIPFail(NSError **error, AMProjZIPErrorCode code,
                          NSString *description, NSDictionary *details) {
    if (error) {
        NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithDictionary:details ?: @{}];
        userInfo[NSLocalizedDescriptionKey] = description ?: @"Project archive error";
        *error = [NSError errorWithDomain:AMProjZIPErrorDomain code:code userInfo:userInfo];
    }
    return NO;
}

static void AMProjZIPPut16(uint8_t *buffer, NSUInteger offset, uint16_t value) {
    buffer[offset] = (uint8_t)value;
    buffer[offset + 1] = (uint8_t)(value >> 8);
}

static void AMProjZIPPut32(uint8_t *buffer, NSUInteger offset, uint32_t value) {
    buffer[offset] = (uint8_t)value;
    buffer[offset + 1] = (uint8_t)(value >> 8);
    buffer[offset + 2] = (uint8_t)(value >> 16);
    buffer[offset + 3] = (uint8_t)(value >> 24);
}

static BOOL AMProjZIPWriteAll(int fd, const void *bytes, size_t length,
                              uint64_t *offset, NSError **error) {
    const uint8_t *cursor = bytes;
    size_t remaining = length;
    while (remaining > 0) {
        ssize_t written = write(fd, cursor, remaining);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) {
            return AMProjZIPFail(error, AMProjZIPErrorOutputIO,
                                 @"Unable to write the project archive",
                                 @{ @"errno": @(errno) });
        }
        cursor += written;
        remaining -= (size_t)written;
        *offset += (uint64_t)written;
    }
    return YES;
}

static BOOL AMProjZIPSeek(int fd, uint64_t offset, NSError **error) {
    if (offset > (uint64_t)LLONG_MAX || lseek(fd, (off_t)offset, SEEK_SET) < 0) {
        return AMProjZIPFail(error, AMProjZIPErrorOutputIO,
                             @"Unable to seek in the project archive",
                             @{ @"errno": @(errno) });
    }
    return YES;
}

static BOOL AMProjZIPValidResourceName(NSString *name, NSData **nameData,
                                       NSError **error) {
    if (![name isKindOfClass:NSString.class] || name.length == 0 ||
        [name isEqualToString:@"."] || [name isEqualToString:@".."] ||
        [name hasPrefix:@"/"] || [name containsString:@"/"] ||
        [name containsString:@"\\"] ||
        [name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) {
        return AMProjZIPFail(error, AMProjZIPErrorInvalidEntry,
                             @"Resource filenames must be non-empty flat filenames",
                             @{ @"entry": name ?: @"" });
    }
    if ([name.pathExtension caseInsensitiveCompare:@"xml"] == NSOrderedSame) {
        return AMProjZIPFail(error, AMProjZIPErrorInvalidEntry,
                             @"A project package may contain only one XML file",
                             @{ @"entry": name });
    }
    NSData *encoded = [name dataUsingEncoding:NSUTF8StringEncoding];
    if (!encoded || encoded.length == 0 || encoded.length > UINT16_MAX) {
        return AMProjZIPFail(error, AMProjZIPErrorInvalidEntry,
                             @"Resource filename is not valid ZIP UTF-8",
                             @{ @"entry": name });
    }
    if (nameData) *nameData = encoded;
    return YES;
}

static NSNumber *AMProjZIPAvailableBytes(NSURL *directoryURL) {
    id capacity = nil;
    if ([directoryURL getResourceValue:&capacity
                                forKey:NSURLVolumeAvailableCapacityForImportantUsageKey
                                 error:nil] && [capacity isKindOfClass:NSNumber.class]) {
        return capacity;
    }
    NSDictionary *attributes = [[NSFileManager defaultManager]
        attributesOfFileSystemForPath:directoryURL.path error:nil];
    id freeSize = attributes[NSFileSystemFreeSize];
    return [freeSize isKindOfClass:NSNumber.class] ? freeSize : nil;
}

static BOOL AMProjZIPAddChecked(uint64_t *total, uint64_t value) {
    if (UINT64_MAX - *total < value) return NO;
    *total += value;
    return YES;
}

static BOOL AMProjZIPPrepareEntries(NSData *sceneXML,
                                    NSDictionary<NSString *, NSURL *> *resourceURLs,
                                    NSArray<AMProjZIPEntry *> **preparedEntries,
                                    uint64_t *uncompressedBytes,
                                    uint64_t *requiredBytes,
                                    NSError **error) {
    if (sceneXML.length == 0) {
        return AMProjZIPFail(error, AMProjZIPErrorInvalidArgument,
                             @"Scene XML is empty", nil);
    }
    if (sceneXML.length > UINT32_MAX || resourceURLs.count >= UINT16_MAX) {
        return AMProjZIPFail(error, AMProjZIPErrorZIP32Limit,
                             @"Project contents exceed ZIP32 limits", nil);
    }

    NSMutableArray<AMProjZIPEntry *> *entries = [NSMutableArray array];
    AMProjZIPEntry *xmlEntry = [AMProjZIPEntry new];
    xmlEntry.name = @"scene.xml";
    xmlEntry.nameData = [xmlEntry.name dataUsingEncoding:NSUTF8StringEncoding];
    xmlEntry.data = sceneXML;
    xmlEntry.sourceLength = sceneXML.length;
    [entries addObject:xmlEntry];

    NSMutableSet<NSString *> *seenNames = [NSMutableSet setWithObject:xmlEntry.name.lowercaseString];
    NSArray<NSString *> *resourceNames = [resourceURLs.allKeys
        sortedArrayUsingSelector:@selector(compare:)];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    for (NSString *name in resourceNames) {
        NSURL *sourceURL = resourceURLs[name];
        NSData *nameData = nil;
        if (!AMProjZIPValidResourceName(name, &nameData, error)) return NO;
        NSString *foldedName = name.lowercaseString;
        if ([seenNames containsObject:foldedName]) {
            return AMProjZIPFail(error, AMProjZIPErrorInvalidEntry,
                                 @"Project archive contains duplicate filenames",
                                 @{ @"entry": name });
        }
        if (![sourceURL isKindOfClass:NSURL.class] || !sourceURL.isFileURL) {
            return AMProjZIPFail(error, AMProjZIPErrorInvalidEntry,
                                 @"Resource source must be a local file URL",
                                 @{ @"entry": name });
        }
        NSDictionary *attributes = [fileManager attributesOfItemAtPath:sourceURL.path error:nil];
        if (![attributes[NSFileType] isEqual:NSFileTypeRegular]) {
            return AMProjZIPFail(error, AMProjZIPErrorSourceUnavailable,
                                 @"Resource file is unavailable",
                                 @{ @"entry": name, @"path": sourceURL.path ?: @"" });
        }
        uint64_t length = [attributes[NSFileSize] unsignedLongLongValue];
        if (length > UINT32_MAX) {
            return AMProjZIPFail(error, AMProjZIPErrorZIP32Limit,
                                 @"A resource exceeds the ZIP32 per-file limit",
                                 @{ @"entry": name, @"bytes": @(length) });
        }

        AMProjZIPEntry *entry = [AMProjZIPEntry new];
        entry.name = name;
        entry.nameData = nameData;
        entry.sourceURL = sourceURL;
        entry.sourceLength = length;
        [entries addObject:entry];
        [seenNames addObject:foldedName];
    }

    uint64_t uncompressed = 0;
    uint64_t worstCase = 22;
    for (AMProjZIPEntry *entry in entries) {
        uLong compressedBound = compressBound((uLong)entry.sourceLength);
        if (compressedBound > UINT32_MAX ||
            !AMProjZIPAddChecked(&uncompressed, entry.sourceLength) ||
            !AMProjZIPAddChecked(&worstCase, 30 + entry.nameData.length) ||
            !AMProjZIPAddChecked(&worstCase, compressedBound) ||
            !AMProjZIPAddChecked(&worstCase, 46 + entry.nameData.length)) {
            return AMProjZIPFail(error, AMProjZIPErrorZIP32Limit,
                                 @"Project archive exceeds ZIP32 limits", nil);
        }
    }
    if (worstCase > UINT32_MAX) {
        return AMProjZIPFail(error, AMProjZIPErrorZIP32Limit,
                             @"Project archive exceeds the 4 GiB ZIP32 limit",
                             @{ @"estimated_bytes": @(worstCase) });
    }

    *preparedEntries = entries;
    *uncompressedBytes = uncompressed;
    *requiredBytes = worstCase;
    return YES;
}

static BOOL AMProjZIPDeflateEntry(AMProjZIPEntry *entry, int outputFD,
                                  uint64_t *outputOffset, NSError **error) {
    int inputFD = -1;
    if (entry.sourceURL) {
        inputFD = open(entry.sourceURL.fileSystemRepresentation, O_RDONLY);
        if (inputFD < 0) {
            return AMProjZIPFail(error, AMProjZIPErrorSourceUnavailable,
                                 @"Unable to open a resource file",
                                 @{ @"entry": entry.name, @"errno": @(errno) });
        }
        struct stat sourceStat = {0};
        if (fstat(inputFD, &sourceStat) != 0 || !S_ISREG(sourceStat.st_mode) ||
            sourceStat.st_size < 0 || (uint64_t)sourceStat.st_size != entry.sourceLength) {
            int savedErrno = errno;
            close(inputFD);
            return AMProjZIPFail(error, AMProjZIPErrorSourceUnavailable,
                                 @"Resource changed while preparing the archive",
                                 @{ @"entry": entry.name, @"errno": @(savedErrno) });
        }
    }

    uint8_t localHeader[30] = {0};
    AMProjZIPPut32(localHeader, 0, 0x04034b50);
    AMProjZIPPut16(localHeader, 4, 20);
    AMProjZIPPut16(localHeader, 6, kAMProjZIPUTF8Flag);
    AMProjZIPPut16(localHeader, 8, 8);
    AMProjZIPPut16(localHeader, 26, (uint16_t)entry.nameData.length);
    entry.localOffset = (uint32_t)*outputOffset;
    if (!AMProjZIPWriteAll(outputFD, localHeader, sizeof(localHeader), outputOffset, error) ||
        !AMProjZIPWriteAll(outputFD, entry.nameData.bytes, entry.nameData.length,
                           outputOffset, error)) {
        if (inputFD >= 0) close(inputFD);
        return NO;
    }
    if (*outputOffset > UINT32_MAX) {
        if (inputFD >= 0) close(inputFD);
        return AMProjZIPFail(error, AMProjZIPErrorZIP32Limit,
                             @"Project archive exceeds ZIP32 offsets", nil);
    }
    entry.payloadOffset = (uint32_t)*outputOffset;

    z_stream stream = {0};
    int zResult = deflateInit2(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED,
                               -MAX_WBITS, 8, Z_DEFAULT_STRATEGY);
    if (zResult != Z_OK) {
        if (inputFD >= 0) close(inputFD);
        return AMProjZIPFail(error, AMProjZIPErrorCompression,
                             @"Unable to initialize ZIP compression",
                             @{ @"zlib": @(zResult), @"entry": entry.name });
    }

    uint8_t inputBuffer[kAMProjZIPBufferSize];
    uint8_t outputBuffer[kAMProjZIPBufferSize];
    uint64_t inputOffset = 0;
    uLong crcValue = crc32(0L, Z_NULL, 0);
    BOOL success = YES;
    while (inputOffset < entry.sourceLength && success) {
        size_t requested = (size_t)MIN((uint64_t)kAMProjZIPBufferSize,
                                       entry.sourceLength - inputOffset);
        const uint8_t *inputBytes = NULL;
        if (entry.data) {
            inputBytes = (const uint8_t *)entry.data.bytes + inputOffset;
        } else {
            size_t received = 0;
            while (received < requested) {
                ssize_t amount = read(inputFD, inputBuffer + received, requested - received);
                if (amount < 0 && errno == EINTR) continue;
                if (amount <= 0) {
                    success = AMProjZIPFail(error, AMProjZIPErrorSourceUnavailable,
                                            @"Unable to read a complete resource file",
                                            @{ @"entry": entry.name, @"errno": @(errno) });
                    break;
                }
                received += (size_t)amount;
            }
            inputBytes = inputBuffer;
        }
        if (!success) break;

        crcValue = crc32(crcValue, inputBytes, (uInt)requested);
        stream.next_in = (Bytef *)inputBytes;
        stream.avail_in = (uInt)requested;
        do {
            stream.next_out = outputBuffer;
            stream.avail_out = (uInt)sizeof(outputBuffer);
            zResult = deflate(&stream, Z_NO_FLUSH);
            if (zResult == Z_BUF_ERROR && stream.avail_in == 0) break;
            if (zResult != Z_OK) {
                success = AMProjZIPFail(error, AMProjZIPErrorCompression,
                                        @"Unable to compress a project resource",
                                        @{ @"entry": entry.name, @"zlib": @(zResult) });
                break;
            }
            size_t produced = sizeof(outputBuffer) - stream.avail_out;
            if (produced && !AMProjZIPWriteAll(outputFD, outputBuffer, produced,
                                               outputOffset, error)) {
                success = NO;
                break;
            }
        } while (stream.avail_in > 0 || stream.avail_out == 0);
        inputOffset += requested;
    }

    while (success) {
        stream.next_out = outputBuffer;
        stream.avail_out = (uInt)sizeof(outputBuffer);
        zResult = deflate(&stream, Z_FINISH);
        if (zResult != Z_OK && zResult != Z_STREAM_END) {
            success = AMProjZIPFail(error, AMProjZIPErrorCompression,
                                    @"Unable to finish ZIP compression",
                                    @{ @"entry": entry.name, @"zlib": @(zResult) });
            break;
        }
        size_t produced = sizeof(outputBuffer) - stream.avail_out;
        if (produced && !AMProjZIPWriteAll(outputFD, outputBuffer, produced,
                                           outputOffset, error)) {
            success = NO;
            break;
        }
        if (zResult == Z_STREAM_END) break;
    }

    uint64_t compressedSize = stream.total_out;
    deflateEnd(&stream);
    if (inputFD >= 0) close(inputFD);
    if (!success) return NO;
    if (compressedSize > UINT32_MAX || entry.sourceLength > UINT32_MAX ||
        *outputOffset > UINT32_MAX) {
        return AMProjZIPFail(error, AMProjZIPErrorZIP32Limit,
                             @"Compressed resource exceeds ZIP32 limits",
                             @{ @"entry": entry.name });
    }

    entry.crc = (uint32_t)crcValue;
    entry.compressedSize = (uint32_t)compressedSize;
    entry.uncompressedSize = (uint32_t)entry.sourceLength;
    uint64_t endOffset = *outputOffset;
    uint8_t sizes[12] = {0};
    AMProjZIPPut32(sizes, 0, entry.crc);
    AMProjZIPPut32(sizes, 4, entry.compressedSize);
    AMProjZIPPut32(sizes, 8, entry.uncompressedSize);
    if (!AMProjZIPSeek(outputFD, entry.localOffset + 14, error)) return NO;
    uint64_t patchOffset = entry.localOffset + 14;
    if (!AMProjZIPWriteAll(outputFD, sizes, sizeof(sizes), &patchOffset, error) ||
        !AMProjZIPSeek(outputFD, endOffset, error)) return NO;
    *outputOffset = endOffset;
    return YES;
}

static BOOL AMProjZIPWriteCentralDirectory(NSArray<AMProjZIPEntry *> *entries,
                                           int outputFD, uint64_t *outputOffset,
                                           NSError **error) {
    if (*outputOffset > UINT32_MAX) {
        return AMProjZIPFail(error, AMProjZIPErrorZIP32Limit,
                             @"Project archive exceeds ZIP32 offsets", nil);
    }
    uint32_t centralOffset = (uint32_t)*outputOffset;
    for (AMProjZIPEntry *entry in entries) {
        uint8_t header[46] = {0};
        AMProjZIPPut32(header, 0, 0x02014b50);
        AMProjZIPPut16(header, 4, 20);
        AMProjZIPPut16(header, 6, 20);
        AMProjZIPPut16(header, 8, kAMProjZIPUTF8Flag);
        AMProjZIPPut16(header, 10, 8);
        AMProjZIPPut32(header, 16, entry.crc);
        AMProjZIPPut32(header, 20, entry.compressedSize);
        AMProjZIPPut32(header, 24, entry.uncompressedSize);
        AMProjZIPPut16(header, 28, (uint16_t)entry.nameData.length);
        AMProjZIPPut32(header, 42, entry.localOffset);
        if (!AMProjZIPWriteAll(outputFD, header, sizeof(header), outputOffset, error) ||
            !AMProjZIPWriteAll(outputFD, entry.nameData.bytes, entry.nameData.length,
                               outputOffset, error)) return NO;
    }
    if (*outputOffset > UINT32_MAX || *outputOffset - centralOffset > UINT32_MAX) {
        return AMProjZIPFail(error, AMProjZIPErrorZIP32Limit,
                             @"ZIP central directory exceeds ZIP32 limits", nil);
    }

    uint8_t endRecord[22] = {0};
    AMProjZIPPut32(endRecord, 0, 0x06054b50);
    AMProjZIPPut16(endRecord, 8, (uint16_t)entries.count);
    AMProjZIPPut16(endRecord, 10, (uint16_t)entries.count);
    AMProjZIPPut32(endRecord, 12, (uint32_t)(*outputOffset - centralOffset));
    AMProjZIPPut32(endRecord, 16, centralOffset);
    return AMProjZIPWriteAll(outputFD, endRecord, sizeof(endRecord), outputOffset, error);
}

static BOOL AMProjZIPVerifyEntries(NSURL *archiveURL,
                                   NSArray<AMProjZIPEntry *> *entries,
                                   NSError **error) {
    int fd = open(archiveURL.fileSystemRepresentation, O_RDONLY);
    if (fd < 0) {
        return AMProjZIPFail(error, AMProjZIPErrorVerification,
                             @"Unable to reopen the project archive",
                             @{ @"errno": @(errno) });
    }
    uint8_t inputBuffer[kAMProjZIPBufferSize];
    uint8_t outputBuffer[kAMProjZIPBufferSize];
    BOOL success = YES;
    for (AMProjZIPEntry *entry in entries) {
        if (!AMProjZIPSeek(fd, entry.payloadOffset, error)) {
            success = NO;
            break;
        }
        z_stream stream = {0};
        int zResult = inflateInit2(&stream, -MAX_WBITS);
        if (zResult != Z_OK) {
            success = AMProjZIPFail(error, AMProjZIPErrorVerification,
                                    @"Unable to initialize ZIP verification",
                                    @{ @"entry": entry.name, @"zlib": @(zResult) });
            break;
        }
        uint64_t remaining = entry.compressedSize;
        uint64_t uncompressed = 0;
        uLong crcValue = crc32(0L, Z_NULL, 0);
        BOOL streamEnded = NO;
        while (remaining > 0 && success && !streamEnded) {
            size_t requested = (size_t)MIN((uint64_t)sizeof(inputBuffer), remaining);
            size_t received = 0;
            while (received < requested) {
                ssize_t amount = read(fd, inputBuffer + received, requested - received);
                if (amount < 0 && errno == EINTR) continue;
                if (amount <= 0) {
                    success = AMProjZIPFail(error, AMProjZIPErrorVerification,
                                            @"Project archive is truncated",
                                            @{ @"entry": entry.name, @"errno": @(errno) });
                    break;
                }
                received += (size_t)amount;
            }
            if (!success) break;
            remaining -= requested;
            stream.next_in = inputBuffer;
            stream.avail_in = (uInt)requested;
            do {
                stream.next_out = outputBuffer;
                stream.avail_out = (uInt)sizeof(outputBuffer);
                zResult = inflate(&stream, Z_NO_FLUSH);
                if (zResult == Z_BUF_ERROR && stream.avail_in == 0) break;
                if (zResult != Z_OK && zResult != Z_STREAM_END) {
                    success = AMProjZIPFail(error, AMProjZIPErrorVerification,
                                            @"Project archive failed decompression verification",
                                            @{ @"entry": entry.name, @"zlib": @(zResult) });
                    break;
                }
                size_t produced = sizeof(outputBuffer) - stream.avail_out;
                if (produced) {
                    crcValue = crc32(crcValue, outputBuffer, (uInt)produced);
                    uncompressed += produced;
                }
                if (zResult == Z_STREAM_END) {
                    streamEnded = YES;
                    if (stream.avail_in != 0 || remaining != 0) {
                        success = AMProjZIPFail(error, AMProjZIPErrorVerification,
                                                @"ZIP entry contains trailing compressed data",
                                                @{ @"entry": entry.name });
                    }
                    break;
                }
                if (produced == 0 && stream.avail_in == 0) break;
            } while ((stream.avail_in > 0 || stream.avail_out == 0) && success);
        }
        inflateEnd(&stream);
        if (!success) break;
        if (!streamEnded || uncompressed != entry.uncompressedSize ||
            (uint32_t)crcValue != entry.crc) {
            success = AMProjZIPFail(error, AMProjZIPErrorVerification,
                                    @"Project archive CRC verification failed",
                                    @{ @"entry": entry.name,
                                       @"expected_crc": @(entry.crc),
                                       @"actual_crc": @((uint32_t)crcValue),
                                       @"expected_bytes": @(entry.uncompressedSize),
                                       @"actual_bytes": @(uncompressed) });
            break;
        }
    }
    close(fd);
    return success;
}

BOOL AMProjZIPWriteProjectArchive(
    NSURL *destinationURL,
    NSData *sceneXML,
    NSDictionary<NSString *, NSURL *> *resourceURLs,
    NSDictionary<NSString *, NSNumber *> **metrics,
    NSError **error) {
    if (metrics) *metrics = nil;
    if (![destinationURL isKindOfClass:NSURL.class] || !destinationURL.isFileURL ||
        ![sceneXML isKindOfClass:NSData.class] ||
        ![resourceURLs isKindOfClass:NSDictionary.class]) {
        return AMProjZIPFail(error, AMProjZIPErrorInvalidArgument,
                             @"Invalid project archive arguments", nil);
    }

    NSArray<AMProjZIPEntry *> *entries = nil;
    uint64_t uncompressedBytes = 0;
    uint64_t requiredBytes = 0;
    if (!AMProjZIPPrepareEntries(sceneXML, resourceURLs, &entries,
                                 &uncompressedBytes, &requiredBytes, error)) return NO;

    NSURL *directoryURL = [destinationURL URLByDeletingLastPathComponent];
    NSNumber *freeBytesNumber = AMProjZIPAvailableBytes(directoryURL);
    uint64_t freeBytes = freeBytesNumber.unsignedLongLongValue;
    uint64_t reserve = MAX(kAMProjZIPSpaceReserve, requiredBytes / 20);
    uint64_t spaceNeeded = requiredBytes > UINT64_MAX - reserve ? UINT64_MAX : requiredBytes + reserve;
    if (freeBytesNumber && freeBytes < spaceNeeded) {
        return AMProjZIPFail(error, AMProjZIPErrorInsufficientSpace,
                             @"Not enough free space to create the project archive",
                             @{ @"available_bytes": @(freeBytes),
                                @"required_bytes": @(spaceNeeded) });
    }

    NSString *partialName = [NSString stringWithFormat:@".%@.%@.partial",
                             destinationURL.lastPathComponent ?: @"project.amproj",
                             NSUUID.UUID.UUIDString];
    NSURL *partialURL = [directoryURL URLByAppendingPathComponent:partialName isDirectory:NO];
    int outputFD = open(partialURL.fileSystemRepresentation,
                        O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR);
    if (outputFD < 0) {
        return AMProjZIPFail(error, AMProjZIPErrorOutputIO,
                             @"Unable to create the project archive",
                             @{ @"errno": @(errno), @"path": partialURL.path ?: @"" });
    }

    uint64_t outputOffset = 0;
    BOOL success = YES;
    for (AMProjZIPEntry *entry in entries) {
        if (!AMProjZIPDeflateEntry(entry, outputFD, &outputOffset, error)) {
            success = NO;
            break;
        }
    }
    if (success) {
        success = AMProjZIPWriteCentralDirectory(entries, outputFD, &outputOffset, error);
    }
    if (success && fsync(outputFD) != 0) {
        success = AMProjZIPFail(error, AMProjZIPErrorOutputIO,
                                @"Unable to flush the project archive",
                                @{ @"errno": @(errno) });
    }
    if (close(outputFD) != 0 && success) {
        success = AMProjZIPFail(error, AMProjZIPErrorOutputIO,
                                @"Unable to close the project archive",
                                @{ @"errno": @(errno) });
    }
    if (!success) {
        [[NSFileManager defaultManager] removeItemAtURL:partialURL error:nil];
        return NO;
    }

    if (!AMProjZIPVerifyEntries(partialURL, entries, error)) {
        [[NSFileManager defaultManager] removeItemAtURL:partialURL error:nil];
        return NO;
    }
    NSDictionary *attributes = [[NSFileManager defaultManager]
        attributesOfItemAtPath:partialURL.path error:nil];
    uint64_t archiveBytes = [attributes[NSFileSize] unsignedLongLongValue];
    if (archiveBytes != outputOffset || archiveBytes > UINT32_MAX) {
        [[NSFileManager defaultManager] removeItemAtURL:partialURL error:nil];
        return AMProjZIPFail(error, AMProjZIPErrorVerification,
                             @"Project archive size verification failed",
                             @{ @"expected_bytes": @(outputOffset),
                                @"actual_bytes": @(archiveBytes) });
    }

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *moveError = nil;
    if ([fileManager fileExistsAtPath:destinationURL.path]) {
        NSURL *resultURL = nil;
        if (![fileManager replaceItemAtURL:destinationURL withItemAtURL:partialURL
                            backupItemName:nil options:0 resultingItemURL:&resultURL
                                     error:&moveError]) {
            [fileManager removeItemAtURL:partialURL error:nil];
            return AMProjZIPFail(error, AMProjZIPErrorOutputIO,
                                 @"Unable to replace the previous project archive",
                                 moveError ? @{ NSUnderlyingErrorKey: moveError } : nil);
        }
    } else if (![fileManager moveItemAtURL:partialURL toURL:destinationURL error:&moveError]) {
        [fileManager removeItemAtURL:partialURL error:nil];
        return AMProjZIPFail(error, AMProjZIPErrorOutputIO,
                             @"Unable to finalize the project archive",
                             moveError ? @{ NSUnderlyingErrorKey: moveError } : nil);
    }

    uint64_t compressedBytes = 0;
    for (AMProjZIPEntry *entry in entries) compressedBytes += entry.compressedSize;
    if (metrics) {
        *metrics = @{
            @"entry_count": @(entries.count),
            @"xml_count": @1,
            @"uncompressed_bytes": @(uncompressedBytes),
            @"compressed_bytes": @(compressedBytes),
            @"archive_bytes": @(archiveBytes),
            @"required_bytes": @(spaceNeeded),
            @"free_bytes_before": @(freeBytes),
            @"crc_verified": @YES,
        };
    }
    return YES;
}

BOOL AMProjWriteArchive(NSURL *destinationURL, NSData *xmlData,
                        NSString *xmlFilename,
                        NSDictionary<NSString *, NSURL *> *resourceURLs,
                        NSError **error) {
    if (![xmlFilename isKindOfClass:NSString.class] ||
        [xmlFilename caseInsensitiveCompare:@"scene.xml"] != NSOrderedSame) {
        return AMProjZIPFail(error, AMProjZIPErrorInvalidArgument,
                             @"The streaming writer currently requires scene.xml",
                             @{ @"entry": xmlFilename ?: @"" });
    }
    return AMProjZIPWriteProjectArchive(destinationURL, xmlData, resourceURLs, nil, error);
}
