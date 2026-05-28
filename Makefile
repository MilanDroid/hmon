APP_NAME    := hmon
BUNDLE_ID   := com.antony.hmon
BUILD_DIR   := .build/release
APP_BUNDLE  := $(BUILD_DIR)/$(APP_NAME).app
INSTALL_DIR := $(HOME)/Applications
INSTALLED   := $(INSTALL_DIR)/$(APP_NAME).app

.PHONY: build app install uninstall run clean

build:
	swift build -c release

app: build
	rm -rf "$(APP_BUNDLE)"
	mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	mkdir -p "$(APP_BUNDLE)/Contents/Resources"
	cp "$(BUILD_DIR)/$(APP_NAME)" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"
	cp Resources/Info.plist "$(APP_BUNDLE)/Contents/Info.plist"
	# Ad-hoc sign so SMAppService accepts the bundle.
	codesign --force --deep --sign - "$(APP_BUNDLE)"
	@echo ""
	@echo "Built $(APP_BUNDLE)"

install: app
	mkdir -p "$(INSTALL_DIR)"
	# Stop any running copy
	-pkill -x $(APP_NAME) 2>/dev/null || true
	rm -rf "$(INSTALLED)"
	cp -R "$(APP_BUNDLE)" "$(INSTALLED)"
	@echo ""
	@echo "Installed to $(INSTALLED)"
	@echo "Launching..."
	open "$(INSTALLED)"

run: app
	-pkill -x $(APP_NAME) 2>/dev/null || true
	open "$(APP_BUNDLE)"

uninstall:
	-pkill -x $(APP_NAME) 2>/dev/null || true
	# Disable launch-at-login first if the binary is still around
	-[ -x "$(INSTALLED)/Contents/MacOS/$(APP_NAME)" ] && \
		"$(INSTALLED)/Contents/MacOS/$(APP_NAME)" --disable-login 2>/dev/null || true
	rm -rf "$(INSTALLED)"
	rm -rf "/Applications/$(APP_NAME).app"
	# Clear any lingering launch services entry
	-launchctl bootout gui/$(shell id -u)/$(BUNDLE_ID) 2>/dev/null || true
	rm -rf "$(HOME)/Library/Caches/$(BUNDLE_ID)"
	rm -rf "$(HOME)/Library/Preferences/$(BUNDLE_ID).plist"
	rm -rf "$(HOME)/Library/Application Support/$(APP_NAME)"
	@echo ""
	@echo "Uninstalled. If 'Login Items' in System Settings still lists hmon,"
	@echo "open it and remove the entry manually."

clean:
	swift package clean
	rm -rf .build
