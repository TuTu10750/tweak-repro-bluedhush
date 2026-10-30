# 原版 dylib 逆向报告（1:1 复刻的权威依据）

> 本文所有结论都来自二进制本身与真机日志；推断项一律标注「推断」。

## 1. 样本身份

| 项 | 值 |
|---|---|
| 文件 | `Payload/Blued.app/Frameworks/BluedHush_5.19.dylib` |
| 大小 | 2,719,216 B |
| sha256 前缀 | `67ca70c5c274c2c0` |
| 依赖 | `libsubstrate.dylib` 297,968 B（随包） |
| 宿主 | Blued 7.50.3（`com.danlan.xiaolan`） |
| 日志文件 | `Documents/hooo`（**不是** `BluedHushREA.log`） |
| ObjC 规模 | **76 个类 / 1015 个方法 / 398 条中文字符串** |

## 2. 类清单（76 个，全部来自 __objc_classlist）

| 类 | 实例方法 | 类方法 |
|---|---|---|
| `HushAUTCapsule` | 8 | 0 |
| `HushActionItem` | 11 | 2 |
| `HushAuthorFooterView` | 4 | 0 |
| `HushConfig` | 29 | 1 |
| `HushEntryButtonTarget` | 6 | 1 |
| `HushFloatBall` | 8 | 0 |
| `HushGalBackupCell` | 7 | 0 |
| `HushGalBackupVC` | 17 | 0 |
| `HushGalCell` | 8 | 0 |
| `HushGalController` | 57 | 0 |
| `HushGalHeaderView` | 8 | 0 |
| `HushGalPreviewPageVC` | 6 | 0 |
| `HushGalPreviewSource` | 5 | 0 |
| `HushGalPreviewVC` | 15 | 0 |
| `HushGalSection` | 7 | 0 |
| `HushGalTap` | 0 | 3 |
| `HushGalZipPickBridge` | 2 | 0 |
| `HushHostStyle` | 38 | 4 |
| `HushIconChoice` | 2 | 1 |
| `HushIconPicker` | 0 | 4 |
| `HushLicense` | 0 | 13 |
| `HushLicenseSessionDelegate` | 1 | 0 |
| `HushLocGestureTarget` | 0 | 3 |
| `HushLocationHistoryController` | 14 | 0 |
| `HushLocationPickerController` | 48 | 0 |
| `HushLogger` | 0 | 21 |
| `HushModuleDetailController` | 17 | 0 |
| `HushModuleEntry` | 13 | 0 |
| `HushModuleSection` | 9 | 1 |
| `HushNAStripView` | 8 | 0 |
| `HushNAViewer` | 32 | 0 |
| `HushNMCardView` | 18 | 0 |
| `HushNMDeckController` | 19 | 0 |
| `HushNMDeckPage` | 26 | 0 |
| `HushNMPhotoViewer` | 15 | 0 |
| `HushNMWeakTableBox` | 3 | 0 |
| `HushNTCheckTap` | 0 | 2 |
| `HushNTEntryTap` | 0 | 5 |
| `HushNTFanPaiController` | 72 | 0 |
| `HushNTFindTargetController` | 27 | 0 |
| `HushNTFormController` | 20 | 0 |
| `HushNTSkipListController` | 13 | 0 |
| `HushPatch` | 0 | 11 |
| `HushPrivacyAlbumGrantTap` | 1 | 1 |
| `HushPrivacyNavController` | 1 | 0 |
| `HushQPBarView` | 6 | 0 |
| `HushQuickPhraseUI` | 26 | 1 |
| `HushRecallTapDelegate` | 1 | 0 |
| `HushRecallTapTarget` | 1 | 1 |
| `HushRiskCell` | 9 | 0 |
| `HushRiskListController` | 15 | 0 |
| `HushRiskReportController` | 10 | 0 |
| `HushRiskTap` | 0 | 1 |
| `HushSettingsPanel` | 51 | 3 |
| `HushSpyCell` | 13 | 0 |
| `HushSpyListController` | 19 | 0 |
| `HushStalkAvatarView` | 3 | 0 |
| `HushStalkDetailController` | 25 | 1 |
| `HushStalkListController` | 20 | 5 |
| `HushStalkMaintCell` | 1 | 0 |
| `HushStalkTapProxy` | 1 | 1 |
| `HushStalkTargetCell` | 15 | 0 |
| `HushSwitchCell` | 8 | 0 |
| `HushSwitchItem` | 11 | 4 |
| `HushTabLPTap` | 4 | 1 |
| `HushTabLongPressSettings` | 0 | 1 |
| `HushTrackMapCardVC` | 17 | 0 |
| `HushTrackMarkerView` | 4 | 0 |
| `HushVLocPlainLocation` | 3 | 0 |
| `HushVanCell` | 11 | 0 |
| `HushVanTap` | 0 | 2 |
| `HushVanishedController` | 28 | 0 |
| `HushVisitClearLP` | 1 | 1 |
| `HushWindowHelper` | 0 | 3 |
| `HushaPhotoViewer` | 9 | 0 |
| `HushaState` | 10 | 0 |

## 3. Hook 面（273 组 / 114 个宿主类）

