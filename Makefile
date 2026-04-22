.THEOSDEVICE_VERSION := 14.5

ARCHS = arm64
TARGET = iphone:latest:14.5
INSTALL_TARGET_PROCESSES = wework

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WeWorkIPadLogin
$(TWEAK_NAME)_FILES = Tweak.xm
$(TWEAK_NAME)_FRAMEWORKS = UIKit Foundation
$(TWEAK_NAME)_CFLAGS = -fno-objc-arc -w -DSUBSTRATE_TARGET_IPHONE
$(TWEAK_NAME)_LDFLAGS = -lz

include $(THEOS)/makefiles/tweak.mk
