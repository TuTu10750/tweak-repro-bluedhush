//
//  HushAntiRevoke.m
//  BluedHushRE
//
//  防撤回的「轮询路径」。HushHooks.m 里 p_filterDeletedMessages: / deleteMessage:
//  那两条 hook 是实时拦截；这个文件是事后补拉 —— 两条路互不依赖。
//
//  ⚠️  v21 重写要点（v20 把宿主私聊弄白屏了，原因见下）
//  =====================================================
//  v20 用 `ATTACH DATABASE 'file:...?mode=ro' AS host` 把宿主库挂到我方连接上，
//  而且一挂就不 DETACH。结果：
//    · 宿主库是 rollback-journal 模式（沙盒里没有 -wal/-shm 文件可以证明）
//    · 每次 `INSERT INTO snapshot SELECT ... FROM host.messageTable` 都是一次
//      跨库事务 —— 同时持我方写锁 + 宿主读锁，3 秒一轮
//    · 宿主自己拉消息时撞上读锁，超时，私聊页拿不到数据
//  日志证据：switch_anti_recall=0（开关关着）却仍然
//      [00:52:44.566] 宿主库已挂载 / tick=17 快照+67 cursor=3508
//  —— 也就是「开关没拦住 + 长连接锁住宿主」两个 bug 叠加。
//
//  v21 改成三条铁律：
//    1. 绝不碰宿主库。复制成 tmp 副本再读：copy → open(copy) → prepare → read → close → unlink
//       → close，全程一个函数内完成，锁的持有时间是微秒级。
//    2. 宿主连接 `busy_timeout=0` + `PRAGMA query_only=1`：撞锁立刻失败返回，
//       绝不排队等宿主，绝不参与宿主的锁调度。
//    3. 开关缓存 + 首次读取必须显式记账。开关关着时零 IO —— 连宿主库路径都不探。
//
//  数据来源（2026-11-03 实测导出沙盒）
//  ==================================
//    Documents/<uid>DB.sqlite
//      messageTable(sessionType, sessionId, msgLocalId, sendState, messageType,
//                   fromId, messageContent, messageId, deleteState, sendTime,
//                   msgExtra, ...)
//      messagesIndex ON messageTable (sessionType, sessionId, messageId)
//    messageType = 24 是闪照；deleteState 非 0 是宿主自己的删除/撤回标记。
//
//  为什么不走 GJIMDBService
//  ------------------------
//  它有 p_getMessagesWithToken:isTempChat:startMsgId:endMsgId:complete:
//  （encoding v52@0:8@16B24Q28Q36@?44），但 74 个方法全是实例方法，没有
//  sharedInstance / defaultInstance 入口 —— 拿实例只能靠 hook 抓 self，
//  那就又变成 hook 的附属品了。读库没有这个约束。
//
//  我方库：Documents/bluedbackups/hush_revoke.sqlite（WAL，和 hush.log 同目录，
//  用户导沙盒一次拿全）。物理独立，绝不写宿主库。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <sqlite3.h>
#import <unistd.h>
#import <stdio.h>
#import <stdarg.h>

#import "HushLogger.h"
#import "HushConfig.h"

#define HUSH_AR_TICK_SEC        3.0     // timer 周期
#define HUSH_AR_HOST_EVERY      5       // 每 5 个 tick 才碰一次宿主库（15 秒）
#define HUSH_AR_RESCAN_TICKS    20      // 每 20 tick 重扫宿主库路径（60 秒）
#define HUSH_AR_PAGE            300     // 单次从宿主拉多少行
#define HUSH_AR_FULL_WINDOW     (7LL * 24 * 3600)
#define HUSH_AR_MISS_BURST      50
#define HUSH_AR_FLASH_TYPE      24

