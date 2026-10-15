//go:build ignore

// Run from the pinned runtime module: go run /path/to/bee/tests/fixtures/hub_pack_fixture.go pack.wapp > tests/fixtures/hub/root_pack.json.gz
package main

import (
	"compress/gzip"
	"encoding/json"
	"os"

	"github.com/wippyai/runtime/boot/deps/packentries"
	"github.com/wippyai/wapp"
)

func main() {
	f, err := os.Open(os.Args[1])
	if err != nil {
		panic(err)
	}
	defer f.Close()
	reader, err := wapp.NewReader(f)
	if err != nil {
		panic(err)
	}
	entries, err := reader.GetEntries()
	if err != nil {
		panic(err)
	}
	rows := make([]map[string]any, 0, len(entries))
	for _, entry := range entries {
		meta := entry.Meta
		if meta == nil {
			meta = map[string]any{}
		}
		var data any = map[string]any{}
		if entry.Kind == "ns.requirement" || entry.Kind == "ns.dependency" || entry.ID.String() == "bee.env.identity:binary_identity" {
			data = packentries.UnwrapPayloadData(entry.Data)
		}
		rows = append(rows, map[string]any{"id": entry.ID.String(), "kind": entry.Kind, "meta": meta, "data": data})
	}
	encoded, err := json.Marshal(rows)
	if err != nil {
		panic(err)
	}
	writer := gzip.NewWriter(os.Stdout)
	if _, err := writer.Write(encoded); err != nil {
		panic(err)
	}
	if err := writer.Close(); err != nil {
		panic(err)
	}
}
