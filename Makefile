# Compiler and SDK settings
CC ?= $(shell which clang || echo clang)
CXX ?= $(shell which clang++ || echo clang++)

# SDK paths with fallback - only evaluate when building, not during install
ifdef MAKECMDGOALS
ifneq ($(filter build all compile installER install test debug,$(MAKECMDGOALS)),)
SDKROOT ?= $(shell xcrun --show-sdk-path 2>/dev/null || echo /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk)
endif
else
# Default case when no goals specified (make with no arguments = all)
SDKROOT ?= $(shell xcrun --show-sdk-path 2>/dev/null || echo /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk)
endif

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
    -Isrc \
    -I$(SOURCE_DIR)/tweak \
    -I$(SOURCE_DIR)/hooks \
    -I$(SOURCE_DIR)/gui
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
TWEAK_DIR = $(SOURCE_DIR)/tweak
HOOKS_DIR = $(SOURCE_DIR)/hooks
GUI_DIR = $(SOURCE_DIR)/gui
INSTALL_DIR = /var/ammonia/core/tweaks

# Source files
DYLIB_SOURCES = $(TWEAK_DIR)/Hider.m \
	$(TWEAK_DIR)/HiderCustomAppDockHider.m \
	$(TWEAK_DIR)/HiderActions.m \
	$(HOOKS_DIR)/Hooks.m
DYLIB_OBJECTS = $(DYLIB_SOURCES:%.m=$(BUILD_DIR)/%.o)

APP_SOURCES = $(GUI_DIR)/HiderApp.swift \
	$(GUI_DIR)/SettingsManager.swift
APP_NAME = Hider
APP_BINARY = $(BUILD_DIR)/$(APP_NAME)
APP_ID = com.aspauldingcode.hider

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
              -current_version 1.0.0 \
              -Wl,-dead_strip

# Default target - build the dylib and the app
# Default target - build the dylib and the app binary
all: $(BUILD_DIR)/$(DYLIB_NAME) $(APP_BINARY)

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
	@echo "Build complete. Only $(DYLIB_NAME) remains in $(BUILD_DIR)/"

# Swift compiler flags: -O for release optimization, -warnings-as-errors for strict build
SWIFTFLAGS = -O -warnings-as-errors

# Build menubar agent binary (pure CLI binary, not a .app)
$(APP_BINARY): $(APP_SOURCES) | $(BUILD_DIR)
	@echo "Building menubar agent binary..."
	swiftc -sdk $(SDKROOT) \
		$(SWIFTFLAGS) \
		$(APP_SOURCES) \
		-o $(APP_BINARY) \
		-emit-executable
	@echo "Binary build complete: $(APP_BINARY)"

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
	@echo "Installing hider binary to $(BIN_INSTALL_DIR)"
	sudo mkdir -p $(BIN_INSTALL_DIR)
	sudo rm -f $(BIN_INSTALL_DIR)/Hider
	sudo install -m 755 $(APP_BINARY) $(BIN_INSTALL_DIR)/hider
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

# Debug: install and attach lldb to Dock for crash analysis
debug: all
	@echo "Installing dylib directly to $(INSTALL_DIR)"
	sudo mkdir -p $(INSTALL_DIR)
	sudo install -m 755 $(BUILD_DIR)/$(DYLIB_NAME) $(INSTALL_DIR)
	@echo "Installing hider binary to $(BIN_INSTALL_DIR)"
	sudo mkdir -p $(BIN_INSTALL_DIR)
	sudo rm -f $(BIN_INSTALL_DIR)/Hider
	sudo install -m 755 $(APP_BINARY) $(BIN_INSTALL_DIR)/hider
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
	@echo "Launch agent installed."
	@rm -f /tmp/hider.log
	@echo ""
	@echo "=== Attaching lldb to Dock ==="
	@echo "If Dock hangs, run 'make recover' from another terminal."
	@echo "On crash, use: bt, bt all, frame variable, register read"
	@echo ""
	@(sleep 2 && sudo pkill -KILL Dock) &
	lldb -n Dock -w -o "continue"

# Emergency recovery: removes dylib, kills lldb, restarts Dock clean
recover:
	@echo "Recovering from hung Dock..."
	-@sudo rm -f $(INSTALL_PATH)
	-@pkill -9 lldb 2>/dev/null
	-@sleep 1
	-@sudo pkill -KILL Dock 2>/dev/null
	@echo "Done — dylib removed, Dock restarted clean."

