ENGINE_BIN := bin/mutate4lua-engine

.PHONY: build-engine test-go test-lua test

build-engine:
	go build -o $(ENGINE_BIN) ./cmd/mutate4lua-engine

test-go:
	go test ./...

test-lua:
	lua test/run.lua

test: test-go test-lua
