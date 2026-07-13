# Makefile — Build AMProjExport.dylib (package-intercept strategy)
# Requirements: macOS + Xcode CLT
# Usage: make

SDK  = $(shell xcrun --sdk iphoneos --show-sdk-path)
CC   = $(shell xcrun --sdk iphoneos -f clang)
CFLAGS = -arch arm64 -dynamiclib -isysroot $(SDK) \
         -miphoneos-version-min=14.0 -fobjc-arc -O2 \
         -framework Foundation -framework UIKit

all: AMProjExport.dylib

AMProjExport.dylib: AMProjExport.m
	$(CC) $(CFLAGS) -o $@ $^
	@ls -la $@

clean:
	rm -f AMProjExport.dylib