提取方法：把 `__cstring`（ASCII）与 `__ustring`（UTF-16 中文）按地址排序，找「宿主类名字符串」后 8 个字符串内出现的、该宿主类自己声明过的方法名。
依据：原版是手写 `HushPatch hookClass:@"X" selector:@"y" …`，两个字面量在产物里相邻。结果与真机日志一致。

| 宿主类 | 选择子 | 类型编码 | 邻近度 |
|---|---|---|---|
| `AppDelegate` | `application:didFinishLaunchingWithOptions:` | `B32@0:8@16@24` | 1 |
| `AppDelegateModel` | `getSplashAdForColdLaunch` | `v16@0:8` | 1 |
| `AppDelegateModel` | `isNeedShowSplashAd` | `B16@0:8` | 2 |
| `AppDelegateModel` | `p_getSplashAdvertisementForColdLaunch` | `v16@0:8` | 3 |
| `AppDelegateModel` | `removeAllSplashAdViews:` | `v24@0:8q16` | 4 |
| `AppDelegateModel` | `showSplashAd:` | `v20@0:8B16` | 5 |
| `AppDelegateModel` | `updateMessagesUnreadCount:showWeakBadge:roomType:` | `v36@0:8Q16B24Q28` | 6 |
| `AppGlobalVariable` | `legal_comply_album` | `q16@0:8` | 1 |
| `BDADXBaseSplashAdManager` | `assembleSplashContainerView:needRemoveHandler:` | `@32@0:8@16@?24` | 1 |
| `BDADX_Blued_Splash_Image_ViewController` | `presentBluedSplashImageViewController` | `v16@0:8` | 1 |
| `BDADX_Blued_Splash_Image_ViewController` | `removeBluedSplashImageViewController` | `v16@0:8` | 2 |
| `BDADX_Blued_Splash_Image_ViewController` | `viewDidLoad` | `v16@0:8` | 4 |
| `BDADX_Blued_Splash_Video_ViewController` | `viewDidLoad` | `v16@0:8` | 1 |
| `BDAdvertisementLoadingServer` | `dealSplashAdsFinish` | `v16@0:8` | 5 |
| `BDAdvertisementLoadingServer` | `releaseTimerForSplashAdForbidden` | `v16@0:8` | 4 |
| `BDAnimatedImageView` | `setImage:` | `v24@0:8@16` | 1 |
| `BDAutoDestoryImageViewController` | `destoryChatAddTimeAction` | `v16@0:8` | 1 |
| `BDAvatarAnnotationView` | `setMapFriendUid:` | `v24@0:8@16` | 1 |
| `BDAvatarLocationModel` | `is_hide_distance` | `q16@0:8` | 1 |
| `BDAvatarSurroundingModel` | `avatar_is_fuzzy` | `B16@0:8` | 3 |
| `BDAvatarSurroundingModel` | `distance` | `d16@0:8` | 5 |
| `BDAvatarSurroundingModel` | `is_unlock` | `B16@0:8` | 1 |
| `BDBlurredLabel` | `blurRadius` | `d16@0:8` | 1 |
| `BDBlurredLabel` | `isBlurringForDesc` | `B16@0:8` | 2 |
| `BDBlurredLabel` | `isBlurringForName` | `B16@0:8` | 3 |
| `BDBlurredLabel` | `setBlurRadius:` | `v24@0:8d16` | 4 |
| `BDBlurredLabel` | `setIsBlurringForDesc:` | `v20@0:8B16` | 5 |
| `BDBlurredLabel` | `setIsBlurringForName:` | `v20@0:8B16` | 6 |
| `BDBottomTabLiveRequest` | `requestUrl` | `@16@0:8` | 1 |
| `BDBurnAfterReadManager` | `exchangeCount` | `Q16@0:8` | 1 |
| `BDChatBasicCell` | `setLimitMessageState` | `v16@0:8` | 1 |
| `BDChatBasicCell` | `setupData` | `v16@0:8` | 2 |
| `BDChatBasicCell` | `tipsHeight` | `d16@0:8` | 3 |
| `BDChatChinaManager` | `p_msgRecallRequestType:groupChat:sessionType:from:to:seqnum:isSuperRecall:isMatchMsg:callback:` | `v64@0:8Q16B24I28I32I36q40B48B52@?56` | 1 |
| `BDChatProtectionManager` | `is_prohibit_chat_screenshot` | `q16@0:8` | 1 |
| `BDChatVideoCell` | `prepareForReuse` | `v16@0:8` | 6 |
| `BDDestoryChatCell` | `prepareForReuse` | `v16@0:8` | 1 |
| `BDDestoryChatCell` | `setImageURL:` | `v24@0:8@16` | 2 |
| `BDDestoryChatCell` | `setVideoURL:` | `v24@0:8@16` | 3 |
| `BDFingerprintManager` | `fingerprint` | `@16@0:8` | 1 |
| `BDFingerprintManager` | `getDuDeviceId` | `@16@0:8` | 2 |
| `BDFingerprintManager` | `getShumeiDeviceId` | `@16@0:8` | 3 |
| `BDFingerprintManager` | `lastOutSideExtra` | `@16@0:8` | 4 |
| `BDFingerprintManager` | `uploadDeviceInfoByLogin` | `v16@0:8` | 5 |
| `BDFingerprintManager` | `uploadDeviceInfoByRegister` | `v16@0:8` | 6 |
| `BDGDTSplashAdManager` | `showGDTSplash` | `v16@0:8` | 1 |
| `BDGlobalBannerManager` | `allowShowGlobalBanner` | `B16@0:8` | 1 |
| `BDGlobalBannerManager` | `prohibitGlobalBanner` | `B16@0:8` | 2 |
| `BDGlobalBannerView` | `showNsnofyView` | `v16@0:8` | 1 |
| `BDGlobalConfig` | `legal_comply` | `q16@0:8` | 1 |
| `BDGlobalConfig` | `vip_status` | `q16@0:8` | 3 |
| `BDHealthServiceCollectionCell` | `awakeFromNib` | `v16@0:8` | 8 |
| `BDHomeAlbumCell` | `awakeFromNib` | `v16@0:8` | 7 |
| `BDHomeAlbumCell` | `configureAllAlbum:lockStatus:isMultiple:indexPath:` | `v40@0:8@16i24B28@32` | 1 |
| `BDHomeAlbumCell` | `p_configureTempAlbum:lockStatus:` | `v28@0:8@16i24` | 2 |
| `BDHomeAlbumCell` | `p_hideEffectView:` | `v20@0:8B16` | 3 |
| `BDHomePageAlbumCell` | `applyPrivacyAlbumStatus:` | `v24@0:8q16` | 1 |
| `BDHomePageAlbumCell` | `awakeFromNib` | `v16@0:8` | 2 |
| `BDHomePageAlbumCell` | `blurImage:withRadius:` | `@32@0:8@16d24` | 3 |
| `BDHomePageAlbumCell` | `configurePrivacyAlbumStatus:isSelf:` | `v24@0:8i16B20` | 4 |
| `BDHomePageAlbumCell` | `setUserAlbum:isSelf:` | `v28@0:8@16B24` | 5 |
| `BDHomePageBlockController` | `p_changeBlockStatus:` | `v20@0:8B16` | 1 |
| `BDHomePageBlockController` | `reloadDataForChangeRelationship` | `v16@0:8` | 2 |
| `BDHomePageBlockController` | `setBlockTip:` | `v24@0:8@16` | 3 |
| `BDHomePageBlockController` | `updateWithUserInfo:` | `v24@0:8@16` | 4 |
| `BDHomePageHeaderView` | `setInfoTagView:` | `v24@0:8@16` | 1 |
| `BDHomePageHeaderView` | `setProtectLockState:` | `v24@0:8@16` | 2 |
| `BDHomePageHeaderView` | `setUserInfo:` | `v24@0:8@16` | 3 |
| `BDHomePageHeaderView` | `updatePrivateAlbum` | `v16@0:8` | 4 |
| `BDHomePageHeaderView` | `updateWithUserInfo:isCacheData:` | `v28@0:8@16B24` | 5 |
| `BDHomePhotoModel` | `audit_status` | `i16@0:8` | 1 |
| `BDHomePhotoModel` | `setAudit_status:` | `v20@0:8i16` | 2 |
| `BDHomePrivacyAlbumModel` | `access_private_photos` | `i16@0:8` | 1 |
| `BDHomePrivacyAlbumModel` | `setAccess_private_photos:` | `v20@0:8i16` | 2 |
| `BDHomePrivacyAlbumModel` | `setPrivacy_photos_has_locked:` | `v20@0:8i16` | 3 |
| `BDHomePrivacyAlbumModel` | `setStatus:` | `v20@0:8i16` | 4 |
| `BDHomePrivacyAlbumModel` | `status` | `i16@0:8` | 5 |
| `BDHomeViewController` | `p_presentFollowSomeoneSecretlyVCWithType:` | `v20@0:8i16` | 2 |
| `BDHomeViewController` | `p_scheduleFollowSomeoneSecretlyVC` | `v16@0:8` | 1 |
| `BDIndexPageCoversManager` | `p_showBluedImageSplash:currentWinAdModel:isColdLaunch:finished:` | `v44@0:8@16@24B32@?36` | 1 |
| `BDIndexPageCoversManager` | `p_showBluedVideoSplash:currentWinAdModel:isColdLaunch:finished:` | `v44@0:8@16@24B32@?36` | 2 |
| `BDIndexPageCoversManager` | `p_showFloatingLayerAds:image:finished:` | `v40@0:8@16@24@?32` | 3 |
| `BDIndexPageCoversManager` | `p_showGDTSplash:isColdLaunch:finished:` | `v36@0:8@16B24@?28` | 4 |
| `BDIndexPageCoversManager` | `p_showKSSplash:isColdLaunch:finished:` | `v36@0:8@16B24@?28` | 5 |
| `BDIndexPageCoversManager` | `p_showPangleSplash:isColdLaunch:finished:` | `v36@0:8@16B24@?28` | 6 |
| `BDIndexPageCoversManager` | `showCoverWithType:currentShowAdModel:currentWinAdModel:extroInfo:isColdLaunch:finished:` | `v60@0:8Q16@24@32@40B48@?52` | 7 |
| `BDIndexPageCoversManager` | `showFloatingLayerAfterNearbyPageShown` | `B16@0:8` | 8 |
| `BDKSSplashAdManager` | `showKSSplash` | `v16@0:8` | 1 |
| `BDLocationService` | `latitude` | `@16@0:8` | 1 |
| `BDLocationService` | `locationManager:didUpdateLocations:` | `v32@0:8@16@24` | 2 |
| `BDLocationService` | `longitude` | `@16@0:8` | 3 |
| `BDLocationService` | `p_reverseGeocodeLocation:` | `v24@0:8@16` | 4 |
| `BDLocationService` | `p_saveLocationWithLot:lat:` | `v32@0:8@16@24` | 5 |
| `BDLocationService` | `p_startLocation` | `v16@0:8` | 6 |
| `BDMediator` | `BDMediator_vipGrade` | `I16@0:8` | 1 |
| `BDMessageRecentSendPhotoModel` | `isPorn` | `B16@0:8` | 1 |
| `BDMessageRecentSendPhotoModel` | `vertifyStatus` | `c16@0:8` | 2 |
| `BDMessageSafetyTipView` | `getSafetyTipViewHeight` | `d16@0:8` | 1 |
| `BDMessageSafetyTipView` | `initWithFrame:info:` | `@56@0:8{CGRect={CGPoint=dd}{CGSize=dd}}16@48` | 2 |
| `BDMessageViewController` | `chatKeyBoardWillChangeFrameWithNewFrame:animationTime:keyBoardState:` | `v60@0:8{CGRect={CGPoint=dd}{CGSize=dd}}16d48i56` | 1 |
| `BDMessageViewController` | `checkSendScreenshotTip` | `v16@0:8` | 2 |
| `BDMessageViewController` | `didReceivePhotoLook:` | `v24@0:8@16` | 3 |
| `BDMessageViewController` | `didReceivePhotoRevoke:` | `v24@0:8@16` | 4 |
| `BDMessageViewController` | `p_screenshotTip` | `v16@0:8` | 5 |
| `BDMessageViewController` | `p_screenshotWarning` | `v16@0:8` | 6 |
| `BDMessageViewController` | `p_showDestoryTip:` | `v24@0:8@16` | 7 |
| `BDMessageViewController` | `receiveNewMessage:` | `v24@0:8@16` | 8 |
| `BDMineBannerCell` | `configerBanner:` | `v24@0:8@16` | 1 |
| `BDMineSVGAFloatView` | `initWithFrame:` | `@48@0:8{CGRect={CGPoint=dd}{CGSize=dd}}16` | 1 |
| `BDMsgSessionDeletedTipView` | `showIfNeed` | `v16@0:8` | 1 |
| `BDNearbyDataAdapter` | `inputWithArray:offset:hasMore:limit:headline:` | `v40@0:8@16i24B28B32B36` | 1 |
| `BDNearbyDataAdapter` | `insertBigMapAndOperationWithModel:originalAd:adBanner:sortType:isRefresh:` | `v52@0:8@16@24@32@40B48` | 2 |
| `BDNearbyDataAdapter` | `setAdmsArray:` | `v24@0:8@16` | 3 |
| `BDNearbyDataAdapter` | `setOriginUserAdsArray:` | `v24@0:8@16` | 4 |
| `BDNearbyFloatingLayerModel` | `hasShown` | `B16@0:8` | 1 |
| `BDNearbyFloatingLayerModel` | `is_show_adm_icon` | `i16@0:8` | 2 |
| `BDNearbyFloatingLayerModel` | `setHasShown:` | `v20@0:8B16` | 3 |
| `BDNearbyFloatingLayerModel` | `videos` | `@16@0:8` | 4 |
| `BDNearbyFloatingLayerView` | `setLayerModel:` | `v24@0:8@16` | 2 |
| `BDNearbyFloatingLayerView` | `showWithAnimation` | `v16@0:8` | 3 |
| `BDNearbyGridView` | `setUser:` | `v24@0:8@16` | 1 |
| `BDNearbyListPublicUserInfoView` | `user` | `@16@0:8` | 1 |
| `BDNearbyMakeFriendsSubPageController` | `synchronizeTopHeaderWithHeight:` | `v24@0:8d16` | 1 |
| `BDNearbyMakeFriendsSubPageController` | `tableView:cellForRowAtIndexPath:` | `@32@0:8@16@24` | 2 |
| `BDNearbyMakeFriendsSubPageController` | `tableView:heightForRowAtIndexPath:` | `d32@0:8@16@24` | 3 |
| `BDNearbyMakeFriendsSubPageController` | `tableView:willDisplayCell:forRowAtIndexPath:` | `v40@0:8@16@24@32` | 4 |
| `BDNearbyMakeFriendsSubPageManager` | `p_parseWithModel:offset:isCached:sortType:` | `v44@0:8@16Q24B32@36` | 1 |
| `BDNearbyMapSearchController` | `dismiss` | `v16@0:8` | 1 |
| `BDNearbyMapSearchController` | `handleMapFriendSelection:` | `v24@0:8@16` | 2 |
| `BDNearbyMapSearchController` | `mapView:viewForAnnotation:` | `@32@0:8@16@24` | 3 |
| `BDNearbyMapSearchController` | `p_dismissWithCompletion:` | `v24@0:8@?16` | 4 |
| `BDNearbyMapSearchController` | `p_showGuideView` | `v16@0:8` | 5 |
| `BDNearbyMapSearchController` | `p_showMapLocationAlert` | `v16@0:8` | 6 |
| `BDNearbyMapSearchSignal` | `use_pay_map` | `q16@0:8` | 1 |
| `BDNearbyMenu` | `tableView:numberOfRowsInSection:` | `q32@0:8@16q24` | 6 |
| `BDNearbyTopFixView` | `layoutDidFinish` | `v16@0:8` | 1 |
| `BDNearbyTopFixView` | `p_topHeight` | `d16@0:8` | 2 |
| `BDNearbyTopFixView` | `tableView:numberOfRowsInSection:` | `q32@0:8@16q24` | 3 |
| `BDNetworkAgent` | `sessionTaskForRequest:error:` | `@32@0:8@16^@24` | 1 |
| `BDNewNavigationTitleViewTagView` | `updatetext:` | `v24@0:8@16` | 1 |
| `BDNewNavigationTitleViewTagView` | `updatetext:colors:` | `v32@0:8@16@24` | 2 |
| `BDPangleSplashAdManager` | `showPangleSplash` | `v16@0:8` | 1 |
| `BDPersonPrivacyAlbumCollectView` | `convertToSwiftStatus:obj:` | `@28@0:8i16@20` | 1 |
| `BDPersonPrivacyAlbumCollectView` | `updatePrivateAlbumWithUid:photos:hasMore:islock:isAccessOpen:picNums:` | `v48@0:8@16@24B32i36i40i44` | 5 |
| `BDPhotoBrowserBasicCell` | `album_ban_save` | `i16@0:8` | 1 |
| `BDPhotoBrowserBasicCell` | `feed_pic_ban_save` | `i16@0:8` | 2 |
| `BDPhotoBrowserController` | `isSecurity` | `B16@0:8` | 1 |
| `BDPhotoBrowserController` | `privatePhoto` | `B16@0:8` | 2 |
| `BDPhotoBrowserController` | `privatePhotoOn` | `B16@0:8` | 3 |
| `BDPhotoBrowserController` | `setDataArr:` | `v24@0:8@16` | 4 |
| `BDPhotoBrowserController` | `setIsSecurity:` | `v20@0:8B16` | 5 |
| `BDPhotoBrowserController` | `setPrivatePhoto:` | `v20@0:8B16` | 6 |
| `BDPhotoBrowserController` | `setPrivatePhotoOn:` | `v20@0:8B16` | 7 |
| `BDPhotoBrowserController` | `setWaterMarkText:` | `v24@0:8@16` | 8 |
| `BDPhotoBrowserPrivacyAlbumCell` | `setupPhotoData:` | `v24@0:8@16` | 1 |
| `BDPrivacyAlbumCell` | `showMaskViewOrNot:` | `v20@0:8B16` | 1 |
| `BDProfile` | `expire_type` | `i16@0:8` | 1 |
| `BDProfile` | `is_eco_user` | `i16@0:8` | 2 |
| `BDProfile` | `is_vip_annual` | `i16@0:8` | 3 |
| `BDProfile` | `vip_exp_lvl` | `i16@0:8` | 4 |
| `BDProfile` | `vip_grade` | `i16@0:8` | 5 |
| `BDSMeiIDManager` | `setup` | `v16@0:8` | 7 |
| `BDSVGAAnimationView` | `playWithResource:bundle:completion:` | `v40@0:8@16@24@?32` | 1 |
| `BDSVGAAnimationView` | `playWithURLString:completion:` | `v32@0:8@16@?24` | 2 |
| `BDSVGAAnimationView` | `startAnimation` | `v16@0:8` | 3 |
| `BDSecurityView` | `secure_updateSecure:` | `v20@0:8B16` | 1 |
| `BDSecurityView` | `setup` | `v16@0:8` | 2 |
| `BDSessionCell` | `configureSubviewsWithData:inSearchResultController:` | `v28@0:8@16B24` | 1 |
| `BDSessionCell` | `setStatusIconImageView:` | `v24@0:8@16` | 2 |
| `BDSessionGuestCallView` | `updateWithCallModel:` | `v24@0:8@16` | 1 |
| `BDSessionGuestCallView` | `updateWithCallState:` | `v24@0:8@16` | 2 |
| `BDSessionListHeader1` | `setCallListView:` | `v24@0:8@16` | 1 |
| `BDSessionPageController` | `updateMessagesUnreadCount:unreadNotiCount:showWeakBadge:roomType:` | `v44@0:8Q16q24B32Q36` | 1 |
| `BDSessionViewController` | `p_insertRecommendUserModelsIfNeeded` | `v16@0:8` | 2 |
| `BDSessionViewController` | `saveRecommendSessions` | `v16@0:8` | 4 |
| `BDSettingShadowRequest` | `uploadShadowLocation:longitude:latitude:isOpen:shadowId:success:failed:` | `v68@0:8@16d24d32B40q44@?52@?60` | 1 |
| `BDShadowPrivilegeController` | `distanceFromLocation` | `d16@0:8` | 1 |
| `BDShadowPrivilegeController` | `inserShadowSetRecordWithKeyword:` | `v24@0:8@16` | 2 |
| `BDShadowPrivilegeController` | `p_confirmAction` | `v16@0:8` | 3 |
| `BDShadowPrivilegeController` | `selectApplePlacemark:` | `v24@0:8@16` | 4 |
| `BDShadowPrivilegeController` | `selectGaodePOI:` | `v24@0:8@16` | 5 |
| `BDSplashImageAdViewController` | `presentInViewController:` | `v24@0:8@16` | 1 |
| `BDUserInfoRequest` | `initWithUserInfoRequestUrl:withMethod:withParamsDict:withUserInterfaceType:` | `@48@0:8@16q24@32q40` | 1 |
| `BDUserInfoRequest` | `userInfomationModel` | `@16@0:8` | 5 |
| `BDUserVisitorCell` | `removeVistorAction:` | `v24@0:8@16` | 1 |
| `BDUserVisitorCell` | `setShowBlur:` | `v20@0:8B16` | 2 |
| `BDUserVisitorCell` | `setVisitor:` | `v24@0:8@16` | 3 |
| `BDUserVisitorCell` | `showBlur` | `B16@0:8` | 4 |
| `BDVIPPrivilegeConfigModel` | `is_filter_ads` | `q16@0:8` | 1 |
| `BDVIPPrivilegeConfigModel` | `is_global_view_secretly` | `q16@0:8` | 2 |
| `BDVIPPrivilegeConfigModel` | `is_improve_backlist` | `q16@0:8` | 3 |
| `BDVIPPrivilegeConfigModel` | `is_view_secretly` | `q16@0:8` | 4 |
| `BDVIPPrivilegeConfigModel` | `is_vip_annual_mark` | `q16@0:8` | 5 |
| `BDVIPPrivilegeConfigModel` | `is_vip_mark` | `q16@0:8` | 6 |
| `BDVideoFileManager` | `deleteAllVideos` | `v16@0:8` | 1 |
| `BDVideoFileManager` | `deleteVideoPath:` | `v24@0:8@16` | 2 |
| `BDVisitorHeaderNewView` | `setVisitorCount:` | `v24@0:8@16` | 1 |
| `BELicenseHelper` | `checkLicenseResult:` | `B24@0:8@16` | 1 |
| `BLYSDKManager` | `startWithAppInfo:delegate:` | `v32@0:8@16@24` | 1 |
| `BlacklistViewController` | `getBlacklistByFistPage` | `v16@0:8` | 1 |
| `BluedTabBar` | `setEntryBadgeText:atItemIndex:` | `v32@0:8@16q24` | 1 |
| `ChatKeyBoardModel` | `showGiftView` | `v16@0:8` | 1 |
| `DLDeviceFingerprint` | `infoClsArray` | `@16@0:8` | 2 |
| `DLDeviceFingerprint` | `p_deviceInfo` | `@16@0:8` | 3 |
| `DLDeviceFingerprint` | `p_requestParams` | `@16@0:8` | 4 |
| `DLDeviceFingerprint` | `p_retryUploadDeviceInfoCompletion:` | `v24@0:8@?16` | 5 |
| `DLDeviceFingerprint` | `p_uploadRequest:completion:` | `v32@0:8@16@?24` | 6 |
| `GJIMChatSessionModel` | `soulmate_enable` | `i16@0:8` | 1 |
| `GJIMEngine` | `gji_requestDeletePackage:completion:` | `v32@0:8@16@?24` | 2 |
| `GJIMEngine` | `handleingGRPCPrivatePackage:` | `v24@0:8@16` | 3 |
| `GJIMEngine` | `p_handleAMessageWithData:` | `v24@0:8@16` | 4 |
| `GJIMMessageModel` | `autoDestroy` | `B16@0:8` | 1 |
| `GJIMMessageModel` | `destroyUrl` | `@16@0:8` | 2 |
| `GJIMMessageModel` | `initWithPushPackage:` | `@24@0:8@16` | 3 |
| `GJIMMessageModel` | `isIdentifyYellow` | `i16@0:8` | 4 |
| `GJIMMessageModel` | `isShowTime` | `B16@0:8` | 5 |
| `GJIMMessageModel` | `isSuperRecallTip` | `B16@0:8` | 6 |
| `GJIMMessageModel` | `msgExtra` | `@16@0:8` | 7 |
| `GJIMMessageModel` | `recallType` | `i16@0:8` | 8 |
| `GJIMMessageService` | `addMessage:` | `v24@0:8@16` | 1 |
| `GJIMMessageService` | `addMessages:` | `v24@0:8@16` | 4 |
| `GJIMMessageService` | `deleteMessage:` | `v24@0:8@16` | 2 |
| `GJIMMessageService` | `updateMessage:` | `v24@0:8@16` | 3 |
| `GJIMSessionService` | `setSoulmate_enable:soulmate_stage1:soulmate_stage2:soulmate_type:byToken:` | `v40@0:8i16i20i24i28@32` | 1 |
| `GJPHPickerController` | `p_updateAlbumSelected:` | `v24@0:8@16` | 1 |
| `GXWatchdog` | `checkConnectOrHeart` | `v16@0:8` | 1 |
| `GtkDbStore` | `cleanExpireData` | `v16@0:8` | 1 |
| `GtkDbStore` | `cleanExpireDataInPaylodMsg:` | `v24@0:8d16` | 2 |
| `HPGrowingTextView` | `becomeFirstResponder` | `B16@0:8` | 1 |
| `HomeDataProvider` | `getUserInformationWithUID:success:failure:` | `v40@0:8@16@?24@?32` | 1 |
| `LoginData` | `device_safe` | `i16@0:8` | 1 |
| `NewKeyBoard` | `p_configBtnStatus:` | `v20@0:8B16` | 1 |
| `NewKeyBoard` | `p_showKeyboardStateRecentPhoto` | `v16@0:8` | 2 |
| `NewKeyBoard` | `setGiftButton:` | `v24@0:8@16` | 3 |
| `NewKeyBoard` | `sinaFaceBoardPressed:` | `v24@0:8@16` | 4 |
| `NewKeyBoardPhotoView` | `actionDes:` | `v24@0:8@16` | 1 |
| `NewKeyBoardPhotoView` | `resetLoadData` | `v16@0:8` | 2 |
| `PrivateChatViewController` | `p_ifShowMatchEmojiView` | `v16@0:8` | 1 |
| `RecentlyVisitorViewController` | `loadMoreVisitor` | `v16@0:8` | 1 |
| `RecentlyVisitorViewController` | `p_needToBuyVip` | `v16@0:8` | 2 |
| `RecentlyVisitorViewController` | `p_processWithNewVisitors:` | `v24@0:8@16` | 3 |
| `RecentlyVisitorViewController` | `p_processWithNewVisits:` | `v24@0:8@16` | 4 |
| `RecentlyVisitorViewController` | `refreshVisit` | `v16@0:8` | 5 |
| `RecentlyVisitorViewController` | `refreshVisitor` | `v16@0:8` | 6 |
| `RecentlyVisitorViewController` | `scrollViewDidScroll:` | `v24@0:8@16` | 7 |
| `SDImageCache` | `imageFromCacheForKey:` | `@24@0:8@16` | 2 |
| `SDImageCache` | `storeImage:forKey:toDisk:completion:` | `v44@0:8@16@24B32@?36` | 3 |
| `SDWebImageManager` | `loadImageWithURL:options:context:progress:completed:` | `@56@0:8@16Q24@32@?40@?48` | 1 |
| `SDWebImageManager` | `loadImageWithURL:options:progress:completed:` | `@48@0:8@16Q24@?32@?40` | 2 |
| `SDWebImagePrefetcher` | `prefetchURLs:` | `@24@0:8@16` | 2 |
| `SceneDelegate` | `scene:willConnectToSession:options:` | `v40@0:8@16@24@32` | 1 |
| `SceneDelegate` | `sceneDidBecomeActive:` | `v24@0:8@16` | 2 |
| `SearchUsersData` | `last_operate` | `i16@0:8` | 1 |
| `SmAntiFraud` | `check:` | `q24@0:8@16` | 1 |
| `SmAntiFraud` | `getDeviceId` | `@16@0:8` | 2 |
| `SmAntiFraud` | `getVdata` | `@16@0:8` | 3 |
| `SmAntiFraud` | `startDetector:` | `v24@0:8@16` | 4 |
| `TXVodLicenseCheckManager` | `checkValid:` | `B20@0:8i16` | 1 |
| `TXVodLicenseCheckManager` | `checkValidForPlayerMonet` | `B16@0:8` | 2 |
| `UserAlbum` | `isBlank` | `B16@0:8` | 1 |
| `UserHTTPRequest` | `updateUserNoteWithUID:withNote:success:failure:` | `v48@0:8@16@24@?32@?40` | 1 |
| `UserInformation` | `setUid:` | `v20@0:8i16` | 1 |
| `UserInformation` | `setUnion_uid:` | `v24@0:8@16` | 2 |
| `UserSetting` | `is_traceless_access` | `i16@0:8` | 1 |
| `ZOAUHandler` | `loginPre:type:apiKey:RL:` | `v44@0:8d16i24@28@?36` | 1 |
| `ZOAUHandler` | `loginPre:ua:type:apiKey:RL:ifDebug:ifGM:` | `v60@0:8d16@24i32@36@?44B52B56` | 3 |
| `_TtC5Blued16BDCustomMenuView` | `reloadData` | `v16@0:8` | 2 |
| `_TtC5Blued30BDChatExchangePhotoContentView` | `leftMaskView` | `@16@0:8` | 8 |
| `_TtC5Blued30BDChatExchangePhotoContentView` | `leftWarnBtn` | `@16@0:8` | 7 |
| `_TtC5Blued30BDChatExchangePhotoContentView` | `leftWarnLab` | `@16@0:8` | 5 |
| `_TtC5Blued30BDChatExchangePhotoContentView` | `leftWarnView` | `@16@0:8` | 3 |
| `_TtC5Blued30BDChatExchangePhotoContentView` | `rightWarnLab` | `@16@0:8` | 6 |
| `_TtC5Blued30BDChatExchangePhotoContentView` | `rightWarnView` | `@16@0:8` | 4 |

