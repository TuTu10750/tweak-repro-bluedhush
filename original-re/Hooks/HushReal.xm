// HushReal.xm — 自动生成，勿手改（tools/gen_real_hooks.py）
// 来源：原版 BluedHush_5.19.dylib 的 557 个 MSHookMessageEx 调用点
//       + 宿主 Blued 7.50.3 的真实 method type encoding
// 有真实类型的用真签名并承载业务逻辑；缺类型的用 (id) 纯透传（零风险）
// 本 translation unit 以 -fno-objc-arc 编译，参数不会被 objc_storeStrong

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>
#import <MapKit/MapKit.h>
#import "HushRuntime.h"
#import "HushLocationBanner.h"
#import "HushConfig.h"
#import "HushLogger.h"

%hook AppDelegateModel
- (void)getSplashAdForColdLaunch { HushHit("AppDelegateModel","getSplashAdForColdLaunch"); %orig; }
- (id)releaseAllAtItemIndex:(id)a0 { return %orig; }
- (id)releaseForKey:(id)a0 atItemIndex:(id)a1 { return %orig; }
- (id)retainForKey:(id)a0 atItemIndex:(id)a1 { return %orig; }
- (id)setBadgeValue:(id)a0 atItemIndex:(id)a1 { return %orig; }
- (id)setCustomImage:(id)a0 atItemIndex:(id)a1 { return %orig; }
- (id)setFocusBadgeValue:(id)a0 tItemIndex:(id)a1 { return %orig; }
- (id)setWaringHidden:(id)a0 atItemIndex:(id)a1 { return %orig; }
- (void)showSplashAd:(BOOL)a0 { HushHit("AppDelegateModel","showSplashAd:"); /* purified */ }
- (void)updateMessagesUnreadCount:(unsigned long long)a0 showWeakBadge:(BOOL)a1 roomType:(unsigned long long)a2 { %orig; }
%end

%hook BDADXBaseSplashAdManager
- (id)assembleSplashContainerView:(id)a0 needRemoveHandler:(id /*block*/)a1 { HushHit("BDADXBaseSplashAdManager","assembleSplashContainerView:needRemoveHandler:"); return nil; }
%end

%hook BDADX_Blued_Splash_Image_ViewController
- (id)p_getSplashAdvertisementForColdLaunch { HushHit("BDADX_Blued_Splash_Image_ViewController","p_getSplashAdvertisementForColdLaunch"); return nil; }
- (void)presentBluedSplashImageViewController { HushHit("BDADX_Blued_Splash_Image_ViewController","presentBluedSplashImageViewController"); /* purified */ }
- (void)removeAllSplashAdViews:(id)a0 { HushHit("BDADX_Blued_Splash_Image_ViewController","removeAllSplashAdViews:"); /* purified */ }
%end

%hook BDADX_Blued_Splash_Video_ViewController
- (void)presentInViewController:(id)a0 { HushHit("BDADX_Blued_Splash_Video_ViewController","presentInViewController:"); /* purified */ }
- (void)removeBluedSplashImageViewController { HushHit("BDADX_Blued_Splash_Video_ViewController","removeBluedSplashImageViewController"); /* purified */ }
%end

%hook BDAnimatedImageView
- (id)prepareForReuse { return %orig; }
- (void)setImage:(id)a0 { %orig; }
%end

%hook BDAudioServiceCollectionViewCell
- (id)setViewControllers:(id)a0 animated:(id)a1 { return %orig; }
%end

%hook BDAvatarAnnotationView
- (id)mapView:(id)a0 viewForAnnotation:(id)a1 { return %orig; }
- (id)viewDidAppear:(id)a0 { return %orig; }
%end

%hook BDAvatarLocationModel
- (id)vip_grade { return %orig; }
%end

%hook BDAvatarSurroundingModel
- (id)componentsJoinedByString:(id)a0 { return %orig; }
- (id)count { return %orig; }
- (void)setAvatar:(id)a0 { %orig; }
%end

%hook BDAvatarSurroundingRequest
- (id)avatar { return %orig; }
- (id)avatar_is_fuzzy { return %orig; }
- (id)is_hide_distance { return %orig; }
- (id)is_unlock { return %orig; }
- (BOOL)needBlur { HushHit("BDAvatarSurroundingRequest","needBlur"); return NO; }
- (id)requestArgument { return %orig; }
%end

