ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:12.0
INSTALL_TARGET_PROCESSES = 捕鱼大决战

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = fishtweak

fishtweak_FILES = Tweak.xm
fishtweak_CFLAGS = -fobjc-arc
fishtweak_FRAMEWORKS = Foundation UIKit CoreServices AdSupport

include $(THEOS_MAKE_PATH)/tweak.mk
