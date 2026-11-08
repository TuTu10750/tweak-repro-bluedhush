#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "HushConfig.h"
#import "HushLogger.h"
#import "HushTrackMapCardVC.h"
#import "HushVirtualLocation.h"

static NSURLRequest *gHushTrackTemplate = nil;
static NSString *const kHushTrackButtonTitle = @"快速定位";
static const NSInteger kHushTrackButtonTag = 0x4854524B; // 'HTRK'

static double HushTrackNumber(id v, double fallback) {
    if ([v respondsToSelector:@selector(doubleValue)]) return [v doubleValue];
    return fallback;
}

static long long HushTrackLL(id obj, NSString *key) {
    @try {
        id v = [obj valueForKey:key];
        if ([v respondsToSelector:@selector(longLongValue)]) return [v longLongValue];
    } @catch (__unused NSException *e) {}
    return LLONG_MIN;
}

void HushTrackCaptureRequest(id request) {
    if (![request isKindOfClass:[NSURLRequest class]]) return;
    NSURLRequest *req = (NSURLRequest *)request;
    NSString *u = [[req URL] absoluteString];
    if (!u.length) return;
    if ([u rangeOfString:@"/users?"].location == NSNotFound) return;
    if ([u rangeOfString:@"req_id="].location == NSNotFound) return;
    static NSInteger notes = 0;
    gHushTrackTemplate = [req copy];
    notes++;
    if (notes <= 8 || notes % 20 == 0) {
        [HushLogger logLevel:2 format:[NSString stringWithFormat:
            @"[Hush][追踪] 已捕获宿主附近请求模板 headers=%lu",
            (unsigned long)req.allHTTPHeaderFields.count]];
    }
}

static UIButton *HushTrackFindFollowButton(UIView *root) {
    NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
    NSInteger guard = 0;
    while (stack.count && guard++ < 280) {
        UIView *v = [stack lastObject];
        [stack removeLastObject];
        if ([v isKindOfClass:[UIButton class]]) {
            NSString *t = [(UIButton *)v titleForState:UIControlStateNormal];
            if ([t rangeOfString:@"关注"].location != NSNotFound) return (UIButton *)v;
        }
        [stack addObjectsFromArray:v.subviews];
    }
    return nil;
}

static UIViewController *HushTrackTopPresenter(UIViewController *controller) {
    UIViewController *top = controller;
    while (top.presentedViewController) top = top.presentedViewController;
    if ([top isKindOfClass:[UINavigationController class]]) {
        top = [(UINavigationController *)top topViewController] ?: top;
    }
    if ([top isKindOfClass:[UITabBarController class]]) {
        top = [(UITabBarController *)top selectedViewController] ?: top;
    }
    return top;
}

static long long HushTrackProfileUid(UIViewController *vc) {
    NSArray *keys = @[@"userInfo", @"userModel", @"selectedUser", @"profile"];
    for (NSString *key in keys) {
        @try {
            id obj = [vc valueForKey:key];
            if (!obj) continue;
            for (NSString *uidKey in @[@"uid", @"target_uid", @"targetUid"]) {
                long long uid = HushTrackLL(obj, uidKey);
                if (uid > 0) return uid;
            }
        } @catch (__unused NSException *e) {}
    }
    return 0;
}

static BOOL HushTrackDistanceForUid(id obj, long long target, double *out) {
    if (!obj || target <= 0) return NO;
    if ([obj isKindOfClass:[NSArray class]]) {
        for (id v in (NSArray *)obj) {
            if (HushTrackDistanceForUid(v, target, out)) return YES;
        }
        return NO;
    }
    if (![obj isKindOfClass:[NSDictionary class]]) return NO;
    NSDictionary *d = (NSDictionary *)obj;
    long long uid = 0;
    for (NSString *k in @[@"uid", @"target_uid", @"userId", @"user_id"]) {
        id v = d[k];
        if ([v respondsToSelector:@selector(longLongValue)]) uid = [v longLongValue];
        if (uid > 0) break;
    }
    if (uid == target) {
        for (NSString *k in @[@"distance", @"dist", @"own_num", @"own-num", @"approx_r"]) {
            id v = d[k];
            if ([v respondsToSelector:@selector(doubleValue)]) {
                double km = [v doubleValue];
                if (km > 1000.0) km /= 1000.0;
                *out = km;
                return YES;
            }
        }
    }
    for (id v in d.allValues) {
        if (HushTrackDistanceForUid(v, target, out)) return YES;
    }
    return NO;
}

