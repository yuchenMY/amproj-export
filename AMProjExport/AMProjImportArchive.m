#import "AMProjImportArchive.h"
#import "AMProjZIPWriter.h"

#import <CommonCrypto/CommonDigest.h>
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
static const uint64_t kAMProjImportMaximumManifestBytes = 16ULL * 1024 * 1024;
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
                             NSString *description, NSDictionary *details);

@interface AMProjImportSceneProbe : NSObject <NSXMLParserDelegate>
@property(nonatomic) BOOL sawRoot;
@property(nonatomic) BOOL validRoot;
@property(nonatomic, copy) NSString *title;
@end

@implementation AMProjImportSceneProbe
- (void)parser:(NSXMLParser *)parser
 didStartElement:(NSString *)elementName
    namespaceURI:(NSString *)namespaceURI
   qualifiedName:(NSString *)qualifiedName
      attributes:(NSDictionary<NSString *, NSString *> *)attributes {
    (void)parser;
    (void)namespaceURI;
    (void)qualifiedName;
    if (self.sawRoot) return;
    self.sawRoot = YES;
    self.validRoot = [elementName isEqualToString:@"scene"];
    if (self.validRoot) self.title = attributes[@"title"] ?: @"";
}
@end

static BOOL AMProjImportProbeSceneXML(NSData *xmlData, NSString **title,
                                      NSError **error) {
    AMProjImportSceneProbe *probe = [AMProjImportSceneProbe new];
    NSXMLParser *parser = [[NSXMLParser alloc] initWithData:xmlData];
    parser.delegate = probe;
    BOOL parsed = [parser parse];
    if (!parsed || !probe.validRoot) {
        return AMProjImportFail(error, AMProjImportArchiveErrorInvalidXML,
                                @"The project XML must contain a valid scene root",
                                @{ @"reason": parser.parserError.localizedDescription ?: @"" });
    }
    if (title) {
        *title = [probe.title stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    }
    return YES;
}

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

static NSString *AMProjImportUpperSHA1(const unsigned char *bytes, size_t length) {
    static const char digits[] = "0123456789ABCDEF";
    if (length != CC_SHA1_DIGEST_LENGTH) return nil;
    char output[CC_SHA1_DIGEST_LENGTH * 2];
    for (size_t index = 0; index < length; index++) {
        output[index * 2] = digits[bytes[index] >> 4];
        output[index * 2 + 1] = digits[bytes[index] & 0x0f];
    }
    return [[NSString alloc] initWithBytes:output length:sizeof(output)
                                  encoding:NSASCIIStringEncoding];
}

static NSString *AMProjImportSHA1ForFileURL(NSURL *fileURL, NSString *entryName,
                                            NSError **error) {
    int fd = open(fileURL.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) {
        AMProjImportFail(error, AMProjImportArchiveErrorExtractionIO,
                         @"Unable to open an extracted project resource for verification",
                         @{ @"entry": entryName ?: @"", @"errno": @(errno) });
        return nil;
    }
    struct stat fileStat = {0};
    if (fstat(fd, &fileStat) != 0 || !S_ISREG(fileStat.st_mode)) {
        int savedErrno = errno;
        close(fd);
        AMProjImportFail(error, AMProjImportArchiveErrorIntegrity,
                         @"An extracted project resource is not a regular file",
                         @{ @"entry": entryName ?: @"", @"errno": @(savedErrno) });
        return nil;
    }

    CC_SHA1_CTX context;
    CC_SHA1_Init(&context);
    uint8_t buffer[kAMProjImportBufferSize];
    BOOL success = YES;
    while (success) {
        ssize_t count = read(fd, buffer, sizeof(buffer));
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) {
            AMProjImportFail(error, AMProjImportArchiveErrorExtractionIO,
                             @"Unable to read an extracted project resource for verification",
                             @{ @"entry": entryName ?: @"", @"errno": @(errno) });
            success = NO;
        } else if (count == 0) {
            break;
        } else {
            CC_SHA1_Update(&context, buffer, (CC_LONG)count);
        }
    }
    int closeResult = close(fd);
    if (!success) return nil;
    if (closeResult != 0) {
        AMProjImportFail(error, AMProjImportArchiveErrorExtractionIO,
                         @"Unable to close a verified project resource",
                         @{ @"entry": entryName ?: @"", @"errno": @(errno) });
        return nil;
    }
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1_Final(digest, &context);
    return AMProjImportUpperSHA1(digest, sizeof(digest));
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

static BOOL AMProjImportEntryIsXML(AMProjImportEntry *entry) {
    return [entry.name.pathExtension caseInsensitiveCompare:@"xml"] == NSOrderedSame;
}

static BOOL AMProjImportEntryIsManifest(AMProjImportEntry *entry) {
    return [entry.name caseInsensitiveCompare:@"manifest.txt"] == NSOrderedSame;
}

static NSString *AMProjImportFoldedName(NSString *name) {
    return name.precomposedStringWithCanonicalMapping.lowercaseString;
}

static BOOL AMProjImportIsUpperSHA1(NSString *value) {
    if (value.length != CC_SHA1_DIGEST_LENGTH * 2) return NO;
    for (NSUInteger index = 0; index < value.length; index++) {
        unichar character = [value characterAtIndex:index];
        BOOL digit = character >= '0' && character <= '9';
        BOOL upperHex = character >= 'A' && character <= 'F';
        if (!digit && !upperHex) return NO;
    }
    return YES;
}

static BOOL AMProjImportValidateManifest(
    NSArray<AMProjImportEntry *> *entries, AMProjImportEntry *manifestEntry,
    NSUInteger *resourceCountOut, NSUInteger *manifestEntryCountOut,
    NSUInteger *verifiedResourceCountOut, BOOL *manifestVerifiedOut,
    NSDictionary<NSString *, NSString *> **resourceHashesByNameOut,
    NSError **error) {
    NSMutableDictionary<NSString *, AMProjImportEntry *> *resourcesByName =
        [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *resourceNamesByName =
        [NSMutableDictionary dictionary];
    for (AMProjImportEntry *entry in entries) {
        if (entry.directory || AMProjImportEntryIsXML(entry) ||
            AMProjImportEntryIsManifest(entry)) {
            continue;
        }
        NSString *folded = AMProjImportFoldedName(entry.name);
        resourcesByName[folded] = entry;
        resourceNamesByName[folded] = entry.name;
    }
    if (resourceCountOut) *resourceCountOut = resourcesByName.count;
    if (manifestEntryCountOut) *manifestEntryCountOut = 0;
    if (verifiedResourceCountOut) *verifiedResourceCountOut = 0;
    if (manifestVerifiedOut) *manifestVerifiedOut = NO;
    if (resourceHashesByNameOut) *resourceHashesByNameOut = nil;
    if (!manifestEntry) {
        // Legacy packages do not carry a manifest, but their media still need
        // the same identity that PackageImporter derives from one. Calculate
        // the hashes from the extracted files so the XML can be upgraded
        // without changing any resource bytes.
        NSMutableDictionary<NSString *, NSString *> *legacyHashes =
            [NSMutableDictionary dictionaryWithCapacity:resourcesByName.count];
        for (NSString *foldedName in resourcesByName) {
            AMProjImportEntry *resource = resourcesByName[foldedName];
            if (!resource.outputURL) continue;
            NSString *hash = AMProjImportSHA1ForFileURL(resource.outputURL,
                                                        resource.name, error);
            if (!hash) return NO;
            legacyHashes[foldedName] = hash;
        }
        if (resourceHashesByNameOut) {
            *resourceHashesByNameOut = [legacyHashes copy];
        }
        return YES;
    }

    if (manifestEntry.uncompressedSize > kAMProjImportMaximumManifestBytes) {
        return AMProjImportFail(error, AMProjImportArchiveErrorLimitExceeded,
                                @"The project resource manifest is too large",
                                @{ @"manifest_bytes": @(manifestEntry.uncompressedSize) });
    }
    NSError *fileError = nil;
    NSData *manifestData = [NSData dataWithContentsOfURL:manifestEntry.outputURL
                                                 options:NSDataReadingMappedIfSafe
                                                   error:&fileError];
    if (!manifestData || manifestData.length != manifestEntry.uncompressedSize) {
        return AMProjImportFail(error, AMProjImportArchiveErrorExtractionIO,
                                @"Unable to read the extracted project resource manifest",
                                @{ @"reason": fileError.localizedDescription ?: @"",
                                   @"expected_bytes": @(manifestEntry.uncompressedSize),
                                   @"actual_bytes": @(manifestData.length) });
    }
    NSString *manifest = [[NSString alloc] initWithData:manifestData
                                                encoding:NSUTF8StringEncoding];
    if (!manifest) {
        return AMProjImportFail(error, AMProjImportArchiveErrorIntegrity,
                                @"manifest.txt is not valid UTF-8", nil);
    }
    manifest = [manifest stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];
    if ([manifest rangeOfString:@"\r"].location != NSNotFound) {
        return AMProjImportFail(error, AMProjImportArchiveErrorIntegrity,
                                @"manifest.txt contains an invalid line ending", nil);
    }
    if ([manifest hasSuffix:@"\n"]) {
        manifest = [manifest substringToIndex:manifest.length - 1];
    }
    NSArray<NSString *> *lines = manifest.length
        ? [manifest componentsSeparatedByString:@"\n"] : @[];

    NSMutableSet<NSString *> *seenNames = [NSMutableSet set];
    NSMutableSet<NSString *> *seenHashes = [NSMutableSet set];
    NSMutableDictionary<NSString *, NSString *> *verifiedHashes =
        [NSMutableDictionary dictionaryWithCapacity:resourcesByName.count];
    NSUInteger verifiedCount = 0;
    for (NSUInteger lineIndex = 0; lineIndex < lines.count; lineIndex++) {
        NSString *line = lines[lineIndex];
        if (line.length <= CC_SHA1_DIGEST_LENGTH * 2 ||
            [line characterAtIndex:CC_SHA1_DIGEST_LENGTH * 2] != ':') {
            return AMProjImportFail(error, AMProjImportArchiveErrorIntegrity,
                                    @"manifest.txt contains a malformed entry",
                                    @{ @"line": @(lineIndex + 1) });
        }
        NSString *expectedHash = [line substringToIndex:CC_SHA1_DIGEST_LENGTH * 2];
        if (!AMProjImportIsUpperSHA1(expectedHash)) {
            return AMProjImportFail(error, AMProjImportArchiveErrorIntegrity,
                                    @"manifest.txt SHA-1 values must use 40 uppercase hexadecimal characters",
                                    @{ @"line": @(lineIndex + 1),
                                       @"sha1": expectedHash ?: @"" });
        }
        NSString *rawName = [line substringFromIndex:CC_SHA1_DIGEST_LENGTH * 2 + 1];
        BOOL directory = NO;
        NSError *nameError = nil;
        NSString *safeName = AMProjImportSafeName(rawName, &directory, &nameError);
        if (!safeName || directory || ![safeName isEqualToString:rawName]) {
            return AMProjImportFail(error, AMProjImportArchiveErrorUnsafeEntry,
                                    @"manifest.txt contains an unsafe resource filename",
                                    @{ @"line": @(lineIndex + 1),
                                       @"entry": rawName ?: @"",
                                       @"reason": nameError.localizedDescription ?: @"" });
        }
        if ([safeName.pathExtension caseInsensitiveCompare:@"xml"] == NSOrderedSame ||
            [safeName caseInsensitiveCompare:@"manifest.txt"] == NSOrderedSame) {
            return AMProjImportFail(error, AMProjImportArchiveErrorIntegrity,
                                    @"manifest.txt may list resources only, not XML or the manifest itself",
                                    @{ @"line": @(lineIndex + 1), @"entry": safeName });
        }
        NSString *foldedName = AMProjImportFoldedName(safeName);
        if ([seenNames containsObject:foldedName]) {
            return AMProjImportFail(error, AMProjImportArchiveErrorIntegrity,
                                    @"manifest.txt contains a duplicate resource filename",
                                    @{ @"line": @(lineIndex + 1), @"entry": safeName });
        }
        if ([seenHashes containsObject:expectedHash]) {
            return AMProjImportFail(error, AMProjImportArchiveErrorIntegrity,
                                    @"manifest.txt contains a duplicate SHA-1 value",
                                    @{ @"line": @(lineIndex + 1), @"sha1": expectedHash });
        }
        AMProjImportEntry *resource = resourcesByName[foldedName];
        if (!resource || !resource.outputURL) {
            return AMProjImportFail(error, AMProjImportArchiveErrorIntegrity,
                                    @"manifest.txt lists a resource that is missing from the project package",
                                    @{ @"line": @(lineIndex + 1), @"entry": safeName });
        }
        NSString *actualHash = AMProjImportSHA1ForFileURL(resource.outputURL,
                                                          resource.name, error);
        if (!actualHash) return NO;
        if (![actualHash isEqualToString:expectedHash]) {
            return AMProjImportFail(error, AMProjImportArchiveErrorIntegrity,
                                    @"A project resource does not match its manifest.txt SHA-1",
                                    @{ @"entry": resource.name,
                                       @"expected_sha1": expectedHash,
                                       @"actual_sha1": actualHash });
        }
        [seenNames addObject:foldedName];
        [seenHashes addObject:expectedHash];
        verifiedHashes[foldedName] = expectedHash;
        verifiedCount++;
    }

    NSMutableSet<NSString *> *unlistedNames =
        [NSMutableSet setWithArray:resourcesByName.allKeys];
    [unlistedNames minusSet:seenNames];
    if (unlistedNames.count > 0) {
        NSMutableArray<NSString *> *displayNames = [NSMutableArray array];
        for (NSString *foldedName in unlistedNames) {
            NSString *name = resourceNamesByName[foldedName];
            if (name.length) [displayNames addObject:name];
        }
        [displayNames sortUsingSelector:@selector(compare:)];
        return AMProjImportFail(error, AMProjImportArchiveErrorIntegrity,
                                @"Project resources are missing from manifest.txt",
                                @{ @"unlisted_entries": displayNames });
    }
    if (manifestEntryCountOut) *manifestEntryCountOut = lines.count;
    if (verifiedResourceCountOut) *verifiedResourceCountOut = verifiedCount;
    if (manifestVerifiedOut) *manifestVerifiedOut = YES;
    if (resourceHashesByNameOut) {
        *resourceHashesByNameOut = [verifiedHashes copy];
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

static NSString *AMProjImportXMLAttributeValue(NSString *tag,
                                                NSString *attributeName,
                                                NSRange *valueRangeOut) {
    if (valueRangeOut) *valueRangeOut = NSMakeRange(NSNotFound, 0);
    if (!tag.length || !attributeName.length) return nil;
    NSCharacterSet *whitespace = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    NSUInteger cursor = 0;
    if ([tag characterAtIndex:cursor] != '<') return nil;
    cursor++;
    if (cursor < tag.length && [tag characterAtIndex:cursor] == '/') cursor++;

    // Skip the element name. Attribute-looking text inside a quoted value must
    // never be mistaken for a real attribute (for example a project title that
    // literally contains `type="preset"`).
    while (cursor < tag.length) {
        unichar character = [tag characterAtIndex:cursor];
        if ([whitespace characterIsMember:character] ||
            character == '/' || character == '>') {
            break;
        }
        cursor++;
    }

    while (cursor < tag.length) {
        while (cursor < tag.length &&
               [whitespace characterIsMember:[tag characterAtIndex:cursor]]) {
            cursor++;
        }
        if (cursor >= tag.length) return nil;
        unichar character = [tag characterAtIndex:cursor];
        if (character == '/' || character == '>') return nil;

        NSUInteger nameStart = cursor;
        while (cursor < tag.length) {
            character = [tag characterAtIndex:cursor];
            if ([whitespace characterIsMember:character] || character == '=' ||
                character == '/' || character == '>') {
                break;
            }
            cursor++;
        }
        if (cursor == nameStart) return nil;
        NSRange nameRange = NSMakeRange(nameStart, cursor - nameStart);

        while (cursor < tag.length &&
               [whitespace characterIsMember:[tag characterAtIndex:cursor]]) {
            cursor++;
        }
        if (cursor >= tag.length || [tag characterAtIndex:cursor] != '=') return nil;
        cursor++;
        while (cursor < tag.length &&
               [whitespace characterIsMember:[tag characterAtIndex:cursor]]) {
            cursor++;
        }
        if (cursor >= tag.length) return nil;
        unichar quote = [tag characterAtIndex:cursor];
        if (quote != '\'' && quote != '"') return nil;
        NSUInteger valueStart = ++cursor;
        while (cursor < tag.length && [tag characterAtIndex:cursor] != quote) cursor++;
        if (cursor >= tag.length) return nil;

        NSString *name = [tag substringWithRange:nameRange];
        if ([name caseInsensitiveCompare:attributeName] == NSOrderedSame) {
            NSRange valueRange = NSMakeRange(valueStart, cursor - valueStart);
            if (valueRangeOut) *valueRangeOut = valueRange;
            return [tag substringWithRange:valueRange];
        }
        cursor++;
    }
    return nil;
}

static NSString *AMProjImportMediaResourceName(NSString *rawURI) {
    NSString *uri = AMProjImportDecodeXMLReference(rawURI);
    if (uri.length < 7 ||
        ![[uri substringToIndex:7].lowercaseString isEqualToString:@"amproj:"]) {
        return nil;
    }
    NSString *reference = [uri substringFromIndex:7];
    BOOL ignoredDirectory = NO;
    NSError *ignoredError = nil;
    NSString *safeName = AMProjImportSafeName(reference, &ignoredDirectory,
                                               &ignoredError);
    return safeName && !ignoredDirectory ? safeName : nil;
}

static void AMProjImportAppendRewriteOperation(NSMutableArray<NSDictionary *> *operations,
                                                NSRange range, NSString *replacement) {
    if (!replacement) return;
    [operations addObject:@{
        @"location": @(range.location),
        @"length": @(range.length),
        @"replacement": replacement
    }];
}

static BOOL AMProjImportIsXMLWhitespace(unichar character) {
    return character == ' ' || character == '\t' || character == '\r' ||
        character == '\n';
}

static NSRange AMProjImportRootSceneTagRange(NSString *xml) {
    NSUInteger cursor = 0;
    if (xml.length && [xml characterAtIndex:0] == 0xfeff) cursor++;

    while (cursor < xml.length) {
        while (cursor < xml.length &&
               AMProjImportIsXMLWhitespace([xml characterAtIndex:cursor])) {
            cursor++;
        }
        if (cursor >= xml.length) return NSMakeRange(NSNotFound, 0);

        NSRange remainder = NSMakeRange(cursor, xml.length - cursor);
        if ([xml compare:@"<?" options:0 range:NSMakeRange(cursor, MIN(2, remainder.length))]
                == NSOrderedSame) {
            NSRange end = [xml rangeOfString:@"?>" options:0 range:remainder];
            if (end.location == NSNotFound) return NSMakeRange(NSNotFound, 0);
            cursor = NSMaxRange(end);
            continue;
        }
        if (remainder.length >= 4 &&
            [xml compare:@"<!--" options:0 range:NSMakeRange(cursor, 4)] == NSOrderedSame) {
            NSRange end = [xml rangeOfString:@"-->" options:0 range:remainder];
            if (end.location == NSNotFound) return NSMakeRange(NSNotFound, 0);
            cursor = NSMaxRange(end);
            continue;
        }
        if (remainder.length >= 9 &&
            [xml compare:@"<!DOCTYPE" options:NSCaseInsensitiveSearch
                   range:NSMakeRange(cursor, 9)] == NSOrderedSame) {
            NSUInteger index = cursor + 9;
            NSUInteger subsetDepth = 0;
            unichar quote = 0;
            for (; index < xml.length; index++) {
                unichar character = [xml characterAtIndex:index];
                if (quote) {
                    if (character == quote) quote = 0;
                    continue;
                }
                if (character == '\'' || character == '"') {
                    quote = character;
                } else if (character == '[') {
                    subsetDepth++;
                } else if (character == ']' && subsetDepth) {
                    subsetDepth--;
                } else if (character == '>' && subsetDepth == 0) {
                    cursor = index + 1;
                    break;
                }
            }
            if (index >= xml.length) return NSMakeRange(NSNotFound, 0);
            continue;
        }
        break;
    }

    static NSString *const prefix = @"<scene";
    if (xml.length - cursor < prefix.length ||
        [xml compare:prefix options:0 range:NSMakeRange(cursor, prefix.length)] !=
            NSOrderedSame) {
        return NSMakeRange(NSNotFound, 0);
    }
    NSUInteger index = cursor + prefix.length;
    if (index < xml.length) {
        unichar boundary = [xml characterAtIndex:index];
        if (!AMProjImportIsXMLWhitespace(boundary) && boundary != '>' && boundary != '/') {
            return NSMakeRange(NSNotFound, 0);
        }
    }

    unichar quote = 0;
    for (; index < xml.length; index++) {
        unichar character = [xml characterAtIndex:index];
        if (quote) {
            if (character == quote) quote = 0;
            continue;
        }
        if (character == '\'' || character == '"') {
            quote = character;
        } else if (character == '>') {
            return NSMakeRange(cursor, index - cursor + 1);
        }
    }
    return NSMakeRange(NSNotFound, 0);
}

static NSString *AMProjImportEnsureProjectSceneRoot(NSString *xml, BOOL *rewritten,
                                                     NSError **error) {
    if (rewritten) *rewritten = NO;
    NSRange tagRange = AMProjImportRootSceneTagRange(xml);
    if (tagRange.location == NSNotFound) {
        AMProjImportFail(error, AMProjImportArchiveErrorInvalidXML,
                         @"Unable to locate the project scene root tag", nil);
        return nil;
    }
    NSString *tag = [xml substringWithRange:tagRange];
    NSRange typeRange = NSMakeRange(NSNotFound, 0);
    NSString *type = AMProjImportXMLAttributeValue(tag, @"type", &typeRange);
    if ([type isEqualToString:@"project"]) return xml;

    NSMutableString *normalized = [xml mutableCopy];
    if (typeRange.location != NSNotFound) {
        NSRange absoluteRange = NSMakeRange(tagRange.location + typeRange.location,
                                            typeRange.length);
        [normalized replaceCharactersInRange:absoluteRange withString:@"project"];
    } else {
        NSUInteger insertionOffset = NSMaxRange(tagRange) - 1;
        if ([tag hasSuffix:@"/>"]) insertionOffset--;
        [normalized insertString:@" type=\"project\"" atIndex:insertionOffset];
    }
    if (rewritten) *rewritten = YES;
    return normalized;
}

static NSData *AMProjImportRewriteXML(NSData *xmlData,
                                      NSArray<AMProjImportEntry *> *entries,
                                      NSDictionary<NSString *, NSString *> *resourceHashesByName,
                                      BOOL rewriteReferences,
                                      NSUInteger *referenceCount,
                                      NSUInteger *rewrittenCount,
                                      NSUInteger *missingCount,
                                      NSArray<NSString *> **missingNames,
                                      NSUInteger *mediaSignatureCount,
                                      NSUInteger *rewrittenMediaSignatureCount,
                                      NSUInteger *missingMediaSignatureCount,
                                      NSUInteger *projectSceneCount,
                                      NSUInteger *rewrittenProjectSceneCount,
                                      NSError **error) {
    if (mediaSignatureCount) *mediaSignatureCount = 0;
    if (rewrittenMediaSignatureCount) *rewrittenMediaSignatureCount = 0;
    if (missingMediaSignatureCount) *missingMediaSignatureCount = 0;
    if (projectSceneCount) *projectSceneCount = 0;
    if (rewrittenProjectSceneCount) *rewrittenProjectSceneCount = 0;
    NSString *xml = [[NSString alloc] initWithData:xmlData encoding:NSUTF8StringEncoding];
    if (!xml) {
        AMProjImportFail(error, AMProjImportArchiveErrorInvalidXML,
                         @"The project XML is not valid UTF-8", nil);
        return nil;
    }
    BOOL projectSceneRewritten = NO;
    xml = AMProjImportEnsureProjectSceneRoot(xml, &projectSceneRewritten, error);
    if (!xml) return nil;
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

    NSError *mediaRegexError = nil;
    NSRegularExpression *mediaRegex = [NSRegularExpression
        regularExpressionWithPattern:@"<media\\b[^<>]*>"
                              options:NSRegularExpressionCaseInsensitive
                                error:&mediaRegexError];
    if (!mediaRegex) {
        AMProjImportFail(error, AMProjImportArchiveErrorInvalidXML,
                         @"Unable to prepare the project media matcher",
                         @{ @"reason": mediaRegexError.localizedDescription ?: @"" });
        return nil;
    }

    NSMutableDictionary<NSString *, NSURL *> *exactURLs = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSURL *> *foldedURLs = [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *ambiguousFolded = [NSMutableSet set];
    if (rewriteReferences) {
        for (AMProjImportEntry *entry in entries) {
            if (entry.directory || !entry.outputURL) continue;
            exactURLs[entry.name] = entry.outputURL;
            NSString *folded = entry.name.precomposedStringWithCanonicalMapping.lowercaseString;
            if (foldedURLs[folded]) [ambiguousFolded addObject:folded];
            else foldedURLs[folded] = entry.outputURL;
        }
        [foldedURLs removeObjectsForKeys:ambiguousFolded.allObjects];
    }

    NSArray<NSTextCheckingResult *> *matches = rewriteReferences
        ? [regex matchesInString:xml options:0 range:NSMakeRange(0, xml.length)]
        : @[];
    NSMutableSet<NSString *> *missingReferences = [NSMutableSet set];
    NSMutableArray<NSDictionary *> *operations = [NSMutableArray array];
    NSUInteger localRewrittenCount = 0;
    for (NSTextCheckingResult *match in matches) {
        if (match.numberOfRanges < 2) continue;
        NSRange referenceRange = [match rangeAtIndex:1];
        NSString *reference = [xml substringWithRange:referenceRange];
        NSURL *url = AMProjImportURLForReference(reference, exactURLs, foldedURLs);
        if (url) {
            AMProjImportAppendRewriteOperation(
                operations, match.range, AMProjImportEscapeXMLValue(url.absoluteString));
            localRewrittenCount++;
        } else {
            NSString *decoded = AMProjImportDecodeXMLReference(reference);
            NSString *identity = decoded.precomposedStringWithCanonicalMapping.lowercaseString;
            if (identity.length) [missingReferences addObject:identity];
        }
    }

    NSUInteger localMediaSignatureCount = 0;
    NSUInteger localRewrittenMediaSignatureCount = 0;
    NSUInteger localMissingMediaSignatureCount = 0;
    NSArray<NSTextCheckingResult *> *mediaMatches =
        [mediaRegex matchesInString:xml options:0 range:NSMakeRange(0, xml.length)];
    for (NSTextCheckingResult *mediaMatch in mediaMatches) {
        NSRange tagRange = mediaMatch.range;
        NSString *tag = [xml substringWithRange:tagRange];
        NSRange uriRange = NSMakeRange(NSNotFound, 0);
        NSString *rawURI = AMProjImportXMLAttributeValue(tag, @"uri", &uriRange);
        NSString *resourceName = AMProjImportMediaResourceName(rawURI);
        if (!resourceName.length) continue;

        NSString *expectedHash =
            resourceHashesByName[AMProjImportFoldedName(resourceName)];
        if (expectedHash.length != CC_SHA1_DIGEST_LENGTH * 2) {
            localMissingMediaSignatureCount++;
            continue;
        }
        localMediaSignatureCount++;

        NSRange sigRange = NSMakeRange(NSNotFound, 0);
        NSString *currentSignature =
            AMProjImportXMLAttributeValue(tag, @"sig", &sigRange);
        if (currentSignature.length &&
            ![currentSignature.uppercaseString isEqualToString:expectedHash]) {
            AMProjImportFail(error, AMProjImportArchiveErrorIntegrity,
                             @"A project media sig does not match manifest.txt",
                             @{ @"entry": resourceName,
                                @"expected_sha1": expectedHash,
                                @"actual_sig": currentSignature });
            return nil;
        }
        if (sigRange.location != NSNotFound) {
            if (![currentSignature isEqualToString:expectedHash]) {
                NSRange absoluteRange = NSMakeRange(tagRange.location + sigRange.location,
                                                    sigRange.length);
                AMProjImportAppendRewriteOperation(operations, absoluteRange,
                                                   expectedHash);
                localRewrittenMediaSignatureCount++;
            }
        } else {
            NSUInteger insertionOffset = tagRange.location + tag.length;
            if ([tag hasSuffix:@"/>"]) insertionOffset -= 2;
            else if ([tag hasSuffix:@">"]) insertionOffset -= 1;
            else continue;
            AMProjImportAppendRewriteOperation(
                operations, NSMakeRange(insertionOffset, 0),
                [NSString stringWithFormat:@" sig=\"%@\"", expectedHash]);
            localRewrittenMediaSignatureCount++;
        }
    }

    // URI replacements and signature edits can occur in the same media tag.
    // Apply all disjoint edits from right to left so source ranges stay valid.
    [operations sortUsingComparator:^NSComparisonResult(NSDictionary *left,
                                                         NSDictionary *right) {
        NSUInteger leftLocation = [left[@"location"] unsignedIntegerValue];
        NSUInteger rightLocation = [right[@"location"] unsignedIntegerValue];
        if (leftLocation > rightLocation) return NSOrderedAscending;
        if (leftLocation < rightLocation) return NSOrderedDescending;
        NSUInteger leftLength = [left[@"length"] unsignedIntegerValue];
        NSUInteger rightLength = [right[@"length"] unsignedIntegerValue];
        if (leftLength > rightLength) return NSOrderedAscending;
        if (leftLength < rightLength) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    NSMutableString *rewritten = [xml mutableCopy];
    for (NSDictionary *operation in operations) {
        NSRange range = NSMakeRange([operation[@"location"] unsignedIntegerValue],
                                    [operation[@"length"] unsignedIntegerValue]);
        [rewritten replaceCharactersInRange:range withString:operation[@"replacement"]];
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
    if (mediaSignatureCount) *mediaSignatureCount = localMediaSignatureCount;
    if (rewrittenMediaSignatureCount) {
        *rewrittenMediaSignatureCount = localRewrittenMediaSignatureCount;
    }
    if (missingMediaSignatureCount) {
        *missingMediaSignatureCount = localMissingMediaSignatureCount;
    }
    if (projectSceneCount) *projectSceneCount = 1;
    if (rewrittenProjectSceneCount) {
        *rewrittenProjectSceneCount = projectSceneRewritten ? 1 : 0;
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
    AMProjImportEntry *manifestEntry = nil;
    NSUInteger manifestCount = 0;
    NSUInteger fileCount = 0;
    NSUInteger directoryCount = 0;
    for (AMProjImportEntry *entry in entries) {
        if (entry.directory) {
            directoryCount++;
            continue;
        }
        fileCount++;
        if (AMProjImportEntryIsXML(entry)) {
            [xmlEntries addObject:entry];
        }
        if (AMProjImportEntryIsManifest(entry)) {
            manifestCount++;
            manifestEntry = entry;
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
    if (manifestEntry.uncompressedSize > kAMProjImportMaximumManifestBytes) {
        close(sourceFD);
        return AMProjImportFail(error, AMProjImportArchiveErrorLimitExceeded,
                                @"The project resource manifest is too large",
                                @{ @"manifest_bytes": @(manifestEntry.uncompressedSize) });
    }
    // A package with several independent scenes needs the official manifest
    // to tell PackageImporter how those scenes belong together. Keep the
    // single-XML legacy path permissive, but reject an ambiguous multi-XML
    // archive before extracting it when no manifest is present.
    if (xmlEntries.count > 1 && manifestCount == 0) {
        close(sourceFD);
        return AMProjImportFail(error, AMProjImportArchiveErrorInvalidZIP,
                                @"A multi-project package must contain manifest.txt",
                                @{ @"xml_count": @(xmlEntries.count),
                                   @"manifest_count": @(manifestCount) });
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

    NSUInteger resourceCount = 0;
    NSUInteger manifestEntryCount = 0;
    NSUInteger manifestVerifiedResourceCount = 0;
    BOOL manifestVerified = NO;
    NSDictionary<NSString *, NSString *> *resourceHashesByName = nil;
    if (!AMProjImportValidateManifest(entries, manifestEntry, &resourceCount,
                                      &manifestEntryCount,
                                      &manifestVerifiedResourceCount,
                                      &manifestVerified, &resourceHashesByName,
                                      error)) {
        [fileManager removeItemAtURL:extractionURL error:nil];
        return NO;
    }

    NSUInteger referenceCount = 0;
    NSUInteger rewrittenCount = 0;
    NSUInteger missingCount = 0;
    NSUInteger mediaSignatureCount = 0;
    NSUInteger rewrittenMediaSignatureCount = 0;
    NSUInteger missingMediaSignatureCount = 0;
    NSUInteger projectSceneCount = 0;
    NSUInteger rewrittenProjectSceneCount = 0;
    NSMutableSet<NSString *> *missingReferenceNames = [NSMutableSet set];
    NSMutableArray<NSString *> *sceneTitles = [NSMutableArray array];
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
        NSString *sceneTitle = nil;
        if (!AMProjImportProbeSceneXML(xmlData, &sceneTitle, error)) {
            [fileManager removeItemAtURL:extractionURL error:nil];
            return NO;
        }
        [sceneTitles addObject:sceneTitle ?: @""];
        NSUInteger xmlReferenceCount = 0;
        NSUInteger xmlRewrittenCount = 0;
        NSUInteger xmlMissingCount = 0;
        NSUInteger xmlMediaSignatureCount = 0;
        NSUInteger xmlRewrittenMediaSignatureCount = 0;
        NSUInteger xmlMissingMediaSignatureCount = 0;
        NSUInteger xmlProjectSceneCount = 0;
        NSUInteger xmlRewrittenProjectSceneCount = 0;
        NSArray<NSString *> *xmlMissingNames = nil;
        NSData *rewritten = AMProjImportRewriteXML(
            xmlData, entries, resourceHashesByName, YES, &xmlReferenceCount,
            &xmlRewrittenCount, &xmlMissingCount, &xmlMissingNames,
            &xmlMediaSignatureCount, &xmlRewrittenMediaSignatureCount,
            &xmlMissingMediaSignatureCount, &xmlProjectSceneCount,
            &xmlRewrittenProjectSceneCount, error);
        if (!rewritten) {
            [fileManager removeItemAtURL:extractionURL error:nil];
            return NO;
        }
        referenceCount += xmlReferenceCount;
        rewrittenCount += xmlRewrittenCount;
        mediaSignatureCount += xmlMediaSignatureCount;
        rewrittenMediaSignatureCount += xmlRewrittenMediaSignatureCount;
        missingMediaSignatureCount += xmlMissingMediaSignatureCount;
        projectSceneCount += xmlProjectSceneCount;
        rewrittenProjectSceneCount += xmlRewrittenProjectSceneCount;
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
            @"resource_count": @(resourceCount),
            @"manifest_entry_count": @(manifestEntryCount),
            @"manifest_verified_resource_count": @(manifestVerifiedResourceCount),
            @"manifest_verified": @(manifestVerified),
            @"resource_hashes": resourceHashesByName ?: @{},
            @"archive_bytes": @(archiveSize),
            @"compressed_bytes": @(compressedTotal),
            @"uncompressed_bytes": @(uncompressedTotal),
            @"reference_count": @(referenceCount),
            @"rewritten_reference_count": @(rewrittenCount),
            @"media_signature_count": @(mediaSignatureCount),
            @"rewritten_media_signature_count": @(rewrittenMediaSignatureCount),
            @"missing_media_signature_count": @(missingMediaSignatureCount),
            @"project_scene_count": @(projectSceneCount),
            @"rewritten_project_scene_count": @(rewrittenProjectSceneCount),
            @"missing_reference_count": @(missingCount),
            @"missing_reference_names": [missingReferenceNames.allObjects
                sortedArrayUsingSelector:@selector(compare:)],
            @"xml_names": [xmlNames copy],
            @"scene_title": sceneTitles.firstObject ?: @"",
            @"scene_titles": [sceneTitles copy],
            @"extraction_directory": extractionURL.path ?: @"",
            @"native_xml": nativeURL.path ?: @"",
        };
    }
    return YES;
}

static void AMProjImportPut16(uint8_t *bytes, NSUInteger offset, uint16_t value) {
    bytes[offset] = (uint8_t)(value & 0xff);
    bytes[offset + 1] = (uint8_t)(value >> 8);
}

static void AMProjImportPut32(uint8_t *bytes, NSUInteger offset, uint32_t value) {
    bytes[offset] = (uint8_t)(value & 0xff);
    bytes[offset + 1] = (uint8_t)((value >> 8) & 0xff);
    bytes[offset + 2] = (uint8_t)((value >> 16) & 0xff);
    bytes[offset + 3] = (uint8_t)(value >> 24);
}

static BOOL AMProjImportCopyRange(int sourceFD, int destinationFD,
                                  uint64_t offset, uint64_t length,
                                  NSError **error) {
    uint8_t buffer[kAMProjImportBufferSize];
    while (length > 0) {
        size_t requested = (size_t)MIN((uint64_t)sizeof(buffer), length);
        ssize_t count = pread(sourceFD, buffer, requested, (off_t)offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) {
            return AMProjImportFail(error, AMProjImportArchiveErrorExtractionIO,
                                    @"Unable to read the validated project archive",
                                    @{ @"offset": @(offset), @"errno": @(errno) });
        }
        if (!AMProjImportWriteAll(destinationFD, buffer, (size_t)count, error)) return NO;
        offset += (uint64_t)count;
        length -= (uint64_t)count;
    }
    return YES;
}

static BOOL AMProjImportReadEOCDMetadata(int fd, uint64_t archiveSize,
                                         uint64_t *eocdOffsetOut,
                                         uint32_t *centralSizeOut,
                                         uint32_t *centralOffsetOut,
                                         uint16_t *entryCountOut,
                                         NSData **commentOut,
                                         NSError **error) {
    const uint64_t maximumTail = 22 + UINT16_MAX;
    size_t tailLength = (size_t)MIN(archiveSize, maximumTail);
    NSMutableData *tail = [NSMutableData dataWithLength:tailLength];
    uint64_t tailOffset = archiveSize - tailLength;
    if (!AMProjImportReadAt(fd, tailOffset, tail.mutableBytes, tailLength, error)) return NO;

    const uint8_t *bytes = tail.bytes;
    NSInteger eocdIndex = -1;
    for (NSInteger index = (NSInteger)tailLength - 22; index >= 0; index--) {
        if (AMProjImportGet32(bytes, (NSUInteger)index) != 0x06054b50) continue;
        uint16_t commentLength = AMProjImportGet16(bytes, (NSUInteger)index + 20);
        if ((NSUInteger)index + 22 + commentLength == tailLength) {
            eocdIndex = index;
            break;
        }
    }
    if (eocdIndex < 0) {
        return AMProjImportFail(error, AMProjImportArchiveErrorInvalidZIP,
                                @"The project package has no valid ZIP32 end record", nil);
    }

    const uint8_t *eocd = bytes + eocdIndex;
    uint16_t disk = AMProjImportGet16(eocd, 4);
    uint16_t centralDisk = AMProjImportGet16(eocd, 6);
    uint16_t diskEntries = AMProjImportGet16(eocd, 8);
    uint16_t totalEntries = AMProjImportGet16(eocd, 10);
    uint32_t centralSize = AMProjImportGet32(eocd, 12);
    uint32_t centralOffset = AMProjImportGet32(eocd, 16);
    uint16_t commentLength = AMProjImportGet16(eocd, 20);
    uint64_t eocdOffset = tailOffset + (uint64_t)eocdIndex;
    if (disk != 0 || centralDisk != 0 || diskEntries != totalEntries ||
        (uint64_t)centralOffset + centralSize != eocdOffset) {
        return AMProjImportFail(error, AMProjImportArchiveErrorInvalidZIP,
                                @"The ZIP32 end record is inconsistent", nil);
    }

    if (eocdOffsetOut) *eocdOffsetOut = eocdOffset;
    if (centralSizeOut) *centralSizeOut = centralSize;
    if (centralOffsetOut) *centralOffsetOut = centralOffset;
    if (entryCountOut) *entryCountOut = totalEntries;
    if (commentOut) {
        *commentOut = [NSData dataWithBytes:eocd + 22 length:commentLength];
    }
    return YES;
}

static NSURL *AMProjImportPartialArchiveURL(NSURL *destinationURL) {
    NSString *name = [NSString stringWithFormat:@".%@.%@.partial",
                      destinationURL.lastPathComponent ?: @"project.amproj",
                      NSUUID.UUID.UUIDString];
    return [destinationURL.URLByDeletingLastPathComponent
        URLByAppendingPathComponent:name isDirectory:NO];
}

static BOOL AMProjImportPublishExactArchive(NSURL *archiveURL,
                                            NSURL *destinationURL,
                                            NSError **error) {
    int sourceFD = open(archiveURL.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW);
    if (sourceFD < 0) {
        return AMProjImportFail(error, AMProjImportArchiveErrorSourceUnavailable,
                                @"Unable to reopen the validated project package",
                                @{ @"errno": @(errno) });
    }
    struct stat sourceStat = {0};
    if (fstat(sourceFD, &sourceStat) != 0 || !S_ISREG(sourceStat.st_mode)) {
        int savedErrno = errno;
        close(sourceFD);
        return AMProjImportFail(error, AMProjImportArchiveErrorSourceUnavailable,
                                @"The validated project package is no longer a regular file",
                                @{ @"errno": @(savedErrno) });
    }

    NSURL *partialURL = AMProjImportPartialArchiveURL(destinationURL);
    int destinationFD = open(partialURL.fileSystemRepresentation,
                             O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (destinationFD < 0) {
        int savedErrno = errno;
        close(sourceFD);
        return AMProjImportFail(error, AMProjImportArchiveErrorExtractionIO,
                                @"Unable to create the preserved project archive",
                                @{ @"errno": @(savedErrno) });
    }

    BOOL success = AMProjImportCopyRange(sourceFD, destinationFD, 0,
                                         (uint64_t)sourceStat.st_size, error);
    if (close(sourceFD) != 0 && success) {
        success = AMProjImportFail(error, AMProjImportArchiveErrorExtractionIO,
                                   @"Unable to close the validated project archive",
                                   @{ @"errno": @(errno) });
    }
    if (success && fsync(destinationFD) != 0) {
        success = AMProjImportFail(error, AMProjImportArchiveErrorExtractionIO,
                                   @"Unable to flush the preserved project archive",
                                   @{ @"errno": @(errno) });
    }
    if (close(destinationFD) != 0 && success) {
        success = AMProjImportFail(error, AMProjImportArchiveErrorExtractionIO,
                                   @"Unable to close the preserved project archive",
                                   @{ @"errno": @(errno) });
    }
    if (success && rename(partialURL.fileSystemRepresentation,
                          destinationURL.fileSystemRepresentation) != 0) {
        success = AMProjImportFail(error, AMProjImportArchiveErrorExtractionIO,
                                   @"Unable to publish the preserved project archive",
                                   @{ @"errno": @(errno) });
    }
    if (!success) unlink(partialURL.fileSystemRepresentation);
    return success;
}

static NSData *AMProjImportSynthesizedManifest(
    NSArray<AMProjImportEntry *> *entries,
    NSDictionary<NSString *, NSString *> *resourceHashesByName,
    NSError **error) {
    NSMutableArray<AMProjImportEntry *> *resources = [NSMutableArray array];
    for (AMProjImportEntry *entry in entries) {
        if (!entry.directory && !AMProjImportEntryIsXML(entry) &&
            !AMProjImportEntryIsManifest(entry)) {
            [resources addObject:entry];
        }
    }
    [resources sortUsingComparator:^NSComparisonResult(AMProjImportEntry *left,
                                                         AMProjImportEntry *right) {
        return [left.name compare:right.name];
    }];

    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithCapacity:resources.count];
    NSMutableSet<NSString *> *seenHashes = [NSMutableSet set];
    for (AMProjImportEntry *entry in resources) {
        NSString *hash = resourceHashesByName[AMProjImportFoldedName(entry.name)];
        if (!AMProjImportIsUpperSHA1(hash)) {
            AMProjImportFail(error, AMProjImportArchiveErrorIntegrity,
                             @"Unable to synthesize a verified project resource manifest",
                             @{ @"entry": entry.name ?: @"" });
            return nil;
        }
        if ([seenHashes containsObject:hash]) {
            AMProjImportFail(error, AMProjImportArchiveErrorIntegrity,
                             @"Project resources must have unique SHA-1 values",
                             @{ @"entry": entry.name ?: @"", @"sha1": hash });
            return nil;
        }
        [seenHashes addObject:hash];
        [lines addObject:[NSString stringWithFormat:@"%@:%@", hash, entry.name]];
    }
    return [[lines componentsJoinedByString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
}

static BOOL AMProjImportPublishArchiveByAddingManifest(
    NSURL *archiveURL, NSURL *destinationURL,
    NSDictionary<NSString *, NSString *> *resourceHashesByName,
    NSDictionary<NSString *, NSNumber *> **zipMetrics,
    NSError **error) {
    if (zipMetrics) *zipMetrics = nil;
    int sourceFD = open(archiveURL.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW);
    if (sourceFD < 0) {
        return AMProjImportFail(error, AMProjImportArchiveErrorSourceUnavailable,
                                @"Unable to reopen the validated project package",
                                @{ @"errno": @(errno) });
    }
    struct stat sourceStat = {0};
    if (fstat(sourceFD, &sourceStat) != 0 || !S_ISREG(sourceStat.st_mode) ||
        sourceStat.st_size < 22) {
        int savedErrno = errno;
        close(sourceFD);
        return AMProjImportFail(error, AMProjImportArchiveErrorSourceUnavailable,
                                @"The validated project package is no longer available",
                                @{ @"errno": @(savedErrno) });
    }
    uint64_t archiveSize = (uint64_t)sourceStat.st_size;
    uint64_t parsedCentralOffset = 0;
    uint64_t compressedTotal = 0;
    uint64_t uncompressedTotal = 0;
    NSArray<AMProjImportEntry *> *entries = AMProjImportReadDirectory(
        sourceFD, archiveSize, &parsedCentralOffset, &compressedTotal,
        &uncompressedTotal, error);
    if (!entries || !AMProjImportValidateLocalHeaders(sourceFD, entries,
                                                       parsedCentralOffset, error)) {
        close(sourceFD);
        return NO;
    }

    NSUInteger xmlCount = 0;
    NSUInteger manifestCount = 0;
    for (AMProjImportEntry *entry in entries) {
        if (!entry.directory && AMProjImportEntryIsXML(entry)) xmlCount++;
        if (!entry.directory && AMProjImportEntryIsManifest(entry)) manifestCount++;
    }
    if (xmlCount != 1 || manifestCount != 0) {
        close(sourceFD);
        return AMProjImportFail(error, AMProjImportArchiveErrorInvalidZIP,
                                @"Only a single-XML package without manifest.txt can be upgraded",
                                @{ @"xml_count": @(xmlCount),
                                   @"manifest_count": @(manifestCount) });
    }

    NSData *manifest = AMProjImportSynthesizedManifest(entries,
                                                        resourceHashesByName, error);
    if (!manifest || manifest.length > UINT32_MAX) {
        close(sourceFD);
        if (manifest && error && !*error) {
            AMProjImportFail(error, AMProjImportArchiveErrorLimitExceeded,
                             @"The synthesized project resource manifest is too large", nil);
        }
        return NO;
    }

    uint64_t eocdOffset = 0;
    uint32_t centralSize = 0;
    uint32_t centralOffset = 0;
    uint16_t entryCount = 0;
    NSData *comment = nil;
    if (!AMProjImportReadEOCDMetadata(sourceFD, archiveSize, &eocdOffset,
                                      &centralSize, &centralOffset, &entryCount,
                                      &comment, error)) {
        close(sourceFD);
        return NO;
    }
    NSData *manifestName = [@"manifest.txt" dataUsingEncoding:NSASCIIStringEncoding];
    uint64_t localRecordSize = 30ULL + manifestName.length + manifest.length;
    uint64_t manifestCentralSize = 46ULL + manifestName.length;
    uint64_t newCentralOffset64 = (uint64_t)centralOffset + localRecordSize;
    uint64_t newCentralSize64 = (uint64_t)centralSize + manifestCentralSize;
    if (parsedCentralOffset != centralOffset || eocdOffset !=
            (uint64_t)centralOffset + centralSize ||
        entryCount != entries.count || entryCount == UINT16_MAX ||
        newCentralOffset64 > UINT32_MAX || newCentralSize64 > UINT32_MAX) {
        close(sourceFD);
        return AMProjImportFail(error, AMProjImportArchiveErrorUnsupportedZIP,
                                @"The project package cannot be upgraded within ZIP32 limits", nil);
    }

    uLong manifestCRC = crc32(0L, Z_NULL, 0);
    manifestCRC = crc32(manifestCRC, manifest.bytes, (uInt)manifest.length);
    uint8_t localHeader[30] = {0};
    AMProjImportPut32(localHeader, 0, 0x04034b50);
    AMProjImportPut16(localHeader, 4, 20);
    AMProjImportPut16(localHeader, 6, kAMProjImportUTF8Flag);
    AMProjImportPut16(localHeader, 8, 0);
    AMProjImportPut16(localHeader, 10, 0);
    AMProjImportPut16(localHeader, 12, 0x0021);
    AMProjImportPut32(localHeader, 14, (uint32_t)manifestCRC);
    AMProjImportPut32(localHeader, 18, (uint32_t)manifest.length);
    AMProjImportPut32(localHeader, 22, (uint32_t)manifest.length);
    AMProjImportPut16(localHeader, 26, (uint16_t)manifestName.length);

    uint8_t centralHeader[46] = {0};
    AMProjImportPut32(centralHeader, 0, 0x02014b50);
    AMProjImportPut16(centralHeader, 4, 0x0314);
    AMProjImportPut16(centralHeader, 6, 20);
    AMProjImportPut16(centralHeader, 8, kAMProjImportUTF8Flag);
    AMProjImportPut16(centralHeader, 10, 0);
    AMProjImportPut16(centralHeader, 12, 0);
    AMProjImportPut16(centralHeader, 14, 0x0021);
    AMProjImportPut32(centralHeader, 16, (uint32_t)manifestCRC);
    AMProjImportPut32(centralHeader, 20, (uint32_t)manifest.length);
    AMProjImportPut32(centralHeader, 24, (uint32_t)manifest.length);
    AMProjImportPut16(centralHeader, 28, (uint16_t)manifestName.length);
    AMProjImportPut32(centralHeader, 38, 0100600U << 16);
    AMProjImportPut32(centralHeader, 42, centralOffset);

    uint8_t eocd[22] = {0};
    AMProjImportPut32(eocd, 0, 0x06054b50);
    AMProjImportPut16(eocd, 8, entryCount + 1);
    AMProjImportPut16(eocd, 10, entryCount + 1);
    AMProjImportPut32(eocd, 12, (uint32_t)newCentralSize64);
    AMProjImportPut32(eocd, 16, (uint32_t)newCentralOffset64);
    AMProjImportPut16(eocd, 20, (uint16_t)comment.length);

    NSURL *partialURL = AMProjImportPartialArchiveURL(destinationURL);
    int destinationFD = open(partialURL.fileSystemRepresentation,
                             O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (destinationFD < 0) {
        int savedErrno = errno;
        close(sourceFD);
        return AMProjImportFail(error, AMProjImportArchiveErrorExtractionIO,
                                @"Unable to create the upgraded project archive",
                                @{ @"errno": @(savedErrno) });
    }

    BOOL success = AMProjImportCopyRange(sourceFD, destinationFD, 0,
                                         centralOffset, error) &&
        AMProjImportWriteAll(destinationFD, localHeader, sizeof(localHeader), error) &&
        AMProjImportWriteAll(destinationFD, manifestName.bytes, manifestName.length, error) &&
        AMProjImportWriteAll(destinationFD, manifest.bytes, manifest.length, error) &&
        AMProjImportCopyRange(sourceFD, destinationFD, centralOffset,
                              centralSize, error) &&
        AMProjImportWriteAll(destinationFD, centralHeader, sizeof(centralHeader), error) &&
        AMProjImportWriteAll(destinationFD, manifestName.bytes, manifestName.length, error) &&
        AMProjImportWriteAll(destinationFD, eocd, sizeof(eocd), error) &&
        AMProjImportWriteAll(destinationFD, comment.bytes, comment.length, error);
    if (close(sourceFD) != 0 && success) {
        success = AMProjImportFail(error, AMProjImportArchiveErrorExtractionIO,
                                   @"Unable to close the validated project archive",
                                   @{ @"errno": @(errno) });
    }
    if (success && fsync(destinationFD) != 0) {
        success = AMProjImportFail(error, AMProjImportArchiveErrorExtractionIO,
                                   @"Unable to flush the upgraded project archive",
                                   @{ @"errno": @(errno) });
    }
    if (close(destinationFD) != 0 && success) {
        success = AMProjImportFail(error, AMProjImportArchiveErrorExtractionIO,
                                   @"Unable to close the upgraded project archive",
                                   @{ @"errno": @(errno) });
    }
    if (success && rename(partialURL.fileSystemRepresentation,
                          destinationURL.fileSystemRepresentation) != 0) {
        success = AMProjImportFail(error, AMProjImportArchiveErrorExtractionIO,
                                   @"Unable to publish the upgraded project archive",
                                   @{ @"errno": @(errno) });
    }
    if (!success) {
        unlink(partialURL.fileSystemRepresentation);
        return NO;
    }

    if (zipMetrics) {
        uint64_t outputBytes = newCentralOffset64 + newCentralSize64 +
            sizeof(eocd) + comment.length;
        *zipMetrics = @{
            @"entry_count": @(entryCount + 1),
            @"xml_count": @1,
            @"manifest_count": @1,
            @"uncompressed_bytes": @(uncompressedTotal + manifest.length),
            @"compressed_bytes": @(compressedTotal + manifest.length),
            @"archive_bytes": @(outputBytes),
            @"crc_verified": @YES,
            @"manifest_verified": @YES,
            @"source_entries_preserved": @YES,
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
        NSUInteger inputManifestCount =
            [preparationMetrics[@"manifest_count"] unsignedIntegerValue];
        NSUInteger inputXMLCount =
            [preparationMetrics[@"xml_count"] unsignedIntegerValue];
        NSUInteger signatureRewrites =
            [preparationMetrics[@"rewritten_media_signature_count"] unsignedIntegerValue];
        NSUInteger missingMediaSignatures =
            [preparationMetrics[@"missing_media_signature_count"] unsignedIntegerValue];
        NSUInteger projectSceneRewrites =
            [preparationMetrics[@"rewritten_project_scene_count"] unsignedIntegerValue];

        if (missingMediaSignatures) {
            return AMProjImportFail(
                error, AMProjImportArchiveErrorIntegrity,
                @"A project media entry has no matching manifest SHA-1",
                @{ @"missing_media_signature_count": @(missingMediaSignatures) });
        }

        BOOL archivePreserved = inputManifestCount == 1 && signatureRewrites == 0 &&
            projectSceneRewrites == 0;
        if (archivePreserved) {
            if (!AMProjImportPublishExactArchive(archiveURL, destinationURL, error)) return NO;
            NSDictionary<NSString *, NSNumber *> *zipMetrics = @{
                @"entry_count": preparationMetrics[@"entry_count"] ?: @0,
                @"xml_count": preparationMetrics[@"xml_count"] ?: @0,
                @"manifest_count": @1,
                @"archive_bytes": preparationMetrics[@"archive_bytes"] ?: @0,
                @"crc_verified": @YES,
                @"manifest_verified": @YES,
                @"source_entries_preserved": @YES,
                @"archive_preserved": @YES,
            };
            if (metrics) {
                *metrics = @{
                    @"entry_count": preparationMetrics[@"entry_count"] ?: @0,
                    @"input_manifest_count": @(inputManifestCount),
                    @"scene_title": preparationMetrics[@"scene_title"] ?: @"",
                    @"scene_titles": preparationMetrics[@"scene_titles"] ?: @[],
                    @"reference_count": preparationMetrics[@"reference_count"] ?: @0,
                    @"media_signature_count":
                        preparationMetrics[@"media_signature_count"] ?: @0,
                    @"rewritten_media_signature_count": @0,
                    @"missing_media_signature_count": @0,
                    @"project_scene_count":
                        preparationMetrics[@"project_scene_count"] ?: @0,
                    @"rewritten_project_scene_count": @0,
                    @"missing_reference_count":
                        preparationMetrics[@"missing_reference_count"] ?: @0,
                    @"missing_reference_names":
                        preparationMetrics[@"missing_reference_names"] ?: @[],
                    @"resource_count": preparationMetrics[@"resource_count"] ?: @0,
                    @"archive_preserved": @YES,
                    @"xml_preserved": @YES,
                    @"normalized_archive": destinationURL.path ?: @"",
                    @"zip": zipMetrics
                };
            }
            return YES;
        }

        __block NSError *enumerationError = nil;
        NSDirectoryEnumerator<NSURL *> *enumerator = [manager
            enumeratorAtURL:extractionURL
 includingPropertiesForKeys:@[NSURLIsDirectoryKey, NSURLIsRegularFileKey]
                    options:0
               errorHandler:^BOOL(NSURL *URL, NSError *scanError) {
            enumerationError = scanError;
            return NO;
        }];
        if (!enumerator) {
            return AMProjImportFail(error, AMProjImportArchiveErrorExtractionIO,
                                    @"Unable to inspect the validated project package",
                                    nil);
        }

        NSString *rootPath = extractionURL.URLByStandardizingPath.path;
        NSString *rootPrefix = [rootPath stringByAppendingString:@"/"];
        NSMutableDictionary<NSString *, NSURL *> *sceneXMLURLs =
            [NSMutableDictionary dictionary];
        NSMutableDictionary<NSString *, NSURL *> *resourceURLs =
            [NSMutableDictionary dictionary];
        for (NSURL *child in enumerator) {
            NSNumber *isDirectory = nil;
            NSNumber *isRegular = nil;
            NSError *resourceError = nil;
            BOOL readDirectory = [child getResourceValue:&isDirectory
                                                   forKey:NSURLIsDirectoryKey
                                                    error:&resourceError];
            BOOL readRegular = readDirectory &&
                [child getResourceValue:&isRegular
                                  forKey:NSURLIsRegularFileKey
                                   error:&resourceError];
            if (!readRegular) {
                return AMProjImportFail(error, AMProjImportArchiveErrorExtractionIO,
                                        @"Unable to inspect an extracted project entry",
                                        @{ @"entry": child.lastPathComponent ?: @"",
                                           @"reason": resourceError.localizedDescription ?: @"" });
            }
            if (isDirectory.boolValue) continue;
            BOOL isGeneratedXML = [child.URLByStandardizingPath.path
                isEqualToString:nativeXMLURL.URLByStandardizingPath.path];
            if (!isRegular.boolValue || isGeneratedXML) continue;
            NSString *childPath = child.URLByStandardizingPath.path;
            if (![childPath hasPrefix:rootPrefix] ||
                childPath.length <= rootPrefix.length) {
                return AMProjImportFail(error, AMProjImportArchiveErrorUnsafeEntry,
                                        @"An extracted project entry escaped its work directory",
                                        @{ @"path": childPath ?: @"" });
            }
            NSString *name = [childPath substringFromIndex:rootPrefix.length];
            if ([name.pathExtension caseInsensitiveCompare:@"xml"] == NSOrderedSame) {
                if (sceneXMLURLs[name]) {
                    return AMProjImportFail(error, AMProjImportArchiveErrorInvalidXML,
                                            @"Validated project package contains duplicate scene XML paths",
                                            @{ @"entry": name });
                }
                sceneXMLURLs[name] = child;
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
        if (enumerationError) {
            return AMProjImportFail(error, AMProjImportArchiveErrorExtractionIO,
                                    @"Unable to enumerate the validated project package",
                                    @{ @"reason": enumerationError.localizedDescription ?: @"" });
        }
        if (sceneXMLURLs.count != inputXMLCount) {
            return AMProjImportFail(error, AMProjImportArchiveErrorInvalidXML,
                                    @"Validated project XML count changed during normalization",
                                    @{ @"expected": @(inputXMLCount),
                                       @"actual": @(sceneXMLURLs.count) });
        }
        NSUInteger expectedResourceCount =
            [preparationMetrics[@"resource_count"] unsignedIntegerValue];
        if (resourceURLs.count != expectedResourceCount) {
            return AMProjImportFail(error, AMProjImportArchiveErrorIntegrity,
                                    @"Validated project resource count changed during normalization",
                                    @{ @"expected": @(expectedResourceCount),
                                       @"actual": @(resourceURLs.count) });
        }

        NSDictionary<NSString *, NSString *> *resourceHashes =
            [preparationMetrics[@"resource_hashes"] isKindOfClass:NSDictionary.class]
                ? preparationMetrics[@"resource_hashes"] : @{};
        NSUInteger mediaSignatureCount = 0;
        NSUInteger rewrittenMediaSignatureCount = 0;
        NSUInteger normalizedMissingMediaSignatureCount = 0;
        NSUInteger projectSceneCount = 0;
        NSUInteger rewrittenProjectSceneCount = 0;
        NSMutableDictionary<NSString *, NSData *> *signedSceneXMLFiles =
            [NSMutableDictionary dictionaryWithCapacity:sceneXMLURLs.count];
        for (NSString *name in [sceneXMLURLs.allKeys
                sortedArrayUsingSelector:@selector(compare:)]) {
            NSError *fileError = nil;
            NSData *sceneXML = [NSData dataWithContentsOfURL:sceneXMLURLs[name]
                                                     options:NSDataReadingMappedIfSafe
                                                       error:&fileError];
            if (!sceneXML.length) {
                return AMProjImportFail(error, AMProjImportArchiveErrorInvalidXML,
                                        @"Unable to read a validated scene XML",
                                        @{ @"entry": name,
                                           @"reason": fileError.localizedDescription ?: @"" });
            }
            NSUInteger sceneMediaSignatureCount = 0;
            NSUInteger sceneRewrittenMediaSignatureCount = 0;
            NSUInteger sceneMissingMediaSignatureCount = 0;
            NSUInteger sceneProjectSceneCount = 0;
            NSUInteger sceneRewrittenProjectSceneCount = 0;
            NSData *signedSceneXML = AMProjImportRewriteXML(
                sceneXML, @[], resourceHashes, NO, NULL, NULL, NULL, NULL,
                &sceneMediaSignatureCount, &sceneRewrittenMediaSignatureCount,
                &sceneMissingMediaSignatureCount, &sceneProjectSceneCount,
                &sceneRewrittenProjectSceneCount, &fileError);
            if (!signedSceneXML) {
                if (error) *error = fileError;
                return NO;
            }
            mediaSignatureCount += sceneMediaSignatureCount;
            rewrittenMediaSignatureCount += sceneRewrittenMediaSignatureCount;
            normalizedMissingMediaSignatureCount += sceneMissingMediaSignatureCount;
            projectSceneCount += sceneProjectSceneCount;
            rewrittenProjectSceneCount += sceneRewrittenProjectSceneCount;
            signedSceneXMLFiles[name] = signedSceneXML;
        }
        if (normalizedMissingMediaSignatureCount) {
            return AMProjImportFail(
                error, AMProjImportArchiveErrorIntegrity,
                @"A project media entry could not be assigned a manifest SHA-1",
                @{ @"missing_media_signature_count":
                       @(normalizedMissingMediaSignatureCount) });
        }

        NSDictionary<NSString *, NSNumber *> *zipMetrics = nil;
        NSError *zipError = nil;
        if (!AMProjZIPWriteProjectArchiveFiles(destinationURL,
                                               signedSceneXMLFiles,
                                               resourceURLs,
                                               &zipMetrics, &zipError)) {
            if (error) *error = zipError;
            return NO;
        }
        if (metrics) {
            *metrics = @{
                @"entry_count": preparationMetrics[@"entry_count"] ?: @0,
                @"input_manifest_count": @(inputManifestCount),
                @"scene_title": preparationMetrics[@"scene_title"] ?: @"",
                @"scene_titles": preparationMetrics[@"scene_titles"] ?: @[],
                @"reference_count": preparationMetrics[@"reference_count"] ?: @0,
                @"media_signature_count": @(mediaSignatureCount),
                @"rewritten_media_signature_count":
                    @(rewrittenMediaSignatureCount),
                @"missing_media_signature_count": @0,
                @"project_scene_count": @(projectSceneCount),
                @"rewritten_project_scene_count": @(rewrittenProjectSceneCount),
                @"missing_reference_count": preparationMetrics[@"missing_reference_count"] ?: @0,
                @"missing_reference_names": preparationMetrics[@"missing_reference_names"] ?: @[],
                @"resource_count": @(resourceURLs.count),
                @"archive_preserved": @NO,
                @"xml_preserved": @(rewrittenMediaSignatureCount == 0 &&
                                     rewrittenProjectSceneCount == 0),
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