## 4. 定位模块：原版 → 我们（REALoc.xm）1:1 对照

| 原版 | 类型 | 我们的实现 | 状态 |
|---|---|---|---|
| `HushLocationPickerController` | 类 | 同名类，48 方法 / 31 ivar 全部同名 | ✅ 1:1 |
| `HushLocGestureTarget` | 类 | 同名类，tap/doubleTap/longPress 三个类方法 | ✅ 1:1 |
| `HushVLocPlainLocation` | 类 | 同名类，CLLocation 子类 + coordinate 重写 | ✅ 1:1 |
| `HushLocationHistoryController` | 类 | 同名类，历史/收藏夹 + 左滑删除 + 清空 | ✅ 1:1 |
| `BDLocationService latitude / longitude` | Hook | 返回假坐标 NSNumber | ✅ 已挂 |
| `BDLocationService locationManager:didUpdateLocations:` | Hook | 替换 locations 数组 | ✅ 已挂 |
| `BDLocationService p_startLocation` | Hook | 观测 + 透传 | ✅ 已挂 |
| `BDLocationService p_reverseGeocodeLocation:` | Hook | 观测 + 透传 | ✅ 已挂 |
| `BDLocationService p_saveLocationWithLot:lat:` | Hook | 观测 + 透传 | ✅ 已挂 |
| `BDSettingShadowRequest uploadShadowLocation:…` | Hook | 改写经纬度后透传（服务端位置） | ✅ 已挂 |

