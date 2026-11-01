# gen_real_hooks.py — 用 557 个 MSHookMessageEx 调用点 + 宿主真实 type encoding
# 生成 Hooks/HushReal.xm：有类型 -> 真签名 + 业务逻辑；无类型 -> (id) 纯透传
# 用法: python gen_real_hooks.py
import json, os, re, sys
from collections import defaultdict

ROOT = r'D:\DeepSeek\hush\tweak-repro\original-re'
PAIRS = r'D:\DeepSeek\hush\_work\hooks557_full.json'
TYPES = r'D:\DeepSeek\hush\_work\hook_types.json'
OUT = os.path.join(ROOT, 'Hooks', 'HushReal.xm')

# ---------------- type encoding -> ObjC ----------------
def _parse_one(s, i):
    c = s[i]
    if c in '@#:':
        if c == '@' and i + 1 < len(s) and s[i+1] == '?':
            return 'id /*block*/', i + 2
        if c == '@' and i + 1 < len(s) and s[i+1] == '"':
            j = s.index('"', i + 2)
            return 'id /*%s*/' % s[i+2:j], j + 1
        return {'@': 'id', '#': 'Class', ':': 'SEL'}[c], i + 1
    if c in 'cislqCISLQB':
        return {'c':'char','i':'int','s':'short','l':'long','q':'long long',
                'C':'unsigned char','I':'unsigned int','S':'unsigned short',
                'L':'unsigned long','Q':'unsigned long long','B':'BOOL'}[c], i + 1
    if c in 'fd':
        return ('float' if c == 'f' else 'double'), i + 1
    if c == 'v':
        return 'void', i + 1
    if c == '*':
        return 'char *', i + 1
    if c == '^':
        t, j = _parse_one(s, i + 1)
        return t + ' *', j
    if c == 'b':
        return 'unsigned int', i + 2
    if c == '{':
        depth, j = 0, i
        while j < len(s):
            if s[j] == '{': depth += 1
            elif s[j] == '}':
                depth -= 1
                if depth == 0: break
            j += 1
        name = s[i+1:s.index('=', i) if '=' in s[i:j] else j]
        return {'CGRect':'CGRect','CGPoint':'CGPoint','CGSize':'CGSize',
                'UIEdgeInsets':'UIEdgeInsets','CGAffineTransform':'CGAffineTransform',
                'NSRange':'NSRange','CATransform3D':'CATransform3D'}.get(name, name), j + 1
    if c in '([':
        close = ')' if c == '(' else ']'
        depth, j = 0, i
        while j < len(s):
            if s[j] == c: depth += 1
            elif s[j] == close:
                depth -= 1
                if depth == 0: break
            j += 1
        inner = s[i+1:j]
        if c == '[':
            t, _ = _parse_one(inner, 0)
            return t + ' *', j + 1
        best = None
        k = 0
        while k < len(inner):
            try:
                t, k2 = _parse_one(inner, k)
                if t != 'void': best = t
                k = k2
            except Exception:
                k += 1
        return best or 'void', j + 1
    raise ValueError(c)

def decode_types(enc):
    """-> (ret, [argtypes]) ; self/_cmd 已剔除"""
    i = 0
    ret, i = _parse_one(enc, i)
    n = len(enc)
    while i < n and enc[i].isdigit(): i += 1
    args = []
    slot = 0
    while i < n:
        while i < n and enc[i].isdigit(): i += 1
        if i >= n: break
        t, i = _parse_one(enc, i)
        if slot >= 2: args.append(t)
        slot += 1
        while i < n and enc[i].isdigit(): i += 1
    return ret, args

def split_selector(sel):
    if not sel.endswith(':'):
        return []
    return [p for p in sel.split(':')[:-1]]

def build_signature(cls, sel, enc):
    ret, args = decode_types(enc)
    parts = split_selector(sel)
    if not parts:
        return ret, sel, []          # 无参：`- (ret)name`
    if len(args) < len(parts):
        args = args + ['id'] * (len(parts) - len(args))
    sig = []
    for k, p in enumerate(parts):
        sig.append('%s:(%s)a%d' % (p, args[k], k))
    return ret, ' '.join(sig), args

