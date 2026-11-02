#import <Foundation/Foundation.h>

// 防撤回的轮询路径（双保险里"事后补拉"那一半）。
//
// %ctor 里调一次即可。内部自带 3 秒 dispatch timer、回前台全量复检、
// 我方快照库（Documents/bluedbackups/hush_revoke.sqlite），
// 与 HushHooks.m 那张 hook 表完全独立 —— 那条表是实时拦截，这里是快照比对，
// 任一条失效另一条仍然兜得住。
//
// 受 switch_anti_recall 开关控制：关着时只保留 timer 心跳，不做任何 IO。
void HushAntiRevokeStart(void);
