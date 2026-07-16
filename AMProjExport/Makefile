# Makefile — Build release and debug AMProjExport dylibs
# Requirements: macOS + Xcode CLT
# Usage: make

SDK  = $(shell xcrun --sdk iphoneos --show-sdk-path)
CC   = $(shell xcrun --sdk iphoneos -f clang)
CFLAGS = -arch arm64 -dynamiclib -isysroot $(SDK) \
         -miphoneos-version-min=14.0 -fobjc-arc -O2
LDLIBS = -framework Foundation -framework UIKit -framework QuartzCore \
         -framework CoreGraphics -framework Photos \
         -framework UniformTypeIdentifiers -lz

all: AMProjExport.dylib AMProjExportDebug.dylib

AMProjExport.dylib: AMProjExport.m AMProjArchiveWriter.h AMProjZIPWriter.m AMProjZIPWriter.h AMProjImportArchive.m AMProjImportArchive.h
	$(CC) $(CFLAGS) -o $@ AMProjExport.m AMProjZIPWriter.m AMProjImportArchive.m $(LDLIBS)
	@ls -la $@

AMProjExportDebug.dylib: AMProjExport.m AMProjArchiveWriter.h AMProjZIPWriter.m AMProjZIPWriter.h AMProjImportArchive.m AMProjImportArchive.h AMDebugTransport.m AMDebugTransport.h
	$(CC) $(CFLAGS) -DAMPROJ_DEBUG=1 -o $@ AMProjExport.m AMProjZIPWriter.m AMProjImportArchive.m AMDebugTransport.m $(LDLIBS)
	@ls -la $@

clean:
	rm -f AMProjExport.dylib AMProjExportDebug.dylib