%hook BDBluedSplashAdHotLimitView
- (id)shouldShowColdLaunchLoadingForIdentifier:(id)a0 { HushHit("BDBluedSplashAdHotLimitView","shouldShowColdLaunchLoadingForIdentifier:"); return %orig; }
%end

%hook BDBlurredLabel
- (void)setIsBlurringForName:(BOOL)a0 { HushHit("BDBlurredLabel","setIsBlurringForName:"); /* purified */ }
%end

%hook BDBottomTabLiveRequest
- (id)sharedInstance { return %orig; }
%end

%hook BDChatBasicCell
- (double)tipsHeight { HushHit("BDChatBasicCell","tipsHeight"); return 0.0; }
%end

%hook BDChatProtectionManager
- (id)secure_updateSecure:(id)a0 { return %orig; }
%end

%hook BDChatProtectionModel
- (id)canGotoSecondLevelViewWithPid:(id)a0 { return %orig; }
%end

%hook BDChatSafeTipCell
- (id)systemLayoutSizeFittingSize:(id)a0 { return %orig; }
%end

%hook BDColdLaunchLoadingView
- (BOOL)shouldShowColdLaunchLoadingForIdentifier:(id)a0 { HushHit("BDColdLaunchLoadingView","shouldShowColdLaunchLoadingForIdentifier:"); return NO; }
%end

%hook BDDirectCallingStateView
- (id)collectionView:(id)a0 numberOfItemsInSection:(id)a1 { return %orig; }
%end

%hook BDEmotionChatCell
- (id)p_scheduleFollowSomeoneSecretlyVC { return %orig; }
- (void)setupData { %orig; }
%end

%hook BDFingerprintManager
- (id)device_safe { return %orig; }
- (id)fingerprint { HushHit("BDFingerprintManager","fingerprint"); return nil; }
- (id)p_retryUploadDeviceInfoCompletion:(id)a0 { return %orig; }
- (id)p_uploadRequest:(id)a0 completion:(id)a1 { return %orig; }
- (void)uploadDeviceInfoByLogin { HushHit("BDFingerprintManager","uploadDeviceInfoByLogin"); /* purified */ }
%end

%hook BDGDTSplashAdManager
- (void)showGDTSplash { HushHit("BDGDTSplashAdManager","showGDTSplash"); /* purified */ }
%end

%hook BDGlobalBannerView
- (void)showNsnofyView { HushHit("BDGlobalBannerView","showNsnofyView"); /* purified */ }
%end

%hook BDGlobalConfig
- (id)addMethod:(id)a0 selector:(id)a1 replacement:(id)a2 original:(id)a3 { return %orig; }
- (long long)ban_applestore_review { HushHit("BDGlobalConfig","ban_applestore_review"); return 0; }
- (id)dictionary { return %orig; }
- (id)dismissSelf { return %orig; }
- (int)expire_type { HushHit("BDGlobalConfig","expire_type"); return 0; }
- (id)feed_pic_ban_save { return %orig; }
- (long long)is_open_pic_ban_save { HushHit("BDGlobalConfig","is_open_pic_ban_save"); return 0; }
- (int)is_vip_annual { HushHit("BDGlobalConfig","is_vip_annual"); return 1; }
- (int)vip_exp_lvl { HushHit("BDGlobalConfig","vip_exp_lvl"); return 8; }
%end

%hook BDHealthServiceCollectionCell
- (id)noteFiltered:(id)a0 { return %orig; }
- (id)setViewControllers:(id)a0 animated:(id)a1 { return %orig; }
%end

%hook BDHomeAlbumCell
- (void)configureAllAlbum:(id)a0 lockStatus:(int)a1 isMultiple:(BOOL)a2 indexPath:(id)a3 { HushHit("BDHomeAlbumCell","configureAllAlbum:lockStatus:isMultiple:indexPath:"); if ([[HushConfig shared] isEnabled:@"switch_private_photo"]) { a1 = 0; } %orig; }
- (id)setAudit_status:(id)a0 { return %orig; }
%end

%hook BDHomeDynamicAlbumModel
- (int)vip_grade { HushHit("BDHomeDynamicAlbumModel","vip_grade"); return 8; }
%end

