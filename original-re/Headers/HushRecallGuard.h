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
