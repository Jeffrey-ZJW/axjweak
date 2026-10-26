ARCHS = arm64
TARGET = iphone:clang:latest:12.0
include $(THEOS)/makefiles/common.mk
TWEAK_NAME = fishtweak
fishtweak_FILES = Tweak.xm
fishtweak_CFLAGS = -fobjc-arc
fishtweak_FRAMEWORKS = Foundation UIKit CoreServices AdSupport Security CFNetwork
fishtweak_LDFLAGS = -lsqlite3
SUBPROJECTS += daemon
include $(THEOS_MAKE_PATH)/aggregate.mk
