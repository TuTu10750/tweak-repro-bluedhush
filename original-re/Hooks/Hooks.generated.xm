// Recovered hook layer for BluedHush 5.19 — signatures from the host binary.
// 309 unique (class, selector) pairs across 107 host classes.
//
// Every body is a pure passthrough (%orig). Two safety nets keep this from
// faulting on argument values we do not touch:
//   1. real type encodings below (pointer params stay pointers, so ARC
//      never objc_retain()s an NSError **);
//   2. this translation unit is compiled with -fno-objc-arc (see Makefile),
//      so any unresolved signature that fell back to `id` still cannot
//      trigger a spurious objc_storeStrong().

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>
#import <MapKit/MapKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>

// ---- host classes referenced by the original hook table ----
@class GJIMSessionService;
@class GJIMMessageModel;
@class GJIMMessageService;
@class GJIMEngine;
@class GXWatchdog;
@class NetworkWatchdog;
@class BDChatBasicCell;
@class BDMessageViewController;
@class NewKeyBoardPhotoView;
@class NewKeyBoard;
@class GJIMDBService;
@class UITableViewCell;
@class BDChatImageCell;
@class BDChatVideoCell;
@class BDChatTextAndFaceCell;
@class BDChatTextAndFaceCellSelf;
@class BDChatTextAndFaceCellPrivateOther;
@class BDAutoDestoryImageViewController;
@class BDDestoryChatCell;
@class GtkDbStore;
@class BDVideoFileManager;
@class NSURLCache;
@class BDSessionCell;
@class SceneDelegate;
@class AppDelegate;
@class UserInformation;
@class HPGrowingTextView;
@class BDLocationService;
@class CLLocation;
@class CLLocationManager;
@class MKUserLocation;
@class BDShadowPrivilegeController;
@class BDSettingShadowRequest;
@class BDHomePageHeaderView;
@class BDHomeViewController;
@class BDNearbyMakeFriendsSubPageController;
@class BDNetworkAgent;
@class BDNearbyBViewController;
@class BDNearbyMapSearchController;
@class UIViewController;
@class BDAvatarSurroundingModel;
@class BDAvatarSurroundingRequest;
@class BDNearbyMapSearchSignal;
@class BDMapBlurBaseView;
@class GJIMChatSessionModel;
@class BDAvatarAnnotationView;
@class SDWebImageManager;
@class NSMutableURLRequest;
@class BDNearbyGridView;
@class BDNearbyListTableViewCell;
@class BDProfile;
@class BaseModel;
@class SearchUsersData;
@class UserSetting;
@class BDVIPPrivilegeConfigModel;
@class UserSettingModel;
@class UITableView;
@class UserBasic;
@class BDAvatarLocationModel;
@class BDHomeDynamicAlbumModel;
@class BDPhotoBrowserDynamic;
@class DynamicRepostModel;
@class LiveVideoAnchor;
@class LivingUserCardUser;
@class BDGlobalConfig;
@class BDPersonPrivacyAlbumCollectView;
@class BDHomePageAlbumCell;
@class UserAlbum;
@class UserAvatar;
@class BDPrivacyAlbumCell;
@class BDHomePrivacyAlbumModel;
@class BDHomePhotoModel;
@class BDHomeAlbumCell;
@class BDPhotoBrowserController;
@class BDPhotoBrowserPrivacyAlbumCell;
@class BDPhotoBrowserBasicCell;
@class BDSecurityView;
@class BDChatProtectionManager;
@class BDChatProtectionModel;
@class BDHomePageBlockController;
@class BlacklistViewController;
@class BELicenseHelper;
@class TXVodLicenseCheckManager;
@class BDChatSafeTipCell;
@class PrivateChatViewController;
@class BDSessionListHeader1;
@class BDNearbyRecommendCell;
@class BDNearbyBannerCell;
@class BDNearbyFloatingLayerModel;
@class BDIndexPageCoversManager;
@class BDNearbyFloatingLayerView;
@class BDEmotionChatCell;
@class BDAnimatedImageView;
@class BDSVGAAnimationView;
@class BDMessageRecentSendPhotoModel;
@class BDNearbySceneMatchingTableViewCell;
@class ChatKeyBoardModel;
@class LoginData;
@class BDFingerprintManager;
@class DLDeviceFingerprint;
@class BDSMeiIDManager;
@class ZOAUHandler;
@class SmAntiFraud;
@class BLYSDKManager;
@class BDSettingViewController;
@class BDVisitorTopView;
@class BDVisitorHeaderNewView;

