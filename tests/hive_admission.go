// SPDX-License-Identifier: MIT
// Run the host-admission fixture without loading the shared Bee source tree.
package main

import (
	"bytes"
	"context"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"time"
)

const admissionMarker = "HIVE_HOST_ADMISSION_OK"

// Retain bounded diagnostics even if a failed runtime produces excessive logs.
type admissionOutput struct {
	mu   sync.Mutex
	data []byte
}

func (out *admissionOutput) Write(p []byte) (int, error) {
	out.mu.Lock()
	defer out.mu.Unlock()
	const limit = 64 * 1024
	n := len(p)
	if n >= limit {
		out.data = append(out.data[:0], p[n-limit:]...)
		return n, nil
	}
	if excess := len(out.data) + n - limit; excess > 0 {
		copy(out.data, out.data[excess:])
		out.data = out.data[:len(out.data)-excess]
	}
	out.data = append(out.data, p...)
	return n, nil
}

func admissionCommand(runtime, directory string, arguments ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, runtime, arguments...)
	cmd.Dir = directory
	cmd.WaitDelay = time.Second
	output := &admissionOutput{}
	cmd.Stdout, cmd.Stderr = output, output
	err := cmd.Run()
	if err != nil {
		if ctx.Err() != nil {
			err = ctx.Err()
		}
		return nil, fmt.Errorf("admission fixture %v: %w\n%s", arguments, err, output.data)
	}
	return output.data, nil
}

func runAdmission() error {
	runtimeFlag := flag.String("runtime", ".wippy/bin/bee-wippy", "native runtime to verify")
	host := flag.String("host", "bee.hive_admission:terminal", "fixture command host")
	flag.Parse()
	runtime, err := filepath.Abs(*runtimeFlag)
	if err != nil {
		return err
	}
	directory, err := os.MkdirTemp("", "bee-hive-admission-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(directory)
	if err := os.CopyFS(filepath.Join(directory, "src"), os.DirFS("tests/fixtures/hive_admission")); err != nil {
		return fmt.Errorf("stage admission fixture: %w", err)
	}
	for name, contents := range map[string]string{
		"wippy.lock":  "directories:\n  modules: .wippy\n  src: ./src\n",
		".wippy.yaml": "version: '1.0'\nshutdown:\n  timeout: 2s\n",
	} {
		if err := os.WriteFile(filepath.Join(directory, name), []byte(contents), 0600); err != nil {
			return err
		}
	}
	if _, err := admissionCommand(runtime, directory, "lint", "--set", "lua.type_system.enabled=true", "--set", "lua.type_system.strict=true"); err != nil {
		return err
	}
	output, err := admissionCommand(runtime, directory, "run", "--host", *host, "--", "hive-admission-proof")
	if err != nil {
		return err
	}
	for _, line := range bytes.Split(output, []byte{'\n'}) {
		if bytes.Equal(bytes.TrimSpace(line), []byte(admissionMarker)) {
			fmt.Println("Hive host admission: denied actors cannot occupy the supervisor host; authorized launch and restart vacancy verified")
			return nil
		}
	}
	return fmt.Errorf("fixture exited without its success receipt:\n%s", output)
}

func main() {
	if err := runAdmission(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
