SHELL := /bin/bash
VERSION := 0.1.0
APP := dist/Spice Client.app
CODESIGN_IDENTITY ?= Developer ID Application
NOTARY_PROFILE ?= nlink-jp-notary
SWIFT := swift

.PHONY: test lint doctor build run package verify-release clean test-vendor simulate
test:
	$(SWIFT) test --disable-sandbox -Xswiftc -warnings-as-errors
	python3 scripts/check-project.py
	python3 -m unittest discover -s Tests -p 'test_*.py'

test-vendor:
	$(SWIFT) test --package-path Vendor/SwiftSpice --no-parallel --disable-sandbox -Xswiftc -warnings-as-errors

simulate:
	python3 scripts/simulate.py

lint:
	$(SWIFT) build --disable-sandbox -Xswiftc -warnings-as-errors
	python3 scripts/check-project.py

doctor:
	bash scripts/doctor.sh

build: doctor
	bash scripts/build-app.sh

run: build
	open "$(APP)"

package: test build
	scripts/codesign-darwin-app.sh "$(APP)" "$(CODESIGN_IDENTITY)"
	scripts/notarize-darwin-app.sh "$(APP)" "$(NOTARY_PROFILE)"
	test -f "$(APP).notarized"
	xcrun stapler validate "$(APP)"
	spctl --assess --type execute "$(APP)"
	/usr/bin/ditto --norsrc --noextattr -c -k --keepParent "$(APP)" "dist/spice-client-v$(VERSION)-darwin-arm64.zip"
	$(MAKE) verify-release

verify-release:
	python3 scripts/verify-release.py "dist/spice-client-v$(VERSION)-darwin-arm64.zip" "$(VERSION)"
	python3 scripts/check-project.py

clean:
	rm -rf "$(CURDIR)/dist"