%hook GJIMSessionService
- (id)p_handlePushPackage:(id)a0 { return %orig; }
- (void)addMessage:(id)a0 { %orig; }
- (void)addMessages:(id)a0 { %orig; }
- (void)updateMessage:(id)a0 { %orig; }
- (void)p_fetchSyncMessagesWithType:(unsigned long long)a0 syncLocalId:(unsigned int)a1 { %orig; }
%end

%hook GJIMMessageModel
- (int) { return %orig; }
- (BOOL) { return %orig; }
- (void)setRecallType:(int)a0 { %orig; }
- (void)setDestroyUrl:(id)a0 { %orig; }
- (void)setIsSuperRecallTip:(BOOL)a0 { %orig; }
- (BOOL) { return %orig; }
- (BOOL) { return %orig; }
- (BOOL) { return %orig; }
- (id) { return %orig; }
- (void)setAutoDestroy:(BOOL)a0 { %orig; }
- (id)initWithPushPackage:(id)a0 { return %orig; }
- (int) { return %orig; }
- (id) { return %orig; }
%end

%hook GJIMMessageService
- (void)deleteMessage:(id)a0 { %orig; }
- (void)addMessage:(id)a0 { %orig; }
- (void)updateMessage:(id)a0 { %orig; }
%end

%hook GJIMEngine
- (void)p_handleAMessageWithData:(id)a0 { %orig; }
- (void)handleingGRPCPrivatePackage:(id)a0 { %orig; }
%end

%hook GXWatchdog
- (void) { %orig; }
%end

%hook NetworkWatchdog
- (void) { %orig; }
%end

%hook BDChatBasicCell
- (void) { %orig; }
- (void) { %orig; }
- (double) { return %orig; }
%end

%hook BDMessageViewController
- (void)setMessages:(id)a0 { %orig; }
- (void)p_showDestoryTip:(id)a0 { %orig; }
- (void)receiveNewMessage:(id)a0 { %orig; }
- (void)updateMessages:(id)a0 updateType:(unsigned long long)a1 { %orig; }
- (void)didReceivePhotoRevoke:(id)a0 { %orig; }
- (void)didReceivePhotoLook:(id)a0 { %orig; }
- (void) { %orig; }
- (void) { %orig; }
- (void) { %orig; }
- (long long) { return %orig; }
- (void)viewDidAppear:(BOOL)a0 { %orig; }
- (void) { %orig; }
- (void)viewWillAppear:(BOOL)a0 { %orig; }
- (void)viewWillDisappear:(BOOL)a0 { %orig; }
- (void)chatKeyBoardWillChangeFrameWithNewFrame:(CGRect)a0 animationTime:(double)a1 keyBoardState:(int)a2 { %orig; }
%end

%hook NewKeyBoardPhotoView
- (void) { %orig; }
- (void)actionDes:(id)a0 { %orig; }
%end

%hook NewKeyBoard
- (void) { %orig; }
- (void)p_configBtnStatus:(BOOL)a0 { %orig; }
- (void)sinaFaceBoardPressed:(id)a0 { %orig; }
- (void)setGiftButton:(id)a0 { %orig; }
%end

%hook GJIMDBService
- (void)p_updateMessage:(id)a0 { %orig; }
%end

%hook UITableViewCell
- (id)contentView { return %orig; }
%end

%hook BDChatImageCell
- (void) { %orig; }
%end

%hook BDChatVideoCell
- (void) { %orig; }
%end

%hook BDChatTextAndFaceCell
- (void) { %orig; }
- (void) { %orig; }
%end

%hook BDChatTextAndFaceCellSelf
- (void) { %orig; }
%end

%hook BDChatTextAndFaceCellPrivateOther
- (void) { %orig; }
%end

%hook BDAutoDestoryImageViewController
- (void) { %orig; }
- (void) { %orig; }
- (void) { %orig; }
- (void) { %orig; }
- (void)setTakeScreenBlock:(id /*block*/)a0 { %orig; }
- (void) { %orig; }
- (void) { %orig; }
- (void) { %orig; }
%end

%hook BDDestoryChatCell
- (void) { %orig; }
- (void) { %orig; }
- (void)setImageURL:(id)a0 { %orig; }
- (void)setVideoURL:(id)a0 { %orig; }
%end

