# Builds live outside ~/Documents: iCloud tags synced files with extended
# attributes, and codesign refuses to sign bundles that carry them.
CACHE := $(HOME)/Library/Caches/Hop
BUILD := $(CACHE)/build
APP   := $(CACHE)/Hop.app

# Signs with your Apple Development certificate when you have one (Xcode makes it
# when you sign in under Settings > Accounts). macOS ties Screen Recording and
# Accessibility to the signature, and this one stays the same across rebuilds, so
# they're granted once. Without one it signs ad hoc, and every build looks like a new
# app. Override with `make install SIGN="Developer ID Application: ..."` or SIGN=-.
SIGN ?= $(or $(shell security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development/ { print $$2; exit }'),-)

.PHONY: test app install run clean

test:
	swift test --scratch-path $(BUILD)

# Wraps the release binary in a .app bundle and signs it.
app:
	swift build -c release --scratch-path $(BUILD)
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp "$$(swift build -c release --scratch-path $(BUILD) --show-bin-path)/Hop" $(APP)/Contents/MacOS/Hop
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	codesign --force --sign "$(SIGN)" $(APP)
	@codesign -dvv $(APP) 2>&1 | grep -E '^(Authority|Signature)=' | head -1

# Replaces ~/Applications/Hop.app and starts it.
install: app
	-pkill -x Hop
	rm -rf $(HOME)/Applications/Hop.app
	mkdir -p $(HOME)/Applications
	ditto $(APP) $(HOME)/Applications/Hop.app
	open $(HOME)/Applications/Hop.app

# Runs the built app without installing it.
run: app
	-pkill -x Hop
	open $(APP)

clean:
	rm -rf $(CACHE)
