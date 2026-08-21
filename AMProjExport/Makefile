# Makefile - Build release, cloud telemetry, and debug AMProjExport dylibs
# Requirements: macOS + Xcode CLT
# Usage: make

SDK  = $(shell xcrun --sdk iphoneos --show-sdk-path)
CC   = $(shell xcrun --sdk iphoneos -f clang)
CFLAGS = -arch arm64 -dynamiclib -isysroot $(SDK) \
         -miphoneos-version-min=14.0 -fobjc-arc -O2
LOADER_CFLAGS = -arch arm64 -dynamiclib -isysroot $(SDK) \
                -miphoneos-version-min=14.0 -O2
LDLIBS = -framework Foundation -framework UIKit -framework QuartzCore \
         -framework CoreGraphics -framework Photos \
         -framework UniformTypeIdentifiers -lz

all: AMProjExport.dylib AMProjExportCloud.dylib AMProjExportDebug.dylib AMMeowLoader.dylib

AMProjExport.dylib: AMProjExport.m AMProjArchiveWriter.h AMProjZIPWriter.m AMProjZIPWriter.h AMProjImportArchive.m AMProjImportArchive.h AMProjNativeImportBridge.m AMProjNativeImportBridge.h AMProjNativeImportBridge.S AMProjStabilityContract.S
	$(CC) $(CFLAGS) -o $@ AMProjExport.m AMProjZIPWriter.m AMProjImportArchive.m AMProjNativeImportBridge.m AMProjNativeImportBridge.S AMProjStabilityContract.S $(LDLIBS)
	@ls -la $@

AMProjExportCloud.dylib: AMProjExport.m AMProjArchiveWriter.h AMProjZIPWriter.m AMProjZIPWriter.h AMProjImportArchive.m AMProjImportArchive.h AMProjNativeImportBridge.m AMProjNativeImportBridge.h AMProjNativeImportBridge.S AMProjStabilityContract.S AMDebugTransport.m AMDebugTransport.h AMCloudSync.m AMCloudSync.h AMCloudPlugins.m AMCloudPlugins.h AMEditorCustomization.m AMEditorCustomization.h AMHomeUI.m AMHomeUI.h
	$(CC) $(CFLAGS) -DAMPROJ_TELEMETRY=1 -DAMPROJ_CLOUD_SYNC=1 -o $@ AMProjExport.m AMProjZIPWriter.m AMProjImportArchive.m AMProjNativeImportBridge.m AMProjNativeImportBridge.S AMProjStabilityContract.S AMDebugTransport.m AMCloudSync.m AMCloudPlugins.m AMEditorCustomization.m AMHomeUI.m $(LDLIBS) -framework Security -framework WebKit
	@ls -la $@

AMProjExportDebug.dylib: AMProjExport.m AMProjArchiveWriter.h AMProjZIPWriter.m AMProjZIPWriter.h AMProjImportArchive.m AMProjImportArchive.h AMProjNativeImportBridge.m AMProjNativeImportBridge.h AMProjNativeImportBridge.S AMProjStabilityContract.S AMDebugTransport.m AMDebugTransport.h
	$(CC) $(CFLAGS) -DAMPROJ_DEBUG=1 -o $@ AMProjExport.m AMProjZIPWriter.m AMProjImportArchive.m AMProjNativeImportBridge.m AMProjNativeImportBridge.S AMProjStabilityContract.S AMDebugTransport.m $(LDLIBS)
	@ls -la $@

AMMeowLoader.dylib: AMMeowLoader.c
	$(CC) $(LOADER_CFLAGS) -Wall -Wextra -Werror -o $@ $< -install_name @rpath/AMMeowLoader.dylib
	@ls -la $@

clean:
	rm -f AMProjExport.dylib AMProjExportCloud.dylib AMProjExportDebug.dylib AMMeowLoader.dylib