%hook GtkDbStore
- (void) { %orig; }
- (void)cleanExpireDataInPaylodMsg:(double)a0 { %orig; }
%end

%hook BDVideoFileManager
- (void) { %orig; }
- (void)deleteVideoPath:(id)a0 { %orig; }
%end

%hook NSURLCache
- (id)removeAllCachedResponses { return %orig; }
- (id)removeCachedResponsesSinceDate:(id)a0 { return %orig; }
%end

%hook BDSessionCell
- (void)setStatusIconImageView:(id)a0 { %orig; }
%end

%hook SceneDelegate
- (void)scene:(id)a0 willConnectToSession:(id)a1 options:(id)a2 { %orig; }
- (void)sceneDidBecomeActive:(id)a0 { %orig; }
%end

%hook AppDelegate
- (BOOL)application:(id)a0 didFinishLaunchingWithOptions:(id)a1 { return %orig; }
%end

%hook UserInformation
- (void)setUid:(int)a0 { %orig; }
- (double) { return %orig; }
- (unsigned int) { return %orig; }
- (int) { return %orig; }
- (void)setUnion_uid:(id)a0 { %orig; }
%end

%hook HPGrowingTextView
- (BOOL) { return %orig; }
%end

%hook BDLocationService
- (void)p_saveLocationWithLot:(id)a0 lat:(id)a1 { %orig; }
- (void)locationManager:(id)a0 didUpdateLocations:(id)a1 { %orig; }
- (void)p_reverseGeocodeLocation:(id)a0 { %orig; }
- (id) { return %orig; }
- (id) { return %orig; }
- (void) { %orig; }
%end

%hook CLLocation
- (id)coordinate { return %orig; }
- (id)altitude { return %orig; }
- (id)verticalAccuracy { return %orig; }
%end

%hook CLLocationManager
- (id)location { return %orig; }
- (id)setDelegate:(id)a0 { return %orig; }
- (id)setDesiredAccuracy:(id)a0 { return %orig; }
- (id)accuracyAuthorization { return %orig; }
- (id)requestTemporaryFullAccuracyAuthorizationWithPurposeKey:(id)a0 completion:(id)a1 { return %orig; }
%end

%hook MKUserLocation
- (id)coordinate { return %orig; }
%end

%hook BDShadowPrivilegeController
- (void)selectGaodePOI:(id)a0 { %orig; }
- (void)selectApplePlacemark:(id)a0 { %orig; }
- (void) { %orig; }
- (void)inserShadowSetRecordWithKeyword:(id)a0 { %orig; }
- (double) { return %orig; }
%end

%hook BDSettingShadowRequest
- (void)uploadShadowLocation:(id)a0 longitude:(double)a1 latitude:(double)a2 isOpen:(BOOL)a3 shadowId:(long long)a4 success:(id /*block*/)a5 failed:(id /*block*/)a6 { %orig; }
%end

%hook BDHomePageHeaderView
- (void)setUserInfo:(id)a0 { %orig; }
- (void)setProtectLockState:(id)a0 { %orig; }
- (void) { %orig; }
- (void)updateWithUserInfo:(id)a0 isCacheData:(BOOL)a1 { %orig; }
- (void)setInfoTagView:(id)a0 { %orig; }
%end

%hook BDHomeViewController
- (void)viewDidDisappear:(BOOL)a0 { %orig; }
- (void)viewWillAppear:(BOOL)a0 { %orig; }
- (void)viewDidAppear:(BOOL)a0 { %orig; }
- (BOOL) { return %orig; }
- (void)setIsUnlockPrivateAlbum:(BOOL)a0 { %orig; }
- (void) { %orig; }
- (void) { %orig; }
- (void)p_presentFollowSomeoneSecretlyVCWithType:(int)a0 { %orig; }
%end

%hook BDNearbyMakeFriendsSubPageController
- (void)viewDidAppear:(BOOL)a0 { %orig; }
%end

%hook BDNetworkAgent
- (id)sessionTaskForRequest:(id)a0 error:(id *)a1 { return %orig; }
%end

%hook BDNearbyBViewController
- (void)viewDidAppear:(BOOL)a0 { %orig; }
- (void) { %orig; }
%end

