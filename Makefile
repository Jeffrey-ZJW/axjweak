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
# NOTE: 包里装的 fishtweak.plist 的 Filter 只匹配按键精灵 "com.cyjh.MobileAnjiandjz"，
#       故意不匹配游戏 com.gzlj.fishdecisive —— 游戏侧改为手动注入（daemon POST /inject），
#       避免「没调注入命令就自动进了插件」导致卡登录 / 钩子二次挂载。
#       按键精灵侧必须自动注入，因为广告屏蔽（Tweak.xm v3.3）只在按键精灵进程里生效；
#       该进程里 FishState 的 %ctor 会因 !is_game_process() 直接 return，
#       不起 5399 端口、不写 fish_state.json、不挂网络 hook，与游戏侧互不干扰。
#       需要恢复游戏自动注入时，把仓库里的 fishtweak.plist.sample 覆盖到
#       /Library/MobileSubstrate/DynamicLibraries/fishtweak.plist 再 respring。
before-stage::
	chmod 755 layout/DEBIAN/postinst layout/DEBIAN/prerm
	@mkdir -p layout/Library/MobileSubstrate/DynamicLibraries
	@cp fishtweak.plist layout/Library/MobileSubstrate/DynamicLibraries/fishtweak.plist
	@cp $$(find . -name fishtweak.dylib -not -path "./layout/*" | head -1) layout/Library/MobileSubstrate/DynamicLibraries/fishtweak.dylib 2>/dev/null && echo "== DYLIB COPIED OK ==" || echo "== WARN: dylib not found =="
	@ls -l layout/DEBIAN/postinst layout/DEBIAN/prerm layout/Library/MobileSubstrate/DynamicLibraries/

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/tool.mk
