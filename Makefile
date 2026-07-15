# Compiler and SDK settings
CC ?= $(shell which clang || echo clang)
CXX ?= $(shell which clang++ || echo clang++)

# SDK path (override via `make SDKROOT=…`). Resolved unconditionally so that
# building a target by its file path (e.g. `make build/libHider.dylib`) works —
# the old goal-name filter left SDKROOT empty for those, breaking the compile.
SDKROOT ?= $(shell xcrun --show-sdk-path 2>/dev/null || echo /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk)

# Compiler and flags
# -Werror: treat warnings as errors (strict compilation)
CFLAGS = -Wall -Wextra -Werror \
    -Wstrict-prototypes \
    -Wmissing-prototypes \
    -Wstrict-aliasing=2 \
    -Wcast-align \
    -Wconversion \
    -Wsign-conversion \
    -Wfloat-equal \
    -Wshadow \
    -Wunused \
    -Wunused-parameter \
    -Wunused-variable \
    -Wunused-function \
    -Wpedantic \
    -Wextra-semi \
    -Wnullability-completeness \
    -Wobjc-method-access \
    -Wstrict-selector-match \
    -Wundeclared-selector \
    -Wdeprecated-implementations \
    -Wgnu-zero-variadic-macro-arguments \
    -Wformat-pedantic \
    -Wdollar-in-identifier-extension \
    -Wlanguage-extension-token \
    -Wgnu-pointer-arith \
    -O2 \
    -fobjc-arc \
    -isysroot $(SDKROOT) \
    -iframework $(SDKROOT)/System/Library/Frameworks \
    -F/System/Library/PrivateFrameworks \
    -Isrc
ARCHS = -arch x86_64 -arch arm64 -arch arm64e
FRAMEWORK_PATH = $(SDKROOT)/System/Library/Frameworks
PRIVATE_FRAMEWORK_PATH = $(SDKROOT)/System/Library/PrivateFrameworks
PUBLIC_FRAMEWORKS = -framework Foundation -framework AppKit -framework QuartzCore -framework Cocoa \
    -framework CoreFoundation -framework ApplicationServices

# Project name and paths
PROJECT = hider
DYLIB_NAME = libHider.dylib
BUILD_DIR = build
SOURCE_DIR = src
INSTALL_DIR = /var/ammonia/core/tweaks

# Source files
DYLIB_SOURCES = $(SOURCE_DIR)/Hider.m
DYLIB_OBJECTS = $(DYLIB_SOURCES:%.m=$(BUILD_DIR)/%.o)

APP_NAME = Hider
APP_ID = com.aspauldingcode.hider
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
APP_BINARY = $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
CLI_BINARY = $(BUILD_DIR)/hiderctl
SWIFT_RELEASE_DIR = .build/release
SWIFT_BUILD_STAMP = $(BUILD_DIR)/.swift-release.stamp
SWIFT_SOURCES = Package.swift $(shell find Sources src Tests -type f \( -name '*.swift' -o -name '*.c' -o -name '*.h' \))
SWIFT_BUILD_ENV = CLANG_MODULE_CACHE_PATH=$(CURDIR)/.build/clang-module-cache \
	SWIFTPM_MODULECACHE_OVERRIDE=$(CURDIR)/.build/swiftpm-module-cache
SWIFT_BUILD_FLAGS ?= --disable-sandbox -debug-info-format none

# Installation targets
INSTALL_PATH = $(INSTALL_DIR)/$(DYLIB_NAME)
BIN_INSTALL_DIR = /usr/local/bin
WHITELIST_SOURCE = lib$(PROJECT).dylib.whitelist
WHITELIST_DEST = $(INSTALL_DIR)/lib$(PROJECT).dylib.whitelist
LAUNCH_AGENT_PLIST = com.aspauldingcode.hider.plist
LAUNCH_AGENT_DEST = $(HOME)/Library/LaunchAgents/$(LAUNCH_AGENT_PLIST)

# Installer package settings
PKG_NAME = $(PROJECT)-installer
PKG_VERSION = 1.0.0
PKG_IDENTIFIER = com.$(PROJECT).installer
PKG_FILE = $(PKG_NAME).pkg
PKG_ROOT = $(BUILD_DIR)/pkg_root
PKG_SCRIPTS = $(BUILD_DIR)/pkg_scripts

