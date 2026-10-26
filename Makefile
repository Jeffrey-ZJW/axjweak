ARCHS = arm64
TARGET = iphone:clang:latest:12.0
include $(THEOS)/makefiles/common.mk
TWEAK_NAME = fishtweak
fishtweak_FILES = Tweak.xm
fishtweak_CFLAGS = -fobjc-arc
fishtweak_FRAMEWORKS = Foundation UIKit CoreServices AdSupport Security CFNetwork
fishtweak_LDFLAGS = -lsqlite3
SUBPROJECTS += daemon

# ---- Ensure DEBIAN maintainer scripts are executable ----
# Use before-stage:: (runs BEFORE layout is copied to stage dir, unlike
# before-package:: which runs after copying and has no effect on the .deb).
# git/zip upload loses exec bit; dpkg requires >=0555 <=0775.
# ALSO: manually copy the tweak dylib + Filter plist into layout,
# because theos may skip staging them when SUBPROJECTS is used.
before-stage::
	chmod 755 layout/DEBIAN/postinst layout/DEBIAN/prerm
	@mkdir -p layout/Library/MobileSubstrate/DynamicLibraries
	@cp $$(find "$(THEOS_OBJ_DIR)" -name fishtweak.dylib | head -1) layout/Library/MobileSubstrate/DynamicLibraries/fishtweak.dylib 2>/dev/null || echo "WARN: dylib not found"
	@cp fishtweak.plist layout/Library/MobileSubstrate/DynamicLibraries/fishtweak.plist
	@ls -l layout/DEBIAN/postinst layout/DEBIAN/prerm layout/Library/MobileSubstrate/DynamicLibraries/

include $(THEOS_MAKE_PATH)/aggregate.mk