static void HushTrackQuery(NSURLRequest *template, double lat, double lng,
                           long long target, void (^done)(BOOL, double)) {
    NSURLComponents *c = [NSURLComponents componentsWithURL:template.URL resolvingAgainstBaseURL:NO];
    NSMutableArray *items = [NSMutableArray array];
    for (NSURLQueryItem *it in c.queryItems ?: @[]) {
        if ([it.name isEqualToString:@"latitude"]) {
            [items addObject:[NSURLQueryItem queryItemWithName:@"latitude"
                                                        value:[NSString stringWithFormat:@"%.8f", lat]]];
        } else if ([it.name isEqualToString:@"longitude"]) {
            [items addObject:[NSURLQueryItem queryItemWithName:@"longitude"
                                                        value:[NSString stringWithFormat:@"%.8f", lng]]];
        } else if ([it.name isEqualToString:@"start"]) {
            [items addObject:[NSURLQueryItem queryItemWithName:@"start" value:@"0"]];
        } else {
            [items addObject:it];
        }
    }
    c.queryItems = items;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:c.URL];
    req.timeoutInterval = 20.0;
    for (NSString *k in template.allHTTPHeaderFields) {
        [req setValue:template.allHTTPHeaderFields[k] forHTTPHeaderField:k];
    }
    NSURLSessionDataTask *task =
        [[NSURLSession sharedSession] dataTaskWithRequest:req
                                       completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (!data.length || err) { done(NO, NAN); return; }
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        double km = 0;
        done(HushTrackDistanceForUid(json, target, &km), km);
    }];
    [task resume];
}

static void HushTrackShowResult(long long uid, double lat, double lng,
                                double residual, UIViewController *from) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *presenter = HushTrackTopPresenter(from);
        if (!presenter || !presenter.viewLoaded || !presenter.view.window) {
            [HushLogger logLevel:1 format:[NSString stringWithFormat:
                @"[Hush][追踪] 无法打开位置卡片：presenter=%@ loaded=%d window=%d",
                NSStringFromClass([presenter class]),
                presenter.viewLoaded ? 1 : 0,
                presenter.view.window ? 1 : 0]];
            return;
        }
        HushTrackMapCardVC *card = [[HushTrackMapCardVC alloc] init];
        card.uid = [NSString stringWithFormat:@"%lld", uid];
        card.lat = lat;
        card.lng = lng;
        card.residual = residual;
        card.sourceViewController = from;
        card.modalPresentationStyle = UIModalPresentationPageSheet;
        id sheet = nil;
        @try { sheet = [card valueForKey:@"sheetPresentationController"]; }
        @catch (__unused NSException *e) { sheet = nil; }
        if (sheet && [sheet respondsToSelector:@selector(setPrefersGrabberVisible:)]) {
            [sheet setValue:@YES forKey:@"prefersGrabberVisible"];
        }
        @try {
            [presenter presentViewController:card animated:YES completion:^{
                [HushLogger logLevel:3 format:[NSString stringWithFormat:
                    @"[Hush][追踪] 位置卡片 present=%@", NSStringFromClass([card class])]];
            }];
        } @catch (NSException *exception) {
            [HushLogger logLevel:1 format:[NSString stringWithFormat:
                @"[Hush][追踪] present 异常 %@: %@",
                exception.name, exception.reason]];
        }
    });
}

static void HushTrackSolve(long long target, UIViewController *from, UIButton *button) {
    NSURLRequest *template = [gHushTrackTemplate copy];
    if (!template) {
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"快速定位"
                                                                    message:@"尚未捕获宿主附近请求模板，请先刷新身边页再试"
                                                             preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
        UIViewController *presenter = HushTrackTopPresenter(from);
        if (presenter.viewLoaded && presenter.view.window) {
            [presenter presentViewController:ac animated:YES completion:nil];
        }
        return;
    }
    NSURLComponents *c = [NSURLComponents componentsWithURL:template.URL
                                    resolvingAgainstBaseURL:NO];
    double lat0 = NAN, lng0 = NAN;
    for (NSURLQueryItem *it in c.queryItems) {
        if ([it.name isEqualToString:@"latitude"]) lat0 = it.value.doubleValue;
        if ([it.name isEqualToString:@"longitude"]) lng0 = it.value.doubleValue;
    }
    if (!c || !isfinite(lat0) || !isfinite(lng0)) {
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"快速定位"
                                                                    message:@"尚未捕获宿主附近请求模板，请先刷新身边页再试"
                                                             preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
        [from presentViewController:ac animated:YES completion:nil];
        return;
    }
    button.enabled = NO;
    if (button) [button setTitle:@"解算中…" forState:UIControlStateNormal];
    double eastKm = 10.0;
    double northKm = 10.0;
    double latE = lat0, lngE = lng0 + eastKm / (111.320 * cos(lat0 * M_PI / 180.0));
    double latN = lat0 + northKm / 111.320, lngN = lng0;
    [HushLogger logLevel:3 format:[NSString stringWithFormat:
        @"[Hush][追踪] 开始 uid=%lld 起点 %.6f,%.6f", target, lat0, lng0]];

    HushTrackQuery(template, lat0, lng0, target, ^(BOOL ok0, double d0) {
        if (!ok0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                button.enabled = YES;
                [button setTitle:kHushTrackButtonTitle forState:UIControlStateNormal];
            });
            return;
        }
        HushTrackQuery(template, latE, lngE, target, ^(BOOL okE, double dE) {
            if (!okE) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    button.enabled = YES;
                    [button setTitle:kHushTrackButtonTitle forState:UIControlStateNormal];
                });
                return;
            }
            HushTrackQuery(template, latN, lngN, target, ^(BOOL okN, double dN) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    button.enabled = YES;
                    [button setTitle:kHushTrackButtonTitle forState:UIControlStateNormal];
                });
                if (!okN) return;
                double xe = (d0*d0 - dE*dE + eastKm*eastKm) / (2.0*eastKm);
                double yn = (d0*d0 - dN*dN + northKm*northKm) / (2.0*northKm);
                double lat = lat0 + yn / 111.320;
                double lng = lng0 + xe / (111.320 * cos(lat0 * M_PI / 180.0));
                double predicted = sqrt(xe*xe + yn*yn);
                double residual = fabs(predicted - d0);
                [HushLogger logLevel:3 format:[NSString stringWithFormat:
                    @"[Hush][追踪] 完成 uid=%lld 目标 %.6f,%.6f d0=%.3f dE=%.3f dN=%.3f residual=%.3f",
                    target, lat, lng, d0, dE, dN, residual]];
                HushTrackShowResult(target, lat, lng, residual, from);
            });
        });
    });
}