%hook BDNearbyMapSearchController
- (void) { %orig; }
- (void)p_dismissWithCompletion:(id /*block*/)a0 { %orig; }
- (void) { %orig; }
- (void) { %orig; }
- (id)mapView:(id)a0 viewForAnnotation:(id)a1 { return %orig; }
- (void)handleMapFriendSelection:(id)a0 { %orig; }
- (void)viewDidAppear:(BOOL)a0 { %orig; }
%end

%hook UIViewController
- (id)presentViewController:(id)a0 animated:(id)a1 completion:(id)a2 { return %orig; }
- (id)addChildViewController:(id)a0 { return %orig; }
%end

%hook BDAvatarSurroundingModel
- (void)setAvatar:(id)a0 { %orig; }
- (id) { return %orig; }
- (double) { return %orig; }
- (BOOL) { return %orig; }
- (BOOL) { return %orig; }
- (BOOL) { return %orig; }
- (BOOL) { return %orig; }
- (BOOL) { return %orig; }
- (BOOL) { return %orig; }
%end

%hook BDAvatarSurroundingRequest
- (long long) { return %orig; }
- (id) { return %orig; }
%end

%hook BDNearbyMapSearchSignal
- (long long) { return %orig; }
%end

%hook BDMapBlurBaseView
- (void)applyBlurRadius:(double)a0 { %orig; }
- (void)applyBlurAlpha:(double)a0 { %orig; }
%end

%hook GJIMChatSessionModel
- (id) { return %orig; }
- (BOOL) { return %orig; }
- (int) { return %orig; }
- (int) { return %orig; }
- (int) { return %orig; }
%end

%hook BDAvatarAnnotationView
- (void)setMapFriendUid:(id)a0 { %orig; }
- (void)setImage:(id)a0 { %orig; }
%end

%hook SDWebImageManager
- (id)loadImageWithURL:(id)a0 options:(unsigned long long)a1 context:(id)a2 progress:(id /*block*/)a3 completed:(id /*block*/)a4 { return %orig; }
- (id)loadImageWithURL:(id)a0 options:(unsigned long long)a1 progress:(id /*block*/)a2 completed:(id /*block*/)a3 { return %orig; }
%end

%hook NSMutableURLRequest
- (id)setURL:(id)a0 { return %orig; }
%end

%hook BDNearbyGridView
- (void)setUser:(id)a0 { %orig; }
%end

%hook BDNearbyListTableViewCell
- (void)setUser:(id)a0 { %orig; }
%end

%hook BDProfile
- (int) { return %orig; }
- (int) { return %orig; }
- (int) { return %orig; }
- (int) { return %orig; }
- (int) { return %orig; }
- (int) { return %orig; }
- (int) { return %orig; }
- (int) { return %orig; }
%end

%hook BaseModel
- (int) { return %orig; }
- (int) { return %orig; }
%end

%hook SearchUsersData
- (int) { return %orig; }
- (int) { return %orig; }
- (double) { return %orig; }
- (int) { return %orig; }
%end

%hook UserSetting
- (int) { return %orig; }
- (unsigned long long) { return %orig; }
- (int) { return %orig; }
%end

%hook BDVIPPrivilegeConfigModel
- (long long) { return %orig; }
- (long long) { return %orig; }
- (long long) { return %orig; }
- (long long) { return %orig; }
- (long long) { return %orig; }
- (long long) { return %orig; }
%end

%hook UserSettingModel
- (int) { return %orig; }
%end

%hook UITableView
- (id)layoutSubviews { return %orig; }
%end

%hook UserBasic
- (char) { return %orig; }
- (int) { return %orig; }
- (int) { return %orig; }
- (int) { return %orig; }
- (int) { return %orig; }
%end

%hook BDAvatarLocationModel
- (long long) { return %orig; }
%end

%hook BDHomeDynamicAlbumModel
- (int) { return %orig; }
%end

%hook BDPhotoBrowserDynamic
- (int) { return %orig; }
%end

%hook DynamicRepostModel
- (int) { return %orig; }
%end

%hook LiveVideoAnchor
- (long long) { return %orig; }
%end

%hook LivingUserCardUser
- (int) { return %orig; }
%end

%hook BDGlobalConfig
- (long long) { return %orig; }
- (long long) { return %orig; }
- (id) { return %orig; }
- (id) { return %orig; }
- (long long) { return %orig; }
%end

