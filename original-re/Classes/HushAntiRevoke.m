//
//  HushAntiRevoke.m
//  BluedHushRE
//
//  防撤回的「轮询路径」。HushHooks.m 里 p_filterDeletedMessages: / deleteMessage:
//  那两条 hook 是实时拦截；这个文件是事后补拉 —— 两条路互不依赖，所以即使某次
//  宿主没走被 hook 的方法（换版本、走别的分支、hook 装晚了），快照仍然兜得住。
//
//  为什么读 sqlite 而不是调宿主 API
//  ================================
//  2026-11-03 从设备导出沙盒实测，宿主 IM 库就在 Documents 下：
//
//    Documents/<uid>DB.sqlite
//      messageTable(sessionType, sessionId, msgLocalId, sendState, messageType,
//                   fromId, messageContent, messageId, deleteState, sendTime,
//                   msgExtra, ...)
//      messagesIndex ON messageTable (sessionType, sessionId, messageId)
//      sessionTable(sessionId, sessionType, sessionName, msgLocalId, messageType,
//                   messageContent, sendTime, ...)
//
//  messageType = 24 是闪照；deleteState 是宿主自己的删除/撤回标记 —— 撤回时
//  宿主把 deleteState 从 0 改成非 0（或在某些路径上整行删掉），这两种都能测。
//
//  为什么不走 GJIMDBService
//  ------------------------
//  GJIMDBService 有 p_getMessagesWithToken:isTempChat:startMsgId:endMsgId:complete:
//  （实测 encoding v52@0:8@16B24Q28Q36@?44），但它没有 sharedInstance /
//  defaultInstance 之类的类方法入口 —— 74 个方法里全是实例方法。想拿到实例只能
//  靠 hook 抓 self，那就又依赖 hook 了，违背双保险的初衷。读库没有这个问题：
//  库路径可以从沙盒自己发现，不需要任何宿主对象。
//
//  三层降级
//  ========
//  L1 宿主库可读   → 增量快照 + deleteState 翻转检测 + 回前台行消失检测
//  L2 宿主库不可读 → 每 30 tick 重扫目录一次（换账号后库名会变），记一条日志
//  L3 我方库打不开 → 放弃本轮，不抛不崩，下一轮再试
//
//  我方库：Documents/bluedbackups/hush_revoke.sqlite（和 hush.log 同目录，
//  用户导沙盒时一次拿全）。WAL 模式，与宿主库物理隔离，绝不写宿主库。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <sqlite3.h>
#import <stdio.h>
#import <stdarg.h>

#import "HushLogger.h"
#import "HushConfig.h"

#define HUSH_AR_TICK_SEC        3.0
#define HUSH_AR_RESCAN_TICKS    30
#define HUSH_AR_FULL_WINDOW     (7LL * 24 * 3600)   // 行消失检测只看最近 7 天
#define HUSH_AR_MISS_BURST      50                  // 单轮行消失超过这个数就不记（删会话）
#define HUSH_AR_FLASH_TYPE      24                  // messageType 24 = 闪照

static sqlite3       *gMineDB    = NULL;    // 我方快照库
static NSString      *gHostPath  = NULL;    // 宿主库路径
static NSString      *gHostAttach = NULL;   // ATTACH 用的 URI
static dispatch_queue_t   gQueue  = NULL;
static dispatch_source_t  gTimer  = NULL;
static int            gTicks      = 0;
static long long      gCursor     = 0;
static BOOL           gStarted    = NO;
static BOOL           gHostWarned = NO;

#pragma mark - small helpers

static long long HushARNow(void) {
    return (long long)[NSDate date].timeIntervalSince1970;
}

static void ARLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    [HushLogger logLevel:3 format:s];
}

// 单引号转义，供 ATTACH 'file:...?mode=ro' 用
static NSString *HushARSQLEscape(NSString *in) {
    if (!in) return @"";
    return [in stringByReplacingOccurrencesOfString:@"'" withString:@"''"];
}