void HushTrackRedoForUid(long long uid, UIViewController *from) {
    if (uid <= 0 || !from) return;
    HushTrackSolve(uid, from, nil);
}

static void HushTrackTapped(id sender, UIViewController *vc) {
    [HushLogger logLevel:3 format:[NSString stringWithFormat:
        @"[Hush][追踪] 按钮点击 sender=%@ controller=%@",
        NSStringFromClass([sender class]), NSStringFromClass([vc class])]];
    if (![sender isKindOfClass:[UIButton class]]) return;
    UIButton *button = (UIButton *)sender;
    long long uid = HushTrackProfileUid(vc);
    [HushLogger logLevel:3 format:[NSString stringWithFormat:
        @"[Hush][追踪] 按钮点击 uid=%lld", uid]];
    if (uid > 0) {
        @try {
            HushTrackSolve(uid, vc, button);
        } @catch (NSException *exception) {
            button.enabled = YES;
            [button setTitle:kHushTrackButtonTitle forState:UIControlStateNormal];
            [HushLogger logLevel:1 format:[NSString stringWithFormat:
                @"[Hush][追踪] 解算异常 %@: %@",
                exception.name, exception.reason]];
        }
    }
}

static void HushTrackRemoveButtonConstraints(UIButton *button) {
    UIView *container = button.superview;
    if (!container) return;
    NSMutableArray *doomed = [NSMutableArray array];
    for (NSLayoutConstraint *constraint in container.constraints) {
        if (constraint.firstItem == button || constraint.secondItem == button) {
            [doomed addObject:constraint];
        }
    }
    if (doomed.count) [container removeConstraints:doomed];
}

void HushTrackInstallOnProfile(UIViewController *vc) {
    if (!vc || ![vc isViewLoaded]) return;
    BOOL on = [[HushConfig shared] isEnabled:@"switch_track"]
          || [[HushConfig shared] isEnabled:@"switch_physical_track"];
    UIView *view = vc.view;
    UIButton *old = nil;
    for (UIView *v in view.subviews) {
        if (v.tag == kHushTrackButtonTag && [v isKindOfClass:[UIButton class]]) old = (UIButton *)v;
    }
    if (!on) {
        if (old) {
            [old removeFromSuperview];
        }
        return;
    }
    UIButton *follow = HushTrackFindFollowButton(view);
    if (!follow) return;
    long long uid = HushTrackProfileUid(vc);
    if (uid <= 0) return;
    UIButton *btn = old;
    if (!btn) {
        btn = [UIButton buttonWithType:UIButtonTypeSystem];
        btn.tag = kHushTrackButtonTag;
        [btn setTitle:kHushTrackButtonTitle forState:UIControlStateNormal];
        [btn setImage:[UIImage systemImageNamed:@"location.fill"] forState:UIControlStateNormal];
        btn.tintColor = [UIColor whiteColor];
        [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        btn.backgroundColor = [UIColor colorWithWhite:0.58 alpha:0.92];
        btn.layer.cornerRadius = 19.0;
        btn.contentEdgeInsets = UIEdgeInsetsMake(0, 12, 0, 12);
        btn.accessibilityIdentifier = @"hush_quick_track";
        __weak UIButton *weakButton = btn;
        __weak UIViewController *weakVC = vc;
        [btn addAction:[UIAction actionWithHandler:^(UIAction *action) {
            HushTrackTapped(weakButton, weakVC);
        }] forControlEvents:UIControlEventTouchUpInside];
    }
    UIView *container = follow.superview;
    if (!container) return;
    if (btn.superview != container) {
        [btn removeFromSuperview];
        [container addSubview:btn];
    }

    HushTrackRemoveButtonConstraints(btn);
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [btn.centerYAnchor constraintEqualToAnchor:follow.centerYAnchor],
        [btn.trailingAnchor constraintEqualToAnchor:follow.leadingAnchor constant:-8.0],
        [btn.heightAnchor constraintEqualToConstant:38.0],
        [btn.widthAnchor constraintEqualToConstant:96.0],
    ]];
    btn.hidden = NO;
}