%hook BDPersonPrivacyAlbumCollectView
- (void)updatePrivateAlbumWithUid:(id)a0 photos:(id)a1 hasMore:(BOOL)a2 islock:(int)a3 isAccessOpen:(int)a4 picNums:(int)a5 { %orig; }
- (id)convertToSwiftStatus:(int)a0 obj:(id)a1 { return %orig; }
- (id)setHidden:(id)a0 { return %orig; }
- (id)setAlpha:(id)a0 { return %orig; }
- (id)didMoveToSuperview { return %orig; }
- (id)setFrame:(id)a0 { return %orig; }
- (id)layoutSubviews { return %orig; }
- (int) { return %orig; }
- (void)setPrivacy_photos_has_locked:(int)a0 { %orig; }
- (int) { return %orig; }
- (void)setAccess_private_photos:(int)a0 { %orig; }
%end

%hook BDHomePageAlbumCell
- (id)blurImage:(id)a0 withRadius:(double)a1 { return %orig; }
- (void)applyPrivacyAlbumStatus:(long long)a0 { %orig; }
- (void)configurePrivacyAlbumStatus:(int)a0 isSelf:(BOOL)a1 { %orig; }
- (void) { %orig; }
- (void)setUserAlbum:(id)a0 isSelf:(BOOL)a1 { %orig; }
%end

%hook UserAlbum
- (int) { return %orig; }
- (void)setAudit_status:(int)a0 { %orig; }
- (BOOL) { return %orig; }
%end

%hook UserAvatar
- (int) { return %orig; }
- (void)setAudit_status:(int)a0 { %orig; }
%end

%hook BDPrivacyAlbumCell
- (void)showMaskViewOrNot:(BOOL)a0 { %orig; }
%end

%hook BDHomePrivacyAlbumModel
- (int) { return %orig; }
- (void)setStatus:(int)a0 { %orig; }
- (int) { return %orig; }
- (void)setPrivacy_photos_has_locked:(int)a0 { %orig; }
- (int) { return %orig; }
- (void)setAccess_private_photos:(int)a0 { %orig; }
%end

%hook BDHomePhotoModel
- (int) { return %orig; }
- (void)setAudit_status:(int)a0 { %orig; }
%end

%hook BDHomeAlbumCell
- (void)configureAllAlbum:(id)a0 lockStatus:(int)a1 isMultiple:(BOOL)a2 indexPath:(id)a3 { %orig; }
- (void)p_configureTempAlbum:(id)a0 lockStatus:(int)a1 { %orig; }
- (void)p_hideEffectView:(BOOL)a0 { %orig; }
%end

%hook BDPhotoBrowserController
- (void)setWaterMarkText:(id)a0 { %orig; }
- (id) { return %orig; }
- (BOOL) { return %orig; }
- (void)setPrivatePhoto:(BOOL)a0 { %orig; }
- (BOOL) { return %orig; }
- (void)setPrivatePhotoOn:(BOOL)a0 { %orig; }
- (BOOL) { return %orig; }
- (void)setIsSecurity:(BOOL)a0 { %orig; }
%end

%hook BDPhotoBrowserPrivacyAlbumCell
- (void)setupPhotoData:(id)a0 { %orig; }
%end

%hook BDPhotoBrowserBasicCell
- (int) { return %orig; }
- (int) { return %orig; }
%end

%hook BDSecurityView
- (void)secure_updateSecure:(BOOL)a0 { %orig; }
- (void) { %orig; }
%end

%hook BDChatProtectionManager
- (long long) { return %orig; }
%end

%hook BDChatProtectionModel
- (long long) { return %orig; }
%end

%hook BDHomePageBlockController
- (void)p_changeBlockStatus:(BOOL)a0 { %orig; }
- (void)setBlockTip:(id)a0 { %orig; }
- (void) { %orig; }
- (void)updateWithUserInfo:(id)a0 { %orig; }
- (id)viewDidAppear:(id)a0 { return %orig; }
- (id)viewDidLayoutSubviews { return %orig; }
%end

%hook BlacklistViewController
- (void) { %orig; }
%end

%hook BELicenseHelper
- (BOOL)checkLicenseResult:(id)a0 { return %orig; }
%end

%hook TXVodLicenseCheckManager
- (BOOL)checkValid:(int)a0 { return %orig; }
- (BOOL) { return %orig; }
%end

