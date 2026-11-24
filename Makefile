VJ_BUILD := vj/native-app/build/mac
JOBS ?= $(shell sysctl -n hw.ncpu)

.PHONY: all patch vj run-patch run-vj test test-patch test-vj clean

all: patch vj

patch:
	patch/scripts/build-app.sh

vj:
	cmake --preset mac -S vj/native-app
	cmake --build $(VJ_BUILD) --target VJNative -j$(JOBS)

run-patch: patch
	open patch/build/Patch.app

run-vj: vj
	open $(VJ_BUILD)/VJ.app

test: test-patch test-vj

test-patch:
	patch/scripts/run-checks.sh

test-vj:
	cmake --preset mac -S vj/native-app
	cmake --build $(VJ_BUILD) -j$(JOBS)
	ctest --test-dir $(VJ_BUILD) -j$(JOBS)

clean:
	rm -rf patch/.build patch/build vj/native-app/build vj/native-renderer/build