static BOOL HushARExec(sqlite3 *db, const char *sql) {
    if (!db || !sql) return NO;
    char *err = NULL;
    int rc = sqlite3_exec(db, sql, NULL, NULL, &err);
    if (rc != SQLITE_OK) {
        ARLog(@"[Hush][防撤回] SQL 失败 rc=%d %s", rc, err ? err : "?");
        if (err) sqlite3_free(err);
        return NO;
    }
    if (err) sqlite3_free(err);
    return YES;
}

static BOOL HushARExecF(sqlite3 *db, NSString *sql) {
    return HushARExec(db, sql.UTF8String);
}

// 单值查询，失败返回 -1
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

// 库里有没有 messageTable —— 这是判定"是不是宿主 IM 库"的唯一可靠依据
static BOOL HushARHasMessageTable(NSString *path) {
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(path.UTF8String, &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
        if (db) sqlite3_close(db);
        return NO;
    }
    BOOL ok = NO;
    sqlite3_stmt *st = NULL;
    const char *q = "SELECT 1 FROM sqlite_master WHERE type='table' AND name='messageTable'";
    if (sqlite3_prepare_v2(db, q, -1, &st, NULL) == SQLITE_OK) {
        ok = (sqlite3_step(st) == SQLITE_ROW);
    }
    if (st) sqlite3_finalize(st);
    sqlite3_close(db);
    return ok;
}

// 宿主库发现：优先找 <uid>DB.sqlite 这种命名，再退化成挨个探 messageTable。
// 换账号后 uid 变、库名变，所以这个函数要能重复调用。
static NSString *HushARFindHostDB(void) {
    NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (dirs.count == 0) return nil;
    NSString *doc = dirs.firstObject;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *names = [fm contentsOfDirectoryAtPath:doc error:NULL];
    if (names.count == 0) return nil;

    // 第一轮：命名里带 DB 的优先（<uid>DB.sqlite）
    for (NSString *n in names) {
        if (![n hasSuffix:@".sqlite"] && ![n hasSuffix:@".db"]) continue;
        if ([n rangeOfString:@"DB"].location == NSNotFound) continue;
        NSString *p = [doc stringByAppendingPathComponent:n];
        if (HushARHasMessageTable(p)) return p;
    }
    // 第二轮：不靠命名
    for (NSString *n in names) {
        if (![n hasSuffix:@".sqlite"] && ![n hasSuffix:@".db"]) continue;
        NSString *p = [doc stringByAppendingPathComponent:n];
        if (HushARHasMessageTable(p)) return p;
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
                             SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_URI, NULL);
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
        " sessionType INTEGER NOT NULL,"
        " sessionId   INTEGER NOT NULL,"
        " messageId   INTEGER NOT NULL,"
        " msgLocalId  INTEGER,"
        " messageType INTEGER,"
        " is_flash    INTEGER NOT NULL DEFAULT 0,"
        " deleteState INTEGER,"
        " sendTime    INTEGER,"
        " content     TEXT,"
        " extra       TEXT,"
        " snapshot_at INTEGER,"
        " PRIMARY KEY (sessionType, sessionId, messageId));");

    HushARExec(gMineDB,
        "CREATE TABLE IF NOT EXISTS revoked ("
        " sessionType INTEGER NOT NULL,"
        " sessionId   INTEGER NOT NULL,"
        " messageId   INTEGER NOT NULL,"
        " messageType INTEGER,"
        " is_flash    INTEGER NOT NULL DEFAULT 0,"
        " reason      TEXT,"
        " content     TEXT,"
        " sendTime    INTEGER,"
        " detected_at INTEGER,"
        " PRIMARY KEY (sessionType, sessionId, messageId));");

    HushARExec(gMineDB,
        "CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT);");

    return YES;
}

static void HushARLoadCursor(void) {
    long long v = HushARQueryLL(gMineDB, "SELECT COALESCE(MAX(messageId),0) FROM snapshot;");
    gCursor = (v < 0) ? 0 : v;
}

static void HushARSaveCursor(long long v) {
    if (!gMineDB || v <= 0) return;
    NSString *sql = [NSString stringWithFormat:
        @"INSERT INTO meta(k,v) VALUES('cursor','%lld') "
         "ON CONFLICT(k) DO UPDATE SET v=excluded.v;", v];
    HushARExecF(gMineDB, sql);
}

