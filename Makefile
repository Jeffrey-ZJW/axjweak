ARCHS = arm64
TARGET = iphone:clang:latest:12.0
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = fishtweak
fishtweak_FILES = Tweak.xm
fishtweak_CFLAGS = -fobjc-arc
fishtweak_FRAMEWORKS = Foundation UIKit CoreServices AdSupport Security CFNetwork
fishtweak_LDFLAGS = -lsqlite3

TOOL_NAME = fishtweakd
fishtweakd_FILES = daemon/daemon.m
fishtweakd_CFLAGS = -fobjc-arc
fishtweakd_FRAMEWORKS = Foundation Security CFNetwork
fishtweakd_LDFLAGS = -lsqlite3
fishtweakd_INSTALL_PATH = /usr/bin

INSTALL_TARGETS = fishtweak fishtweakd

# ---- Ensure DEBIAN maintainer scripts are executable ----
# before-stage:: runs BEFORE layout is copied to stage dir (before-package::
# runs after copying, no effect on .deb). git/zip upload loses exec bit;
# dpkg requires >=0555 <=0775.
# Also manually copy tweak dylib + Filter plist into layout as a safety net.
before-stage::
	chmod 755 layout/DEBIAN/postinst layout/DEBIAN/prerm
	@mkdir -p layout/Library/MobileSubstrate/DynamicLibraries
	@cp $$(find . -name fishtweak.dylib -not -path "./layout/*" | head -1) layout/Library/MobileSubstrate/DynamicLibraries/fishtweak.dylib 2>/dev/null && echo "== DYLIB COPIED OK ==" || echo "== WARN: dylib not found =="
	@cp fishtweak.plist layout/Library/MobileSubstrate/DynamicLibraries/fishtweak.plist
	@ls -l layout/DEBIAN/postinst layout/DEBIAN/prerm layout/Library/MobileSubstrate/DynamicLibraries/

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/tool.mk
