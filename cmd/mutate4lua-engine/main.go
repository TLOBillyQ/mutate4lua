package main

import (
	"os"

	"github.com/billyq/mutate4lua/internal/cli"
)

func main() {
	cwd, _ := os.Getwd()
	os.Exit(cli.Execute(os.Args[1:], cwd, os.Stdout, os.Stderr))
}
