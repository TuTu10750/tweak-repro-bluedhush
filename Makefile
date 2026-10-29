TARGET := iphone:clang:latest:14.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = Blued

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BluedHushREA

BluedHushREA_FILES = Tweak.xm
BluedHushREA_CFLAGS = -fobjc-arc -Wno-objc-method-access
BluedHushREA_FRAMEWORKS = Foundation UIKit CoreLocation

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 Blued || true"
