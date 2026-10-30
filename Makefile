TARGET := iphone:clang:latest:14.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = Blued

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BluedHushREA

# v9：拆成两个编译单元
#   Tweak.xm  —— Hook 引擎（Runtime 换实现 + 36 个目标 selector + 报告）
#   REAUI.xm  —— 交互层（悬浮球 / 分类菜单 / 开关面板，复刻原版 HushFloatBall + HushSettingsPanel）
#
# v13.0 新增 M-1 取证变体（make M1=1）：
#   M1Trace.xm —— 只含观测埋点，不装任何净化锚点、不改任何宿主行为
#   TWEAK_NAME / install_name / plist 全部不变，安装路径与 v12 完全一致
#   这样"换不换观察员"只有一行 Makefile 的差别，不引入第二个变量
ifeq ($(M1),1)
BluedHushREA_FILES = M1Trace.xm
else
BluedHushREA_FILES = Tweak.xm REAUI.xm
endif
BluedHushREA_CFLAGS = -fobjc-arc -Wno-objc-method-access -Wno-unused-parameter -Wno-deprecated-declarations
BluedHushREA_FRAMEWORKS = Foundation UIKit CoreLocation

# v3 关键链接参数：
#   -install_name / @rpath  —— 不再留下 /Library/MobileSubstrate/... 这种 rootful 绝对 install_name
#   -dead_strip_dylibs      —— 把未使用的 -lsubstrate 依赖整条剥离（本工程不引用任何 substrate 符号）
BluedHushREA_LDFLAGS = -Wl,-install_name,@rpath/BluedHushREA.dylib -Wl,-dead_strip_dylibs

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 Blued || true"
