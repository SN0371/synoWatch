APP_NAME    = SynoWatch
BUNDLE_ID   = com.local.synowatch
BUILD_DIR   = .build/release
APP_BUNDLE  = $(APP_NAME).app
INSTALL_DIR = $(HOME)/Applications

.PHONY: all build app install clean

## Build the binary and assemble the .app bundle in the project directory.
all: app

build:
	swift build -c release

## Assemble SynoWatch.app from the compiled binary.
app: build
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	@cp $(BUILD_DIR)/$(APP_NAME) $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
	@/usr/libexec/PlistBuddy -c "Add :CFBundleName              string $(APP_NAME)"      $(APP_BUNDLE)/Contents/Info.plist
	@/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable        string $(APP_NAME)"      $(APP_BUNDLE)/Contents/Info.plist
	@/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier        string $(BUNDLE_ID)"     $(APP_BUNDLE)/Contents/Info.plist
	@/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType       string APPL"             $(APP_BUNDLE)/Contents/Info.plist
	@/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string 1.0"             $(APP_BUNDLE)/Contents/Info.plist
	@/usr/libexec/PlistBuddy -c "Add :NSPrincipalClass          string NSApplication"    $(APP_BUNDLE)/Contents/Info.plist
	@/usr/libexec/PlistBuddy -c "Add :LSUIElement               bool true"               $(APP_BUNDLE)/Contents/Info.plist
	@/usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity    dict"                    $(APP_BUNDLE)/Contents/Info.plist
	@/usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity:NSAllowsLocalNetworking bool true" $(APP_BUNDLE)/Contents/Info.plist
	@echo "Built $(APP_BUNDLE)"

## Copy SynoWatch.app to ~/Applications (creates it if needed).
install: app
	@mkdir -p $(INSTALL_DIR)
	@rm -rf $(INSTALL_DIR)/$(APP_BUNDLE)
	@cp -R $(APP_BUNDLE) $(INSTALL_DIR)/$(APP_BUNDLE)
	@echo "Installed to $(INSTALL_DIR)/$(APP_BUNDLE)"

clean:
	@rm -rf $(APP_BUNDLE) .build
