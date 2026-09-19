// SPDX-License-Identifier: MIT
// Verify source headless startup and shutdown without allocating a PTY.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"time"
)

func boot(runtime, root, pack string) (string, error) {
	// Source-free fixtures need the normal local resource directory too.
	if err := os.MkdirAll(filepath.Join(root, ".wippy"), 0700); err != nil {
		return "", err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()
	verbosity := "--verbose"
	args := []string{"run"}
	if pack != "" {
		args = append(args, pack)
	}
	args = append(args, verbosity, "--host", "bee:workers", "--", "bee-host")
	cmd := exec.CommandContext(ctx, runtime, args...)
	cmd.Dir = root
	cmd.Env = append(os.Environ(), "BEE_WORKSPACE_DB="+filepath.Join(root, "workspace.db"), "BEE_THREADS_DB="+filepath.Join(root, "threads.db"))
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return "", err
	}
	cmd.Stderr = cmd.Stdout
	if err := cmd.Start(); err != nil {
		return "", err
	}
	ready := make(chan string, 1)
	scanned := make(chan struct{})
	var trace []string
	go func() {
		defer close(scanned)
		scanner := bufio.NewScanner(stdout)
		for scanner.Scan() {
			trace = append(trace, scanner.Text())
			if strings.Contains(scanner.Text(), "Bee workspace ready") {
				match := regexp.MustCompile(`"workspace_id":\s*"([^"]+)"`).FindStringSubmatch(scanner.Text())
				if len(match) != 2 {
					continue
				}
				id := match[1]
				select {
				case ready <- id:
				default:
				}
			}
		}
	}()
	var identity string
	select {
	case identity = <-ready:
	case <-scanned:
		waitErr := cmd.Wait()
		return "", fmt.Errorf("host exited before ready: %v\n%s", waitErr, strings.Join(trace, "\n"))
	case <-ctx.Done():
		_ = cmd.Wait()
		<-scanned
		return "", fmt.Errorf("headless readiness timeout:\n%s", strings.Join(trace, "\n"))
	}
	started := time.Now()
	if err := cmd.Process.Signal(syscall.SIGTERM); err != nil {
		cancel()
		_ = cmd.Wait()
		<-scanned
		return "", err
	}
	err = cmd.Wait()
	<-scanned
	if err != nil {
		return "", fmt.Errorf("headless shutdown: %v\n%s", err, strings.Join(trace, "\n"))
	}
	if elapsed := time.Since(started); elapsed > 3*time.Second {
		return "", fmt.Errorf("headless shutdown took %s", elapsed)
	}
	// A ready workspace does not imply that its other auto-start services booted.
	// Inspect after the reader has joined so startup failure cannot be hidden by
	// successful owner readiness or a clean shutdown exit code.
	for _, line := range trace {
		fields := strings.IndexByte(line, '{')
		if fields < 0 {
			continue
		}
		var state struct {
			ServiceID string `json:"serviceID"`
			Status    string `json:"status"`
			Error     string `json:"error"`
		}
		if json.Unmarshal([]byte(line[fields:]), &state) == nil && state.ServiceID != "" && state.Status == "failed" {
			return "", fmt.Errorf("headless background service %s failed: %s", state.ServiceID, state.Error)
		}
	}
	return identity, nil
}

func run() error {
	if len(os.Args) != 2 {
		return fmt.Errorf("usage: headless RUNTIME")
	}
	runtime, err := filepath.Abs(os.Args[1])
	if err != nil {
		return err
	}
	root, err := os.MkdirTemp("", "bee-headless-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(root)
	if err := os.CopyFS(filepath.Join(root, "src"), os.DirFS("src")); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(root, "wippy.lock"), []byte("directories:\n  modules: .wippy\n  src: ./src\n"), 0600); err != nil {
		return err
	}
	manifest, manifestErr := os.ReadFile("wippy.yaml")
	if manifestErr != nil {
		return manifestErr
	}
	if err := os.WriteFile(filepath.Join(root, "wippy.yaml"), manifest, 0600); err != nil {
		return err
	}
	first, err := boot(runtime, root, "")
	if err != nil {
		return err
	}
	second, err := boot(runtime, root, "")
	if err != nil {
		return err
	}
	if first == "" || first != second {
		return fmt.Errorf("workspace identity changed across headless restart: %q %q", first, second)
	}
	fmt.Println("Headless source: piped boot, recovered readiness, stable workspace identity and bounded signal shutdown")
	pack := filepath.Join(root, "bee.wapp")
	packing := exec.Command(runtime, "pack", pack)
	packing.Dir = root
	if output, err := packing.CombinedOutput(); err != nil {
		return fmt.Errorf("pack headless source: %w: %s", err, output)
	}
	packed := filepath.Join(root, "packed")
	if err := os.Mkdir(packed, 0700); err != nil {
		return err
	}
	first, err = boot(runtime, packed, pack)
	if err != nil {
		return err
	}
	second, err = boot(runtime, packed, pack)
	if err != nil {
		return err
	}
	if first == "" || first != second {
		return fmt.Errorf("packed workspace identity changed: %q %q", first, second)
	}
	fmt.Println("Headless pack: source-free piped boot, stable workspace identity and bounded signal shutdown")
	return nil
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
