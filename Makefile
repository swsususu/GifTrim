VERSION ?= 0.1.0
SDK := $(shell scripts/sdk.sh)
# Command Line Tools keep the swift-testing macro plugin in a subfolder the driver doesn't search.
TESTING_PLUGIN := $(wildcard $(shell xcode-select -p)/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib)
TEST_FLAGS := $(if $(TESTING_PLUGIN),-Xswiftc -load-plugin-library -Xswiftc $(TESTING_PLUGIN),)

.PHONY: all gifski build cli app dmg test run clean

all: app

gifski:
	scripts/build-gifski.sh

Vendor/lib/libgifski.a:
	scripts/build-gifski.sh

build cli: Vendor/lib/libgifski.a
	SDKROOT=$(SDK) swift build --product giftrim-cli

app: Vendor/lib/libgifski.a
	scripts/build-app.sh $(VERSION)

dmg: app
	scripts/make-dmg.sh $(VERSION)

test: Vendor/lib/libgifski.a
	SDKROOT=$(SDK) swift test $(TEST_FLAGS)

run: app
	open build/GifTrim.app

clean:
	rm -rf .build build