%hook BDHomePageAlbumCell
- (id)access_private_photos { return %orig; }
- (id)blurImage:(id)a0 withRadius:(double)a1 { HushHit("BDHomePageAlbumCell","blurImage:withRadius:"); return a0; }
- (id)convertToSwiftStatus:(id)a0 obj:(id)a1 { return %orig; }
- (id)didMoveToSuperview { return %orig; }
- (id)privacy_photos_has_locked { return %orig; }
- (id)setAccess_private_photos:(id)a0 { return %orig; }
- (id)setAlpha:(id)a0 { return %orig; }
- (id)setFrame:(id)a0 { return %orig; }
- (id)setHidden:(id)a0 { return %orig; }
- (id)setPrivacy_photos_has_locked:(id)a0 { return %orig; }
%end

%hook BDHomePageBlockController
- (id)canGotoSecondLevelViewWithPid:(id)a0 { return %orig; }
- (void)p_changeBlockStatus:(BOOL)a0 { %orig; }
%end

%hook BDHomePageHeaderView
- (id)p_updatePrivatePhoto { return %orig; }
- (id)setIsUnlockPrivateAlbum:(id)a0 { return %orig; }
- (void)setProtectLockState:(id)a0 { %orig; }
%end

%hook BDHomePhotoModel
- (int)audit_status { HushHit("BDHomePhotoModel","audit_status"); return 0; }
- (id)setInfoTagView:(id)a0 { return %orig; }
- (id)setUserInfo:(id)a0 { return %orig; }
- (id)updatePrivateAlbum { return %orig; }
- (id)updateWithUserInfo:(id)a0 isCacheData:(id)a1 { return %orig; }
%end

%hook BDHomePrivacyAlbumModel
- (int)status { HushHit("BDHomePrivacyAlbumModel","status"); return 1; }
%end

%hook BDHomeViewController
- (id)access_private_photos { return %orig; }
- (BOOL)isUnlockPrivateAlbum { HushHit("BDHomeViewController","isUnlockPrivateAlbum"); return YES; }
- (id)layoutSubviews { return %orig; }
- (void)p_scheduleFollowSomeoneSecretlyVC { %orig; }
- (id)privacy_photos_has_locked { return %orig; }
- (id)setAccess_private_photos:(id)a0 { return %orig; }
- (id)setPrivacy_photos_has_locked:(id)a0 { return %orig; }
- (id)setStatus:(id)a0 { return %orig; }
- (id)showPopWithUrl:(id)a0 handler:(id)a1 { return %orig; }
%end

%hook BDIndexPageCoversManager
- (void)showCoverWithType:(unsigned long long)a0 currentShowAdModel:(id)a1 currentWinAdModel:(id)a2 extroInfo:(id)a3 isColdLaunch:(BOOL)a4 finished:(id /*block*/)a5 { HushHit("BDIndexPageCoversManager","showCoverWithType:currentShowAdModel:currentWinAdModel:extroInfo:isColdLaunch:finished:"); /* purified */ }
- (BOOL)showFloatingLayerAfterNearbyPageShown { HushHit("BDIndexPageCoversManager","showFloatingLayerAfterNearbyPageShown"); return NO; }
- (void)showSplashAd:(id)a0 currentWinAdModel:(id)a1 isColdLaunch:(BOOL)a2 finished:(id /*block*/)a3 { HushHit("BDIndexPageCoversManager","showSplashAd:currentWinAdModel:isColdLaunch:finished:"); /* purified */ }
%end

%hook BDJailbreakChecker
- (BOOL)amIJailBroken { HushHit("BDJailbreakChecker","amIJailBroken"); return NO; }
%end

%hook BDKSSplashAdManager
- (void)showKSSplash { HushHit("BDKSSplashAdManager","showKSSplash"); /* purified */ }
%end

%hook BDLivePullLiveRequest
- (id)sharedInstance { return %orig; }
%end

%hook BDMapBlurBaseView
- (void)applyBlurRadius:(double)a0 { HushHit("BDMapBlurBaseView","applyBlurRadius:"); /* purified */ }
- (BOOL)isHavingSomePrivilege { HushHit("BDMapBlurBaseView","isHavingSomePrivilege"); return YES; }
- (BOOL)needToBuyPrivilege:(id)a0 sender:(id)a1 { HushHit("BDMapBlurBaseView","needToBuyPrivilege:sender:"); return YES; }
%end

