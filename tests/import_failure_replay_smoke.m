// 猫鹤 AM · 失败导入跨进程恢复、文件替换与主动重试回归。
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#include <assert.h>
#include <stdio.h>

static NSObject *amproj_importDedupeLock(void) {
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}
// AMPROJ_PRODUCTION_REPLAY_HELPERS
int main(int argc, const char **argv) {
    @autoreleasepool {
        assert(argc == 4);
        NSString *phase = @(argv[1]), *suite = @(argv[2]);
        NSURL *root = [NSURL fileURLWithPath:@(argv[3]) isDirectory:YES];
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
        NSFileManager *manager = NSFileManager.defaultManager;
        NSURL *failed = [root URLByAppendingPathComponent:@"failed.amproj"];
        if ([phase isEqual:@"seed"]) {
            assert([@"bad!" writeToURL:failed atomically:YES encoding:NSUTF8StringEncoding error:nil]);
            assert(!amproj_shouldSkipFailedAutomaticImport(failed, defaults));
            amproj_rememberFailedAutomaticImport(amproj_automaticImportFileIdentity(failed), defaults);
            assert(amproj_shouldSkipFailedAutomaticImport(failed, defaults));
            assert([defaults synchronize]);
            puts("IMPORT_REPLAY_SEED_PASS");
            return 0;
        }
        assert([phase isEqual:@"verify"]);
        // 新进程仍跳过同一失败文件，不依赖 6 秒的内存去重。
        assert(amproj_shouldSkipFailedAutomaticImport(failed, defaults));
        assert([manager fileExistsAtPath:failed.path]);
        NSURL *other = [root URLByAppendingPathComponent:@"other.amproj"];
        assert([@"good" writeToURL:other atomically:YES encoding:NSUTF8StringEncoding error:nil]);
        assert(!amproj_shouldSkipFailedAutomaticImport(other, defaults));
        NSDictionary *old = amproj_automaticImportFileIdentity(failed);
        NSDate *changed = [old[@"modified"] dateByAddingTimeInterval:5];
        assert([manager setAttributes:@{NSFileModificationDate:changed} ofItemAtPath:failed.path error:nil]);
        // 复用同一个 NSURL，也必须读取新属性；不能命中其旧 resourceValues 缓存。
        assert(!amproj_shouldSkipFailedAutomaticImport(failed, defaults));
        // 延迟结束的旧校验只记旧版本，不能把刚替换的文件一并屏蔽。
        amproj_rememberFailedAutomaticImport(old, defaults);
        assert(!amproj_shouldSkipFailedAutomaticImport(failed, defaults));
        amproj_rememberFailedAutomaticImport(amproj_automaticImportFileIdentity(failed), defaults);
        assert(amproj_shouldSkipFailedAutomaticImport(failed, defaults));
        NSDictionary *beforeReplacement = amproj_automaticImportFileIdentity(failed);
        assert([@"good" writeToURL:failed atomically:YES encoding:NSUTF8StringEncoding error:nil]);
        assert([manager setAttributes:@{NSFileModificationDate:beforeReplacement[@"modified"]} ofItemAtPath:failed.path error:nil]);
        // 同大小、同时间的原子替换仍是新文件，不能沿用失败记录。
        assert(!amproj_shouldSkipFailedAutomaticImport(failed, defaults));
        amproj_rememberFailedAutomaticImport(amproj_automaticImportFileIdentity(failed), defaults);
        assert(amproj_shouldSkipFailedAutomaticImport(failed, defaults));
        amproj_forgetFailedAutomaticImport(failed, defaults);
        assert(!amproj_shouldSkipFailedAutomaticImport(failed, defaults));
        assert([manager fileExistsAtPath:failed.path]);
        assert([manager fileExistsAtPath:other.path]);
        assert(!amproj_shouldSkipFailedAutomaticImport([root URLByAppendingPathComponent:@"missing.amproj"], defaults));
        assert(!amproj_shouldSkipFailedAutomaticImport([NSURL URLWithString:@"https://example.test/project.amproj"], defaults));
        [defaults removePersistentDomainForName:suite];
        [defaults synchronize];
        puts("IMPORT_FAILURE_REPLAY_PASS");
    }
    return 0;
}