static sqlite3       *gMineDB       = NULL;
static NSString      *gHostPath     = NULL;
static dispatch_queue_t   gQueue    = NULL;
static dispatch_source_t  gTimer    = NULL;
static int            gTicks        = 0;
static long long      gCursor       = 0;
static BOOL           gStarted      = NO;
static BOOL           gEnabled      = NO;   // switch_anti_recall 的缓存
static BOOL           gEnabledRead  = NO;
static BOOL           gHostWarned   = NO;
// 诊断计数器：复制方案与读库都不能静默失败，否则出问题时说不清
// "15 秒延迟正常" 和 "一直读不到"。全部进 tick 行。
static int            gCopyOk      = 0;   // 复制+打开副本成功
static int            gFailIo      = 0;   // 复制 IO 失败（磁盘/权限/路径，SQLITE_CANTOPEN）
static int            gFailCorrupt = 0;   // 副本页级不一致（SQLITE_NOTADB / SQLITE_CORRUPT）
static int            gCopyBadMagic= 0;   // 不是明文 sqlite（SQLCipher？）
static int            gHostBusy    = 0;   // 副本读到一半撞 BUSY/LOCKED
static double         gOpenMsLast  = 0.0; // 最近一次 复制+open 的毫秒数

#pragma mark - helpers

static long long HushARNow(void) { return (long long)[NSDate date].timeIntervalSince1970; }

static void ARLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    [HushLogger logLevel:3 format:s];
}

static BOOL HushARExec(sqlite3 *db, const char *sql) {
    if (!db || !sql) return NO;
    char *err = NULL;
    int rc = sqlite3_exec(db, sql, NULL, NULL, &err);
    if (rc != SQLITE_OK) {
        ARLog(@"[Hush][防撤回] 我方库 SQL 失败 rc=%d %s", rc, err ? err : "?");
        if (err) sqlite3_free(err);
        return NO;
    }
    if (err) sqlite3_free(err);
    return YES;
}

static BOOL HushARExecF(sqlite3 *db, NSString *sql) {
    return HushARExec(db, sql.UTF8String);
}

static long long HushARQueryLL(sqlite3 *db, const char *sql) {
    if (!db) return -1;
    sqlite3_stmt *st = NULL;
    long long v = -1;
    if (sqlite3_prepare_v2(db, sql, -1, &st, NULL) == SQLITE_OK) {
        if (sqlite3_step(st) == SQLITE_ROW) v = sqlite3_column_int64(st, 0);
    }
    if (st) sqlite3_finalize(st);
    return v;
}

#pragma mark - paths

static NSString *HushARBackupDir(void) {
    NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (dirs.count == 0) return nil;
    NSString *d = [dirs.firstObject stringByAppendingPathComponent:@"bluedbackups"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:d]) {
        [fm createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:NULL];
    }
    return d;
}

// Copy the host database to tmp and read THAT.  No connection is ever made
// against the host file itself.  The host very likely runs its sqlite with
// locking_mode=EXCLUSIVE -- a second connection makes its own reads/writes
// fail, which shows up as a blank private-chat page and sent messages never
// landing.  A file copy is plain POSIX IO: no sqlite, no db lock, so it
// cannot contend with the host.  If the copy is torn, open/prepare fails and
// we simply skip this round; the host is untouched either way.
static sqlite3 *HushAROpenHostCopy(NSString **outTmp) {
    if (!gHostPath) return NULL;
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
                     [NSString stringWithFormat:@"hush_hostcopy_%d.db", (int)getpid()]];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:tmp error:NULL];

    NSTimeInterval t0 = [NSDate timeIntervalSinceReferenceDate];
    if (![fm copyItemAtPath:gHostPath toPath:tmp error:NULL]) {
        gFailIo++;                                  // 文件层失败，与 sqlite 无关
        return NULL;
    }

    sqlite3 *db = NULL;
    int orc = sqlite3_open_v2(tmp.UTF8String, &db,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, NULL);
    if (orc != SQLITE_OK) {
        if (db) sqlite3_close(db);
        [fm removeItemAtPath:tmp error:NULL];
        // 页级不一致：复制时宿主正写到一半，副本头部/页校验不过。
        // 与磁盘/权限失败处置完全不同（后者重试无意义，前者等宿主空闲再试）。
        if (orc == SQLITE_NOTADB || orc == SQLITE_CORRUPT) {
            gFailCorrupt++;
            ARLog(@"[Hush][防撤回] 副本不可读 rc=%d（NOTADB/CORRUPT，宿主正在写），本轮跳过", orc);
        } else {
            gFailIo++;
            ARLog(@"[Hush][防撤回] 副本打不开 rc=%d（IO/权限），本轮跳过", orc);
        }
        return NULL;
    }
    sqlite3_busy_timeout(db, 0);
    gOpenMsLast = ([NSDate timeIntervalSinceReferenceDate] - t0) * 1000.0;
    gCopyOk++;
    if (outTmp) *outTmp = tmp;
    return db;
}

