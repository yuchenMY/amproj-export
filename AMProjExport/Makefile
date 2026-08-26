# Makefile - Build release, cloud telemetry, and debug AMProjExport dylibs
# Requirements: macOS + Xcode CLT
# Usage: make
#
# v45 起包含 AMProjTransform3D.m（空对象 3D 父级控制器的数学模块与
# meow3d.* 序列化，见 AMProjTransform3D.h）。

SDK  = $(shell xcrun --sdk iphoneos --show-sdk-path)
CC   = $(shell xcrun --sdk iphoneos -f clang)
CFLAGS = -arch arm64 -dynamiclib -isysroot $(SDK) \
         -miphoneos-version-min=14.0 -fobjc-arc -O2
LDLIBS = -framework Foundation -framework UIKit -framework QuartzCore \
         -framework CoreGraphics -framework Photos \
         -framework UniformTypeIdentifiers -lz

all: AMProjExport.dylib AMProjExportCloud.dylib AMProjExportDebug.dylib

AMProjExport.dylib: AMProjExport.m AMProjArchiveWriter.h AMProjZIPWriter.m AMProjZIPWriter.h AMProjImportArchive.m AMProjImportArchive.h AMProjNativeImportBridge.m AMProjNativeImportBridge.h AMProjNativeImportBridge.S AMProjTransform3D.m AMProjTransform3D.h
	$(CC) $(CFLAGS) -o $@ AMProjExport.m AMProjZIPWriter.m AMProjImportArchive.m AMProjNativeImportBridge.m AMProjNativeImportBridge.S AMProjTransform3D.m $(LDLIBS)
	@ls -la $@

AMProjExportCloud.dylib: AMProjExport.m AMProjArchiveWriter.h AMProjZIPWriter.m AMProjZIPWriter.h AMProjImportArchive.m AMProjImportArchive.h AMProjNativeImportBridge.m AMProjNativeImportBridge.h AMProjNativeImportBridge.S AMProjTransform3D.m AMProjTransform3D.h AMDebugTransport.m AMDebugTransport.h
	$(CC) $(CFLAGS) -DAMPROJ_TELEMETRY=1 -o $@ AMProjExport.m AMProjZIPWriter.m AMProjImportArchive.m AMProjNativeImportBridge.m AMProjNativeImportBridge.S AMProjTransform3D.m AMDebugTransport.m $(LDLIBS)
	@ls -la $@

AMProjExportDebug.dylib: AMProjExport.m AMProjArchiveWriter.h AMProjZIPWriter.m AMProjZIPWriter.h AMProjImportArchive.m AMProjImportArchive.h AMProjNativeImportBridge.m AMProjNativeImportBridge.h AMProjNativeImportBridge.S AMProjTransform3D.m AMProjTransform3D.h AMDebugTransport.m AMDebugTransport.h
	$(CC) $(CFLAGS) -DAMPROJ_DEBUG=1 -o $@ AMProjExport.m AMProjZIPWriter.m AMProjImportArchive.m AMProjNativeImportBridge.m AMProjNativeImportBridge.S AMProjTransform3D.m AMDebugTransport.m $(LDLIBS)
	@ls -la $@

clean:
	rm -f AMProjExport.dylib AMProjExportCloud.dylib AMProjExportDebug.dylib
