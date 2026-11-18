ARCHS = arm64
TARGET = iphone:clang:latest:12.0
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = fishtweak
fishtweak_FILES = Tweak.xm FishState.xm
fishtweak_CFLAGS = -fobjc-arc
fishtweak_FRAMEWORKS = Foundation UIKit CoreServices AdSupport Security CFNetwork
fishtweak_LIBRARIES = substrate
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
# NOTE: 不再安装 fishtweak.plist —— 带 Filter 的 plist 会让 Substrate 在游戏/按键精灵
#       启动时自动注入，导致「没调注入命令也进了插件、进而卡住登录/钩子二次挂载」。
#       本插件采用手动注入（daemon POST /inject），因此包里只放 dylib，不放 Filter plist。
#       需要自动注入时，把仓库里的 fishtweak.plist.sample 拷进
#       /Library/MobileSubstrate/DynamicLibraries/fishtweak.plist 再 respring。
before-stage::
	chmod 755 layout/DEBIAN/postinst layout/DEBIAN/prerm
	@mkdir -p layout/Library/MobileSubstrate/DynamicLibraries
	@rm -f layout/Library/MobileSubstrate/DynamicLibraries/fishtweak.plist
	@cp $$(find . -name fishtweak.dylib -not -path "./layout/*" | head -1) layout/Library/MobileSubstrate/DynamicLibraries/fishtweak.dylib 2>/dev/null && echo "== DYLIB COPIED OK ==" || echo "== WARN: dylib not found =="
	@ls -l layout/DEBIAN/postinst layout/DEBIAN/prerm layout/Library/MobileSubstrate/DynamicLibraries/

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/tool.mk
