APP := build/Clippeek.app
ICON := build/AppIcon.icns
BUILD := swift build -c release --arch arm64 --arch x86_64
BIN = $(shell $(BUILD) --show-bin-path)

.PHONY: app install test clean

app: $(ICON)
	$(BUILD)
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BIN)/ClippeekApp $(APP)/Contents/MacOS/
	cp Resources/Info.plist $(APP)/Contents/
	cp $(ICON) $(APP)/Contents/Resources/
	codesign --force --sign - $(APP)

$(ICON): scripts/make-icon.swift
	rm -rf build/AppIcon.iconset
	swift scripts/make-icon.swift build/AppIcon.iconset
	iconutil -c icns build/AppIcon.iconset -o $(ICON)

install: app
	-pkill -x ClippeekApp
	rm -rf /Applications/Clippeek.app
	cp -R $(APP) /Applications/
	open /Applications/Clippeek.app

test:
	swift test

clean:
	rm -rf .build build