# Test target that compiles, installs, and kills dock for testing
test: $(BUILD_DIR)/$(DYLIB_NAME)
	@echo "Installing dylib for testing..."
	# Create the target directory.
	sudo mkdir -p $(INSTALL_DIR)
	# Install the tweak's dylib where injection takes place.
	sudo install -m 755 $(BUILD_DIR)/$(DYLIB_NAME) $(INSTALL_DIR)
	@if [ -f $(WHITELIST_SOURCE) ]; then \
		sudo cp $(WHITELIST_SOURCE) $(WHITELIST_DEST); \
		sudo chmod 644 $(WHITELIST_DEST); \
		echo "Installed $(DYLIB_NAME) and whitelist"; \
	else \
		echo "Warning: $(WHITELIST_SOURCE) not found"; \
		echo "Installed $(DYLIB_NAME)"; \
	fi
	@echo "Clearing previous log file..."
	@rm -f /tmp/hider.log
	@echo "Force quitting Dock to reload tweak..."
	killall Dock 2>/dev/null || true
	@sleep 1
	@echo "Dock restarted with new tweak loaded"
	@echo ""
	@echo "=== Tailing /tmp/hider.log ==="
	@if [ -f /tmp/hider.log ]; then \
		echo "Showing existing log content:"; \
		cat /tmp/hider.log; \
		echo ""; \
		echo "Tailing log file (Ctrl+C to stop)..."; \
		tail -f /tmp/hider.log; \
	else \
		echo "Log file not found yet. Waiting 2 seconds and trying again..."; \
		sleep 2; \
		if [ -f /tmp/hider.log ]; then \
			echo "Showing existing log content:"; \
			cat /tmp/hider.log; \
			echo ""; \
			echo "Tailing log file (Ctrl+C to stop)..."; \
			tail -f /tmp/hider.log; \
		else \
			echo "Log file still not found. Dock may not have loaded the tweak yet."; \
			echo "Check /tmp/hider.log manually or restart Dock again."; \
		fi \
	fi

# Trigger runtime dumps from injected Dock tweak.
dump:
	@echo "Requesting Dock layer dump..."
	@notifyutil -p com.hider.dump || true
	@sleep 1
	@ls -l /tmp/dock_layer_dump.txt 2>/dev/null || echo "No /tmp/dock_layer_dump.txt yet"
	@echo "Layer dump path: /tmp/dock_layer_dump.txt"

classdump:
	@echo "Requesting Dock class dump..."
	@notifyutil -p com.hider.classdump || true
	@sleep 1
	@ls -l /tmp/dock_class_dump.txt 2>/dev/null || echo "No /tmp/dock_class_dump.txt yet"
	@echo "Class dump path: /tmp/dock_class_dump.txt"

# Clean build files
clean:
	@rm -rf $(BUILD_DIR)
	@echo "Cleaned build directory"

# Delete installed files
delete:
	@echo "Deleting installed files..."
	@launchctl unload $(LAUNCH_AGENT_DEST) 2>/dev/null || true
	@rm -f $(LAUNCH_AGENT_DEST)
	@sudo rm -f $(INSTALL_PATH)
	@sudo rm -f $(WHITELIST_DEST)
	@sudo rm -f $(INSTALL_DIR)/lib$(PROJECT).dylib.blacklist
	@sudo rm -f $(BIN_INSTALL_DIR)/hider
	@sudo rm -f $(BIN_INSTALL_DIR)/Hider
	@echo "Deleted $(DYLIB_NAME), hider binary, whitelist, and launch agent"
	@echo "Restarting Dock..."
	sudo pkill -KILL Dock 2>/dev/null || true

# Uninstall
uninstall:
	@echo "Uninstalling..."
	@launchctl unload $(LAUNCH_AGENT_DEST) 2>/dev/null || true
	@rm -f $(LAUNCH_AGENT_DEST)
	@sudo rm -f $(INSTALL_PATH)
	@sudo rm -f $(WHITELIST_DEST)
	@sudo rm -f $(INSTALL_DIR)/lib$(PROJECT).dylib.blacklist
	@sudo rm -f $(BIN_INSTALL_DIR)/hider
	@sudo rm -f $(BIN_INSTALL_DIR)/Hider
	@echo "Uninstalled $(DYLIB_NAME), hider binary, whitelist, and launch agent"
	@echo "Restarting Dock..."
	sudo pkill -KILL Dock 2>/dev/null || true

# Live log tail — run this in a second terminal while `make debug` runs in the first.
# Usage: open a new terminal, cd to this directory, run `make log`
log:
	@echo "=== Hider Live Log (/tmp/hider.log) ==="
	@echo "Tip: run 'make debug' in another terminal to start testing."
	@echo "Press Ctrl+C to stop tailing."
	@echo ""
	@touch /tmp/hider.log
	@tail -F /tmp/hider.log

# Clear the log and start a fresh tail (useful when re-running make debug).
logclean:
	@echo "Clearing /tmp/hider.log..."
	@rm -f /tmp/hider.log
	@touch /tmp/hider.log
	@echo "Log cleared. Tailing fresh log..."
	@tail -F /tmp/hider.log

.PHONY: all clean install installER test debug recover delete uninstall compile dump classdump log logclean


# verbose test
## log show --predicate 'process == "Dock"' --info --last 2m | tail -30
# log show --predicate 'process == "Dock" AND eventMessage CONTAINS "Hider"' --info --last 2m