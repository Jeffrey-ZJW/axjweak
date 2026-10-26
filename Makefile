ARCHS = arm64
TARGET = iphone:clang:latest:12.0
include $(THEOS)/makefiles/common.mk
TWEAK_NAME = fishtweak
fishtweak_FILES = Tweak.xm
fishtweak_CFLAGS = -fobjc-arc
fishtweak_FRAMEWORKS = Foundation UIKit CoreServices AdSupport Security CFNetwork
fishtweak_LDFLAGS = -lsqlite3
SUBPROJECTS += daemon

# ---- Ensure DEBIAN maintainer scripts are executable before packaging ----
# (git/zip upload loses exec bit; dpkg requires >=0555 <=0775) ----
before-package::
	chmod 755 layout/DEBIAN/postinst layout/DEBIAN/prerm
	@ls -l layout/DEBIAN/postinst layout/DEBIAN/prerm

include $(THEOS_MAKE_PATH)/aggregate.mk
