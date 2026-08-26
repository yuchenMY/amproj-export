# Makefile — 独立构建 AM3D.dylib（空对象 3D 渲染桥，与 AMProjExport 完全独立）
# Requirements: macOS + Xcode CLT
# Usage: make

SDK  = $(shell xcrun --sdk iphoneos --show-sdk-path)
CC   = $(shell xcrun --sdk iphoneos -f clang)
CFLAGS = -arch arm64 -dynamiclib -isysroot $(SDK) \
         -miphoneos-version-min=14.0 -fobjc-arc -O2
LDLIBS = -framework Foundation -framework UIKit -framework QuartzCore

all: AM3D.dylib

AM3D.dylib: AM3D.m AM3D.h AM3DTransform3D.m AM3DTransform3D.h
	$(CC) $(CFLAGS) -o $@ AM3D.m AM3DTransform3D.m $(LDLIBS)
	@ls -la $@

clean:
	rm -f AM3D.dylib