# ---------------- behaviour table ----------------
# ('noop',)            -> 什么都不做（void）
# ('ret', expr)        -> 直接返回表达式
# ('bool', key, val)   -> 开关开时返回 val，否则 %orig
# ('int',  key, val)   -> 同上（数值）
# ('double', key, expr)-> 同上
# ('pass',)            -> 纯透传 %orig
B = {
 # ===== 净化：入口/广告 =====
 'AppDelegateModel|showSplashAd:':                         ('noop',),
 'BDADX_Blued_Splash_Image_ViewController|presentBluedSplashImageViewController': ('noop',),
 'BDSplashImageAdViewController|presentInViewController:': ('noop',),
 'BDGDTSplashAdManager|showGDTSplash':                     ('noop',),
 'BDKSSplashAdManager|showKSSplash':                       ('noop',),
 'BDPangleSplashAdManager|showPangleSplash':               ('noop',),
 'BDIndexPageCoversManager|showSplashAd:currentWinAdModel:isColdLaunch:finished:': ('noop',),
 'BDIndexPageCoversManager|showCoverWithType:currentShowAdModel:currentWinAdModel:extroInfo:isColdLaunch:finished:': ('noop',),
 'BDIndexPageCoversManager|showFloatingLayerAfterNearbyPageShown': ('ret', 'NO'),
 'BDColdLaunchLoadingView|shouldShowColdLaunchLoadingForIdentifier:': ('ret', 'NO'),
 'BDGlobalBannerView|showNsnofyView':                      ('noop',),
 'BDMineBannerCell|configerBanner:':                       ('noop',),
 'BDNearbyDataAdapter|setAdmsArray:':                      ('noop',),
 'BDNearbyFloatingLayerModel|hasShown':                    ('ret', 'YES'),
 'BDNearbyFloatingLayerModel|setHasShown:':                ('noop',),
 'BDNearbyTopFixView|p_topHeight':                         ('ret', '0.0'),
 'BDNearbyListPopForH5View|showPopWithUrl:handler:':       ('noop',),
 'BDSessionViewController|p_insertRecommendUserModelsIfNeeded': ('noop',),
 'BDMapBlurBaseView|applyBlurRadius:':                     ('noop',),
 'BDBlurredLabel|setIsBlurringForName:':                   ('noop',),
 'BluedTabBar|p_showFindBubble':                           ('noop',),
 'BDMessageSafetyTipView|initWithFrame:info:':             ('ret', 'nil'),
 'BDChatBasicCell|tipsHeight':                             ('ret', '0.0'),
 'BDADXBaseSplashAdManager|assembleSplashContainerView:needRemoveHandler:': ('ret', 'nil'),
 # ===== 隐私相册 =====
 'BDHomeViewController|isUnlockPrivateAlbum':              ('ret', 'YES'),
 'BDHomePrivacyAlbumModel|status':                         ('ret', '1'),
 'BDHomePhotoModel|audit_status':                          ('ret', '0'),
 'BDPhotoBrowserBasicCell|album_ban_save':                 ('ret', '0'),
 'BDGlobalConfig|is_open_pic_ban_save':                    ('ret', '0'),
 'BDGlobalConfig|ban_applestore_review':                   ('ret', '0'),
 'BDPrivacyAlbumCell|showMaskViewOrNot:':                  ('noop',),
 'BDPhotoBrowserController|setWaterMarkText:':             ('noop',),
 'BDHomePageAlbumCell|blurImage:withRadius:':              ('ret', 'a0'),
 # ===== 会员 =====
 'BDProfile|vip_grade':                                    ('ret', '8'),
 'BDHomeDynamicAlbumModel|vip_grade':                      ('ret', '8'),
 'BDPhotoBrowserDynamic|vip_grade':                        ('ret', '8'),
 'LivingUserCardUser|vip_grade':                           ('ret', '8'),
 'GJIMChatSessionModel|vip_grade':                         ('ret', '8'),
 'LiveVideoAnchor|vip_grade':                              ('ret', '8'),
 'BDVIPPrivilegeConfigModel|is_view_secretly':             ('ret', '1'),
 'BDPrivilegeService|isHavingThePrivilege:':               ('ret', 'YES'),
 'BDPrivilegeService|canGotoSecondLevelViewWithPid:':      ('ret', 'YES'),
 'BDGlobalConfig|vip_exp_lvl':                             ('ret', '8'),
 'BDGlobalConfig|is_vip_annual':                           ('ret', '1'),
 'BDGlobalConfig|expire_type':                             ('ret', '0'),
 'BDProfile|is_eco_user':                                  ('ret', '0'),
 # ===== 风控 / 设备 =====
 'BDJailbreakChecker|amIJailBroken':                       ('ret', 'NO'),
 'DLJailbreakChecker|amIJailBroken':                       ('ret', 'NO'),
 'LoginData|device_safe':                                  ('ret', '1'),
 'BDFingerprintManager|fingerprint':                       ('ret', 'nil'),
 'BDFingerprintManager|uploadDeviceInfoByLogin':           ('noop',),
 'DLDeviceFingerprint|p_uploadRequest:completion:':        ('noop',),
 'DLRiskAppChecker|getRiskApps':                           ('ret', '@[]'),
 'DLRiskInfo|mapInfo':                                     ('ret', '@{}'),
 'SmAntiFraud|getDeviceId':                                ('ret', '@"00000000-0000-0000-0000-000000000000"'),
 # ===== 内容净化 =====
 'GJIMMessageModel|isIdentifyYellow':                      ('ret', '0'),
 'BDMessageRecentSendPhotoModel|isPorn':                   ('ret', 'NO'),
 'BDUserVisitorCell|showBlur':                             ('ret', 'NO'),
 # ===== 距离伪造 =====
 'UserInformation|distance':                               ('double', 'switch_real_location_mask', '0.0'),
 'SearchUsersData|distance':                               ('double', 'switch_real_location_mask', '0.0'),
}

