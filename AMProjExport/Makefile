# Makefile - Build release, cloud telemetry, and debug AMProjExport dylibs
# Requirements: macOS + Xcode CLT
# Usage: make

SDK  = $(shell xcrun --sdk iphoneos --show-sdk-path)
CC   = $(shell xcrun --sdk iphoneos -f clang)
LEGACY_862 ?= 0
CFLAGS = -arch arm64 -dynamiclib -isysroot $(SDK) \
         -miphoneos-version-min=14.0 -fobjc-arc -O2
LOADER_CFLAGS = -arch arm64 -dynamiclib -isysroot $(SDK) \
                -miphoneos-version-min=14.0 -O2
LDLIBS = -framework Foundation -framework UIKit -framework QuartzCore \
         -framework CoreGraphics -framework Photos \
         -framework UniformTypeIdentifiers -lz

.PHONY: all clean legacy-loader

all: AMProjExport.dylib AMProjExportDebug.dylib AMHomeUI.dylib

AMProjExport.dylib: AMProjExport.m AMProjArchiveWriter.h AMProjZIPWriter.m AMProjZIPWriter.h AMProjImportArchive.m AMProjImportArchive.h AMProjNativeImportBridge.m AMProjNativeImportBridge.h AMProjNativeImportBridge.S AMProjStabilityContract.S AMDebugTransport.m AMDebugTransport.h AMCloudSync.m AMCloudSync.h AMCloudPlugins.m AMCloudPlugins.h AMEditorCustomization.m AMEditorCustomization.h
	$(CC) $(CFLAGS) -DAMPROJ_ENABLE_LEGACY_862=$(LEGACY_862) -DAMPROJ_TELEMETRY=1 -DAMPROJ_CLOUD_SYNC=1 -o $@ AMProjExport.m AMProjZIPWriter.m AMProjImportArchive.m AMProjNativeImportBridge.m AMProjNativeImportBridge.S AMProjStabilityContract.S AMDebugTransport.m AMCloudSync.m AMCloudPlugins.m AMEditorCustomization.m $(LDLIBS) -framework Security -framework WebKit -install_name @rpath/AMProjExport.dylib
	@ls -la $@

AMProjExportOffline.dylib: AMProjExport.m AMProjArchiveWriter.h AMProjZIPWriter.m AMProjZIPWriter.h AMProjImportArchive.m AMProjImportArchive.h AMProjNativeImportBridge.m AMProjNativeImportBridge.h AMProjNativeImportBridge.S AMProjStabilityContract.S
	$(CC) $(CFLAGS) -DAMPROJ_ENABLE_LEGACY_862=$(LEGACY_862) -o $@ AMProjExport.m AMProjZIPWriter.m AMProjImportArchive.m AMProjNativeImportBridge.m AMProjNativeImportBridge.S AMProjStabilityContract.S $(LDLIBS) -install_name @rpath/AMProjExportOffline.dylib
	@ls -la $@

AMProjExportDebug.dylib: AMProjExport.m AMProjArchiveWriter.h AMProjZIPWriter.m AMProjZIPWriter.h AMProjImportArchive.m AMProjImportArchive.h AMProjNativeImportBridge.m AMProjNativeImportBridge.S AMProjStabilityContract.S AMDebugTransport.m AMDebugTransport.h
	$(CC) $(CFLAGS) -DAMPROJ_ENABLE_LEGACY_862=$(LEGACY_862) -DAMPROJ_DEBUG=1 -o $@ AMProjExport.m AMProjZIPWriter.m AMProjImportArchive.m AMProjNativeImportBridge.m AMProjNativeImportBridge.S AMProjStabilityContract.S AMDebugTransport.m $(LDLIBS)
	@ls -la $@

AMMeowLoader.dylib: AMMeowLoader.c
	$(CC) $(LOADER_CFLAGS) -Wall -Wextra -Werror -o $@ $< -install_name @rpath/AMMeowLoader.dylib
	@ls -la $@

# Historical fallback only. Build 865 strongly loads AMProjExport.dylib and
# must not ship this loader, otherwise the release library can initialize twice.
legacy-loader: AMMeowLoader.dylib

AMHomeUI.dylib: AMHomeUI.m AMHomeUI.h
	$(CC) $(CFLAGS) -Wall -Wextra -Werror -o $@ AMHomeUI.m \
		-framework Foundation -framework UIKit -framework QuartzCore \
		-framework CoreGraphics -framework WebKit -install_name @rpath/AMHomeUI.dylib
	@ls -la $@

clean:
	rm -f AMProjExport.dylib AMProjExportOffline.dylib AMProjExportDebug.dylib AMMeowLoader.dylib AMHomeUI.dylib
