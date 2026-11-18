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
# NOTE: fishtweak.plist 的 Filter 恢复为两条（与老版本完全一致）：
#         com.gzlj.fishdecisive    游戏进程启动即注入 —— IDFA/时间/VPN/缓存登录免验证码等老功能全靠这条，
#                                  且注入发生在登录前，登录包（账号/金币/最大炮倍）才接得住。
#         com.cyjh.MobileAnjiandjz 按键精灵进程启动即注入 —— 用于屏蔽它的开屏/弹窗广告。
#       注意：这两条是老功能，绝不能删。新功能（读四项 / 改炮倍 / 改倍率）走 daemon 8888 手动接口，
#       但"防二次注入"由 daemon 的 /inject 负责：它先 ping 插件 5399，活着就直接返回 already_running，
#       绝不再 cynject 一次（二次注入会打死钩子链，表现为卡登录、四项全 0）。
before-stage::
	chmod 755 layout/DEBIAN/postinst layout/DEBIAN/prerm
	@mkdir -p layout/Library/MobileSubstrate/DynamicLibraries
	@cp fishtweak.plist layout/Library/MobileSubstrate/DynamicLibraries/fishtweak.plist
	@cp $$(find . -name fishtweak.dylib -not -path "./layout/*" | head -1) layout/Library/MobileSubstrate/DynamicLibraries/fishtweak.dylib 2>/dev/null && echo "== DYLIB COPIED OK ==" || echo "== WARN: dylib not found =="
	@ls -l layout/DEBIAN/postinst layout/DEBIAN/prerm layout/Library/MobileSubstrate/DynamicLibraries/

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/tool.mk
