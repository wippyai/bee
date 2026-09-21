// SPDX-License-Identifier: MIT
// Verify the retained owner composes the existing Lua supervisor in source and pack launches.
package main

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

func databaseEnvironment(root string) []string {
	names := []string{"workspace", "threads", "approvals", "resources", "credentials", "gateway", "placement", "node", "governance", "sync"}
	environment := make([]string, 0, len(names)+2)
	for _, name := range names {
		environment = append(environment, "BEE_"+strings.ToUpper(name)+"_DB="+filepath.Join(root, name+".db"))
	}
	return append(environment, "BEE_CLIENT_DB="+filepath.Join(root, "client.db"), "BEE_PLACEMENT_ROOT="+filepath.Join(root, "placement"))
}

func boot(runtime, root, pack string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()
	args := []string{"run"}
	if pack != "" {
		args = append(args, pack)
	}
	args = append(args, "--verbose", "--host", "bee:workers", "--", "bee-owner")
	command := exec.CommandContext(ctx, runtime, args...)
	command.Dir = root
	command.Env = append(os.Environ(), databaseEnvironment(root)...)
	stdout, err := command.StdoutPipe()
	if err != nil {
		return err
	}
	command.Stderr = command.Stdout
	if err := command.Start(); err != nil {
		return err
	}
	ready := make(chan struct{}, 1)
	scanned := make(chan struct{})
	var lines []string
	go func() {
		defer close(scanned)
		scanner := bufio.NewScanner(stdout)
		for scanner.Scan() {
			line := scanner.Text()
			lines = append(lines, line)
			if strings.Contains(line, "Bee retained workspace ready") {
				select {
				case ready <- struct{}{}:
				default:
				}
			}
		}
	}()
	select {
	case <-ready:
	case <-scanned:
		waitErr := command.Wait()
		return fmt.Errorf("retained owner exited before ready: %v\n%s", waitErr, strings.Join(lines, "\n"))
	case <-ctx.Done():
		_ = command.Wait()
		<-scanned
		return fmt.Errorf("retained owner readiness timeout:\n%s", strings.Join(lines, "\n"))
	}
	if err := command.Process.Signal(syscall.SIGTERM); err != nil {
		cancel()
		_ = command.Wait()
		<-scanned
		return err
	}
	started := time.Now()
	err = command.Wait()
	<-scanned
	if err != nil {
		return fmt.Errorf("retained owner shutdown: %w\n%s", err, strings.Join(lines, "\n"))
	}
	if elapsed := time.Since(started); elapsed > 3*time.Second {
		return fmt.Errorf("retained owner shutdown took %s", elapsed)
	}
	for _, line := range lines {
		if strings.Contains(line, `"status":"failed"`) {
			return fmt.Errorf("retained owner background service failed: %s", line)
		}
	}
	return nil
}

func run() error {
	if len(os.Args) != 2 {
		return fmt.Errorf("usage: retained_owner RUNTIME")
	}
	runtime, err := filepath.Abs(os.Args[1])
	if err != nil {
		return err
	}
	root, err := os.MkdirTemp("", "bee-retained-owner-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(root)
	if err := os.CopyFS(filepath.Join(root, "src"), os.DirFS("src")); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Join(root, ".wippy"), 0700); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(root, "wippy.lock"), []byte("directories:\n  modules: .wippy\n  src: ./src\n"), 0600); err != nil {
		return err
	}
	manifest, err := os.ReadFile("wippy.yaml")
	if err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(root, "wippy.yaml"), manifest, 0600); err != nil {
		return err
	}
	if err := boot(runtime, root, ""); err != nil {
		return fmt.Errorf("retained owner source: %w", err)
	}
	pack := filepath.Join(root, "bee.wapp")
	packing := exec.Command(runtime, "pack", pack)
	packing.Dir = root
	if output, err := packing.CombinedOutput(); err != nil {
		return fmt.Errorf("pack retained owner source: %w: %s", err, output)
	}
	packed := filepath.Join(root, "packed")
	if err := os.Mkdir(packed, 0700); err != nil {
		return err
	}
	if err := boot(runtime, packed, pack); err != nil {
		return fmt.Errorf("retained owner pack: %w", err)
	}
	return nil
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Println("Retained owner: source and source-free pack boot the Lua workspace/desktop supervisor and stop cleanly")
}
