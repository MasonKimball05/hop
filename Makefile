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

# Every build runs with the hardened runtime, which notarization requires, so what you
# run is what gets shipped; Hop.entitlements lists what Hop needs under it.
ENTITLEMENTS := Resources/Hop.entitlements
# A secure timestamp, which notarization also requires; set for Developer ID builds.
TIMESTAMP ?=

# For builds other people download: your Developer ID Application certificate.
DEVELOPER_ID ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk '/"Developer ID Application/ { print $$2; exit }')
# How notarytool signs in: a keychain profile saved with
# `xcrun notarytool store-credentials` (NOTARY_PROFILE=name), or an App Store Connect
# API key (NOTARY_KEY=path/to/key.p8 NOTARY_KEY_ID=… NOTARY_ISSUER=…), as CI does.
NOTARY_AUTH = $(if $(NOTARY_PROFILE),--keychain-profile "$(NOTARY_PROFILE)",--key "$(NOTARY_KEY)" --key-id "$(NOTARY_KEY_ID)" --issuer "$(NOTARY_ISSUER)")

.PHONY: test app dist notarized install run clean

test:
	swift test --scratch-path $(BUILD)

# Wraps the release binary in a .app bundle and signs it.
app:
	swift build -c release --scratch-path $(BUILD)
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp "$$(swift build -c release --scratch-path $(BUILD) --show-bin-path)/Hop" $(APP)/Contents/MacOS/Hop
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	codesign --force --sign "$(SIGN)" --options runtime --entitlements $(ENTITLEMENTS) $(TIMESTAMP) $(APP)
	@codesign -dvv $(APP) 2>&1 | grep -E '^(Authority|Signature)=' | head -1

# Hop.app zipped for sharing (what CI uploads and releases publish).
dist: app
	rm -f $(CACHE)/Hop.zip
	ditto -c -k --keepParent $(APP) $(CACHE)/Hop.zip

# Hop.zip signed with Developer ID, notarized by Apple and stapled: it opens on any Mac
# without a warning. On a rejection, prints Apple's log of what was wrong.
notarized:
	@test -n "$(DEVELOPER_ID)" || { echo "No Developer ID Application certificate in the keychain (see README: Signed releases)."; exit 1; }
	$(MAKE) dist SIGN="$(DEVELOPER_ID)" TIMESTAMP=--timestamp
	@result=$$(xcrun notarytool submit $(CACHE)/Hop.zip $(NOTARY_AUTH) --wait --output-format json); echo "$$result"; \
	if ! echo "$$result" | grep -Eq '"status" *: *"Accepted"'; then \
		id=$$(echo "$$result" | sed -nE 's/.*"id" *: *"([^"]+)".*/\1/p'); \
		[ -n "$$id" ] && xcrun notarytool log "$$id" $(NOTARY_AUTH); \
		exit 1; \
	fi
	xcrun stapler staple $(APP)
	rm -f $(CACHE)/Hop.zip
	ditto -c -k --keepParent $(APP) $(CACHE)/Hop.zip
	spctl --assess --type execute --verbose=2 $(APP)

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
