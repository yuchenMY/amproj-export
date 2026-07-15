SDK := $(shell xcrun --sdk iphoneos --show-sdk-path)
CC := $(shell xcrun --sdk iphoneos -f clang)

BUILD_DIR := build
APPEX_NAME := AMProjShareExtension.appex
APPEX_DIR := $(BUILD_DIR)/$(APPEX_NAME)
EXECUTABLE := $(APPEX_DIR)/AMProjShareExtension
OUTPUT_ENTITLEMENTS := $(BUILD_DIR)/AMProjShareExtension.entitlements

CFLAGS := -arch arm64 -isysroot $(SDK) -miphoneos-version-min=14.0 \
	-fobjc-arc -fapplication-extension -O2 -Wall -Wextra
LDFLAGS := -framework Foundation -framework UIKit -framework UniformTypeIdentifiers \
	-Xlinker -application_extension \
	-Xlinker -e -Xlinker _NSExtensionMain \
	-Xlinker -rpath -Xlinker @executable_path/Frameworks \
	-Xlinker -rpath -Xlinker @executable_path/../../Frameworks \
	-Xlinker -no_adhoc_codesign

.PHONY: all clean verify

all: $(EXECUTABLE) $(APPEX_DIR)/Info.plist $(OUTPUT_ENTITLEMENTS) verify

$(EXECUTABLE): AMProjShareViewController.m AMProjShareViewController.h
	@mkdir -p $(APPEX_DIR)
	$(CC) $(CFLAGS) -o $@ AMProjShareViewController.m $(LDFLAGS)

$(APPEX_DIR)/Info.plist: Info.plist
	@mkdir -p $(APPEX_DIR)
	cp $< $@

$(OUTPUT_ENTITLEMENTS): AMProjShareExtension.entitlements
	@mkdir -p $(BUILD_DIR)
	cp $< $@

verify: $(EXECUTABLE) $(APPEX_DIR)/Info.plist
	plutil -lint $(APPEX_DIR)/Info.plist
	file $(EXECUTABLE)

clean:
	rm -rf $(BUILD_DIR)
