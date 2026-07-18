#import "AMProjImportArchive.h"
#import "AMProjZIPWriter.h"

#import <errno.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>
#import <zlib.h>

NSString *const AMProjImportArchiveErrorDomain = @"com.amproj.import.archive";

enum {
    kAMProjImportBufferSize = 64 * 1024,
    kAMProjImportMaximumEntries = 4096,
};

static const uint64_t kAMProjImportMaximumArchiveBytes = 2ULL * 1024 * 1024 * 1024;
static const uint64_t kAMProjImportMaximumEntryBytes = 1024ULL * 1024 * 1024;
static const uint64_t kAMProjImportMaximumTotalBytes = 2ULL * 1024 * 1024 * 1024;
static const uint64_t kAMProjImportMaximumXMLBytes = 64ULL * 1024 * 1024;
static const uint64_t kAMProjImportMaximumCentralDirectoryBytes = 64ULL * 1024 * 1024;
static const uint16_t kAMProjImportUTF8Flag = 0x0800;

@interface AMProjImportEntry : NSObject
@property(nonatomic, copy) NSString *name;
@property(nonatomic, strong) NSData *nameData;
@property(nonatomic) uint16_t flags;
@property(nonatomic) uint16_t method;
@property(nonatomic) uint32_t crc;
@property(nonatomic) uint32_t compressedSize;
@property(nonatomic) uint32_t uncompressedSize;
@property(nonatomic) uint32_t localOffset;
@property(nonatomic) uint32_t externalAttributes;
@property(nonatomic) BOOL directory;
@property(nonatomic) uint64_t payloadOffset;
@property(nonatomic, strong, nullable) NSURL *outputURL;
@end

@implementation AMProjImportEntry
@end

static BOOL AMProjImportFail(NSError **error, AMProjImportArchiveErrorCode code,
                             NSString *description, NSDictionary *details) {
    if (error) {
        NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithDictionary:details ?: @{}];
        userInfo[NSLocalizedDescriptionKey] = description ?: @"Project import archive error";
        *error = [NSError errorWithDomain:AMProjImportArchiveErrorDomain
                                     code:code userInfo:userInfo];
    }
    return NO;
}

static uint16_t AMProjImportGet16(const uint8_t *bytes, NSUInteger offset) {
    return (uint16_t)(bytes[offset] | ((uint16_t)bytes[offset + 1] << 8));
}

static uint32_t AMProjImportGet32(const uint8_t *bytes, NSUInteger offset) {
    return (uint32_t)bytes[offset] |
        ((uint32_t)bytes[offset + 1] << 8) |
        ((uint32_t)bytes[offset + 2] << 16) |
        ((uint32_t)bytes[offset + 3] << 24);
}

static BOOL AMProjImportAdd(uint64_t left, uint64_t right, uint64_t *sum) {
    if (UINT64_MAX - left < right) return NO;
    *sum = left + right;
    return YES;
}

static BOOL AMProjImportReadAt(int fd, uint64_t offset, void *buffer, size_t length,
                               NSError **error) {
    uint8_t *cursor = buffer;
    size_t remaining = length;
    while (remaining > 0) {
        ssize_t count = pread(fd, cursor, remaining, (off_t)offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) {
            return AMProjImportFail(error, AMProjImportArchiveErrorInvalidZIP,
                                    @"The project package is truncated",
                                    @{ @"offset": @(offset), @"errno": @(errno) });
        }
        cursor += count;
        remaining -= (size_t)count;
        offset += (uint64_t)count;
    }
    return YES;
}

static BOOL AMProjImportWriteAll(int fd, const void *buffer, size_t length,
                                 NSError **error) {
    const uint8_t *cursor = buffer;
    size_t remaining = length;
    while (remaining > 0) {
        ssize_t count = write(fd, cursor, remaining);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) {
            return AMProjImportFail(error, AMProjImportArchiveErrorExtractionIO,
                                    @"Unable to write an extracted project file",
                                    @{ @"errno": @(errno) });
        }
        cursor += count;
        remaining -= (size_t)count;
    }
    return YES;
}

static BOOL AMProjImportExtraIsZIP32(NSData *extra, NSString *entryName,
                                     NSError **error) {
    const uint8_t *bytes = extra.bytes;
    NSUInteger cursor = 0;
    while (cursor < extra.length) {
        if (extra.length - cursor < 4) {
            return AMProjImportFail(error, AMProjImportArchiveErrorInvalidZIP,
                                    @"A ZIP extra field is truncated",
                                    @{ @"entry": entryName ?: @"" });
        }
        uint16_t identifier = AMProjImportGet16(bytes, cursor);
        uint16_t size = AMProjImportGet16(bytes, cursor + 2);
        cursor += 4;
        if (size > extra.length - cursor) {
            return AMProjImportFail(error, AMProjImportArchiveErrorInvalidZIP,
                                    @"A ZIP extra field has an invalid length",
                                    @{ @"entry": entryName ?: @"" });
        }
        if (identifier == 0x0001) {
            return AMProjImportFail(error, AMProjImportArchiveErrorUnsupportedZIP,
                                    @"ZIP64 project packages are not supported",
                                    @{ @"entry": entryName ?: @"" });
        }
        cursor += size;
    }
    return YES;
}

static NSString *AMProjImportDecodeName(NSData *data, uint16_t flags) {
    NSString *name = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!name && !(flags & kAMProjImportUTF8Flag)) {
        name = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    }
    return name;
}

