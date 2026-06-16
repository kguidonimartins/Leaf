PROJECT = Leaf.xcodeproj
SCHEME  = Leaf
CONFIG  ?= Debug
DERIVED = build
APP         = $(DERIVED)/Build/Products/$(CONFIG)/Leaf.app
RELEASE_APP = $(DERIVED)/Build/Products/Release/Leaf.app
INSTALL_DIR = /Applications
# Extra xcodebuild build settings, e.g. on CI without signing certs:
#   make test XCODEFLAGS="CODE_SIGNING_ALLOWED=NO"
XCODEFLAGS ?=

.PHONY: build release run install test clean resolve

build: test
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) -derivedDataPath $(DERIVED) $(XCODEFLAGS) build

release:
	$(MAKE) build CONFIG=Release

run: build
	open "$(APP)"

install: release
	cp -R "$(RELEASE_APP)" "$(INSTALL_DIR)/"
	@echo "Installed Leaf to $(INSTALL_DIR)/Leaf.app"

test:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination 'platform=macOS' -derivedDataPath $(DERIVED) $(XCODEFLAGS) test

resolve:
	xcodebuild -project $(PROJECT) -resolvePackageDependencies

clean:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) clean
	rm -rf $(DERIVED)