%hook BDMenHealthCareCenterCollectionViewCell
- (id)viewDidLoad { return %orig; }
%end

%hook BDMessageRecentSendPhotoModel
- (BOOL)isPorn { HushHit("BDMessageRecentSendPhotoModel","isPorn"); return NO; }
%end

%hook BDMessageSafetyTipView
- (id)initWithFrame:(CGRect)a0 info:(id)a1 { HushHit("BDMessageSafetyTipView","initWithFrame:info:"); return nil; }
%end

%hook BDMineBannerCell
- (void)configerBanner:(id)a0 { HushHit("BDMineBannerCell","configerBanner:"); /* purified */ }
- (BOOL)hasShown { HushHit("BDMineBannerCell","hasShown"); return YES; }
- (id)images { HushHit("BDMineBannerCell","images"); return @[]; }
- (id)videos { HushHit("BDMineBannerCell","videos"); return @[]; }
%end

%hook BDMineSVGAFloatView
- (id)setViewControllers:(id)a0 animated:(id)a1 { return %orig; }
%end

%hook BDMineVipOperateView
- (id)viewDidLoad { return %orig; }
%end

%hook BDMineWalletCollectionCell
- (id)viewDidLoad { return %orig; }
%end

%hook BDMsgSafetyTipView
- (id)setupData { return %orig; }
%end

%hook BDNearbyBannerCell
- (double)p_topHeight { HushHit("BDNearbyBannerCell","p_topHeight"); return 0.0; }
- (void)setHasShown:(BOOL)a0 { HushHit("BDNearbyBannerCell","setHasShown:"); /* purified */ }
%end

%hook BDNearbyDataAdapter
- (void)setAdmsArray:(id)a0 { HushHit("BDNearbyDataAdapter","setAdmsArray:"); /* purified */ }
- (void)synchronizeTopHeaderWithHeight:(double)a0 { HushHit("BDNearbyDataAdapter","synchronizeTopHeaderWithHeight:"); /* purified */ }
- (id)viewDidLayoutSubviews { return %orig; }
%end

%hook BDNearbyFloatingLayerModel
- (BOOL)hasShown { HushHit("BDNearbyFloatingLayerModel","hasShown"); return YES; }
- (void)setHasShown:(BOOL)a0 { HushHit("BDNearbyFloatingLayerModel","setHasShown:"); /* purified */ }
- (void)setLayerModel:(id)a0 { HushHit("BDNearbyFloatingLayerModel","setLayerModel:"); /* purified */ }
%end

%hook BDNearbyFloatingLayerView
- (id)didMoveToSuperview { HushHit("BDNearbyFloatingLayerView","didMoveToSuperview"); return %orig; }
- (id)p_showFloatingLayerAds:(id)a0 image:(id)a1 finished:(id)a2 { return %orig; }
%end

%hook BDNearbyListPopForH5View
- (void)showPopWithUrl:(id)a0 handler:(id /*block*/)a1 { HushHit("BDNearbyListPopForH5View","showPopWithUrl:handler:"); /* purified */ }
%end

%hook BDNearbyListPublicUserInfoView
- (double)calculatedAgeHeightWeightWidthWithBodyTypeName:(id)a0 { return %orig; }
%end

%hook BDNearbyListTableViewCell
- (id)noteFiltered:(id)a0 { return %orig; }
%end

%hook BDNearbyMakeFriendsSubPageController
- (long long)tableView:(id)a0 numberOfRowsInSection:(long long)a1 { return %orig; }
- (void)viewDidLayoutSubviews { HushHit("BDNearbyMakeFriendsSubPageController","viewDidLayoutSubviews"); %orig; dispatch_async(dispatch_get_main_queue(), ^{ [HushLocationBanner installInto:(UIView *)((UIViewController *)self).view]; }); }
%end

%hook BDNearbyMapSearchController
- (id)mapView:(id)a0 viewForAnnotation:(id)a1 { return %orig; }
%end

%hook BDNearbyMapSearchSignal
- (id)requestArgument { return %orig; }
%end

