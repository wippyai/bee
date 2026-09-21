// SPDX-License-Identifier: MIT
// Exercise the native module through the real Wippy scheduler and permissions.
package main

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

func copyTree(source, destination string) error {
	return filepath.Walk(source, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		relative, err := filepath.Rel(source, path)
		if err != nil {
			return err
		}
		target := filepath.Join(destination, relative)
		if info.IsDir() {
			return os.MkdirAll(target, info.Mode())
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		return os.WriteFile(target, data, info.Mode())
	})
}

func run(timeout time.Duration, runtime, workspace string, environment []string, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	command := exec.CommandContext(ctx, runtime, args...)
	command.Dir = workspace
	command.Env = environment
	return command.CombinedOutput()
}

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: integration RUNTIME")
		os.Exit(2)
	}
	runtime, err := filepath.Abs(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	temporary, err := os.MkdirTemp("", "bee-ioevents-")
	if err != nil {
		panic(err)
	}
	defer os.RemoveAll(temporary)
	workspace := filepath.Join(temporary, "application")
	fixture := filepath.Join("tests", "fixture")
	if _, err := os.Stat(fixture); err != nil {
		fixture = filepath.Join("native", "tests", "fixture")
	}
	fixture, err = filepath.Abs(fixture)
	if err != nil {
		panic(err)
	}
	if err := copyTree(fixture, workspace); err != nil {
		panic(err)
	}
	root := filepath.Join(temporary, "watched files")
	if err := os.MkdirAll(root, 0o755); err != nil {
		panic(err)
	}
	environment := append([]string{}, os.Environ()...)
	environment = append(environment, "BEE_IOEVENTS_TEST_ROOT="+root)
	if output, err := run(30*time.Second, runtime, workspace, environment, "lint", "--silent"); err != nil {
		fmt.Fprintf(os.Stderr, "lint failed: %s\n%s", err, output)
		os.Exit(1)
	}
	denied, err := run(15*time.Second, runtime, workspace, environment, "run", "--silent", "denied")
	if err != nil || !bytes.Contains(denied, []byte("DENIED")) || !bytes.Contains(denied, []byte("not permitted")) {
		fmt.Fprintf(os.Stderr, "Permission denial failed: %s\n%s", err, denied)
		os.Exit(1)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, runtime, "run", "--silent", "watch")
	command.Dir = workspace
	command.Env = environment
	stdout, err := command.StdoutPipe()
	if err != nil {
		panic(err)
	}
	command.Stderr = command.Stdout
	if err := command.Start(); err != nil {
		panic(err)
	}
	outputChannel := make(chan []byte, 8)
	go func() {
		buffer := make([]byte, 32*1024)
		for {
			count, readErr := stdout.Read(buffer)
			if count > 0 {
				chunk := append([]byte(nil), buffer[:count]...)
				outputChannel <- chunk
			}
			if readErr != nil {
				close(outputChannel)
				return
			}
		}
	}()
	var output []byte
	created := false
	deadline := time.NewTimer(15 * time.Second)
	defer deadline.Stop()
	for !created {
		select {
		case data, open := <-outputChannel:
			if open {
				output = append(output, data...)
				created = bytes.Contains(output, []byte("READY"))
			} else {
				if !bytes.Contains(output, []byte("READY")) {
					fmt.Fprintf(os.Stderr, "Watcher exited before readiness: %s\n", output)
					_ = command.Wait()
					os.Exit(1)
				}
				created = true
			}
		case <-time.After(200 * time.Millisecond):
			if !created {
				// Reading the entire pipe is safe here because the fixture emits
				// only its readiness line before waiting for the file event.
				continue
			}
		case <-deadline.C:
			_ = command.Process.Kill()
			_ = command.Wait()
			fmt.Fprintf(os.Stderr, "Watcher timed out: %s\n", output)
			os.Exit(1)
		}
		if bytes.Contains(output, []byte("READY")) {
			if err := os.WriteFile(filepath.Join(root, "changed.txt"), []byte("native change\n"), 0o644); err != nil {
				panic(err)
			}
			created = true
		}
	}
	status := command.Wait()
	// Closing the pipe releases a descendant that may have inherited the
	// descriptor; do not let cleanup wait forever for an EOF from that
	// descendant. The fixture itself exits promptly, but the bound is part of
	// this acceptance's process-cleanup contract.
	_ = stdout.Close()
	drain := time.NewTimer(2 * time.Second)
	defer drain.Stop()
	for {
		select {
		case data, open := <-outputChannel:
			if !open {
				goto drained
			}
			output = append(output, data...)
		case <-drain.C:
			goto drained
		}
	}
drained:
	if status != nil || !bytes.Contains(output, []byte("CHANGED")) {
		fmt.Fprintf(os.Stderr, "Watcher failed: %s\n%s\n", status, strings.TrimSpace(string(output)))
		os.Exit(1)
	}
	fmt.Println("Native module typing, permission denial and scheduler event delivery passed")
}
