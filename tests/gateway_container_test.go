// SPDX-License-Identifier: MIT
package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestGatewayListenerFixtureUsesHostComposition(t *testing.T) {
	for _, address := range []string{"127.0.0.1", "172.17.0.1"} {
		t.Run(address, func(t *testing.T) {
			root := t.TempDir()
			for _, path := range []string{"src/_index.yaml", "src/gateway/api/_index.yaml", "modules/gateway/src/_index.yaml"} {
				data, err := os.ReadFile(filepath.Join("..", path))
				if err != nil {
					t.Fatal(err)
				}
				target := filepath.Join(root, path)
				if err := os.MkdirAll(filepath.Dir(target), 0700); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(target, data, 0600); err != nil {
					t.Fatal(err)
				}
			}
			if err := configureGatewayListener(root, address); err != nil {
				t.Fatal(err)
			}
			path := "src/gateway/api/_index.yaml"
			original, err := os.ReadFile(filepath.Join("..", path))
			if err != nil {
				t.Fatal(err)
			}
			configured, err := os.ReadFile(filepath.Join(root, path))
			if err != nil {
				t.Fatal(err)
			}
			if strings.Count(string(configured), address+":0") != 2 {
				t.Fatal("endpoint and listener must select the same interface and a native random port")
			}
			if !bytes.Equal(configured, bytes.ReplaceAll(original, []byte("127.0.0.1:0"), []byte(address+":0"))) {
				t.Fatal("listener fixture changed unrelated host wiring")
			}
			for _, path := range []string{"src/_index.yaml", "modules/gateway/src/_index.yaml"} {
				original, err := os.ReadFile(filepath.Join("..", path))
				if err != nil {
					t.Fatal(err)
				}
				configured, err := os.ReadFile(filepath.Join(root, path))
				if err != nil {
					t.Fatal(err)
				}
				if !bytes.Equal(original, configured) {
					t.Fatalf("listener fixture changed %s", path)
				}
			}
		})
	}
}

func TestGatewayListenerFixtureRefusesChangedWiring(t *testing.T) {
	root := t.TempDir()
	path := "src/gateway/api/_index.yaml"
	original, err := os.ReadFile(filepath.Join("..", path))
	if err != nil {
		t.Fatal(err)
	}
	changed := bytes.Replace(original, []byte("127.0.0.1:0"), []byte("127.0.0.1:9000"), 1)
	target := filepath.Join(root, path)
	if err := os.MkdirAll(filepath.Dir(target), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(target, changed, 0600); err != nil {
		t.Fatal(err)
	}
	if err := configureGatewayListener(root, "172.17.0.1"); err == nil {
		t.Fatal("fixture accepted a listener and endpoint with different port selection")
	}
	current, err := os.ReadFile(target)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(current, changed) {
		t.Fatal("refused fixture changed host wiring")
	}
}