%hook BDNearbyMenu
- (double)p_topHeight { HushHit("BDNearbyMenu","p_topHeight"); return 0.0; }
%end

%hook BDNearbyRecommendCell
- (id)p_baseHeaderHeight { HushHit("BDNearbyRecommendCell","p_baseHeaderHeight"); return %orig; }
- (id)p_updateHeaderHeight { HushHit("BDNearbyRecommendCell","p_updateHeaderHeight"); return %orig; }
- (void)setHasShown:(BOOL)a0 { HushHit("BDNearbyRecommendCell","setHasShown:"); /* purified */ }
%end

%hook BDNearbyRecommendSquareItemCell
- (double)p_topHeight { HushHit("BDNearbyRecommendSquareItemCell","p_topHeight"); return 0.0; }
%end

%hook BDNearbySceneMatchingTableViewCell
- (double)p_topHeight { HushHit("BDNearbySceneMatchingTableViewCell","p_topHeight"); return 0.0; }
%end

%hook BDNearbyTopFixView
- (double)p_topHeight { HushHit("BDNearbyTopFixView","p_topHeight"); return 0.0; }
%end

%hook BDNewNavigationTitleViewTagView
- (id)addMethod:(id)a0 selector:(id)a1 replacement:(id)a2 original:(id)a3 { return %orig; }
- (id)setIsBlurringForName:(id)a0 { HushHit("BDNewNavigationTitleViewTagView","setIsBlurringForName:"); return %orig; }
%end

%hook BDNormalCallingStateView
- (id)collectionView:(id)a0 numberOfItemsInSection:(id)a1 { return %orig; }
%end

%hook BDOtherServiceCollectionCell
- (id)setViewControllers:(id)a0 animated:(id)a1 { return %orig; }
%end

%hook BDPangleSplashAdManager
- (void)showPangleSplash { HushHit("BDPangleSplashAdManager","showPangleSplash"); /* purified */ }
%end

%hook BDPersonPrivacyAlbumCollectView
- (id)is_filter_ads { return %orig; }
- (id)is_improve_backlist { return %orig; }
- (id)is_vip_annual_mark { return %orig; }
- (id)is_vip_mark { return %orig; }
- (void)updatePrivateAlbumWithUid:(id)a0 photos:(id)a1 hasMore:(BOOL)a2 islock:(int)a3 isAccessOpen:(int)a4 picNums:(int)a5 { HushHit("BDPersonPrivacyAlbumCollectView","updatePrivateAlbumWithUid:photos:hasMore:islock:isAccessOpen:picNums:"); if ([[HushConfig shared] isEnabled:@"switch_private_photo"]) { a3 = 0; a4 = 1; } %orig; }
%end

%hook BDPhotoBrowserBasicCell
- (int)album_ban_save { HushHit("BDPhotoBrowserBasicCell","album_ban_save"); return 0; }
%end

%hook BDPhotoBrowserController
- (id)configureAllAlbum:(id)a0 lockStatus:(id)a1 isMultiple:(id)a2 indexPath:(id)a3 { HushHit("BDPhotoBrowserController","configureAllAlbum:lockStatus:isMultiple:indexPath:"); return %orig; }
- (id)p_hideEffectView:(id)a0 { return %orig; }
- (void)setWaterMarkText:(id)a0 { HushHit("BDPhotoBrowserController","setWaterMarkText:"); /* purified */ }
%end

%hook BDPhotoBrowserDynamic
- (int)vip_grade { HushHit("BDPhotoBrowserDynamic","vip_grade"); return 8; }
%end

%hook BDPhotoBrowserPrivacyAlbumCell
- (id)privatePhoto { return %orig; }
- (id)privatePhotoOn { return %orig; }
- (id)setPrivatePhotoOn:(id)a0 { return %orig; }
- (id)setWaterMarkText:(id)a0 { HushHit("BDPhotoBrowserPrivacyAlbumCell","setWaterMarkText:"); return %orig; }
- (void)setupPhotoData:(id)a0 { %orig; }
%end

%hook BDPrivacyAlbumCell
- (void)showMaskViewOrNot:(BOOL)a0 { HushHit("BDPrivacyAlbumCell","showMaskViewOrNot:"); /* purified */ }
%end