static void HushARCloseHostCopy(sqlite3 *db, NSString *tmp) {
    if (db) sqlite3_close(db);
    if (tmp) [[NSFileManager defaultManager] removeItemAtPath:tmp error:NULL];
}

// Does this file carry messageTable?  Goes through a copy, never the host file.
static BOOL HushARProbeHost(NSString *path) {
    if (!path) return NO;
    // Cheap header check first so we never copy an unrelated large file.
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) return NO;
    NSData *head = [fh readDataOfLength:16];
    [fh closeFile];
    if (head.length < 16) return NO;
    if (memcmp(head.bytes, "SQLite format 3", 16) != 0) {
        // 前 16 字节不是 "SQLite format 3"：要么是 SQLCipher 加密库（前 16 字节是盐），
        // 要么根本不是 sqlite。两种都读不了，但绝不能静默 —— 否则事后无法解释
        // "为什么没有快照"。
        gCopyBadMagic++;
        ARLog(@"[Hush][防撤回] 跳过 %@：不是明文 sqlite（疑似 SQLCipher），无 key 不可读",
              [path lastPathComponent]);
        return NO;
    }

    NSString *saved = gHostPath;
    gHostPath = path;
    NSString *tmp = nil;
    sqlite3 *db = HushAROpenHostCopy(&tmp);
    gHostPath = saved;
    if (!db) return NO;

    BOOL ok = NO;
    sqlite3_stmt *st = NULL;
    const char *q = "SELECT 1 FROM sqlite_master WHERE type='table' AND name='messageTable'";
    if (sqlite3_prepare_v2(db, q, -1, &st, NULL) == SQLITE_OK) {
        ok = (sqlite3_step(st) == SQLITE_ROW);
    }
    if (st) sqlite3_finalize(st);
    HushARCloseHostCopy(db, tmp);
    return ok;
}

static NSString *HushARFindHostDB(void) {
    NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (dirs.count == 0) return nil;
    NSString *doc = dirs.firstObject;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *names = [fm contentsOfDirectoryAtPath:doc error:NULL];
    if (names.count == 0) return nil;

    for (NSString *n in names) {          // 第一轮：<uid>DB.sqlite 这种命名优先
        if (![n hasSuffix:@".sqlite"] && ![n hasSuffix:@".db"]) continue;
        if ([n rangeOfString:@"DB"].location == NSNotFound) continue;
        NSString *p = [doc stringByAppendingPathComponent:n];
        if (HushARProbeHost(p)) return p;
    }
    for (NSString *n in names) {          // 第二轮：不靠命名
        if (![n hasSuffix:@".sqlite"] && ![n hasSuffix:@".db"]) continue;
        NSString *p = [doc stringByAppendingPathComponent:n];
        if (HushARProbeHost(p)) return p;
    }
    return nil;
}

#pragma mark - my own database

