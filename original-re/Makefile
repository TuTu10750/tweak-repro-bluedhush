# Recovered BluedHush 5.19 source tree — Theos build
TARGET := iphone:clang:latest:14.0
ARCHS  := arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BluedHushRE

BluedHushRE_FILES = $(wildcard Classes/*.m)
BluedHushRE_FILES += Hooks/Hooks.generated.xm
BluedHushRE_CFLAGS = -fobjc-arc -Wno-everything -Wno-objc-method-access
BluedHushRE_FRAMEWORKS = Foundation UIKit CoreLocation QuartzCore MapKit QuickLook
BluedHushRE_PRIVATE_FRAMEWORKS =
BluedHushRE_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk
