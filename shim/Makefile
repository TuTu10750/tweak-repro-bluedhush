# Substrate shim — drop-in replacement for CydiaSubstrate's MSHookMessageEx.
# Ships next to BluedHushRE.dylib so self-signed / LiveContainer installs load.
TARGET := iphone:clang:latest:14.0
ARCHS  := arm64

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = substrate_shim
substrate_shim_FILES = SubstrateShim.m
substrate_shim_CFLAGS = -fobjc-arc -Wno-everything
substrate_shim_FRAMEWORKS = Foundation
substrate_shim_LDFLAGS = -install_name @rpath/libsubstrate_shim.dylib

include $(THEOS_MAKE_PATH)/library.mk
