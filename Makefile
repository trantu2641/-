
TARGET := iphone:clang:latest:16.0
ARCHS := arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = NetworkMonitor

NetworkMonitor_FILES = Tweak.xm
NetworkMonitor_CFLAGS = -fobjc-arc
NetworkMonitor_FRAMEWORKS = Foundation UIKit SystemConfiguration
NetworkMonitor_PRIVATE_FRAMEWORKS = Preferences
NetworkMonitor_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 Preferences || true"
