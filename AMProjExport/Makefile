# Makefile - Build release, cloud telemetry, and debug AMProjExport dylibs
# Requirements: macOS + Xcode CLT
# Usage: make

SDK  = $(shell xcrun --sdk iphoneos --show-sdk-path)
CC   = $(shell xcrun --sdk iphoneos -f clang)
LEGACY_862 ?= 0
DIAGNOSTIC_BUILD_ID ?= $(shell git rev-parse --short=12 HEAD)-beta
RELEASE_CODE ?= 180
CLIENT_BUILD_ID ?= $(shell git rev-parse --short=12 HEAD)
CLIENT_RELEASE_DATE ?= $(shell TZ=Asia/Shanghai date +%Y%m%d)
CFLAGS = -arch arm64 -dynamiclib -isysroot $(SDK) \
         -miphoneos-version-min=14.0 -fobjc-arc -O2 \
         -DAMPROJ_RELEASE_CODE=$(RELEASE_CODE) -DAMPROJ_CLIENT_BUILD_ID='"$(CLIENT_BUILD_ID)"' \
         -DAMPROJ_CLIENT_RELEASE_DATE='"$(CLIENT_RELEASE_DATE)"'
LOADER_CFLAGS = -arch arm64 -dynamiclib -isysroot $(SDK) \
                -miphoneos-version-min=14.0 -O2
LDLIBS = -framework Foundation -framework UIKit -framework QuartzCore \
         -framework CoreGraphics -framework Photos -framework AVFoundation -framework CoreMedia \
         -framework UniformTypeIdentifiers -framework SafariServices -lz

.PHONY: all clean legacy-loader

all: AMProjExport.dylib AMProjExportDebug.dylib AMHomeUI.dylib AMProjExportBeta.dylib

AMProjExport.dylib: AMProjExport.m AMProjArchiveWriter.h AMProjZIPWriter.m AMProjZIPWriter.h AMProjImportArchive.m AMProjImportArchive.h AMProjNativeImportBridge.m AMProjNativeImportBridge.h AMProjNativeImportBridge.S AMProjStabilityContract.S AMProjV865ProjectFlow.m AMProjV865ProjectFlow.h AMDebugTransport.m AMDebugTransport.h AMCloudSync.m AMCloudSync.h AMCloudPlugins.m AMCloudPlugins.h AMEditorCustomization.m AMEditorCustomization.h AMProjCrashReporter.m AMProjCrashReporter.h
AMProjExport.dylib: AMCloudTabPolicy.h AMClientRelease.m AMClientRelease.h AMClientReleasePolicy.h AMClientPackageIdentity.h AMAppUpdate.m AMAppUpdate.h AMAppUpdatePolicy.h
	$(CC) $(CFLAGS) -DAMPROJ_ENABLE_LEGACY_862=$(LEGACY_862) -DAMPROJ_TELEMETRY=1 -DAMPROJ_CLOUD_SYNC=1 -o $@ AMProjExport.m AMProjZIPWriter.m AMProjImportArchive.m AMProjNativeImportBridge.m AMProjNativeImportBridge.S AMProjStabilityContract.S AMProjV865ProjectFlow.m AMDebugTransport.m AMCloudSync.m AMClientRelease.m AMAppUpdate.m AMCloudPlugins.m AMEditorCustomization.m AMProjCrashReporter.m $(LDLIBS) -framework Security -framework WebKit -install_name @rpath/AMProjExport.dylib
	@ls -la $@

AMProjExportOffline.dylib: AMProjExport.m AMProjArchiveWriter.h AMProjZIPWriter.m AMProjZIPWriter.h AMProjImportArchive.m AMProjImportArchive.h AMProjNativeImportBridge.m AMProjNativeImportBridge.h AMProjNativeImportBridge.S AMProjStabilityContract.S AMProjV865ProjectFlow.m AMProjV865ProjectFlow.h AMProjCrashReporter.m AMProjCrashReporter.h
	$(CC) $(CFLAGS) -DAMPROJ_ENABLE_LEGACY_862=$(LEGACY_862) -o $@ AMProjExport.m AMProjZIPWriter.m AMProjImportArchive.m AMProjNativeImportBridge.m AMProjNativeImportBridge.S AMProjStabilityContract.S AMProjV865ProjectFlow.m AMProjCrashReporter.m $(LDLIBS) -install_name @rpath/AMProjExportOffline.dylib
	@ls -la $@

AMProjExportDebug.dylib: AMProjExport.m AMProjArchiveWriter.h AMProjZIPWriter.m AMProjZIPWriter.h AMProjImportArchive.m AMProjImportArchive.h AMProjNativeImportBridge.m AMProjNativeImportBridge.h AMProjNativeImportBridge.S AMProjStabilityContract.S AMProjV865ProjectFlow.m AMProjV865ProjectFlow.h AMDebugTransport.m AMDebugTransport.h AMProjCrashReporter.m AMProjCrashReporter.h
	$(CC) $(CFLAGS) -DAMPROJ_ENABLE_LEGACY_862=$(LEGACY_862) -DAMPROJ_DEBUG=1 -o $@ AMProjExport.m AMProjZIPWriter.m AMProjImportArchive.m AMProjNativeImportBridge.m AMProjNativeImportBridge.S AMProjStabilityContract.S AMProjV865ProjectFlow.m AMDebugTransport.m AMProjCrashReporter.m $(LDLIBS)
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
		-framework CoreGraphics -framework WebKit -framework CoreText \
		-install_name @rpath/AMHomeUI.dylib
	@ls -la $@

AMProjThreadProbe.o: AMProjThreadProbe.c AMProjThreadProbe.h
	$(CC) $(filter-out -dynamiclib -fobjc-arc,$(CFLAGS)) -Wall -Wextra -Werror -c AMProjThreadProbe.c -o $@

AMProjExportBeta.dylib: AMProjExport.dylib AMProjBetaDiagnostics.m AMProjBetaDiagnostics.h AMProjPerformancePolicy.h AMProjPerformanceReport.h AMProjThreadProbe.o AMAppUpdate.m AMAppUpdate.h AMAppUpdatePolicy.h
	$(CC) $(CFLAGS) -DAMPROJ_ENABLE_LEGACY_862=$(LEGACY_862) -DAMPROJ_TELEMETRY=1 -DAMPROJ_CLOUD_SYNC=1 -DAMPROJ_BETA_DIAGNOSTICS=1 -DAMPROJ_DIAGNOSTIC_BUILD_ID='"$(DIAGNOSTIC_BUILD_ID)"' -o $@ AMProjExport.m AMProjZIPWriter.m AMProjImportArchive.m AMProjNativeImportBridge.m AMProjNativeImportBridge.S AMProjStabilityContract.S AMProjV865ProjectFlow.m AMDebugTransport.m AMCloudSync.m AMClientRelease.m AMAppUpdate.m AMCloudPlugins.m AMEditorCustomization.m AMProjCrashReporter.m AMProjBetaDiagnostics.m AMProjThreadProbe.o $(LDLIBS) -framework Security -framework WebKit -install_name @rpath/AMProjExport.dylib
	@ls -la $@

clean:
	rm -f AMProjExportBeta.dylib AMProjThreadProbe.o
	rm -f AMProjExport.dylib AMProjExportOffline.dylib AMProjExportDebug.dylib AMMeowLoader.dylib AMHomeUI.dylib
