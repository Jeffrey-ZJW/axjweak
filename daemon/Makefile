ARCHS = arm64
TARGET = iphone:clang:latest:12.0
include $(THEOS)/makefiles/common.mk
TOOL_NAME = fishtweakd
fishtweakd_FILES = daemon.m
fishtweakd_CFLAGS = -fobjc-arc
fishtweakd_FRAMEWORKS = Foundation Security CFNetwork
include $(THEOS_MAKE_PATH)/tool.mk
