#import <Foundation/Foundation.h>

// 防撤回的轮询路径（双保险里"事后补拉"那一半）。
//
// %ctor 里调一次即可。内部自带 3 秒 dispatch timer、回前台全量复检、
// 我方快照库（Documents/bluedbackups/hush_revoke.sqlite），
// 与 HushHooks.m 那张 hook 表完全独立 —— 那条表是实时拦截，这里是快照比对，
// 任一条失效另一条仍然兜得住。
//
// 受 switch_anti_recall 开关控制：关着时只保留 timer 心跳，不做任何 IO。
//
// FOUNDATION_EXPORT, not a bare `void f(void)`: HushEntry.xm goes through the
// C++ front end, so an unqualified declaration gets mangled to
// __Z18HushAntiRevokeStartv while the .m emits plain _HushAntiRevokeStart ->
//   Undefined symbols for architecture arm64: "HushAntiRevokeStart()"
// FOUNDATION_EXPORT expands to `extern "C" __attribute__((visibility("default")))`
// under __cplusplus, which is why HushInstallHooks(void) in HushRuntime.h never
// hit this. Keep the two consistent.
FOUNDATION_EXPORT void HushAntiRevokeStart(void);

/// Persist a packet that HushRecallGuard held back. Written to both `snapshot`
/// (so a restart does not lose the original text) and `revoked` with reason
/// `hook-blocked`. Safe to call before Start(): it no-ops when the DB is closed.
FOUNDATION_EXPORT void HushAntiRevokeRecordBlocked(long long sessionType,
                                                   long long sessionId,
                                                   long long messageId,
                                                   long long messageType,
                                                   NSString *content);
