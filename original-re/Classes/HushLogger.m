// HushLogger — real implementation.
//
// The recovered stub returned 0 / nil for everything, so every call site that
// logged ended up doing nothing, and `isEnabledForLevel:` was always NO.  This
// version writes an actual file so behaviour can be verified on device via the
// panel's "showLog" action.
//
// Levels: 0 off, 1 error, 2 warn, 3 info, 4 debug, 5 trace.
// Default level is 4 (debug) while the recovery is still being validated; the
// panel writes `switch_debug_log` to raise or lower it.

#import "HushLogger.h"
#import "HushConfig.h"

static long long gHushLogLevel = 4;          // @0x243e20 in the original
static unsigned long long gHushFiltered[6] = {0, 0, 0, 0, 0, 0};
static unsigned long long gHushEmitted[6]  = {0, 0, 0, 0, 0, 0};
static NSLock *gHushLogLock = nil;

@implementation HushLogger

+ (void)initialize {
    if (self == [HushLogger class]) {
        gHushLogLock = [[NSLock alloc] init];
    }
}

+ (long long)level {
    return gHushLogLevel;
}

+ (void)setLevel:(long long)a0 {
    if (a0 < 0) a0 = 0;
    if (a0 > 5) a0 = 5;
    gHushLogLevel = a0;
}

+ (BOOL)isEnabledForLevel:(long long)a0 {
    // The original compares `level >= n` (0x16658), i.e. a message is emitted
    // when its severity number is at or below the configured verbosity.
    if (a0 < 0) return NO;
    return gHushLogLevel >= a0;
}

+ (void)noteFiltered:(long long)a0 {
    if (a0 < 0 || a0 > 5) return;
    gHushFiltered[a0]++;
}

+ (id)levelName:(long long)a0 {
    static NSArray<NSString *> *names = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = @[@"off", @"error", @"warn", @"info", @"debug", @"trace"];
    });
    if (a0 < 0 || a0 > 5) return @"?";
    return names[(NSUInteger)a0];
}

+ (id)levelTag:(long long)a0 {
    static NSArray<NSString *> *tags = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        tags = @[@"-", @"E", @"W", @"I", @"D", @"T"];
    });
    if (a0 < 0 || a0 > 5) return @"?";
    return tags[(NSUInteger)a0];
}

+ (void)loadLevelFromConfig {
    HushConfig *cfg = [HushConfig shared];
    // `switch_debug_log` is the persisted master; anything else keeps 4.
    BOOL debugOn = [cfg isEnabled:@"switch_debug_log"];
    gHushLogLevel = debugOn ? 5 : 3;
}

+ (void)persistLevel:(long long)a0 {
    [self setLevel:a0];
    [[HushConfig shared] setEnabled:(a0 >= 4) forKey:@"switch_debug_log"];
}

+ (id)levelStatistics {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    for (long long i = 0; i <= 5; i++) {
        NSString *name = [self levelName:i];
        d[[name stringByAppendingString:@"_emitted"]]  = @(gHushEmitted[i]);
        d[[name stringByAppendingString:@"_filtered"]] = @(gHushFiltered[i]);
    }
    d[@"level"] = @(gHushLogLevel);
    return d;
}

+ (id)logFilePath {
    NSString *dir = [[HushConfig shared] backupDir];
    if ([dir length] == 0) dir = NSTemporaryDirectory();
    NSString *logs = [dir stringByAppendingPathComponent:@"logs"];
    [[NSFileManager defaultManager] createDirectoryAtPath:logs
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    return [logs stringByAppendingPathComponent:@"hush.log"];
}

+ (id)formatLine:(id)a0 levelTag:(id)a1 {
    if (!a0) return @"";
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"HH:mm:ss.SSS";
    NSString *ts = [fmt stringFromDate:[NSDate date]];
    return [NSString stringWithFormat:@"[%@][%@] %@\n", ts, (a1 ?: @"-"), a0];
}

+ (void)openFdIfNeeded {
    // Nothing to pre-open; appendLine: opens on demand.  Kept for API parity.
}

+ (void)rollIfNeeded {
    NSString *path = [self logFilePath];
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
    if (!attrs) return;
    if ([attrs fileSize] < 4ULL * 1024 * 1024) return;     // 4 MB cap

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *old = [path stringByAppendingString:@".1"];
    [fm removeItemAtPath:old error:NULL];
    [fm moveItemAtPath:path toPath:old error:NULL];
}

+ (BOOL)flushBuffer {
    return YES;      // every append writes and closes, so nothing is buffered
}

+ (void)appendLine:(id)a0 {
    if (![a0 length]) return;
    NSString *path = [self logFilePath];
    NSData *data = [(NSString *)a0 dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return;

    [gHushLogLock lock];
    [self rollIfNeeded];

    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) [fm createFileAtPath:path contents:nil attributes:nil];

    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (fh) {
        @try {
            [fh seekToEndOfFile];
            [fh writeData:data];
        } @catch (__unused NSException *e) {
        }
        [fh closeFile];
    }
    [gHushLogLock unlock];
}

+ (void)emit:(id)a0 levelTag:(id)a1 throttle:(BOOL)a2 {
    if (!a0) return;
    NSString *line = [self formatLine:a0 levelTag:a1];
    [self appendLine:line];
    // throttle==YES suppresses the console copy (chatty paths); the file still
    // gets the line so nothing is lost.
    // No "[Hush] " here: every format string already carries its own tag
    // ([Hush] / [Panel] / [Ball]), and prefixing again produced the
    // "[Hush] [Hush] entry installed" double tag seen in the 23:54 syslog.
    if (!a2) NSLog(@"%@", a0);
}

+ (void)logLevel:(long long)a0 format:(id)a1 {
    if (a0 < 0 || a0 > 5) return;
    if (![self isEnabledForLevel:a0]) {
        [self noteFiltered:a0];
        return;
    }
    gHushEmitted[a0]++;
    [self emit:a1 levelTag:[self levelTag:a0] throttle:(a0 <= 2)];
}

+ (void)logSync:(id)a0 {
    [self logLevel:3 format:a0];
}

+ (void)flush {
    [self flushBuffer];
}

+ (id)tail:(unsigned long long)a0 {
    NSString *path = [self logFilePath];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return @"";
    NSString *all = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!all) return @"";

    NSUInteger limit = (a0 == 0 || a0 > 400) ? 400 : (NSUInteger)a0;   // line count
    NSArray<NSString *> *lines = [all componentsSeparatedByString:@"\n"];
    if ([lines count] <= limit) return all;

    NSArray<NSString *> *tail = [lines subarrayWithRange:NSMakeRange([lines count] - limit, limit)];
    return [tail componentsJoinedByString:@"\n"];
}

+ (void)clear {
    NSString *path = [self logFilePath];
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
    for (int i = 0; i <= 5; i++) { gHushEmitted[i] = 0; gHushFiltered[i] = 0; }
}

@end