def body_for(key, ret, sig, args, enc):
    act = B.get(key)
    if act is None:
        return '%orig;' if ret == 'void' else 'return %orig;'
    kind = act[0]
    if kind == 'noop':
        return '/* purified */' if ret == 'void' else 'return %orig;'
    if kind == 'ret':
        return 'return %s;' % act[1] if ret != 'void' else '%orig;'
    if kind == 'bool':
        return 'if ([[HushConfig shared] isEnabled:@"%s"]) return %s; return %%orig;' % (act[1], act[2]) \
               if ret != 'void' else '%orig;'
    if kind == 'int':
        return 'if ([[HushConfig shared] isEnabled:@"%s"]) return %s; return %%orig;' % (act[1], act[2]) \
               if ret != 'void' else '%orig;'
    if kind == 'double':
        return 'if ([[HushConfig shared] isEnabled:@"%s"]) return %s; return %%orig;' % (act[1], act[2])
    return 'return %orig;' if ret != 'void' else '%orig;'

def _fallback_sig(sel):
    parts = split_selector(sel)
    if not parts:
        return 'id', sel, []
    return 'id', ' '.join('%s:(id)a%d' % (p, k) for k, p in enumerate(parts)), ['id'] * len(parts)

def _valid_class(name):
    return bool(name) and all(32 <= ord(ch) < 127 for ch in name) and '$' not in name

def main():
    pairs = json.load(open(PAIRS, encoding='utf-8'))
    types = json.load(open(TYPES, encoding='utf-8'))
    want = defaultdict(set)
    for o in pairs:
        if o['cls'] and o['sel']:
            want[o['cls']].add(o['sel'])

    lines = []
    lines.append('// HushReal.xm — 自动生成，勿手改（tools/gen_real_hooks.py）')
    lines.append('// 来源：原版 BluedHush_5.19.dylib 的 557 个 MSHookMessageEx 调用点')
    lines.append('//       + 宿主 Blued 7.50.3 的真实 method type encoding')
    lines.append('// 有真实类型的用真签名并承载业务逻辑；缺类型的用 (id) 纯透传（零风险）')
    lines.append('// 本 translation unit 以 -fno-objc-arc 编译，参数不会被 objc_storeStrong')
    lines.append('')
    lines.append('#import <Foundation/Foundation.h>')
    lines.append('#import <UIKit/UIKit.h>')
    lines.append('#import <CoreLocation/CoreLocation.h>')
    lines.append('#import <MapKit/MapKit.h>')
    lines.append('#import "HushRuntime.h"')
    lines.append('#import "HushConfig.h"')
    lines.append('#import "HushLogger.h"')
    lines.append('')

    real = typed = 0
    for cls in sorted(want):
        if not _valid_class(cls):
            continue
        sels = sorted(want[cls])
        lines.append('%%hook %s' % cls)
        for sel in sels:
            key = '%s|%s' % (cls, sel)
            enc = types.get(key)
            if enc:
                try:
                    ret, sig, args = build_signature(cls, sel, enc)
                except Exception:
                    ret, sig, args = _fallback_sig(sel)
                typed += 1
            else:
                ret, sig, args = _fallback_sig(sel)
            body = body_for(key, ret, sig, args, enc)
            lines.append('- (%s)%s { %s }' % (ret, sig, body))
        lines.append('%end')
        lines.append('')
        real += 1

    src = '\n'.join(lines)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    open(OUT, 'w', encoding='utf-8', newline='\n').write(src)
    print('classes %d  methods %d  typed %d  untyped %d' % (
        real, sum(len(s) for s in want.values()), typed,
        sum(len(s) for s in want.values()) - typed))
    print('written:', OUT, os.path.getsize(OUT), 'bytes')
    print('behaviour entries:', len(B))
    # 覆盖率
    covered = set(B)
    have = {'%s|%s' % (c, s) for c in want for s in want[c]}
    print('behaviour hits: %d / %d' % (len(covered & have), len(covered)))
    miss = covered - have
    if miss: print('behaviour keys with no matching hook:', sorted(miss))

if __name__ == '__main__':
    main()
