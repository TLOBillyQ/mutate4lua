GO_BIN := bin/mutate4lua-go

.PHONY: build-go test-go test-lua test

build-go:
	go build -o $(GO_BIN) ./cmd/mutate4lua-go

test-go:
	go test ./...

test-lua:
	lua test/run.lua

test: test-go test-lua