#pragma mark - host attach

static void HushARDetachHost(void) {
    if (!gMineDB || !gHostAttach) return;
    HushARExec(gMineDB, "DETACH DATABASE host;");
    gHostAttach = nil;
}

// ATTACH 宿主库为只读。失败就不挂，本轮跳过 —— 不阻塞、不重试风暴。
static BOOL HushARAttachHost(void) {
    if (!gMineDB) return NO;
    if (gHostAttach) return YES;

    if (!gHostPath) gHostPath = HushARFindHostDB();
    if (!gHostPath) return NO;
    if (!HushARHasMessageTable(gHostPath)) { gHostPath = nil; return NO; }

    NSString *uri = [NSString stringWithFormat:@"file:%@?mode=ro", gHostPath];
    NSString *sql = [NSString stringWithFormat:@"ATTACH DATABASE '%@' AS host;",
                     HushARSQLEscape(uri)];
    if (!HushARExecF(gMineDB, sql)) { gHostPath = nil; return NO; }

    gHostAttach = gHostPath;
    ARLog(@"[Hush][防撤回] 宿主库已挂载 %@", [gHostPath lastPathComponent]);
    return YES;
}

// 每 N tick 重挂一次：宿主可能切账号换库、也可能把库整个重建
static void HushARReopenHost(void) {
    HushARDetachHost();
    gHostPath = nil;
    HushARAttachHost();
}

#pragma mark - the two detections

// 检测 A：deleteState 由 0 翻成非 0 —— 这是宿主自己的撤回/删除标记。
// 必须先于 snapshot 的 upsert 跑，否则旧值被覆盖就再也测不到翻转。
static int HushARDetectFlip(void) {
    if (!gMineDB || !gHostAttach) return 0;

    NSString *sql = [NSString stringWithFormat:
        @"INSERT OR IGNORE INTO revoked "
         "(sessionType,sessionId,messageId,messageType,is_flash,reason,content,sendTime,detected_at) "
         "SELECT h.sessionType, h.sessionId, h.messageId, "
         "       COALESCE(h.messageType,0), "
         "       CASE WHEN COALESCE(h.messageType,0)=%d THEN 1 ELSE 0 END, "
         "       'deleteState=' || COALESCE(h.deleteState,0), "
         "       s.content, COALESCE(h.sendTime,0), %lld "
         "FROM host.messageTable h "
         "JOIN snapshot s ON s.sessionType=h.sessionType "
         "               AND s.sessionId=h.sessionId "
         "               AND s.messageId=h.messageId "
         "WHERE COALESCE(h.deleteState,0) != 0 AND COALESCE(s.deleteState,0) = 0;",
        HUSH_AR_FLASH_TYPE, HushARNow()];

    if (!HushARExecF(gMineDB, sql)) return 0;
    int n = (int)sqlite3_changes(gMineDB);

    if (n > 0) {
        // 只打本轮新增的（用 rowid 水位），否则每 3 秒会把最近 10 秒的记录重复刷一遍。
        static long long lastRowid = 0;
        sqlite3_stmt *st = NULL;
        const char *q = "SELECT rowid,sessionId,messageId,messageType,reason,is_flash "
                        "FROM revoked WHERE rowid > ? ORDER BY rowid LIMIT 8;";
        if (sqlite3_prepare_v2(gMineDB, q, -1, &st, NULL) == SQLITE_OK) {
            sqlite3_bind_int64(st, 1, lastRowid);
            while (sqlite3_step(st) == SQLITE_ROW) {
                lastRowid = sqlite3_column_int64(st, 0);
                ARLog(@"[Hush][防撤回] 撤回命中 msgId=%lld session=%lld type=%d %s flash=%d",
                      sqlite3_column_int64(st, 2), sqlite3_column_int64(st, 1),
                      sqlite3_column_int(st, 3),
                      (const char *)sqlite3_column_text(st, 4),
                      sqlite3_column_int(st, 5));
            }
        }
        if (st) sqlite3_finalize(st);
    }
    return n;
}