%hook BDPrivilegeService
- (BOOL)canGotoSecondLevelViewWithPid:(long long)a0 { HushHit("BDPrivilegeService","canGotoSecondLevelViewWithPid:"); return YES; }
- (BOOL)isHavingThePrivilege:(long long)a0 { HushHit("BDPrivilegeService","isHavingThePrivilege:"); return YES; }
- (id)requestArgument { return %orig; }
%end

%hook BDProfile
- (id)canGotoSecondLevelViewWithPid:(id)a0 { return %orig; }
- (id)distance { return %orig; }
- (int)is_eco_user { HushHit("BDProfile","is_eco_user"); return 0; }
- (int)vip_grade { HushHit("BDProfile","vip_grade"); return 8; }
%end

%hook BDSecurityView
- (id)isIdentifyYellow { return %orig; }
%end

%hook BDSessionGuestCallView
- (id)p_insertRecommendUserModelIfNeeded { HushHit("BDSessionGuestCallView","p_insertRecommendUserModelIfNeeded"); return %orig; }
- (id)removeRecommendSessionWithUid:(id)a0 { HushHit("BDSessionGuestCallView","removeRecommendSessionWithUid:"); return %orig; }
- (id)saveRecommendSession:(id)a0 { HushHit("BDSessionGuestCallView","saveRecommendSession:"); return %orig; }
- (id)setAllSessions:(id)a0 { return %orig; }
- (id)setSessions:(id)a0 { return %orig; }
%end

%hook BDSessionListHeader1
- (void)layoutSubviews { %orig; }
- (id)p_ifShowMatchEmojiView { return %orig; }
- (id)tableView:(id)a0 cellForRowAtIndexPath:(id)a1 { return %orig; }
%end

%hook BDSessionPageController
- (void)updateMessagesUnreadCount:(unsigned long long)a0 unreadNotiCount:(long long)a1 showWeakBadge:(BOOL)a2 roomType:(unsigned long long)a3 { %orig; }
%end

%hook BDSessionViewController
- (void)p_insertRecommendUserModelsIfNeeded { HushHit("BDSessionViewController","p_insertRecommendUserModelsIfNeeded"); /* purified */ }
%end

%hook BDSplashImageAdViewController
- (id)p_showGDTSplash:(id)a0 isColdLaunch:(id)a1 finished:(id)a2 { HushHit("BDSplashImageAdViewController","p_showGDTSplash:isColdLaunch:finished:"); return %orig; }
- (id)p_showKSSplash:(id)a0 isColdLaunch:(id)a1 finished:(id)a2 { HushHit("BDSplashImageAdViewController","p_showKSSplash:isColdLaunch:finished:"); return %orig; }
- (id)p_showPangleSplash:(id)a0 isColdLaunch:(id)a1 finished:(id)a2 { HushHit("BDSplashImageAdViewController","p_showPangleSplash:isColdLaunch:finished:"); return %orig; }
- (void)presentInViewController:(id)a0 { HushHit("BDSplashImageAdViewController","presentInViewController:"); /* purified */ }
- (id)shouldShowColdLaunchLoadingForIdentifier:(id)a0 { HushHit("BDSplashImageAdViewController","shouldShowColdLaunchLoadingForIdentifier:"); return %orig; }
- (id)showSplashAd_Adx:(id)a0 currentWinAdModel:(id)a1 isColdLaunch:(id)a2 finished:(id)a3 { HushHit("BDSplashImageAdViewController","showSplashAd_Adx:currentWinAdModel:isColdLaunch:finished:"); return %orig; }
- (id)showSplashAd_Normal:(id)a0 isColdLaunch:(id)a1 finished:(id)a2 { HushHit("BDSplashImageAdViewController","showSplashAd_Normal:isColdLaunch:finished:"); return %orig; }
%end

%hook BDSplashVideoAdViewController
- (id)shouldShowColdLaunchLoadingForIdentifier:(id)a0 { HushHit("BDSplashVideoAdViewController","shouldShowColdLaunchLoadingForIdentifier:"); return %orig; }
%end

%hook BDSuperCallingCardConfigView
- (long long)collectionView:(id)a0 numberOfItemsInSection:(long long)a1 { return %orig; }
%end

