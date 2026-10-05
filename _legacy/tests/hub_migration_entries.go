// MIT. Read a supplied test artifact without installing its dependencies.
package main

import (
	"encoding/json"
	"os"

	"github.com/wippyai/wapp"
)

func main() {
	file, err := os.Open(os.Args[1])
	if err != nil {
		panic(err)
	}
	defer file.Close()
	reader, err := wapp.NewReader(file)
	if err != nil {
		panic(err)
	}
	entries, err := reader.GetEntries()
	if err != nil {
		panic(err)
	}
	if err := json.NewEncoder(os.Stdout).Encode(entries); err != nil {
		panic(err)
	}
}
