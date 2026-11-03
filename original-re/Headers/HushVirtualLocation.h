//
//  HushVirtualLocation.h
//  BluedHushRE
//
//  Virtual location, reconstructed from the original reference log.
//
//  What the original actually does (hooo1, 23:29:xx):
//
//      [VLocCL] 已包装 delegate SmGpsDelegate                的 didUpdateLocations
//      [VLocCL] 已包装 delegate BMKLocationManager            的 didUpdateLocations
//      [VLocCL] 已包装 delegate BaiduMobAdLocationManager     的 didUpdateLocations
//      [VLocCL] 已包装 delegate BUSDKLocation                 的 didUpdateLocations
//      [VLocCL] 已包装 delegate KSAdLocationManager           的 didUpdateLocations
//      [VLocCL] 已包装 delegate GTCGbdLService                的 didUpdateLocations
//      [VLocCL] 主动投递假位置（startUpdatingLocation）
//      [VLoc]   启动：开关=关，宿主坐标=22.555796,114.129283
//      [LocStatus] 状态行 enabled=1 lat=39.904200 lng=116.407400
//
//  So it does not touch CLLocationManager globally.  It wraps the
//  -locationManager:didUpdateLocations: delegate on each location provider the
//  host installs, and pushes a fabricated fix through the same channel.  That
//  keeps every consumer (nearby list, map, request headers) consistent because
//  they all read the host's own location cache.
//
//  This file implements the same interception: the six delegate classes are
//  hooked on `didUpdateLocations:` (the array of CLLocation the host receives is
//  replaced with one built from runtime_custom_lat / runtime_custom_lng) when
//  switch_virtual_location is on.
//
//  Not yet implemented (listed as a gap in the report): the original's cache
//  teardown — `[VLoc] 观测到「虚拟定位 生效 → 失效」` clearing latitude,
//  longitude, cityInfo_keys, user_city, LastCityName and re-starting the real
//  GPS.  Without it, turning the switch off keeps the last fake fix until the
//  host refreshes on its own.
//

#import <Foundation/Foundation.h>

/// Wrap the six location delegates and start injecting. Idempotent.
FOUNDATION_EXPORT void HushVirtualLocationInstall(void);

/// YES when a usable fake point is configured (both lat and lng parse).
FOUNDATION_EXPORT BOOL HushVirtualLocationHasPoint(void);

/// Current configured point. Returns NO when unset.
FOUNDATION_EXPORT BOOL HushVirtualLocationPoint(double *lat, double *lng);
