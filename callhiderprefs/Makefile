export ARCHS = arm64 arm64e
export TARGET = iphone:clang:16.5:15.0

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = CallHiderPrefs
CallHiderPrefs_FILES = CHRootListController.m CHContactsController.m
CallHiderPrefs_INSTALL_PATH = /Library/PreferenceBundles
CallHiderPrefs_FRAMEWORKS = UIKit Contacts ContactsUI
CallHiderPrefs_PRIVATE_FRAMEWORKS = Preferences
CallHiderPrefs_CFLAGS = -fobjc-arc

include $(THEOS)/makefiles/bundle.mk

internal-stage::
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences"$(ECHO_END)
	$(ECHO_NOTHING)cp entry.plist "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/CallHider.plist"$(ECHO_END)
