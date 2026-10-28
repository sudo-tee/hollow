.DEFAULT_GOAL := help

# ARGS are passed to the selected command; quote them as shell arguments.
ARGS ?=
ZIG ?= zig

.PHONY: help setup build run dev launch bench test test-all test-lua test-launch

help:
	@printf '%s\n' \
	  'Hollow development commands:' \
	  '  make setup        Fetch and patch dependencies' \
	  '  make build        Build for the native platform' \
	  '  make run          Build and run on the native platform' \
	  '  make dev          Incremental Windows cross-build and launch' \
	  '  make launch       Windows cross-build and launch' \
	  '  make bench        List or run benchmarks' \
	  '  make test         Run Zig unit tests' \
	  '  make test-all     Run native and Lua tests' \
	  '  make test-lua     Run Lua tests' \
	  '  make test-launch  Run launch script tests' \
	  '' \
	  'Pass options with ARGS, e.g. make dev ARGS="--build-only"' \
	  'or make bench ARGS="scroll 100". See each command for its options.'

setup:
	./scripts/setup.sh $(ARGS)

build:
	$(ZIG) build $(ARGS)

run:
	$(ZIG) build run $(ARGS)

dev:
	./dev.sh $(ARGS)

launch:
	./launch.sh $(ARGS)

bench:
	@./bench.sh $(ARGS)

test:
	$(ZIG) build test $(ARGS)

test-all:
	$(ZIG) build test-all $(ARGS)

test-lua:
	./scripts/test-lua.sh $(ARGS)

test-launch:
	bash ./scripts/test-launch.sh