static BOOL HushAROpenMine(void) {
    if (gMineDB) return YES;
    NSString *dir = HushARBackupDir();
    if (!dir) return NO;
    NSString *p = [dir stringByAppendingPathComponent:@"hush_revoke.sqlite"];

    int rc = sqlite3_open_v2(p.UTF8String, &gMineDB,
                             SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, NULL);
    if (rc != SQLITE_OK) {
        ARLog(@"[Hush][防撤回] 我方库打不开 rc=%d，本轮放弃", rc);
        if (gMineDB) { sqlite3_close(gMineDB); gMineDB = NULL; }
        return NO;
    }
    sqlite3_busy_timeout(gMineDB, 2000);
    HushARExec(gMineDB, "PRAGMA journal_mode=WAL;");
    HushARExec(gMineDB, "PRAGMA synchronous=NORMAL;");

    HushARExec(gMineDB,
        "CREATE TABLE IF NOT EXISTS snapshot ("
        " sessionType INTEGER NOT NULL, sessionId INTEGER NOT NULL,"
        " messageId INTEGER NOT NULL, msgLocalId INTEGER, messageType INTEGER,"
        " is_flash INTEGER NOT NULL DEFAULT 0, deleteState INTEGER, sendTime INTEGER,"
        " content TEXT, extra TEXT, snapshot_at INTEGER,"
        " PRIMARY KEY (sessionType, sessionId, messageId));");

    HushARExec(gMineDB,
        "CREATE TABLE IF NOT EXISTS revoked ("
        " sessionType INTEGER NOT NULL, sessionId INTEGER NOT NULL,"
        " messageId INTEGER NOT NULL, messageType INTEGER,"
        " is_flash INTEGER NOT NULL DEFAULT 0, reason TEXT, content TEXT,"
        " sendTime INTEGER, detected_at INTEGER,"
        " PRIMARY KEY (sessionType, sessionId, messageId));");

    HushARExec(gMineDB, "CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT);");
    return YES;
}

static void HushARLoadCursor(void) {
    long long v = HushARQueryLL(gMineDB, "SELECT COALESCE(MAX(messageId),0) FROM snapshot;");
    gCursor = (v < 0) ? 0 : v;
}

#pragma mark - host read (through a file copy, never a connection to the host)