%hook BDTabBarConfig
- (id)titles { return %orig; }
%end

%hook BDUserVisitorCell
- (id)p_needToBuyVip { return %orig; }
- (id)p_processWithNewVisitors:(id)a0 { return %orig; }
- (id)p_processWithNewVisits:(id)a0 { return %orig; }
- (id)refreshVisitor { return %orig; }
- (id)scrollViewDidScroll:(id)a0 { return %orig; }
- (BOOL)showBlur { HushHit("BDUserVisitorCell","showBlur"); return NO; }
%end

%hook BDVIPPrivilegeConfigModel
- (long long)is_view_secretly { HushHit("BDVIPPrivilegeConfigModel","is_view_secretly"); return 1; }
- (id)is_vip { return %orig; }
- (id)layoutSubviews { return %orig; }
- (id)vip_expire_days { return %orig; }
%end

%hook BDVisitBottomView
- (void)setShowBlur:(BOOL)a0 { HushHit("BDVisitBottomView","setShowBlur:"); /* purified */ }
- (id)setVisitor:(id)a0 { return %orig; }
- (void)showNsnofyView { HushHit("BDVisitBottomView","showNsnofyView"); /* purified */ }
%end

%hook BELicenseHelper
- (id)p_configBtnStatus:(id)a0 { return %orig; }
%end

%hook BaseModel
- (id)distance { return %orig; }
%end

%hook BlacklistViewController
- (void)getBlacklistByFistPage { %orig; }
- (id)reloadDataForChangeRelationship { return %orig; }
- (id)updateWithUserInfo:(id)a0 { return %orig; }
- (id)viewDidAppear:(id)a0 { return %orig; }
%end

%hook BluedTabBar
- (id)animationImages_dark { return %orig; }
- (id)animationImages_light { return %orig; }
- (id)normalImages { return %orig; }
- (void)p_showFindBubble { HushHit("BluedTabBar","p_showFindBubble"); /* purified */ }
- (id)titles { return %orig; }
%end

%hook DLDeviceFingerprint
- (void)p_uploadRequest:(id)a0 completion:(id /*block*/)a1 { HushHit("DLDeviceFingerprint","p_uploadRequest:completion:"); /* purified */ }
%end

%hook DLJailbreakChecker
- (BOOL)amIJailBroken { HushHit("DLJailbreakChecker","amIJailBroken"); return NO; }
%end

%hook DLRiskAppChecker
- (id)getRiskApps { HushHit("DLRiskAppChecker","getRiskApps"); return @[]; }
- (id)isFishhooked { return %orig; }
%end

%hook DLRiskInfo
- (id)canOpenURLFromList:(id)a0 { return %orig; }
- (id)checkExistenceOfSuspiciousFiles { return %orig; }
- (id)checkRestrictedDirectoriesWriteable { return %orig; }
- (id)checkSuspiciousFilesCanBeOpened { return %orig; }
- (id)checkURLSchemes { return %orig; }
- (id)mapInfo { HushHit("DLRiskInfo","mapInfo"); return @{}; }
%end

%hook GJIMChatSessionModel
- (id)applyBlurAlpha:(id)a0 { HushHit("GJIMChatSessionModel","applyBlurAlpha:"); return %orig; }
- (id)mapView:(id)a0 viewForAnnotation:(id)a1 { return %orig; }
- (unsigned int)vip_grade { HushHit("GJIMChatSessionModel","vip_grade"); return 8; }
%end

%hook GJIMMessageModel
- (int)isIdentifyYellow { HushHit("GJIMMessageModel","isIdentifyYellow"); return 0; }
%end

%hook LiveVideoAnchor
- (long long)vip_grade { HushHit("LiveVideoAnchor","vip_grade"); return 8; }
%end

%hook LivingUserCardUser
- (int)vip_grade { HushHit("LivingUserCardUser","vip_grade"); return 8; }
%end

%hook LoginData
- (id)checkExistenceOfSuspiciousFiles { return %orig; }
- (id)checkForkWithCompletion:(id)a0 { return %orig; }
- (id)checkRestrictedDirectoriesWriteable { return %orig; }
- (id)checkURLSchemes { return %orig; }
- (int)device_safe { HushHit("LoginData","device_safe"); return 1; }
- (id)emulatorCheckCompile { return %orig; }
- (id)performChecks { return %orig; }
%end

