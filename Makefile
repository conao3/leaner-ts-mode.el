## Makefile

PACKAGE_NAME := leaner-ts-mode
EMACS ?= emacs

.PHONY: all
all: help

.PHONY: help
help:
	$(info )
	$(info Commands)
	$(info ========)
	$(info   - make          # Show this help)
	$(info   - make build    # Compile Elisp files)
	$(info   - make lint     # Lint Elisp files)
	$(info   - make test     # Compile Elisp files and run the tests)
	$(info   - make check    # Run lint and test)
	$(info   - make clean    # Clean compiled files)
	$(info )

.PHONY: build
build:
	keg build

.PHONY: lint
lint:
	keg lint

.PHONY: test
test: build
	keg exec $(EMACS) --batch -l $(PACKAGE_NAME)-tests.el -f cort-test-run

.PHONY: check
check: lint test

.PHONY: clean
clean:
	keg clean
