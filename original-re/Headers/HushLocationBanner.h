//  HushLocationBanner.h
//  身边页顶部的虚拟定位信息条（运行时注入，tag 9877）
//  原版没有这个类：信息是动态 UILabel + HushLocGestureTarget 手势拼出来的。
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>

#ifndef BLUEDHUSH_ORIG_HUSHLOCATIONBANNER_H
#define BLUEDHUSH_ORIG_HUSHLOCATIONBANNER_H

@class HushConfig;

@interface HushLocationBanner : UIView

// 幂等：host 上已有就只刷新；开关全关则移除
+ (void)installInto:(UIView *)host;
+ (NSString *)displayTextForConfig:(HushConfig *)cfg;
+ (instancetype)bannerIn:(UIView *)host;

- (void)refresh;

@end

#endif