## 5. 原版 UI 文案（__ustring 直接取出，用于 1:1 对齐）

- `[LocPicker] 长按 → 蓝点落在 %.6f,%.6f（镜头不动；保存以此点为准）`
- `[LocPicker] 地图类型 → %@`
- `[LocPicker] 选中搜索结果：%@ (%.6f,%.6f)`
- `[LocPicker] 搜索地名：…`
- `[LocPicker] 搜索无结果：%@（err=%@）`
- `[LocPicker] 海拔模拟 → …`
- `[LocPicker] 海拔已保存：%.2f 米`
- `[LocPicker] 已收藏当前位置：%@（收藏夹共 %lu 条）`
- `[LocPicker] 手动输入的位置`
- `[LocPicker] 离开搜索点 %.0f 米 → 摘掉地名「%@」`
- `[LocPicker] 首次对准 → %.6f,%.6f`
- `[LocPicker] 历史已删除 1 条（余 %lu）`
- `[LocStatus] 地址反查完成：%@`
- `[LocStatus] 虚拟定位已打开`
- `[LocStatus] 虚拟定位已关闭`
- `[LocStatus] 拒绝开启：尚未设置位置（hasCustomLocation=NO）`
- `还没有收藏的坐标`
- `（在选点页点左上角「收藏」即可）`
- `(已清空)`
- `纬度范围：-90 ~ 90`
- `经度范围：-180 ~ 180`
- `请输入正确的海拔高度（可以是负值）`
- `请先在地图上选择位置再收藏`
- `请先设置海拔高度`