// 检测 B：我方有、宿主整行没了。只在回前台全量时跑，因为"消失"也可能是
// 宿主正常清理。单轮命中超过 HUSH_AR_MISS_BURST 就当删会话处理，不记。
static int HushARDetectMissing(void) {
    if (!gMineDB || !gHostAttach) return 0;

    long long since = HushARNow() - HUSH_AR_FULL_WINDOW;

    // 先数一下有多少，超过阈值就只记日志
    NSString *countSQL = [NSString stringWithFormat:
        @"SELECT COUNT(*) FROM snapshot s "
         "LEFT JOIN host.messageTable h ON h.sessionType=s.sessionType "
         "                             AND h.sessionId=s.sessionId "
         "                             AND h.messageId=s.messageId "
         "WHERE h.messageId IS NULL AND COALESCE(s.sendTime,0) > %lld;", since];
    long long total = HushARQueryLL(gMineDB, countSQL.UTF8String);

    if (total <= 0) return 0;
    if (total > HUSH_AR_MISS_BURST) {
        ARLog(@"[Hush][防撤回] 行消失 %lld 条，超阈值（疑似删除会话），本轮不记", total);
        return 0;
    }

    NSString *sql = [NSString stringWithFormat:
        @"INSERT OR IGNORE INTO revoked "
         "(sessionType,sessionId,messageId,messageType,is_flash,reason,content,sendTime,detected_at) "
         "SELECT s.sessionType, s.sessionId, s.messageId, COALESCE(s.messageType,0), "
         "       COALESCE(s.is_flash,0), 'row-missing', s.content, "
         "       COALESCE(s.sendTime,0), %lld "
         "FROM snapshot s "
         "LEFT JOIN host.messageTable h ON h.sessionType=s.sessionType "
         "                             AND h.sessionId=s.sessionId "
         "                             AND h.messageId=s.messageId "
         "WHERE h.messageId IS NULL AND COALESCE(s.sendTime,0) > %lld LIMIT 200;",
        HushARNow(), since];

    if (!HushARExecF(gMineDB, sql)) return 0;
    int n = (int)sqlite3_changes(gMineDB);
    if (n > 0) ARLog(@"[Hush][防撤回] 行消失命中 %d 条（reason=row-missing）", n);
    return n;
}

#pragma mark - incremental pull

// 增量：从游标往后拉，先检翻转、再 upsert 快照。游标存在我方库的 meta 里，
// 不从宿主读 —— 宿主把游标删了我们也还在。
static void HushARPullIncremental(void) {
    if (!gMineDB || !gHostAttach) return;

    int flipped = HushARDetectFlip();   // 必须在 upsert 之前

    NSString *sql = [NSString stringWithFormat:
        @"INSERT INTO snapshot "
         "(sessionType,sessionId,messageId,msgLocalId,messageType,is_flash,deleteState,"
         " sendTime,content,extra,snapshot_at) "
         "SELECT COALESCE(sessionType,0), COALESCE(sessionId,0), messageId, "
         "       COALESCE(msgLocalId,0), COALESCE(messageType,0), "
         "       CASE WHEN COALESCE(messageType,0)=%d THEN 1 ELSE 0 END, "
         "       COALESCE(deleteState,0), COALESCE(sendTime,0), "
         "       COALESCE(messageContent,''), COALESCE(msgExtra,''), %lld "
         "FROM host.messageTable WHERE messageId > %lld "
         "ORDER BY messageId ASC LIMIT %d "
         "ON CONFLICT(sessionType,sessionId,messageId) DO UPDATE SET "
         " msgLocalId=excluded.msgLocalId, messageType=excluded.messageType, "
         " is_flash=excluded.is_flash, deleteState=excluded.deleteState, "
         " sendTime=excluded.sendTime, "
         " content=excluded.content, extra=excluded.extra, snapshot_at=excluded.snapshot_at;",
        HUSH_AR_FLASH_TYPE, HushARNow(), gCursor, 500];

    if (!HushARExecF(gMineDB, sql)) return;
    int added = (int)sqlite3_changes(gMineDB);

    long long newMax = HushARQueryLL(gMineDB, "SELECT COALESCE(MAX(messageId),0) FROM snapshot;");
    if (newMax > gCursor) {
        gCursor = newMax;
        HushARSaveCursor(gCursor);
    }

    long long totalSnap = HushARQueryLL(gMineDB, "SELECT COUNT(*) FROM snapshot;");
    long long totalRev  = HushARQueryLL(gMineDB, "SELECT COUNT(*) FROM revoked;");

    // 有新快照或命中撤回就报，否则静默（3 秒一轮不能刷屏）
    if (added > 0 || flipped > 0) {
        ARLog(@"[Hush][防撤回] tick=%d 快照+%d 撤回+%d 累计=%lld/%lld cursor=%lld",
              gTicks, added, flipped, totalSnap, totalRev, gCursor);
    }
}