%hook BDChatSafeTipCell
- (id)systemLayoutSizeFittingSize:(id)a0 { return %orig; }
- (id)systemLayoutSizeFittingSize:(id)a0 withHorizontalFittingPriority:(id)a1 verticalFittingPriority:(id)a2 { return %orig; }
%end

%hook PrivateChatViewController
- (id)tableView:(id)a0 cellForRowAtIndexPath:(id)a1 { return %orig; }
- (void) { %orig; }
%end

%hook BDSessionListHeader1
- (void) { %orig; }
- (double) { return %orig; }
- (double)p_callNewGuestHeaderHeightWithTip:(BOOL)a0 { return %orig; }
- (void) { %orig; }
%end

%hook BDNearbyRecommendCell
- (void) { %orig; }
- (id)initWithStyle:(id)a0 reuseIdentifier:(id)a1 { return %orig; }
%end

%hook BDNearbyBannerCell
- (void) { %orig; }
- (id)initWithStyle:(id)a0 reuseIdentifier:(id)a1 { return %orig; }
%end

%hook BDNearbyFloatingLayerModel
- (void)setHasShown:(BOOL)a0 { %orig; }
%end

%hook BDIndexPageCoversManager
- (BOOL) { return %orig; }
- (void)p_showFloatingLayerAds:(id)a0 image:(id)a1 finished:(id /*block*/)a2 { %orig; }
%end

%hook BDNearbyFloatingLayerView
- (id)didMoveToSuperview { return %orig; }
%end

%hook BDEmotionChatCell
- (void) { %orig; }
- (void) { %orig; }
%end

%hook BDAnimatedImageView
- (void)setImage:(id)a0 { %orig; }
%end

%hook BDSVGAAnimationView
- (void) { %orig; }
- (void)playWithResource:(id)a0 bundle:(id)a1 completion:(id /*block*/)a2 { %orig; }
- (void)playWithURLString:(id)a0 completion:(id /*block*/)a1 { %orig; }
%end

%hook BDMessageRecentSendPhotoModel
- (BOOL) { return %orig; }
%end

%hook BDNearbySceneMatchingTableViewCell
- (void) { %orig; }
- (id)initWithStyle:(long long)a0 reuseIdentifier:(id)a1 { return %orig; }
%end

%hook ChatKeyBoardModel
- (void) { %orig; }
%end

%hook LoginData
- (int) { return %orig; }
%end

%hook BDFingerprintManager
- (void) { %orig; }
- (void) { %orig; }
- (id) { return %orig; }
- (id) { return %orig; }
- (id) { return %orig; }
- (id) { return %orig; }
%end

%hook DLDeviceFingerprint
- (void)p_uploadRequest:(id)a0 completion:(id /*block*/)a1 { %orig; }
- (void)p_retryUploadDeviceInfoCompletion:(id /*block*/)a0 { %orig; }
- (id) { return %orig; }
- (id) { return %orig; }
- (id) { return %orig; }
%end

%hook BDSMeiIDManager
- (id) { return %orig; }
%end

%hook ZOAUHandler
- (void)loginPre:(double)a0 ua:(id)a1 type:(int)a2 apiKey:(id)a3 RL:(id /*block*/)a4 ifDebug:(BOOL)a5 ifGM:(BOOL)a6 { %orig; }
- (id)loginPre:(id)a0 type:(id)a1 apiKey:(id)a2 RL:(id)a3 ifDebug:(id)a4 { return %orig; }
- (void)loginPre:(double)a0 type:(int)a1 apiKey:(id)a2 RL:(id /*block*/)a3 { %orig; }
%end

%hook SmAntiFraud
- (id) { return %orig; }
- (id) { return %orig; }
- (long long)check:(id)a0 { return %orig; }
- (void)startDetector:(id)a0 { %orig; }
%end

%hook BLYSDKManager
- (void)startWithAppInfo:(id)a0 delegate:(id)a1 { %orig; }
%end

%hook BDSettingViewController
- (void)viewWillAppear:(BOOL)a0 { %orig; }
- (id)viewDidAppear:(id)a0 { return %orig; }
- (id)viewDidDisappear:(id)a0 { return %orig; }
%end

%hook BDVisitorTopView
- (void)setVisitorCount:(id)a0 { %orig; }
%end

%hook BDVisitorHeaderNewView
- (void)setVisitorCount:(id)a0 { %orig; }
%end