static NSString *AMProjImportSafeName(NSString *rawName, BOOL *directory,
                                      NSError **error) {
    if (![rawName isKindOfClass:NSString.class] || rawName.length == 0 ||
        [rawName rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) {
        AMProjImportFail(error, AMProjImportArchiveErrorUnsafeEntry,
                         @"The project package contains an invalid filename", nil);
        return nil;
    }

    NSString *name = [rawName stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    BOOL isDirectory = [name hasSuffix:@"/"];
    if ([name hasPrefix:@"/"] || [name hasPrefix:@"~"] ||
        [name rangeOfString:@":"].location != NSNotFound) {
        AMProjImportFail(error, AMProjImportArchiveErrorUnsafeEntry,
                         @"The project package contains an absolute or unsafe path",
                         @{ @"entry": rawName });
        return nil;
    }

    NSMutableArray<NSString *> *components = [NSMutableArray array];
    NSArray<NSString *> *rawComponents = [name componentsSeparatedByString:@"/"];
    for (NSUInteger index = 0; index < rawComponents.count; index++) {
        NSString *component = rawComponents[index];
        BOOL trailingDirectoryMarker = isDirectory && index == rawComponents.count - 1;
        if (trailingDirectoryMarker && component.length == 0) continue;
        if (component.length == 0 || [component isEqualToString:@"."] ||
            [component isEqualToString:@".."]) {
            AMProjImportFail(error, AMProjImportArchiveErrorUnsafeEntry,
                             @"The project package contains an unsafe path component",
                             @{ @"entry": rawName });
            return nil;
        }
        [components addObject:component];
    }
    if (components.count == 0) {
        AMProjImportFail(error, AMProjImportArchiveErrorUnsafeEntry,
                         @"The project package contains an empty path",
                         @{ @"entry": rawName });
        return nil;
    }
    if (directory) *directory = isDirectory;
    return [components componentsJoinedByString:@"/"];
}

static BOOL AMProjImportValidateUnixType(uint16_t versionMadeBy,
                                         uint32_t externalAttributes,
                                         BOOL directory, NSString *name,
                                         NSError **error) {
    if ((versionMadeBy >> 8) != 3) return YES;
    uint16_t mode = (uint16_t)(externalAttributes >> 16);
    uint16_t type = mode & 0170000;
    if (type == 0) return YES;
    if (type == 0120000 || (type != 0100000 && type != 0040000)) {
        return AMProjImportFail(error, AMProjImportArchiveErrorUnsafeEntry,
                                @"Links and special files are not allowed in a project package",
                                @{ @"entry": name ?: @"" });
    }
    if ((type == 0040000) != directory) {
        return AMProjImportFail(error, AMProjImportArchiveErrorInvalidZIP,
                                @"A ZIP entry has inconsistent file attributes",
                                @{ @"entry": name ?: @"" });
    }
    return YES;
}

static NSArray<AMProjImportEntry *> *AMProjImportReadDirectory(
    int fd, uint64_t archiveSize, uint64_t *centralOffsetOut,
    uint64_t *compressedTotalOut, uint64_t *uncompressedTotalOut,
    NSError **error) {
    const uint64_t maximumTail = 22 + UINT16_MAX;
    size_t tailLength = (size_t)MIN(archiveSize, maximumTail);
    NSMutableData *tail = [NSMutableData dataWithLength:tailLength];
    uint64_t tailOffset = archiveSize - tailLength;
    if (!AMProjImportReadAt(fd, tailOffset, tail.mutableBytes, tailLength, error)) return nil;

    const uint8_t *tailBytes = tail.bytes;
    NSInteger eocdIndex = -1;
    for (NSInteger index = (NSInteger)tailLength - 22; index >= 0; index--) {
        if (AMProjImportGet32(tailBytes, (NSUInteger)index) != 0x06054b50) continue;
        uint16_t commentLength = AMProjImportGet16(tailBytes, (NSUInteger)index + 20);
        if ((NSUInteger)index + 22 + commentLength == tailLength) {
            eocdIndex = index;
            break;
        }
    }
    if (eocdIndex < 0) {
        AMProjImportFail(error, AMProjImportArchiveErrorInvalidZIP,
                         @"The project package has no valid ZIP32 end record", nil);
        return nil;
    }

    const uint8_t *eocd = tailBytes + eocdIndex;
    uint16_t disk = AMProjImportGet16(eocd, 4);
    uint16_t centralDisk = AMProjImportGet16(eocd, 6);
    uint16_t diskEntries = AMProjImportGet16(eocd, 8);
    uint16_t totalEntries = AMProjImportGet16(eocd, 10);
    uint32_t centralSize = AMProjImportGet32(eocd, 12);
    uint32_t centralOffset = AMProjImportGet32(eocd, 16);
    uint64_t eocdOffset = tailOffset + (uint64_t)eocdIndex;

    if (disk != 0 || centralDisk != 0 || diskEntries != totalEntries) {
        AMProjImportFail(error, AMProjImportArchiveErrorUnsupportedZIP,
                         @"Split project packages are not supported", nil);
        return nil;
    }
    if (totalEntries == UINT16_MAX || centralSize == UINT32_MAX ||
        centralOffset == UINT32_MAX) {
        AMProjImportFail(error, AMProjImportArchiveErrorUnsupportedZIP,
                         @"ZIP64 project packages are not supported", nil);
        return nil;
    }
    if (totalEntries == 0 || totalEntries > kAMProjImportMaximumEntries ||
        centralSize > kAMProjImportMaximumCentralDirectoryBytes) {
        AMProjImportFail(error, AMProjImportArchiveErrorLimitExceeded,
                         @"The project package has too many entries or an oversized directory",
                         @{ @"entry_count": @(totalEntries), @"directory_bytes": @(centralSize) });
        return nil;
    }
    uint64_t centralEnd = 0;
    if (!AMProjImportAdd(centralOffset, centralSize, &centralEnd) || centralEnd != eocdOffset) {
        AMProjImportFail(error, AMProjImportArchiveErrorInvalidZIP,
                         @"The ZIP central directory range is inconsistent", nil);
        return nil;
    }
    if (eocdOffset >= 20) {
        uint8_t locator[4];
        if (AMProjImportReadAt(fd, eocdOffset - 20, locator, sizeof(locator), nil) &&
            AMProjImportGet32(locator, 0) == 0x07064b50) {
            AMProjImportFail(error, AMProjImportArchiveErrorUnsupportedZIP,
                             @"ZIP64 project packages are not supported", nil);
            return nil;
        }
    }

    NSMutableData *centralData = [NSMutableData dataWithLength:centralSize];
    if (!AMProjImportReadAt(fd, centralOffset, centralData.mutableBytes, centralSize, error)) return nil;
    const uint8_t *bytes = centralData.bytes;
    NSUInteger cursor = 0;
    uint64_t compressedTotal = 0;
    uint64_t uncompressedTotal = 0;
    NSMutableArray<AMProjImportEntry *> *entries = [NSMutableArray arrayWithCapacity:totalEntries];
    NSMutableSet<NSString *> *seenNames = [NSMutableSet set];

    for (NSUInteger index = 0; index < totalEntries; index++) {
        if (centralSize - cursor < 46 || AMProjImportGet32(bytes, cursor) != 0x02014b50) {
            AMProjImportFail(error, AMProjImportArchiveErrorInvalidZIP,
                             @"A ZIP central directory entry is invalid",
                             @{ @"entry_index": @(index) });
            return nil;
        }
        uint16_t versionMadeBy = AMProjImportGet16(bytes, cursor + 4);
        uint16_t versionNeeded = AMProjImportGet16(bytes, cursor + 6);
        uint16_t flags = AMProjImportGet16(bytes, cursor + 8);
        uint16_t method = AMProjImportGet16(bytes, cursor + 10);
        uint32_t crc = AMProjImportGet32(bytes, cursor + 16);
        uint32_t compressedSize = AMProjImportGet32(bytes, cursor + 20);
        uint32_t uncompressedSize = AMProjImportGet32(bytes, cursor + 24);
        uint16_t nameLength = AMProjImportGet16(bytes, cursor + 28);
        uint16_t extraLength = AMProjImportGet16(bytes, cursor + 30);
        uint16_t commentLength = AMProjImportGet16(bytes, cursor + 32);
        uint16_t diskStart = AMProjImportGet16(bytes, cursor + 34);
        uint32_t externalAttributes = AMProjImportGet32(bytes, cursor + 38);
        uint32_t localOffset = AMProjImportGet32(bytes, cursor + 42);
        uint64_t recordLength = 46ULL + nameLength + extraLength + commentLength;
        if (recordLength > centralSize - cursor || nameLength == 0) {
            AMProjImportFail(error, AMProjImportArchiveErrorInvalidZIP,
                             @"A ZIP directory entry is truncated",
                             @{ @"entry_index": @(index) });
            return nil;
        }
        if (diskStart != 0) {
            AMProjImportFail(error, AMProjImportArchiveErrorUnsupportedZIP,
                             @"Split project packages are not supported", nil);
            return nil;
        }
        if (versionNeeded > 20 || compressedSize == UINT32_MAX ||
            uncompressedSize == UINT32_MAX || localOffset == UINT32_MAX) {
            AMProjImportFail(error, AMProjImportArchiveErrorUnsupportedZIP,
                             @"This project package requires ZIP64 or unsupported ZIP features",
                             @{ @"entry_index": @(index) });
            return nil;
        }
        if ((flags & 0x2041) != 0) {
            AMProjImportFail(error, AMProjImportArchiveErrorUnsupportedZIP,
                             @"Encrypted project packages are not supported",
                             @{ @"entry_index": @(index) });
            return nil;
        }
        if (method != 0 && method != 8) {
            AMProjImportFail(error, AMProjImportArchiveErrorUnsupportedZIP,
                             @"Only stored and deflated ZIP entries are supported",
                             @{ @"method": @(method), @"entry_index": @(index) });
            return nil;
        }
        if (method == 0 && compressedSize != uncompressedSize) {
            AMProjImportFail(error, AMProjImportArchiveErrorInvalidZIP,
                             @"A stored ZIP entry has inconsistent sizes",
                             @{ @"entry_index": @(index) });
            return nil;
        }
        if (uncompressedSize > kAMProjImportMaximumEntryBytes) {
            AMProjImportFail(error, AMProjImportArchiveErrorLimitExceeded,
                             @"A project package entry is too large",
                             @{ @"bytes": @(uncompressedSize), @"entry_index": @(index) });
            return nil;
        }

        NSData *nameData = [NSData dataWithBytes:bytes + cursor + 46 length:nameLength];
        NSString *decodedName = AMProjImportDecodeName(nameData, flags);
        BOOL directory = NO;
        NSString *safeName = decodedName ? AMProjImportSafeName(decodedName, &directory, error) : nil;
        if (!safeName) {
            if (decodedName == nil) {
                AMProjImportFail(error, AMProjImportArchiveErrorUnsafeEntry,
                                 @"A project package filename cannot be decoded",
                                 @{ @"entry_index": @(index) });
            }
            return nil;
        }
        NSString *foldedName = safeName.precomposedStringWithCanonicalMapping.lowercaseString;
        if ([seenNames containsObject:foldedName]) {
            AMProjImportFail(error, AMProjImportArchiveErrorUnsafeEntry,
                             @"The project package contains duplicate filenames",
                             @{ @"entry": safeName });
            return nil;
        }
        [seenNames addObject:foldedName];

        NSData *extra = [NSData dataWithBytes:bytes + cursor + 46 + nameLength
                                       length:extraLength];
        if (!AMProjImportExtraIsZIP32(extra, safeName, error) ||
            !AMProjImportValidateUnixType(versionMadeBy, externalAttributes,
                                           directory, safeName, error)) {
            return nil;
        }
        if (directory && (compressedSize != 0 || uncompressedSize != 0)) {
            AMProjImportFail(error, AMProjImportArchiveErrorInvalidZIP,
                             @"A ZIP directory entry contains file data",
                             @{ @"entry": safeName });
            return nil;
        }
        if (directory && crc != 0) {
            AMProjImportFail(error, AMProjImportArchiveErrorIntegrity,
                             @"A ZIP directory entry has an invalid CRC",
                             @{ @"entry": safeName, @"crc": @(crc) });
            return nil;
        }
        if (!AMProjImportAdd(compressedTotal, compressedSize, &compressedTotal) ||
            !AMProjImportAdd(uncompressedTotal, uncompressedSize, &uncompressedTotal) ||
            uncompressedTotal > kAMProjImportMaximumTotalBytes) {
            AMProjImportFail(error, AMProjImportArchiveErrorLimitExceeded,
                             @"The extracted project package would be too large", nil);
            return nil;
        }

        AMProjImportEntry *entry = [AMProjImportEntry new];
        entry.name = safeName;
        entry.nameData = nameData;
        entry.flags = flags;
        entry.method = method;
        entry.crc = crc;
        entry.compressedSize = compressedSize;
        entry.uncompressedSize = uncompressedSize;
        entry.localOffset = localOffset;
        entry.externalAttributes = externalAttributes;
        entry.directory = directory;
        [entries addObject:entry];
        cursor += (NSUInteger)recordLength;
    }
    if (cursor != centralSize) {
        AMProjImportFail(error, AMProjImportArchiveErrorInvalidZIP,
                         @"The ZIP central directory length is inconsistent", nil);
        return nil;
    }
    if (centralOffsetOut) *centralOffsetOut = centralOffset;
    if (compressedTotalOut) *compressedTotalOut = compressedTotal;
    if (uncompressedTotalOut) *uncompressedTotalOut = uncompressedTotal;
    return entries;
}

static BOOL AMProjImportValidateLocalHeaders(int fd,
                                             NSArray<AMProjImportEntry *> *entries,
                                             uint64_t centralOffset,
                                             NSError **error) {
    NSMutableArray<NSDictionary<NSString *, NSNumber *> *> *ranges = [NSMutableArray array];
    for (AMProjImportEntry *entry in entries) {
        uint8_t header[30];
        if (entry.localOffset >= centralOffset ||
            !AMProjImportReadAt(fd, entry.localOffset, header, sizeof(header), error)) return NO;
        if (AMProjImportGet32(header, 0) != 0x04034b50) {
            return AMProjImportFail(error, AMProjImportArchiveErrorInvalidZIP,
                                    @"A ZIP local file header is invalid",
                                    @{ @"entry": entry.name });
        }
        uint16_t flags = AMProjImportGet16(header, 6);
        uint16_t method = AMProjImportGet16(header, 8);
        uint16_t nameLength = AMProjImportGet16(header, 26);
        uint16_t extraLength = AMProjImportGet16(header, 28);
        if (flags != entry.flags || method != entry.method || nameLength != entry.nameData.length) {
            return AMProjImportFail(error, AMProjImportArchiveErrorInvalidZIP,
                                    @"A ZIP local header disagrees with its directory entry",
                                    @{ @"entry": entry.name });
        }
        uint64_t nameOffset = (uint64_t)entry.localOffset + sizeof(header);
        uint64_t payloadOffset = 0;
        if (!AMProjImportAdd(nameOffset, nameLength, &payloadOffset) ||
            !AMProjImportAdd(payloadOffset, extraLength, &payloadOffset)) {
            return AMProjImportFail(error, AMProjImportArchiveErrorInvalidZIP,
                                    @"A ZIP local header overflows", @{ @"entry": entry.name });
        }
        uint64_t payloadEnd = 0;
        if (!AMProjImportAdd(payloadOffset, entry.compressedSize, &payloadEnd) ||
            payloadEnd > centralOffset) {
            return AMProjImportFail(error, AMProjImportArchiveErrorInvalidZIP,
                                    @"A ZIP payload extends outside the file area",
                                    @{ @"entry": entry.name });
        }
        NSMutableData *localVariable = [NSMutableData dataWithLength:nameLength + extraLength];
        if (!AMProjImportReadAt(fd, nameOffset, localVariable.mutableBytes,
                                localVariable.length, error)) return NO;
        NSData *localName = [localVariable subdataWithRange:NSMakeRange(0, nameLength)];
        if (![localName isEqualToData:entry.nameData]) {
            return AMProjImportFail(error, AMProjImportArchiveErrorInvalidZIP,
                                    @"A ZIP entry has mismatched local and central filenames",
                                    @{ @"entry": entry.name });
        }
        NSData *localExtra = [localVariable subdataWithRange:NSMakeRange(nameLength, extraLength)];
        if (!AMProjImportExtraIsZIP32(localExtra, entry.name, error)) return NO;
        if (!(flags & 0x0008) &&
            (AMProjImportGet32(header, 14) != entry.crc ||
             AMProjImportGet32(header, 18) != entry.compressedSize ||
             AMProjImportGet32(header, 22) != entry.uncompressedSize)) {
            return AMProjImportFail(error, AMProjImportArchiveErrorInvalidZIP,
                                    @"A ZIP local header has inconsistent CRC or sizes",
                                    @{ @"entry": entry.name });
        }
        entry.payloadOffset = payloadOffset;
        [ranges addObject:@{ @"start": @(entry.localOffset), @"end": @(payloadEnd) }];
    }
    [ranges sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        return [left[@"start"] compare:right[@"start"]];
    }];
    uint64_t previousEnd = 0;
    for (NSDictionary<NSString *, NSNumber *> *range in ranges) {
        uint64_t start = [range[@"start"] unsignedLongLongValue];
        uint64_t end = [range[@"end"] unsignedLongLongValue];
        if (start < previousEnd) {
            return AMProjImportFail(error, AMProjImportArchiveErrorUnsafeEntry,
                                    @"ZIP entries overlap each other", nil);
        }
        previousEnd = end;
    }
    return YES;
}

static BOOL AMProjImportExtractStored(int sourceFD, int outputFD,
                                      AMProjImportEntry *entry,
                                      uint64_t *writtenOut, uint32_t *crcOut,
                                      NSError **error) {
    uint8_t buffer[kAMProjImportBufferSize];
    uint64_t remaining = entry.compressedSize;
    uint64_t offset = entry.payloadOffset;
    uint64_t written = 0;
    uLong crc = crc32(0L, Z_NULL, 0);
    while (remaining > 0) {
        size_t count = (size_t)MIN(remaining, sizeof(buffer));
        if (!AMProjImportReadAt(sourceFD, offset, buffer, count, error) ||
            !AMProjImportWriteAll(outputFD, buffer, count, error)) return NO;
        crc = crc32(crc, buffer, (uInt)count);
        remaining -= count;
        offset += count;
        written += count;
    }
    *writtenOut = written;
    *crcOut = (uint32_t)crc;
    return YES;
}

static BOOL AMProjImportExtractDeflated(int sourceFD, int outputFD,
                                        AMProjImportEntry *entry,
                                        uint64_t *writtenOut, uint32_t *crcOut,
                                        NSError **error) {
    uint8_t input[kAMProjImportBufferSize];
    uint8_t output[kAMProjImportBufferSize];
    z_stream stream = {0};
    int result = inflateInit2(&stream, -MAX_WBITS);
    if (result != Z_OK) {
        return AMProjImportFail(error, AMProjImportArchiveErrorUnsupportedZIP,
                                @"Unable to initialize ZIP decompression",
                                @{ @"zlib": @(result) });
    }

    uint64_t remaining = entry.compressedSize;
    uint64_t sourceOffset = entry.payloadOffset;
    uint64_t written = 0;
    uLong crc = crc32(0L, Z_NULL, 0);
    BOOL ended = NO;
    BOOL success = YES;
    while (success && remaining > 0 && !ended) {
        size_t inputCount = (size_t)MIN(remaining, sizeof(input));
        if (!AMProjImportReadAt(sourceFD, sourceOffset, input, inputCount, error)) {
            success = NO;
            break;
        }
        sourceOffset += inputCount;
        remaining -= inputCount;
        stream.next_in = input;
        stream.avail_in = (uInt)inputCount;
        do {
            uInt availableBefore = stream.avail_in;
            stream.next_out = output;
            stream.avail_out = sizeof(output);
            result = inflate(&stream, Z_NO_FLUSH);
            size_t produced = sizeof(output) - stream.avail_out;
            if (produced > 0) {
                if (written > entry.uncompressedSize ||
                    produced > entry.uncompressedSize - written ||
                    !AMProjImportWriteAll(outputFD, output, produced, error)) {
                    success = NO;
                    break;
                }
                crc = crc32(crc, output, (uInt)produced);
                written += produced;
            }
            if (result == Z_STREAM_END) {
                ended = YES;
            } else if (result == Z_BUF_ERROR && stream.avail_in == 0) {
                break;
            } else if (result != Z_OK) {
                AMProjImportFail(error, AMProjImportArchiveErrorInvalidZIP,
                                 @"A deflated ZIP entry is damaged",
                                 @{ @"entry": entry.name, @"zlib": @(result) });
                success = NO;
            } else if (produced == 0 && stream.avail_in == availableBefore) {
                if (stream.avail_in > 0) {
                    AMProjImportFail(error, AMProjImportArchiveErrorInvalidZIP,
                                     @"A deflated ZIP entry made no decompression progress",
                                     @{ @"entry": entry.name });
                    success = NO;
                }
                break;
            }
        } while (success && !ended &&
                 (stream.avail_in > 0 || stream.avail_out == 0));
    }
    if (success && (!ended || remaining != 0 || stream.avail_in != 0)) {
        AMProjImportFail(error, AMProjImportArchiveErrorInvalidZIP,
                         @"A deflated ZIP entry has trailing or incomplete data",
                         @{ @"entry": entry.name });
        success = NO;
    }
    inflateEnd(&stream);
    if (!success) return NO;
    *writtenOut = written;
    *crcOut = (uint32_t)crc;
    return YES;
}

static BOOL AMProjImportExtractEntry(int sourceFD, AMProjImportEntry *entry,
                                     NSURL *rootURL, NSError **error) {
    NSURL *outputURL = [rootURL URLByAppendingPathComponent:entry.name
                                                isDirectory:entry.directory];
    entry.outputURL = outputURL;
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSError *directoryError = nil;
    if (entry.directory) {
        if (![fileManager createDirectoryAtURL:outputURL
                   withIntermediateDirectories:YES attributes:nil error:&directoryError]) {
            return AMProjImportFail(error, AMProjImportArchiveErrorExtractionIO,
                                    @"Unable to create an extracted project directory",
                                    @{ @"entry": entry.name,
                                       @"reason": directoryError.localizedDescription ?: @"" });
        }
        return YES;
    }
    if (![fileManager createDirectoryAtURL:outputURL.URLByDeletingLastPathComponent
               withIntermediateDirectories:YES attributes:nil error:&directoryError]) {
        return AMProjImportFail(error, AMProjImportArchiveErrorExtractionIO,
                                @"Unable to create a directory for an extracted project file",
                                @{ @"entry": entry.name,
                                   @"reason": directoryError.localizedDescription ?: @"" });
    }

    int outputFD = open(outputURL.fileSystemRepresentation,
                        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (outputFD < 0) {
        return AMProjImportFail(error, AMProjImportArchiveErrorExtractionIO,
                                @"Unable to create an extracted project file",
                                @{ @"entry": entry.name, @"errno": @(errno) });
    }
    uint64_t written = 0;
    uint32_t crc = 0;
    BOOL success = entry.method == 0
        ? AMProjImportExtractStored(sourceFD, outputFD, entry, &written, &crc, error)
        : AMProjImportExtractDeflated(sourceFD, outputFD, entry, &written, &crc, error);
    int closeResult = close(outputFD);
    if (!success || closeResult != 0) {
        unlink(outputURL.fileSystemRepresentation);
        if (success) {
            return AMProjImportFail(error, AMProjImportArchiveErrorExtractionIO,
                                    @"Unable to close an extracted project file",
                                    @{ @"entry": entry.name, @"errno": @(errno) });
        }
        return NO;
    }
    if (written != entry.uncompressedSize || crc != entry.crc) {
        unlink(outputURL.fileSystemRepresentation);
        return AMProjImportFail(error, AMProjImportArchiveErrorIntegrity,
                                @"An extracted project file failed its size or CRC check",
                                @{ @"entry": entry.name,
                                   @"expected_bytes": @(entry.uncompressedSize),
                                   @"actual_bytes": @(written),
                                   @"expected_crc": @(entry.crc),
                                   @"actual_crc": @(crc) });
    }
    return YES;
}

static NSString *AMProjImportDecodeXMLReference(NSString *value) {
    // Decode exactly one XML entity layer. Ampersand must be last so a literal
    // "&amp;quot;" filename does not become a quote through a second decode.
    value = [value stringByReplacingOccurrencesOfString:@"&quot;" withString:@"\""];
    value = [value stringByReplacingOccurrencesOfString:@"&apos;" withString:@"'"];
    value = [value stringByReplacingOccurrencesOfString:@"&lt;" withString:@"<"];
    value = [value stringByReplacingOccurrencesOfString:@"&gt;" withString:@">"];
    value = [value stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
    NSString *decoded = value.stringByRemovingPercentEncoding;
    return decoded ?: value;
}

static NSString *AMProjImportEscapeXMLValue(NSString *value) {
    value = [value stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"];
    value = [value stringByReplacingOccurrencesOfString:@"\"" withString:@"&quot;"];
    value = [value stringByReplacingOccurrencesOfString:@"'" withString:@"&apos;"];
    value = [value stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"];
    return [value stringByReplacingOccurrencesOfString:@">" withString:@"&gt;"];
}

static NSURL * _Nullable AMProjImportURLForReference(
    NSString *reference, NSDictionary<NSString *, NSURL *> *exactURLs,
    NSDictionary<NSString *, NSURL *> *foldedURLs) {
    NSString *decoded = AMProjImportDecodeXMLReference(reference);
    BOOL ignoredDirectory = NO;
    NSError *ignoredError = nil;
    NSString *safeName = AMProjImportSafeName(decoded, &ignoredDirectory, &ignoredError);
    NSURL *url = nil;
    if (safeName && !ignoredDirectory) {
        url = exactURLs[safeName];
        if (!url) url = foldedURLs[safeName.precomposedStringWithCanonicalMapping.lowercaseString];
    }
    return url;
}

static NSData *AMProjImportRewriteXML(NSData *xmlData,
                                      NSArray<AMProjImportEntry *> *entries,
                                      NSUInteger *referenceCount,
                                      NSUInteger *rewrittenCount,
                                      NSUInteger *missingCount,
                                      NSArray<NSString *> **missingNames,
                                      NSError **error) {
    NSString *xml = [[NSString alloc] initWithData:xmlData encoding:NSUTF8StringEncoding];
    if (!xml) {
        AMProjImportFail(error, AMProjImportArchiveErrorInvalidXML,
                         @"The project XML is not valid UTF-8", nil);
        return nil;
    }
    NSError *regexError = nil;
    NSRegularExpression *regex = [NSRegularExpression
        regularExpressionWithPattern:@"amproj:((?:&(?:amp|quot|apos|lt|gt);|[^\\\"'<>&])+)"
                              options:0 error:&regexError];
    if (!regex) {
        AMProjImportFail(error, AMProjImportArchiveErrorInvalidXML,
                         @"Unable to prepare the project XML matcher",
                         @{ @"reason": regexError.localizedDescription ?: @"" });
        return nil;
    }

    NSMutableDictionary<NSString *, NSURL *> *exactURLs = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSURL *> *foldedURLs = [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *ambiguousFolded = [NSMutableSet set];
    for (AMProjImportEntry *entry in entries) {
        if (entry.directory || !entry.outputURL) continue;
        exactURLs[entry.name] = entry.outputURL;
        NSString *folded = entry.name.precomposedStringWithCanonicalMapping.lowercaseString;
        if (foldedURLs[folded]) [ambiguousFolded addObject:folded];
        else foldedURLs[folded] = entry.outputURL;
    }
    [foldedURLs removeObjectsForKeys:ambiguousFolded.allObjects];

    NSMutableString *rewritten = [xml mutableCopy];
    NSArray<NSTextCheckingResult *> *matches = [regex matchesInString:xml options:0
                                                               range:NSMakeRange(0, xml.length)];
    NSMutableSet<NSString *> *missingReferences = [NSMutableSet set];
    NSUInteger localRewrittenCount = 0;
    for (NSTextCheckingResult *match in matches.reverseObjectEnumerator) {
        if (match.numberOfRanges < 2) continue;
        NSRange referenceRange = [match rangeAtIndex:1];
        NSString *reference = [xml substringWithRange:referenceRange];
        NSURL *url = AMProjImportURLForReference(reference, exactURLs, foldedURLs);
        if (url) {
            [rewritten replaceCharactersInRange:match.range
                                      withString:AMProjImportEscapeXMLValue(url.absoluteString)];
            localRewrittenCount++;
        } else {
            NSString *decoded = AMProjImportDecodeXMLReference(reference);
            NSString *identity = decoded.precomposedStringWithCanonicalMapping.lowercaseString;
            if (identity.length) [missingReferences addObject:identity];
        }
    }
    NSData *result = [rewritten dataUsingEncoding:NSUTF8StringEncoding];
    if (!result) {
        AMProjImportFail(error, AMProjImportArchiveErrorInvalidXML,
                         @"Unable to encode the rewritten project XML", nil);
        return nil;
    }
    if (referenceCount) *referenceCount = matches.count;
    if (rewrittenCount) *rewrittenCount = localRewrittenCount;
    if (missingCount) *missingCount = missingReferences.count;
    if (missingNames) {
        *missingNames = [missingReferences.allObjects
            sortedArrayUsingSelector:@selector(compare:)];
    }
    return result;
}

static BOOL AMProjImportAtomicWrite(NSData *data, NSURL *destinationURL,
                                    NSError **error) {
    NSURL *temporaryURL = [destinationURL.URLByDeletingLastPathComponent
        URLByAppendingPathComponent:[@"." stringByAppendingString:NSUUID.UUID.UUIDString]];
    int fd = open(temporaryURL.fileSystemRepresentation,
                  O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (fd < 0) {
        return AMProjImportFail(error, AMProjImportArchiveErrorExtractionIO,
                                @"Unable to create the native import XML",
                                @{ @"errno": @(errno) });
    }
    BOOL success = AMProjImportWriteAll(fd, data.bytes, data.length, error);
    if (success && fsync(fd) != 0) {
        success = AMProjImportFail(error, AMProjImportArchiveErrorExtractionIO,
                                   @"Unable to flush the native import XML",
                                   @{ @"errno": @(errno) });
    }
    if (close(fd) != 0 && success) {
        success = AMProjImportFail(error, AMProjImportArchiveErrorExtractionIO,
                                   @"Unable to close the native import XML",
                                   @{ @"errno": @(errno) });
    }
    if (success && rename(temporaryURL.fileSystemRepresentation,
                          destinationURL.fileSystemRepresentation) != 0) {
        success = AMProjImportFail(error, AMProjImportArchiveErrorExtractionIO,
                                   @"Unable to publish the native import XML",
                                   @{ @"errno": @(errno) });
    }
    if (!success) unlink(temporaryURL.fileSystemRepresentation);
    return success;
}

BOOL AMProjPrepareNativeImport(NSURL *archiveURL, NSURL *workDirectoryURL,
                               NSURL **nativeXMLURL,
                               NSDictionary<NSString *, id> **metrics,
                               NSError **error) {
    if (nativeXMLURL) *nativeXMLURL = nil;
    if (metrics) *metrics = nil;
    if (error) *error = nil;
    if (![archiveURL isKindOfClass:NSURL.class] || !archiveURL.isFileURL ||
        ![workDirectoryURL isKindOfClass:NSURL.class] || !workDirectoryURL.isFileURL) {
        return AMProjImportFail(error, AMProjImportArchiveErrorInvalidArgument,
                                @"Archive and work directory must be local file URLs", nil);
    }

    int sourceFD = open(archiveURL.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW);
    if (sourceFD < 0) {
        return AMProjImportFail(error, AMProjImportArchiveErrorSourceUnavailable,
                                @"Unable to open the project package",
                                @{ @"errno": @(errno), @"path": archiveURL.path ?: @"" });
    }
    struct stat sourceStat = {0};
    if (fstat(sourceFD, &sourceStat) != 0 || !S_ISREG(sourceStat.st_mode) ||
        sourceStat.st_size < 22 || (uint64_t)sourceStat.st_size > kAMProjImportMaximumArchiveBytes) {
        close(sourceFD);
        return AMProjImportFail(error, AMProjImportArchiveErrorSourceUnavailable,
                                @"The project package is not a supported regular ZIP file",
                                @{ @"bytes": sourceStat.st_size > 0 ? @(sourceStat.st_size) : @0 });
    }
    uint64_t archiveSize = (uint64_t)sourceStat.st_size;
    uint64_t centralOffset = 0;
    uint64_t compressedTotal = 0;
    uint64_t uncompressedTotal = 0;
    NSArray<AMProjImportEntry *> *entries = AMProjImportReadDirectory(
        sourceFD, archiveSize, &centralOffset, &compressedTotal, &uncompressedTotal, error);
    if (!entries || !AMProjImportValidateLocalHeaders(sourceFD, entries, centralOffset, error)) {
        close(sourceFD);
        return NO;
    }

    NSMutableArray<AMProjImportEntry *> *xmlEntries = [NSMutableArray array];
    NSUInteger manifestCount = 0;
    NSUInteger fileCount = 0;
    NSUInteger directoryCount = 0;
    for (AMProjImportEntry *entry in entries) {
        if (entry.directory) {
            directoryCount++;
            continue;
        }
        fileCount++;
        if ([entry.name.pathExtension caseInsensitiveCompare:@"xml"] == NSOrderedSame) {
            [xmlEntries addObject:entry];
        }
        if ([entry.name caseInsensitiveCompare:@"manifest.txt"] == NSOrderedSame) {
            manifestCount++;
        }
    }
    if (xmlEntries.count == 0) {
        close(sourceFD);
        return AMProjImportFail(error, AMProjImportArchiveErrorInvalidXML,
                                @"A project package must contain at least one XML file",
                                @{ @"xml_count": @(xmlEntries.count) });
    }
    if (manifestCount > 1) {
        close(sourceFD);
        return AMProjImportFail(error, AMProjImportArchiveErrorInvalidZIP,
                                @"A project package may contain at most one root manifest.txt",
                                @{ @"manifest_count": @(manifestCount) });
    }
    for (AMProjImportEntry *xmlEntry in xmlEntries) {
        if (xmlEntry.uncompressedSize == 0 ||
            xmlEntry.uncompressedSize > kAMProjImportMaximumXMLBytes) {
            close(sourceFD);
            return AMProjImportFail(error, AMProjImportArchiveErrorInvalidXML,
                                    @"A project XML is empty or too large",
                                    @{ @"entry": xmlEntry.name ?: @"",
                                       @"xml_bytes": @(xmlEntry.uncompressedSize) });
        }
    }

    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSError *fileError = nil;
    if (![fileManager createDirectoryAtURL:workDirectoryURL
               withIntermediateDirectories:YES attributes:nil error:&fileError]) {
        close(sourceFD);
        return AMProjImportFail(error, AMProjImportArchiveErrorExtractionIO,
                                @"Unable to create the native import work directory",
                                @{ @"reason": fileError.localizedDescription ?: @"" });
    }
    NSString *directoryName = [@"amproj-" stringByAppendingString:NSUUID.UUID.UUIDString.lowercaseString];
    NSURL *extractionURL = [workDirectoryURL URLByAppendingPathComponent:directoryName
                                                             isDirectory:YES];
    if (![fileManager createDirectoryAtURL:extractionURL
               withIntermediateDirectories:NO attributes:nil error:&fileError]) {
        close(sourceFD);
        return AMProjImportFail(error, AMProjImportArchiveErrorExtractionIO,
                                @"Unable to create a private extraction directory",
                                @{ @"reason": fileError.localizedDescription ?: @"" });
    }

    BOOL extracted = YES;
    for (AMProjImportEntry *entry in entries) {
        if (!AMProjImportExtractEntry(sourceFD, entry, extractionURL, error)) {
            extracted = NO;
            break;
        }
    }
    close(sourceFD);
    if (!extracted) {
        [fileManager removeItemAtURL:extractionURL error:nil];
        return NO;
    }

    NSUInteger referenceCount = 0;
    NSUInteger rewrittenCount = 0;
    NSUInteger missingCount = 0;
    NSMutableSet<NSString *> *missingReferenceNames = [NSMutableSet set];
    NSData *nativeData = nil;
    AMProjImportEntry *primaryXMLEntry = xmlEntries.firstObject;
    for (AMProjImportEntry *xmlEntry in xmlEntries) {
        NSData *xmlData = [NSData dataWithContentsOfURL:xmlEntry.outputURL
                                                options:NSDataReadingMappedIfSafe
                                                  error:&fileError];
        if (!xmlData) {
            [fileManager removeItemAtURL:extractionURL error:nil];
            return AMProjImportFail(error, AMProjImportArchiveErrorExtractionIO,
                                    @"Unable to read an extracted project XML",
                                    @{ @"entry": xmlEntry.name ?: @"",
                                       @"reason": fileError.localizedDescription ?: @"" });
        }
        NSUInteger xmlReferenceCount = 0;
        NSUInteger xmlRewrittenCount = 0;
        NSUInteger xmlMissingCount = 0;
        NSArray<NSString *> *xmlMissingNames = nil;
        NSData *rewritten = AMProjImportRewriteXML(
            xmlData, entries, &xmlReferenceCount, &xmlRewrittenCount,
            &xmlMissingCount, &xmlMissingNames, error);
        if (!rewritten) {
            [fileManager removeItemAtURL:extractionURL error:nil];
            return NO;
        }
        referenceCount += xmlReferenceCount;
        rewrittenCount += xmlRewrittenCount;
        [missingReferenceNames addObjectsFromArray:xmlMissingNames ?: @[]];
        if (xmlEntry == primaryXMLEntry) nativeData = rewritten;
    }
    missingCount = missingReferenceNames.count;
    NSMutableArray<NSString *> *xmlNames = [NSMutableArray arrayWithCapacity:xmlEntries.count];
    for (AMProjImportEntry *xmlEntry in xmlEntries) {
        if (xmlEntry.name.length) [xmlNames addObject:xmlEntry.name];
    }
    NSString *nativeName = [NSUUID.UUID.UUIDString.lowercaseString
        stringByAppendingString:@".native-import.xml"];
    NSURL *nativeURL = [primaryXMLEntry.outputURL.URLByDeletingLastPathComponent
        URLByAppendingPathComponent:nativeName];
    if (!AMProjImportAtomicWrite(nativeData, nativeURL, error)) {
        [fileManager removeItemAtURL:extractionURL error:nil];
        return NO;
    }

    if (nativeXMLURL) *nativeXMLURL = nativeURL;
    if (metrics) {
        *metrics = @{
            @"entry_count": @(entries.count),
            @"file_count": @(fileCount),
            @"directory_count": @(directoryCount),
            @"xml_count": @(xmlEntries.count),
            @"manifest_count": @(manifestCount),
            @"archive_bytes": @(archiveSize),
            @"compressed_bytes": @(compressedTotal),
            @"uncompressed_bytes": @(uncompressedTotal),
            @"reference_count": @(referenceCount),
            @"rewritten_reference_count": @(rewrittenCount),
            @"missing_reference_count": @(missingCount),
            @"missing_reference_names": [missingReferenceNames.allObjects
                sortedArrayUsingSelector:@selector(compare:)],
            @"xml_names": [xmlNames copy],
            @"extraction_directory": extractionURL.path ?: @"",
            @"native_xml": nativeURL.path ?: @"",
        };
    }
    return YES;
}

BOOL AMProjNormalizeProjectArchive(NSURL *archiveURL, NSURL *workDirectoryURL,
                                   NSURL *destinationURL,
                                   NSDictionary<NSString *, id> **metrics,
                                   NSError **error) {
    if (metrics) *metrics = nil;
    if (error) *error = nil;
    if (![destinationURL isKindOfClass:NSURL.class] || !destinationURL.isFileURL) {
        return AMProjImportFail(error, AMProjImportArchiveErrorInvalidArgument,
                                @"Normalized archive destination must be a local file URL", nil);
    }

    NSURL *nativeXMLURL = nil;
    NSDictionary<NSString *, id> *preparationMetrics = nil;
    if (!AMProjPrepareNativeImport(archiveURL, workDirectoryURL, &nativeXMLURL,
                                   &preparationMetrics, error)) {
        return NO;
    }
    NSString *extractionPath = [preparationMetrics[@"extraction_directory"]
        isKindOfClass:NSString.class] ? preparationMetrics[@"extraction_directory"] : nil;
    NSURL *extractionURL = extractionPath.length
        ? [NSURL fileURLWithPath:extractionPath isDirectory:YES]
        : nativeXMLURL.URLByDeletingLastPathComponent;
    NSFileManager *manager = NSFileManager.defaultManager;

    @try {
        NSError *fileError = nil;
        NSArray<NSURL *> *children = [manager contentsOfDirectoryAtURL:extractionURL
            includingPropertiesForKeys:@[NSURLIsDirectoryKey, NSURLIsRegularFileKey]
                               options:0
                                 error:&fileError];
        if (!children) {
            return AMProjImportFail(error, AMProjImportArchiveErrorExtractionIO,
                                    @"Unable to inspect the validated project package",
                                    @{ @"reason": fileError.localizedDescription ?: @"" });
        }

        NSURL *sceneXMLURL = nil;
        NSMutableDictionary<NSString *, NSURL *> *resourceURLs = [NSMutableDictionary dictionary];
        for (NSURL *child in children) {
            NSNumber *isDirectory = nil;
            NSNumber *isRegular = nil;
            NSError *resourceError = nil;
            BOOL readDirectory = [child getResourceValue:&isDirectory
                                                   forKey:NSURLIsDirectoryKey
                                                    error:&resourceError];
            BOOL readRegular = readDirectory && [child getResourceValue:&isRegular
                                                                  forKey:NSURLIsRegularFileKey
                                                                   error:&resourceError];
            if (!readRegular) {
                return AMProjImportFail(error, AMProjImportArchiveErrorExtractionIO,
                                        @"Unable to inspect an extracted project entry",
                                        @{ @"entry": child.lastPathComponent ?: @"",
                                           @"reason": resourceError.localizedDescription ?: @"" });
            }
            if (isDirectory.boolValue) {
                return AMProjImportFail(error, AMProjImportArchiveErrorUnsafeEntry,
                                        @"Canonical project packages require flat resource filenames",
                                        @{ @"entry": child.lastPathComponent ?: @"" });
            }
            BOOL isGeneratedXML = [child.URLByStandardizingPath.path
                isEqualToString:nativeXMLURL.URLByStandardizingPath.path];
            if (!isRegular.boolValue || isGeneratedXML) continue;
            NSString *name = child.lastPathComponent ?: @"";
            if ([name.pathExtension caseInsensitiveCompare:@"xml"] == NSOrderedSame) {
                if (sceneXMLURL) {
                    return AMProjImportFail(error, AMProjImportArchiveErrorInvalidXML,
                                            @"Validated project package contains multiple scene XML files", nil);
                }
                sceneXMLURL = child;
                continue;
            }
            if ([name caseInsensitiveCompare:@"manifest.txt"] == NSOrderedSame) continue;
            if (!name.length || resourceURLs[name]) {
                return AMProjImportFail(error, AMProjImportArchiveErrorUnsafeEntry,
                                        @"Project package contains duplicate resource filenames",
                                        @{ @"entry": name });
            }
            resourceURLs[name] = child;
        }
        if (!sceneXMLURL) {
            return AMProjImportFail(error, AMProjImportArchiveErrorInvalidXML,
                                    @"Validated project package has no scene XML", nil);
        }

        NSData *sceneXML = [NSData dataWithContentsOfURL:sceneXMLURL
                                                 options:NSDataReadingMappedIfSafe
                                                   error:&fileError];
        if (!sceneXML.length) {
            return AMProjImportFail(error, AMProjImportArchiveErrorInvalidXML,
                                    @"Unable to read the validated scene XML",
                                    @{ @"reason": fileError.localizedDescription ?: @"" });
        }

        NSDictionary<NSString *, NSNumber *> *zipMetrics = nil;
        NSError *zipError = nil;
        BOOL written = AMProjZIPWriteProjectArchive(destinationURL, sceneXML, resourceURLs,
                                                     &zipMetrics, &zipError);
        if (!written) {
            if (error) *error = zipError;
            return NO;
        }
        if (metrics) {
            *metrics = @{
                @"entry_count": preparationMetrics[@"entry_count"] ?: @0,
                @"input_manifest_count": preparationMetrics[@"manifest_count"] ?: @0,
                @"reference_count": preparationMetrics[@"reference_count"] ?: @0,
                @"missing_reference_count": preparationMetrics[@"missing_reference_count"] ?: @0,
                @"missing_reference_names": preparationMetrics[@"missing_reference_names"] ?: @[],
                @"resource_count": @(resourceURLs.count),
                @"normalized_archive": destinationURL.path ?: @"",
                @"zip": zipMetrics ?: @{}
            };
        }
        return YES;
    } @finally {
        if (extractionURL.path.length) {
            [manager removeItemAtURL:extractionURL error:nil];
        }
    }
}
