export THEOS_PACKAGE_SCHEME = roothide
export ARCHS = arm64 arm64e
export TARGET = iphone:clang:16.5:15.0

INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = CallHider
CallHider_FILES = Tweak.xm
CallHider_CFLAGS = -fobjc-arc
CallHider_FRAMEWORKS = UIKit Foundation AudioToolbox

include $(THEOS)/makefiles/tweak.mk

SUBPROJECTS += callhiderprefs
include $(THEOS)/makefiles/aggregate.mk
