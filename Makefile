TARGET := iphone:clang:latest:14.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = Blued

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BluedHushREA

BluedHushREA_FILES = Tweak.xm
BluedHushREA_CFLAGS = -fobjc-arc -Wno-objc-method-access -Wno-unused-parameter
BluedHushREA_FRAMEWORKS = Foundation UIKit CoreLocation

# v3 关键链接参数：
#   -install_name / @rpath  —— 不再留下 /Library/MobileSubstrate/... 这种 rootful 绝对 install_name
#   -dead_strip_dylibs      —— 把未使用的 -lsubstrate 依赖整条剥离（本工程不引用任何 substrate 符号）
BluedHushREA_LDFLAGS = -Wl,-install_name,@rpath/BluedHushREA.dylib -Wl,-dead_strip_dylibs

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 Blued || true"