#pragma mark - tick / rescan

static void HushARTick(void) {
    gTicks++;

    // 闸门：开关关着就什么都不做，只每 30 轮打一条心跳
    BOOL on = [[HushConfig shared] isEnabled:@"switch_anti_recall"];
    if (!on) {
        if (gTicks % HUSH_AR_RESCAN_TICKS == 0) {
            ARLog(@"[Hush][防撤回] switch_anti_recall=0，轮询待命 tick=%d", gTicks);
        }
        return;
    }

    if (!HushAROpenMine()) return;

    if (!gHostAttach) {
        if (!HushARAttachHost()) {
            // L2：宿主库还不可读（未登录 / 还没建库）。降频重扫，不刷屏。
            if (!gHostWarned || gTicks % HUSH_AR_RESCAN_TICKS == 0) {
                gHostWarned = YES;
                ARLog(@"[Hush][防撤回] 宿主库不可达，第 %d 轮重扫", gTicks);
            }
            return;
        }
        gHostWarned = NO;
        HushARLoadCursor();
    }

    HushARPullIncremental();

    // 每 30 轮重挂一次，覆盖切账号/重建库
    if (gTicks % HUSH_AR_RESCAN_TICKS == 0) {
        HushARReopenHost();
        HushARLoadCursor();
    }
}

// 回前台：全量复检。这一步会扫最近 7 天的快照，放后台队列，不占主线程。
static void HushARFullRescan(void) {
    if (![[HushConfig shared] isEnabled:@"switch_anti_recall"]) return;
    if (!HushAROpenMine()) return;
    if (!gHostAttach && !HushARAttachHost()) return;

    int flipped = HushARDetectFlip();
    HushARPullIncremental();
    int missing = HushARDetectMissing();

    long long totalRev = HushARQueryLL(gMineDB, "SELECT COUNT(*) FROM revoked;");
    ARLog(@"[Hush][防撤回] 回前台全量复检完成 翻转+%d 消失+%d 累计撤回=%lld",
          flipped, missing, totalRev);
}

static void HushAROnBecameActive(CFNotificationCenterRef center,
                                 void *observer,
                                 CFStringRef name,
                                 const void *object,
                                 CFDictionaryRef userInfo) {
    dispatch_async(gQueue, ^{
        HushARFullRescan();
    });
}

#pragma mark - public entry

void HushAntiRevokeStart(void) {
    if (gStarted) return;
    gStarted = YES;

    gQueue = dispatch_queue_create("hush.antirevoke", DISPATCH_QUEUE_SERIAL);

    dispatch_async(gQueue, ^{
        if (!HushAROpenMine()) {
            ARLog(@"[Hush][防撤回] 初始化失败（我方库不可用），模块不启用");
            return;
        }

        BOOL attached = HushARAttachHost();
        HushARLoadCursor();

        long long totalSnap = HushARQueryLL(gMineDB, "SELECT COUNT(*) FROM snapshot;");
        ARLog(@"[Hush][防撤回] 定时扫描已启动（每 %.0f 秒增量建快照，不依赖宿主 hook）"
              " 宿主库=%@ 已有快照=%lld cursor=%lld",
              HUSH_AR_TICK_SEC,
              gHostPath ? [gHostPath lastPathComponent] : @"(未发现)",
              totalSnap, gCursor);

        if (!attached) {
            ARLog(@"[Hush][防撤回] 宿主库暂不可达，将按 %d 秒周期重扫", (int)HUSH_AR_TICK_SEC);
        }

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
            HushARTick();
        });
        dispatch_resume(gTimer);
    });
}
