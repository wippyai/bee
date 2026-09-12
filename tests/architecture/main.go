// SPDX-License-Identifier: MIT
// Production architecture checker: declared graph, permissions, import
// closure, source containment, and exact source/pack loaded inventory.
package main

import (
	"fmt"
	"os"
	"path/filepath"
)

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintf(os.Stderr, "usage: architecture <repo-root> <runtime-path>\n")
		os.Exit(2)
	}
	root, err := filepath.Abs(os.Args[1])
	if err != nil {
		fatal(err)
	}
	runtime, err := filepath.Abs(os.Args[2])
	if err != nil {
		fatal(err)
	}
	if err := CheckArchitecture(root, runtime); err != nil {
		fatal(err)
	}
}

// CheckArchitecture runs the complete production architecture audit.
func CheckArchitecture(root, runtime string) error {
	if err := CheckRepositoryLayout(root); err != nil {
		return err
	}
	catalog, err := LoadCatalog(root)
	if err != nil {
		return err
	}
	if err := CheckDeclaredGraph(catalog); err != nil {
		return err
	}
	fmt.Printf("Architecture: %d entries; on-demand default applications, closed imports, denied ambient app authority\n", len(catalog.Entries))
	return CheckLoadedInventories(catalog, runtime)
}

func fatal(err error) {
	fmt.Fprintf(os.Stderr, "%s\n", err)
	os.Exit(1)
}