## 6. 已确认**未**还原的部分（不假装做了）

| 模块 | 原版证据 | 现状 | 还原需要什么 |
|---|---|---|---|
| 位置追踪（物理追踪/公式收敛） | `[Track] 探测 stage=… attempt=… dist=…`、`[PreTrack] 两轴增量定位 @C(%.6f,%.6f)` | 未实现 | 原版真机 `Documents/hooo` 里 `[Track]` 那一段（你给的日志里 0 条） |
| 授权 / 激活码 | `[License] 激活码格式不对`、`已被吊销`、`受限键` | 未实现 | 签发规则与服务器地址（二进制只有校验逻辑） |
| 聊天库备份 / 还原 | `[Backup]` 全族 | 未实现 | `HushGal*` 12 类方法体语义，需分批静态还原 |
| 相册备份（展览馆） | `HushGalController` 等 12 类 | 未实现 | 同上 |
| 关系标签 / 角色自绘 / 风险名单 | `[Rel]`、`[Role]`、`[RiskMark]` | 未实现 | 38 个 `HushHostStyle` 键的含义表 |
| 日志等级 / 迁移 / 兼容适配 | `[Log]`、`[Migrate]`、`[Compat]` | 未实现 | 下一轮按类照抄 |

## 7. 关于那份 `BluedHushREA.log`

`C:\Users\Fox-OS\Desktop\BluedHushREA.log`（644,292 B / 7,143 行）里是**我们自己的构建**打的日志，不是原版的：

- 出现 `[REA] build=v13.0-P0 / v13.1-P1 / v13.2-P1`（原版没有 `[REA]` 前缀，原版写 `Documents/hooo`）
- 出现 `hook MISS … 候选: …`、`本类无自有实现，跳过以免触发 +initialize`（这是我们引擎的措辞）
- `[Loc] BDLocationService didUpdateLocations hook=ok` 与 `[Loc] BDSettingShadowRequest uploadShadowLocation hook=ok` 各 18 次 → v13.2 两个钩子确实装上了
- `影子位置` 命中 0 次 → 宿主没走那条上传路径，这正是本轮补上 `latitude/longitude/p_startLocation/p_saveLocationWithLot:lat:` 四条的原因

拿原版日志请取原版 App 沙盒里的 `Documents/hooo`。
