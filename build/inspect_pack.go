// SPDX-License-Identifier: MIT
// Inspect raw WAPP entries without applying host composition or linking.
package main

import (
	"encoding/json"
	"os"

	"github.com/wippyai/wapp"
)

type entryRecord struct {
	ID   string          `json:"id"`
	Kind string          `json:"kind"`
	Meta json.RawMessage `json:"meta"`
	Data json.RawMessage `json:"data"`
}

func main() {
	records := []entryRecord{}
	for _, path := range os.Args[1:] {
		records = append(records, readEntries(path)...)
	}
	check(json.NewEncoder(os.Stdout).Encode(records))
}

func readEntries(path string) []entryRecord {
	file, err := os.Open(path)
	check(err)
	defer file.Close()
	reader, err := wapp.NewReader(file)
	check(err)
	entries, err := reader.GetEntries()
	check(err)
	records := make([]entryRecord, 0, len(entries))
	for _, entry := range entries {
		meta, err := json.Marshal(entry.Meta)
		check(err)
		data, err := json.Marshal(entry.Data)
		check(err)
		records = append(records, entryRecord{entry.ID.String(), entry.Kind, meta, data})
	}
	return records
}

func check(err error) {
	if err != nil {
		panic(err)
	}
}
