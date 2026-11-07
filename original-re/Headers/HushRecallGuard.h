//
//  HushRecallGuard.h
//  BluedHushRE
//
//  Recall interception at the two nodes the reference log names.
//
//  hooo1, the exact moment a second account recalled a message:
//
//      23:32:38.561 DBService.p_updateMessage GJIMMessageModel type=55 msgId=216 status=3
//      23:32:39.431 [Chat] 撤回通知到达 type=55（普通撤回）
//      23:32:39.432 SessionService.addMessages NSArray(1) [0]=… type=55 msgId=216 status=3
//      23:32:39.432 ChatVC.receiveNewMessage … type=55 msgId=216 status=3
//      23:32:39.432 ChatVC.updateMessages updateType=1 NSArray(4)
//
//  So a recall is a brand new message of type 55 with status 3.  It reaches the
//  host twice: once as a DB write (GJIMDBService -p_updateMessage:) and once as
//  an in-memory append (GJIMSessionService -addMessages:).
//
//  Both nodes are handled here, and neither one swallows the call:
//
//    * addMessages: takes an ARRAY.  Returning early would drop every other
//      message in the same batch (the host does batch-append on sync).  The
//      array is filtered and forwarded instead.
//
//    * p_updateMessage: takes ONE model.  Skipping it keeps the row we already
//      have instead of rewriting it as recalled.
//
//  A recall of *our own* message is let through — the reference log does the
//  same (`[Chat] 撤回包来自自己（from=100938367），放行`), and so does an unknown
//  login state (`按 fail-safe 放行不拦`).
//

#import <Foundation/Foundation.h>

/// uid of the signed-in account, taken from the host chat DB file name
/// (`Documents/<uid>DB.sqlite`). Returns 0 when it cannot be resolved — callers
/// must treat 0 as "unknown" and fail open.
FOUNDATION_EXPORT long long HushRecallCurrentUid(void);

/// v62: uid resolved per conversation. A machine can hold more than one
/// `Documents/<uid>DB.sqlite` (real log: 100938367 and 120159476), which makes
/// `HushRecallCurrentUid()` useless. In a 1:1 chat `sessionId` IS the peer's uid,
/// so excluding it from the candidates leaves our own uid. Returns 0 when that
/// still does not narrow down to exactly one candidate.
FOUNDATION_EXPORT long long HushRecallResolveUidForSession(long long sid);

/// v62: "did *I* send this recall?" — shared by the packet leg and the three
/// model-level legs so they can never disagree. Order: a resolved uid decides
/// (`from == me`); otherwise `from == sessionId` proves the peer did it; anything
/// else is treated as ours (fail open, same as the reference tweak).
/// `outMe` may be NULL and receives the uid that was used (0 when unknown).
FOUNDATION_EXPORT BOOL HushRecallIsSelfRecall(long long sid, long long from,
                                              long long *outMe);

/// YES when `model` is a recall packet that came from somebody else.
/// `outMsgId` may be NULL.
FOUNDATION_EXPORT BOOL HushRecallIsForeignRecall(id model, long long *outMsgId);

/// Filter a message array, drop foreign recall packets and forward the rest.
/// `orig` must be non-NULL. When nothing survives, `orig` is not called.
FOUNDATION_EXPORT void HushRecallFilterAndForward(id self, SEL _cmd, id msgs,
                                                  void (*orig)(id, SEL, id));

/// Forward a single-model DB write unless it is a foreign recall packet.
FOUNDATION_EXPORT void HushRecallGuardSingleWrite(id self, SEL _cmd, id model,
                                                  void (*orig)(id, SEL, id));

/// How many packets have been held back this session (for the hit report).
FOUNDATION_EXPORT long HushRecallBlockedCount(void);

/// UI leg: `PrivateChatViewController -updateMessages:updateType:` takes an array
/// plus a mode. Foreign recall packets are removed before the table reloads, so
/// the in-memory model never gets a chance to hide the row.
FOUNDATION_EXPORT void HushRecallFilterArrayForward(id self, SEL _cmd, id msgs,
                                                    unsigned long long updateType,
                                                    void (*orig)(id, SEL, id, unsigned long long));

/// UI leg, single-model form (`-receiveNewMessage:`). Dropped means orig is not
/// called at all: there is only one message in this call.
FOUNDATION_EXPORT void HushRecallDropSingleForward(id self, SEL _cmd, id model,
                                                   void (*orig)(id, SEL, id));

/// YES when this model was neutralised by us (type 55 -> 1). Used by the chat
/// cell hook to decide whether the「已拦截」badge belongs on screen.
FOUNDATION_EXPORT // v37 摸底：同步通道（GJIMMessageService -p_handleSyncRangeMessages:syncType:）
// 是推送之外的第二条投递路径。只统计、不改行为。
int HushRecallScanArrayForRecall(id arr);

BOOL HushRecallModelWasIntercepted(id model);

/// Attach / hide the「已拦截」badge on a chat cell for `model`. Safe to call for
/// every model: it hides the badge when the message was not intercepted.
FOUNDATION_EXPORT void HushRecallDecorateCell(id cell, id model);

/// v41: 闪照（type=282）解锁。摘遮罩/杀倒计时/亮图/挂「闪照」标。
/// 由 BDChatBasicCell -setMessage: 那条腿调用，模型不是 282 时直接返回。
FOUNDATION_EXPORT void HushAutoDestroyUnlock(id cell, id model);

/// v41: `BDDestoryChatCell -showAutoDestroyImage:` 放行之后的收尾。
/// 原版那次调用负责真正解密/铺图，但会顺手重挂遮罩、重开倒计时 —— 这里再拆一遍。
/// 不判模型类型：能进这条 hook 就说明是闪照 cell。
FOUNDATION_EXPORT void HushAutoDestroyKeepAlive(id cell);

/// Restore every neutralised model in `obj` (array or single model) to the
/// host's original type / status / content before it reaches a DB writer.
FOUNDATION_EXPORT void HushRecallRestoreDirtyArray(id obj);

#pragma mark - packet layer (v36)

/// Packet entry. Returns YES when the packet was swallowed and `orig` must NOT be
/// called. The reference log does exactly this — it never lets a `messageType=55`
/// packet reach the model layer, so the host keeps its in-memory list, its SQLite
/// row and its table diff untouched:
///
///     [Chat] 已拦截撤回（吞掉 type=55 推送包）msgId=75 sessionId=… from=…
///
/// A recall of our own message, an unknown login state and a packet without an id
/// are all forwarded (fail open), same as the reference.
FOUNDATION_EXPORT BOOL HushRecallHandlePrivatePackage(id self, SEL _cmd, id pkg,
                                                      void (*orig)(id, SEL, id));

/// Remember / query a msgId swallowed at the packet layer. The host never marks
/// those messages, so the chat cell hook uses this set to decide on the badge.
FOUNDATION_EXPORT void HushRecallMarkIntercepted(long long mid);
FOUNDATION_EXPORT BOOL HushRecallIsIntercepted(long long mid);

/// Observation only: log the host's own `-p_checkIfNeedBlockPackage:` verdict.
FOUNDATION_EXPORT void HushRecallProbeBlockDecision(id pkg, BOOL verdict);
