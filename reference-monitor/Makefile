TARGET := iphone:clang:latest:14.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = HushMonitorSafe
HushMonitorSafe_FILES = HushMonitor.m
HushMonitorSafe_CFLAGS = -fobjc-arc -Wno-everything \
                         -I$(THEOS_PROJECT_DIR)/../original-re/Headers \
                         -finput-charset=UTF-8 -fexec-charset=UTF-8
HushMonitorSafe_FRAMEWORKS = Foundation UIKit
HushMonitorSafe_LDFLAGS = -Wl,-install_name,@rpath/HushMonitorSafe.dylib \
                          -Wl,-dead_strip_dylibs

include $(THEOS_MAKE_PATH)/library.mk

