SHELL := /bin/bash
NAME := spice-client
# The only place the version is stated: a release is exactly a tag.
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
APP := dist/Spice Client.app
ZIP := dist/$(NAME)-$(VERSION)-darwin-arm64.zip
CODESIGN_IDENTITY ?= Developer ID Application
NOTARY_PROFILE ?= nlink-jp-notary
SWIFT := swift

BREW_KIND := cask
BREW_DESC := Native SPICE client for QEMU and Ravada virtual desktops
BREW_NAME := $(NAME)
BREW_APP := Spice Client.app
BREW_BUNDLE_ID := jp.nlink.spice-client
BREW_MACOS_FLOOR := :tahoe
include scripts/release-brew.mk

.PHONY: test lint doctor build run package verify-release clean test-vendor verify-vendor simulate live-peer live-peer-clean
test:
	$(SWIFT) test --disable-sandbox -Xswiftc -warnings-as-errors
	python3 scripts/check-project.py
	python3 -m unittest discover -s Tests -p 'test_*.py'

test-vendor:
	$(SWIFT) test --package-path Vendor/SwiftSpice --no-parallel --disable-sandbox -Xswiftc -warnings-as-errors

# Needs the network: fetches the pinned upstream and replays Vendor/*.patch.
verify-vendor:
	bash scripts/verify-vendor-patches.sh

simulate:
	python3 scripts/simulate.py

# Real spice-server in QEMU (TCG) under Podman with a minimal Linux guest (ADR-0002).
live-peer:
	bash Integration/LivePeer/gate.sh

live-peer-clean:
	bash Integration/LivePeer/stop.sh
	podman rmi -f localhost/spice-client-live-peer:local > /dev/null 2>&1 || true
	rm -rf "$(CURDIR)/Integration/LivePeer/Artifacts"

lint:
	$(SWIFT) build --disable-sandbox -Xswiftc -warnings-as-errors
	python3 scripts/check-project.py

doctor:
	bash scripts/doctor.sh

build: doctor
	bash scripts/build-app.sh "$(VERSION)"

run: build
	open "$(APP)"

package:
	@echo "$(VERSION)" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$$' || { echo "package: '$(VERSION)' is not a release tag; tag the commit or pass VERSION=vX.Y.Z" >&2; exit 1; }
	bash Integration/LivePeer/require-pass.sh "$$(git rev-parse HEAD)"
	$(MAKE) test
	$(MAKE) build
	scripts/codesign-darwin-app.sh "$(APP)" "$(CODESIGN_IDENTITY)"
	scripts/notarize-darwin-app.sh "$(APP)" "$(NOTARY_PROFILE)"
	test -f "$(APP).notarized"
	xcrun stapler validate "$(APP)"
	spctl --assess --type execute "$(APP)"
	/usr/bin/ditto --norsrc --noextattr -c -k --keepParent "$(APP)" "$(ZIP)"
	$(MAKE) verify-release

verify-release:
	@scripts/verify-app-zip.sh "$(ZIP)"
	python3 scripts/verify-release.py "$(ZIP)" "$(VERSION)"
	python3 scripts/check-project.py

clean:
	rm -rf "$(CURDIR)/dist"
