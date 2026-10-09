APP := build/Clippeek.app
BUILD := swift build -c release --arch arm64 --arch x86_64
BIN = $(shell $(BUILD) --show-bin-path)

.PHONY: app install test clean

app:
	$(BUILD)
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp $(BIN)/ClippeekApp $(APP)/Contents/MacOS/
	cp Resources/Info.plist $(APP)/Contents/
	codesign --force --sign - $(APP)

install: app
	-pkill -x ClippeekApp
	rm -rf /Applications/Clippeek.app
	cp -R $(APP) /Applications/
	open /Applications/Clippeek.app

test:
	swift test

clean:
	rm -rf .build build
