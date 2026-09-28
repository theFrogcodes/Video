.PHONY: app run debug-app test build clean

## Build the signed .app into build/
app:
	./scripts/build-app.sh release

## Build and launch
run: app
	open "build/Netflix Dubber.app"

debug-app:
	./scripts/build-app.sh debug

build:
	swift build -c release

test:
	swift test --filter DubberCoreTests

clean:
	rm -rf .build build