// 从宿主库读一批行。open/close 全在本函数内，锁持有时间 = 一次 SELECT。
// busy_timeout=0：撞上宿主正在写就立刻返回空，绝不排队（排队才是把宿主拖死的原因）。
static NSArray<NSDictionary *> *HushARFetchHost(long long cursor, int limit) {
    if (!gHostPath) return nil;

    NSString *tmpPath = nil;
    sqlite3 *db = HushAROpenHostCopy(&tmpPath);
    if (!db) return nil;

    const char *q =
        "SELECT COALESCE(sessionType,0), COALESCE(sessionId,0), messageId,"
        "       COALESCE(msgLocalId,0), COALESCE(messageType,0), COALESCE(deleteState,0),"
        "       COALESCE(sendTime,0),"
        "       COALESCE(CAST(messageContent AS TEXT),''),"
        "       COALESCE(CAST(msgExtra AS TEXT),'') "
        "FROM messageTable WHERE messageId > ? ORDER BY messageId ASC LIMIT ?";

    sqlite3_stmt *st = NULL;
    NSMutableArray<NSDictionary *> *out = [NSMutableArray arrayWithCapacity:64];
    if (sqlite3_prepare_v2(db, q, -1, &st, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(st, 1, cursor);
        sqlite3_bind_int(st, 2, limit);
        int rc = SQLITE_ROW;
        while ((rc = sqlite3_step(st)) == SQLITE_ROW) {
            const unsigned char *ct = sqlite3_column_text(st, 7);
            const unsigned char *ex = sqlite3_column_text(st, 8);
            [out addObject:@{
                @"st":      @(sqlite3_column_int64(st, 0)),
                @"sid":     @(sqlite3_column_int64(st, 1)),
                @"mid":     @(sqlite3_column_int64(st, 2)),
                @"lid":     @(sqlite3_column_int64(st, 3)),
                @"type":    @(sqlite3_column_int(st, 4)),
                @"del":     @(sqlite3_column_int(st, 5)),
                @"time":    @(sqlite3_column_int64(st, 6)),
                @"content": ct ? @((const char *)ct) : @"",
                @"extra":   ex ? @((const char *)ex) : @"",
            }];
        }
        if (rc == SQLITE_BUSY || rc == SQLITE_LOCKED) {
            gHostBusy++;            // 记次数，不刷屏；tick 行会带出来
        }
    }
    if (st) sqlite3_finalize(st);
    HushARCloseHostCopy(db, tmpPath);
    return out;
}

// 回前台全量：把宿主现有 msgId 读成一个集合，用于发现"我方有、宿主没了"。
static NSSet<NSNumber *> *HushARFetchHostAllIds(long long since) {
    if (!gHostPath) return nil;
    NSString *tmpPath = nil;
    sqlite3 *db = HushAROpenHostCopy(&tmpPath);
    if (!db) return nil;

    NSMutableSet<NSNumber *> *set = [NSMutableSet setWithCapacity:512];
    sqlite3_stmt *st = NULL;
    const char *q = "SELECT messageId FROM messageTable WHERE COALESCE(sendTime,0) > ?";
    if (sqlite3_prepare_v2(db, q, -1, &st, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(st, 1, since);
        while (sqlite3_step(st) == SQLITE_ROW) {
            [set addObject:@(sqlite3_column_int64(st, 0))];
        }
    }
    if (st) sqlite3_finalize(st);
    HushARCloseHostCopy(db, tmpPath);
    return set;
}

#pragma mark - write side (my db only)

static long long HushAROldDeleteState(long long st_, long long sid, long long mid) {
    sqlite3_stmt *s = NULL;
    long long v = 0;
    const char *q = "SELECT COALESCE(deleteState,0) FROM snapshot "
                    "WHERE sessionType=? AND sessionId=? AND messageId=?;";
    if (sqlite3_prepare_v2(gMineDB, q, -1, &s, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(s, 1, st_);
        sqlite3_bind_int64(s, 2, sid);
        sqlite3_bind_int64(s, 3, mid);
        if (sqlite3_step(s) == SQLITE_ROW) v = sqlite3_column_int64(s, 0);
    }
    if (s) sqlite3_finalize(s);
    return v;
}

static void HushARRecordRevoke(NSDictionary *r, NSString *reason) {
    sqlite3_stmt *s = NULL;
    const char *q =
        "INSERT OR IGNORE INTO revoked "
        "(sessionType,sessionId,messageId,messageType,is_flash,reason,content,sendTime,detected_at) "
        "VALUES (?,?,?,?,?,?,?,?,?);";
    if (sqlite3_prepare_v2(gMineDB, q, -1, &s, NULL) != SQLITE_OK) return;
    long long type = [r[@"type"] longLongValue];
    sqlite3_bind_int64(s, 1, [r[@"st"] longLongValue]);
    sqlite3_bind_int64(s, 2, [r[@"sid"] longLongValue]);
    sqlite3_bind_int64(s, 3, [r[@"mid"] longLongValue]);
    sqlite3_bind_int64(s, 4, type);
    sqlite3_bind_int(s, 5, (type == HUSH_AR_FLASH_TYPE) ? 1 : 0);
    sqlite3_bind_text(s, 6, reason.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(s, 7, [r[@"content"] UTF8String], -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(s, 8, [r[@"time"] longLongValue]);
    sqlite3_bind_int64(s, 9, HushARNow());
    sqlite3_step(s);
    sqlite3_finalize(s);
}

static void HushARUpsertRow(NSDictionary *r) {
    sqlite3_stmt *s = NULL;
    const char *q =
        "INSERT INTO snapshot "
        "(sessionType,sessionId,messageId,msgLocalId,messageType,is_flash,deleteState,"
        " sendTime,content,extra,snapshot_at) VALUES (?,?,?,?,?,?,?,?,?,?,?) "
        "ON CONFLICT(sessionType,sessionId,messageId) DO UPDATE SET "
        " msgLocalId=excluded.msgLocalId, messageType=excluded.messageType,"
        " is_flash=excluded.is_flash, deleteState=excluded.deleteState,"
        " sendTime=excluded.sendTime, content=excluded.content,"
        " extra=excluded.extra, snapshot_at=excluded.snapshot_at;";
    if (sqlite3_prepare_v2(gMineDB, q, -1, &s, NULL) != SQLITE_OK) return;
    long long type = [r[@"type"] longLongValue];
    sqlite3_bind_int64(s, 1, [r[@"st"] longLongValue]);
    sqlite3_bind_int64(s, 2, [r[@"sid"] longLongValue]);
    sqlite3_bind_int64(s, 3, [r[@"mid"] longLongValue]);
    sqlite3_bind_int64(s, 4, [r[@"lid"] longLongValue]);
    sqlite3_bind_int64(s, 5, type);
    sqlite3_bind_int(s, 6, (type == HUSH_AR_FLASH_TYPE) ? 1 : 0);
    sqlite3_bind_int64(s, 7, [r[@"del"] longLongValue]);
    sqlite3_bind_int64(s, 8, [r[@"time"] longLongValue]);
    sqlite3_bind_text(s, 9, [r[@"content"] UTF8String], -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(s, 10, [r[@"extra"] UTF8String], -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(s, 11, HushARNow());
    sqlite3_step(s);
    sqlite3_finalize(s);
}

#pragma mark - the poll

// 一次完整往返：读宿主（短连接）→ 内存里判定翻转 → 写我方库 → 关宿主
static void HushARPullOnce(void) {
    if (!gMineDB) return;
    if (!gHostPath) gHostPath = HushARFindHostDB();
    if (!gHostPath) return;

    NSArray<NSDictionary *> *rows = HushARFetchHost(gCursor, HUSH_AR_PAGE);
    if (!rows) return;                  // 撞锁/不可读：本轮直接跳过，下轮再来
    if (rows.count == 0) return;

    int flipped = 0, added = 0;
    long long maxMid = gCursor;

    HushARExec(gMineDB, "BEGIN IMMEDIATE;");
    for (NSDictionary *r in rows) {
        long long mid = [r[@"mid"] longLongValue];
        long long del = [r[@"del"] longLongValue];

        // 检测 A：宿主 deleteState 由 0 翻成非 0。必须在 upsert 之前读旧值。
        if (del != 0) {
            long long old = HushAROldDeleteState([r[@"st"] longLongValue],
                                                 [r[@"sid"] longLongValue], mid);
            if (old == 0) {
                HushARRecordRevoke(r, [NSString stringWithFormat:@"deleteState=%lld", del]);
                flipped++;
                ARLog(@"[Hush][防撤回] 撤回命中 msgId=%lld session=%lld type=%lld %s flash=%d",
                      mid, [r[@"sid"] longLongValue], [r[@"type"] longLongValue],
                      [NSString stringWithFormat:@"deleteState=%lld", del].UTF8String,
                      ([r[@"type"] longLongValue] == HUSH_AR_FLASH_TYPE) ? 1 : 0);
            }
        }

        HushARUpsertRow(r);
        added++;
        if (mid > maxMid) maxMid = mid;
    }
    HushARExec(gMineDB, "COMMIT;");

    if (maxMid > gCursor) gCursor = maxMid;

    if (added > 0 || flipped > 0) {
        long long totalSnap = HushARQueryLL(gMineDB, "SELECT COUNT(*) FROM snapshot;");
        long long totalRev  = HushARQueryLL(gMineDB, "SELECT COUNT(*) FROM revoked;");
        ARLog(@"[Hush][防撤回] tick=%d 快照+%d 撤回+%d 累计=%lld/%lld cursor=%lld"
              " copy ok=%d failIo=%d failCorrupt=%d bad=%d busy=%d open=%.1fms",
              gTicks, added, flipped, totalSnap, totalRev, gCursor,
              gCopyOk, gFailIo, gFailCorrupt, gCopyBadMagic, gHostBusy, gOpenMsLast);
    }
}

// 回前台：全量复检。查"我方有、宿主没了"的行。
static void HushARFullRescan(void) {
    if (!gEnabled) return;
    if (!HushAROpenMine()) return;
    if (!gHostPath) gHostPath = HushARFindHostDB();
    if (!gHostPath) return;

    HushARPullOnce();                   // 先把新增补上

    long long since = HushARNow() - HUSH_AR_FULL_WINDOW;
    NSSet<NSNumber *> *hostIds = HushARFetchHostAllIds(since);
    if (!hostIds) return;               // 宿主不可读就跳过，不算失败

    NSMutableArray<NSNumber *> *mine = [NSMutableArray array];
    sqlite3_stmt *s = NULL;
    const char *q = "SELECT messageId FROM snapshot WHERE COALESCE(sendTime,0) > ?;";
    if (sqlite3_prepare_v2(gMineDB, q, -1, &s, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(s, 1, since);
        while (sqlite3_step(s) == SQLITE_ROW) [mine addObject:@(sqlite3_column_int64(s, 0))];
    }
    if (s) sqlite3_finalize(s);

    NSMutableArray<NSNumber *> *missing = [NSMutableArray array];
    for (NSNumber *n in mine) if (![hostIds containsObject:n]) [missing addObject:n];

    if (missing.count > 0 && missing.count <= HUSH_AR_MISS_BURST) {
        HushARExec(gMineDB, "BEGIN IMMEDIATE;");
        for (NSNumber *n in missing) {
            sqlite3_stmt *d = NULL;
            const char *dq = "SELECT sessionType,sessionId,messageId,messageType,"
                             "COALESCE(deleteState,0),COALESCE(sendTime,0),COALESCE(content,'') "
                             "FROM snapshot WHERE messageId=? LIMIT 1;";
            if (sqlite3_prepare_v2(gMineDB, dq, -1, &d, NULL) == SQLITE_OK) {
                sqlite3_bind_int64(d, 1, n.longLongValue);
                if (sqlite3_step(d) == SQLITE_ROW) {
                    const unsigned char *ct = sqlite3_column_text(d, 6);
                    NSDictionary *r = @{
                        @"st": @(sqlite3_column_int64(d, 0)),
                        @"sid": @(sqlite3_column_int64(d, 1)),
                        @"mid": @(sqlite3_column_int64(d, 2)),
                        @"type": @(sqlite3_column_int(d, 3)),
                        @"del": @(sqlite3_column_int64(d, 4)),
                        @"time": @(sqlite3_column_int64(d, 5)),
                        @"content": ct ? @((const char *)ct) : @"",
                    };
                    HushARRecordRevoke(r, @"row-missing");
                }
            }
            if (d) sqlite3_finalize(d);
        }
        HushARExec(gMineDB, "COMMIT;");
    } else if (missing.count > HUSH_AR_MISS_BURST) {
        ARLog(@"[Hush][防撤回] 行消失 %lu 条，超阈值（疑似删除会话），本轮不记",
              (unsigned long)missing.count);
    }

    long long totalRev = HushARQueryLL(gMineDB, "SELECT COUNT(*) FROM revoked;");
    ARLog(@"[Hush][防撤回] 回前台全量复检完成 宿主集合=%lu 我方缺失=%lu 累计撤回=%lld",
          (unsigned long)hostIds.count, (unsigned long)missing.count, totalRev);
}

static void HushAROnBecameActive(CFNotificationCenterRef center,
                                 void *observer,
                                 CFStringRef name,
                                 const void *object,
                                 CFDictionaryRef userInfo) {
    dispatch_async(gQueue, ^{ @autoreleasepool { HushARFullRescan(); } });
}

#pragma mark - tick

static void HushARTick(void) {
    gTicks++;

    // 开关：首次必须读一次并记账；之后每 HUSH_AR_RESCAN_TICKS 轮重读。
    // v20 的教训 —— 用户日志里 switch_anti_recall=0，模块却挂上宿主库并拉了 67 行，
    // 现在把读到的值显式打出来，任何"开关没拦住"都能一眼看到。
    if (!gEnabledRead || gTicks % HUSH_AR_RESCAN_TICKS == 1) {
        gEnabledRead = YES;
        BOOL now = [[HushConfig shared] isEnabled:@"switch_anti_recall"];
        if (now != gEnabled || gTicks == 1) {
            ARLog(@"[Hush][防撤回] switch_anti_recall=%d", (int)now);
        }
        gEnabled = now;
    }

    if (!gEnabled) {
        if (gTicks % HUSH_AR_RESCAN_TICKS == 0) {
            ARLog(@"[Hush][防撤回] 待命 tick=%d（开关关闭，零 IO）", gTicks);
        }
        return;
    }

    if (!HushAROpenMine()) return;

    // 宿主库只在每 HUSH_AR_HOST_EVERY 个 tick 碰一次（15 秒），
    // 并且只在发现路径时才探测；探不到就降频重试，不刷屏。
    BOOL due = (gTicks % HUSH_AR_HOST_EVERY == 0) || (gTicks == 1);
    if (!due) return;

    if (!gHostPath) {
        // 每 HUSH_AR_RESCAN_TICKS 才真的去扫目录
        if (gTicks % HUSH_AR_RESCAN_TICKS != 0 && gTicks != 1) return;
        gHostPath = HushARFindHostDB();
        if (!gHostPath) {
            if (!gHostWarned || gTicks % HUSH_AR_RESCAN_TICKS == 0) {
                gHostWarned = YES;
                ARLog(@"[Hush][防撤回] 宿主库不可达，第 %d 轮重扫", gTicks);
            }
            return;
        }
        gHostWarned = NO;
        ARLog(@"[Hush][防撤回] 宿主库已发现 %@", [gHostPath lastPathComponent]);
        HushARLoadCursor();
    }

    @autoreleasepool {
        HushARPullOnce();
    }
}

#pragma mark - entry

void HushAntiRevokeStart(void) {
    if (gStarted) return;
    gStarted = YES;

    gQueue = dispatch_queue_create("hush.antirevoke", DISPATCH_QUEUE_SERIAL);

    dispatch_async(gQueue, ^{
        @autoreleasepool {
            // 进程崩溃 / 被系统杀掉时 removeItemAtPath 不会执行，126 KB 的副本
            // 会攒在 tmp 里。启动先清一遍，避免沙盒 tmp 长成几十 MB。
            NSFileManager *fm0 = [NSFileManager defaultManager];
            NSString *td = NSTemporaryDirectory();
            for (NSString *f in [fm0 contentsOfDirectoryAtPath:td error:NULL]) {
                if ([f hasPrefix:@"hush_hostcopy_"]) {
                    [fm0 removeItemAtPath:[td stringByAppendingPathComponent:f] error:NULL];
                }
            }

            if (!HushAROpenMine()) {
                ARLog(@"[Hush][防撤回] 初始化失败（我方库不可用），模块不启用");
                return;
            }

            // 启动阶段只读开关，不碰宿主库 —— 关着就纯待命。
            gEnabled = [[HushConfig shared] isEnabled:@"switch_anti_recall"];
            gEnabledRead = YES;
            HushARLoadCursor();
            long long totalSnap = HushARQueryLL(gMineDB, "SELECT COUNT(*) FROM snapshot;");

            ARLog(@"[Hush][防撤回] 定时扫描已启动（每 %.0f 秒 tick，每 %d tick 读一次宿主库）"
                  " switch=%d 已有快照=%lld cursor=%lld",
                  HUSH_AR_TICK_SEC, HUSH_AR_HOST_EVERY, (int)gEnabled, totalSnap, gCursor);

            CFNotificationCenterAddObserver(CFNotificationCenterGetLocalCenter(),
                                            NULL,
                                            HushAROnBecameActive,
                                            CFSTR("UIApplicationDidBecomeActiveNotification"),
                                            NULL,
                                            CFNotificationSuspensionBehaviorDeliverImmediately);
            ARLog(@"[Hush][防撤回] 回前台全量复检已挂");

            gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gQueue);
            uint64_t period = (uint64_t)(HUSH_AR_TICK_SEC * NSEC_PER_SEC);
            dispatch_source_set_timer(gTimer,
                                      dispatch_time(DISPATCH_TIME_NOW, (int64_t)period),
                                      period,
                                      (uint64_t)(0.5 * NSEC_PER_SEC));
            dispatch_source_set_event_handler(gTimer, ^{
                @autoreleasepool { HushARTick(); }
            });
            dispatch_resume(gTimer);
        }
    });
}