# Dylib settings
DYLIB_FLAGS = -dynamiclib \
              -install_name @rpath/$(DYLIB_NAME) \
              -compatibility_version 1.0.0 \
              -current_version 1.0.0

# Default target - build the dylib, app bundle, and CLI
all: $(BUILD_DIR)/$(DYLIB_NAME) $(APP_BUNDLE) $(CLI_BINARY)

# Explicit build target
compile: all

# Create build directory and subdirectories
$(BUILD_DIR):
	@mkdir -p $(BUILD_DIR)
	@mkdir -p $(BUILD_DIR)/src

# Compile source files
$(BUILD_DIR)/%.o: %.m
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) $(ARCHS) -c $< -o $@

# Link dylib
$(BUILD_DIR)/$(DYLIB_NAME): $(DYLIB_OBJECTS) | $(BUILD_DIR)
	$(CC) $(DYLIB_FLAGS) $(ARCHS) $(DYLIB_OBJECTS) -o $@ \
	-F$(FRAMEWORK_PATH) \
	-F$(PRIVATE_FRAMEWORK_PATH) \
	$(PUBLIC_FRAMEWORKS) \
	-L$(SDKROOT)/usr/lib
	@echo "Cleaning intermediate build files..."
	@find $(BUILD_DIR) -name "*.o" -delete
	@find $(BUILD_DIR) -type d -empty -delete
	@echo "Dylib build complete: $@"

# Build all Swift targets with SwiftPM.
$(SWIFT_BUILD_STAMP): $(SWIFT_SOURCES) | $(BUILD_DIR)
	$(SWIFT_BUILD_ENV) swift build -c release $(SWIFT_BUILD_FLAGS)
	@touch $@

# Assemble and ad-hoc sign the desktop application bundle.
$(APP_BUNDLE): $(SWIFT_BUILD_STAMP)
	@echo "Assembling Hider.app..."
	@rm -rf $@
	@mkdir -p $@/Contents/MacOS
	@cp $(SWIFT_RELEASE_DIR)/HiderApp $(APP_BINARY)
	@plutil -create xml1 $@/Contents/Info.plist
	@plutil -insert CFBundleExecutable -string Hider $@/Contents/Info.plist
	@plutil -insert CFBundleIdentifier -string $(APP_ID) $@/Contents/Info.plist
	@plutil -insert CFBundleName -string Hider $@/Contents/Info.plist
	@plutil -insert CFBundlePackageType -string APPL $@/Contents/Info.plist
	@plutil -insert CFBundleShortVersionString -string 1.0.0 $@/Contents/Info.plist
	@plutil -insert CFBundleVersion -string 1 $@/Contents/Info.plist
	@plutil -insert LSMinimumSystemVersion -string 26.0 $@/Contents/Info.plist
	@plutil -lint $@/Contents/Info.plist
	@codesign --force --sign - $@

$(CLI_BINARY): $(SWIFT_BUILD_STAMP)
	@cp $(SWIFT_RELEASE_DIR)/hiderctl $@
	@chmod 755 $@

# Create installer package
installER: $(BUILD_DIR)/$(DYLIB_NAME)
	@echo "Creating installer package..."
	@mkdir -p $(PKG_ROOT)$(INSTALL_DIR)
	@mkdir -p $(PKG_SCRIPTS)
	
	# Copy dylib to package root
	@cp $(BUILD_DIR)/$(DYLIB_NAME) $(PKG_ROOT)$(INSTALL_DIR)/
	@chmod 755 $(PKG_ROOT)$(INSTALL_DIR)/$(DYLIB_NAME)
	
	# Copy whitelist if it exists
	@if [ -f $(WHITELIST_SOURCE) ]; then \
		cp $(WHITELIST_SOURCE) $(PKG_ROOT)$(INSTALL_DIR)/; \
		chmod 644 $(PKG_ROOT)$(INSTALL_DIR)/$(WHITELIST_SOURCE); \
	fi
	
	# Create postinstall script
	@echo '#!/bin/bash' > $(PKG_SCRIPTS)/postinstall
	@echo 'echo "$(PROJECT) tweak installed successfully"' >> $(PKG_SCRIPTS)/postinstall
	@echo 'echo "Restarting Dock to load tweak..."' >> $(PKG_SCRIPTS)/postinstall
	@echo 'killall Dock 2>/dev/null || true' >> $(PKG_SCRIPTS)/postinstall
	@echo 'exit 0' >> $(PKG_SCRIPTS)/postinstall
	@chmod +x $(PKG_SCRIPTS)/postinstall
	
	# Build the package
	@pkgbuild --root $(PKG_ROOT) \
		--scripts $(PKG_SCRIPTS) \
		--identifier $(PKG_IDENTIFIER) \
		--version $(PKG_VERSION) \
		--install-location / \
		$(PKG_FILE)
	
	@chmod 755 $(PKG_FILE)
	@echo "Installer package created: $(PKG_FILE)"

