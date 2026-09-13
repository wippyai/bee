//go:build integration

// SPDX-License-Identifier: MIT

package docker

import (
	"bufio"
	"context"
	"fmt"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/moby/moby/api/types/container"
	"github.com/moby/moby/client"
)

// Requires a local daemon and already-local alpine:latest. The fixture uses
// Docker directly; it does not establish Bee's full sandbox/profile admission.
func TestExistingContainerPTYIntegration(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	cli, err := client.New(client.FromEnv)
	if err != nil {
		t.Fatal(err)
	}
	defer cli.Close()
	image, err := cli.ImageInspect(ctx, "alpine:latest")
	if err != nil {
		t.Fatal("local image required; no pulls:", err)
	}
	name := fmt.Sprintf("bee-attachment-test-%d", time.Now().UnixNano())
	labels := map[string]string{"bee.test": name}
	created, err := cli.ContainerCreate(ctx, client.ContainerCreateOptions{
		Config:     &container.Config{Image: image.ID, Cmd: []string{"sh", "-c", "stty -echo; echo ready; IFS= read line; printf 'input=%s\\n' \"$line\"; stty size; sleep 60"}, Tty: true, OpenStdin: true, AttachStdin: true, AttachStdout: true, AttachStderr: true, Labels: labels},
		HostConfig: &container.HostConfig{AutoRemove: false}, Name: name,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		cleanupCtx, cleanupCancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cleanupCancel()
		_, err := cli.ContainerRemove(cleanupCtx, created.ID, client.ContainerRemoveOptions{Force: true})
		if err != nil {
			t.Errorf("fixture cleanup: %v", err)
		}
	}()
	if _, err := cli.ContainerStart(ctx, created.ID, client.ContainerStartOptions{}); err != nil {
		t.Fatal(err)
	}
	observed, err := cli.ContainerInspect(ctx, created.ID, client.ContainerInspectOptions{})
	if err != nil {
		t.Fatal(err)
	}
	handle, err := New(ctx, cli, Identity{ContainerID: created.ID, ImageID: image.ID, StartedAt: observed.Container.State.StartedAt, Labels: labels})
	if err != nil {
		t.Fatal(err)
	}
	defer handle.Stop()
	labels["bee.test"] = "caller-mutated-after-admission"
	if err := handle.Start(); err != nil {
		t.Fatal(err)
	}
	if err := handle.Start(); err == nil {
		t.Fatal("duplicate attachment allowed")
	}
	output := handle.Stdout()
	defer output.Close()
	lines := make(chan string, 32)
	go func() {
		defer close(lines)
		scanner := bufio.NewScanner(output)
		for scanner.Scan() {
			select {
			case lines <- scanner.Text():
			case <-ctx.Done():
				return
			}
		}
	}()
	waitLine := func(want string) {
		t.Helper()
		for {
			select {
			case line, ok := <-lines:
				if !ok {
					t.Fatal("stream closed before", want)
				}
				if strings.Contains(line, want) {
					return
				}
			case <-ctx.Done():
				t.Fatal("waiting for", want, ctx.Err())
			}
		}
	}
	waitLine("ready")
	if err := handle.Resize(80, 24); err != nil {
		t.Fatal(err)
	}
	if err := handle.WriteStdin([]byte("hello\n")); err != nil {
		t.Fatal(err)
	}
	waitLine("input=hello")
	waitLine("24 80")
	if err := handle.Signal(int(syscall.SIGKILL)); err != nil {
		t.Fatal(err)
	}
	if err := handle.Wait(); err == nil {
		t.Fatal("killed container reported successful exit")
	}
	after, err := cli.ContainerInspect(ctx, created.ID, client.ContainerInspectOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if after.Container.ID != created.ID || after.Container.State.Status != container.StateExited || after.Container.Name != "/"+name {
		t.Fatal("wrong container lifecycle result")
	}
}
