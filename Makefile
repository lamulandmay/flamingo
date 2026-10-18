# Flamingo. Every target is a thin wrapper over scripts/.
.PHONY: all build run test demo release fixtures clean

all: build

build:
	scripts/build.sh

run:
	scripts/run.sh

test:
	scripts/test.sh

demo:
	scripts/demo.sh

release:
	scripts/release.sh

fixtures:
	scripts/make-fixtures.sh

clean:
	rm -rf .build build fixtures/vault/.flamingo/index.sqlite*