# Install by compiling first and then installing directly
install: all
	@echo "Installing dylib directly to $(INSTALL_DIR)"
	# Create the target directory.
	sudo mkdir -p $(INSTALL_DIR)
	# Install the tweak's dylib where injection takes place.
	sudo install -m 755 $(BUILD_DIR)/$(DYLIB_NAME) $(INSTALL_DIR)
	@echo "Installing Hider binary to $(BIN_INSTALL_DIR)"
	sudo mkdir -p $(BIN_INSTALL_DIR)
	sudo install -m 755 $(APP_BINARY) $(BIN_INSTALL_DIR)/hider
	sudo install -m 755 $(APP_BINARY) $(BIN_INSTALL_DIR)/Hider
	sudo install -m 755 $(CLI_BINARY) $(BIN_INSTALL_DIR)/hiderctl
	@if [ -f $(WHITELIST_SOURCE) ]; then \
		sudo cp $(WHITELIST_SOURCE) $(WHITELIST_DEST); \
		sudo chmod 644 $(WHITELIST_DEST); \
		echo "Installed $(DYLIB_NAME) and whitelist"; \
	else \
		echo "Warning: $(WHITELIST_SOURCE) not found"; \
		echo "Installed $(DYLIB_NAME)"; \
	fi
	@echo "Installing launch agent to $(LAUNCH_AGENT_DEST)"
	@mkdir -p $(HOME)/Library/LaunchAgents
	@cp $(LAUNCH_AGENT_PLIST) $(LAUNCH_AGENT_DEST)
	@launchctl unload $(LAUNCH_AGENT_DEST) 2>/dev/null || true
	@launchctl load $(LAUNCH_AGENT_DEST)
	@echo "Launch agent installed. Hider will start at login."
	@echo "Force quitting Dock to reload tweak..."
	sudo killall -9 Dock 2>/dev/null || true

# Run the non-invasive Swift unit tests. Injection testing remains manual.
test:
	$(SWIFT_BUILD_ENV) swift test $(SWIFT_BUILD_FLAGS)

# Clean build files
clean:
	@rm -rf $(BUILD_DIR) .build
	@echo "Cleaned build directory"

# Delete installed files
delete:
	@echo "Force quitting Dock..."
	killall Dock 2>/dev/null || true
	@launchctl unload $(LAUNCH_AGENT_DEST) 2>/dev/null || true
	@rm -f $(LAUNCH_AGENT_DEST)
	@sudo rm -f $(INSTALL_PATH)
	@sudo rm -f $(WHITELIST_DEST)
	@sudo rm -f $(INSTALL_DIR)/lib$(PROJECT).dylib.blacklist
	@sudo rm -f $(BIN_INSTALL_DIR)/hider $(BIN_INSTALL_DIR)/Hider $(BIN_INSTALL_DIR)/hiderctl
	@echo "Deleted $(DYLIB_NAME), whitelist, and launch agent"

# Uninstall
uninstall:
	@echo "Force quitting Dock..."
	killall Dock 2>/dev/null || true
	@launchctl unload $(LAUNCH_AGENT_DEST) 2>/dev/null || true
	@rm -f $(LAUNCH_AGENT_DEST)
	@sudo rm -f $(INSTALL_PATH)
	@sudo rm -f $(WHITELIST_DEST)
	@sudo rm -f $(INSTALL_DIR)/lib$(PROJECT).dylib.blacklist
	@sudo rm -f $(BIN_INSTALL_DIR)/hider $(BIN_INSTALL_DIR)/Hider $(BIN_INSTALL_DIR)/hiderctl
	@echo "Uninstalled $(DYLIB_NAME), whitelist, and launch agent"

.PHONY: all clean install installER test delete uninstall compile


# verbose test
## log show --predicate 'process == "Dock"' --info --last 2m | tail -30
# log show --predicate 'process == "Dock" AND eventMessage CONTAINS "Hider"' --info --last 2m
