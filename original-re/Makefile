# Recovered BluedHush 5.19 source tree — Theos build
TARGET := iphone:clang:latest:14.0
ARCHS  := arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BluedHushRE

BluedHushRE_FILES = $(wildcard Classes/*.m)
# HushReal.xm disabled for the minimal-loop run (114 classes / 286 methods,
# 194 of them untyped). Re-enable only after the table-driven layer is verified.
# BluedHushRE_FILES += Hooks/HushReal.xm
BluedHushRE_FILES += Hooks/HushEntry.xm
BluedHushRE_FILES += Hooks/SubstrateShim.m
BluedHushRE_FILES += Hooks/HushHooks.m
BluedHushRE_CFLAGS = -I$(THEOS_PROJECT_DIR)/Headers -fobjc-arc -Wno-everything -Wno-objc-method-access

# ---------------------------------------------------------------------------
# The hook layer is compiled WITHOUT ARC on purpose.
#
# Every hook body is a pure passthrough (`return %orig;`), but under ARC the
# compiler still materialises a __strong temporary for each object-typed
# parameter and calls objc_storeStrong() on it. When the real parameter is not
# an object — the canonical case is BDNetworkAgent
# -sessionTaskForRequest:error: whose error: is `NSError **` (encoding ^@) —
# that spurious retain reads a bogus isa and the app dies instantly:
#
#   #0 objc_retain        KERN_INVALID_ADDRESS at 0x20
#   #1 objc_storeStrong
#   #2 _logos_method$_ungrouped$BDNetworkAgent$sessionTaskForRequest$error$
#
# Two independent fixes are in place:
#   1. tools/gen_hooks2.py now emits the real signature read from the host
#      binary, so `error:` is typed `id *` and is never retained;
#   2. this file is MRC anyway, which covers any hook whose signature we could
#      not resolve and that therefore still falls back to `(id)`.
#
# The 76 recovered classes stay ARC — only this one translation unit opts out.
# ---------------------------------------------------------------------------
Hooks/HushReal.xm_CFLAGS = -fno-objc-arc
# Theos resolves per-file flags by several spellings depending on version, so
# declare the bare filename form as well; a no-op when unused.
HushReal.xm_CFLAGS = -fno-objc-arc

Hooks/HushHooks.m_CFLAGS = -fno-objc-arc
HushHooks.m_CFLAGS = -fno-objc-arc

BluedHushRE_FRAMEWORKS = Foundation UIKit CoreLocation QuartzCore MapKit QuickLook
BluedHushRE_LIBRARIES = sqlite3
BluedHushRE_PRIVATE_FRAMEWORKS =

include $(THEOS_MAKE_PATH)/tweak.mk
