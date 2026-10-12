APP := build/Clippeek.app
ICON := build/AppIcon.icns
BUILD := swift build -c release --arch arm64 --arch x86_64
BIN = $(shell $(BUILD) --show-bin-path)
# A stable certificate keeps the Keychain's "Always Allow" across updates; "-" signs ad hoc.
SIGN_IDENTITY ?= -

.PHONY: app install release snapshots test clean

app: $(ICON)
	$(BUILD)
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BIN)/ClippeekApp $(APP)/Contents/MacOS/
	cp Resources/Info.plist $(APP)/Contents/
	cp $(ICON) $(APP)/Contents/Resources/
	codesign --force --sign "$(SIGN_IDENTITY)" $(APP)

$(ICON): scripts/make-icon.swift
	rm -rf build/AppIcon.iconset
	swift scripts/make-icon.swift build/AppIcon.iconset
	iconutil -c icns build/AppIcon.iconset -o $(ICON)

install: app
	-pkill -x ClippeekApp
	rm -rf /Applications/Clippeek.app
	cp -R $(APP) /Applications/
	open /Applications/Clippeek.app

release: app
	cd build && rm -f Clippeek.zip && ditto -c -k --keepParent Clippeek.app Clippeek.zip
	cd build && LC_ALL=C shasum -a 256 Clippeek.zip > Clippeek.zip.sha256

# Renders every screen with sample data, without touching the real inbox, history or Keychain.
snapshots: $(ICON)
	swift build
	.build/debug/ClippeekApp --snapshots build/snapshots
	-defaults delete ClippeekApp 2>/dev/null

test:
	swift test

clean:
	rm -rf .build build
