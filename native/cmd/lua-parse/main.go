package main

import (
	"encoding/json"
	"fmt"
	"os"

	"github.com/wippyai/go-lua/compiler/parse"
)

func run() error {
	var sources []string
	if err := json.NewDecoder(os.Stdin).Decode(&sources); err != nil {
		return err
	}
	valid := make([]bool, len(sources))
	for i, source := range sources {
		_, err := parse.ParseString(source, "comment")
		valid[i] = err == nil
	}
	return json.NewEncoder(os.Stdout).Encode(valid)
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