%hook NSMutableURLRequest
- (id)setURL:(id)a0 { return %orig; }
%end

%hook NSURLSession
- (id)dataTaskWithRequest:(id)a0 completionHandler:(id)a1 { return %orig; }
- (id)setURL:(id)a0 { return %orig; }
%end

%hook NewKeyBoard
- (id)beginInlineEdit:(id)a0 { return %orig; }
- (id)count { return %orig; }
- (void)p_configBtnStatus:(BOOL)a0 { %orig; }
- (id)setUnion_uid:(id)a0 { return %orig; }
- (id)tag { return %orig; }
%end

%hook PrivateChatViewController
- (id)systemLayoutSizeFittingSize:(id)a0 { return %orig; }
- (id)tableView:(id)a0 cellForRowAtIndexPath:(id)a1 { return %orig; }
%end

%hook RecentlyVisitorViewController
- (void)p_processWithNewVisitors:(id)a0 { %orig; }
- (id)setAdmsArray:(id)a0 { HushHit("RecentlyVisitorViewController","setAdmsArray:"); return %orig; }
- (id)setOriginUserAdsArray:(id)a0 { HushHit("RecentlyVisitorViewController","setOriginUserAdsArray:"); return %orig; }
%end

%hook SearchUsersData
- (double)distance { HushHit("SearchUsersData","distance"); if ([[HushConfig shared] isEnabled:@"switch_real_location_mask"]) return 0.0; return %orig; }
%end

%hook SmAntiFraud
- (id)getDeviceId { HushHit("SmAntiFraud","getDeviceId"); return @"00000000-0000-0000-0000-000000000000"; }
%end

%hook UITabBarController
- (id)setViewControllers:(id)a0 animated:(id)a1 { return %orig; }
%end

%hook UITableView
- (id)layoutSubviews { return %orig; }
%end

%hook UserAlbum
- (id)applyPrivacyAlbumStatus:(id)a0 { return %orig; }
%end

%hook UserAvatar
- (id)isBlank { return %orig; }
- (id)showMaskViewOrNot:(id)a0 { return %orig; }
%end

%hook UserBasic
- (long long)last_operate { return %orig; }
%end

%hook UserInformation
- (int)access_private_photos { HushHit("UserInformation","access_private_photos"); if ([[HushConfig shared] isEnabled:@"switch_private_photo"]) return 1; return %orig; }
- (int)album_ban_save { HushHit("UserInformation","album_ban_save"); if ([[HushConfig shared] isEnabled:@"switch_private_photo"]) return 0; return %orig; }
- (double)distance { HushHit("UserInformation","distance"); if ([[HushConfig shared] isEnabled:@"switch_real_location_mask"]) return 0.0; return %orig; }
- (int)is_locked { HushHit("UserInformation","is_locked"); if ([[HushConfig shared] isEnabled:@"switch_private_photo"]) return 0; return %orig; }
- (id)layoutSubviews { return %orig; }
- (id)mapView:(id)a0 viewForAnnotation:(id)a1 { return %orig; }
- (int)privacy_photos_has_locked { HushHit("UserInformation","privacy_photos_has_locked"); if ([[HushConfig shared] isEnabled:@"switch_private_photo"]) return 0; return %orig; }
- (void)setIs_locked:(int)a0 { HushHit("UserInformation","setIs_locked:"); if ([[HushConfig shared] isEnabled:@"switch_private_photo"]) { a0 = 0; } %orig; }
- (void)setPrivacy_photos_has_locked:(int)a0 { HushHit("UserInformation","setPrivacy_photos_has_locked:"); if ([[HushConfig shared] isEnabled:@"switch_private_photo"]) { a0 = 0; } %orig; }
- (void)setUnion_uid:(id)a0 { %orig; }
- (id)viewDidAppear:(id)a0 { return %orig; }
%end

%hook UserSetting
- (id)canGotoSecondLevelViewWithPid:(id)a0 { return %orig; }
%end

%hook UserSettingModel
- (id)layoutSubviews { return %orig; }
%end

%hook var
- (id)noteFiltered:(id)a0 { return %orig; }
%end
