// SPDX-License-Identifier: MIT

package docker

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/moby/moby/client"
)

func admitted() Identity {
	return Identity{ContainerID: strings.Repeat("a", 64), ImageID: "sha256:" + strings.Repeat("b", 64), StartedAt: "2026-09-13T12:00:00Z", Labels: map[string]string{"attempt": "one"}}
}
func TestRejectsUnqualifiedIdentityBeforeDaemonIO(t *testing.T) {
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { requests.Add(1); http.Error(w, "unexpected", 500) }))
	defer server.Close()
	cli, err := client.New(client.WithHost("tcp://"+strings.TrimPrefix(server.URL, "http://")), client.WithAPIVersion("1.44"))
	if err != nil {
		t.Fatal(err)
	}
	defer cli.Close()
	for _, edit := range []func(*Identity){
		func(i *Identity) { i.ContainerID = "short" }, func(i *Identity) { i.ImageID = "alpine:latest" }, func(i *Identity) { i.Labels = nil }, func(i *Identity) { i.StartedAt = "" },
	} {
		expected := admitted()
		edit(&expected)
		handle, err := New(context.Background(), cli, expected)
		if err == nil || handle != nil {
			t.Fatal("invalid identity accepted")
		}
	}
	if requests.Load() != 0 {
		t.Fatal("invalid identity contacted daemon")
	}
}
func TestStartRejectsChangedContainerWithoutSideEffects(t *testing.T) {
	for _, changed := range []string{"id", "image", "labels", "tty", "stdin", "state", "execution"} {
		t.Run(changed, func(t *testing.T) {
			expected := admitted()
			var inspect, mutations atomic.Int32
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Method != "GET" || !strings.HasSuffix(r.URL.Path, "/containers/"+expected.ContainerID+"/json") {
					mutations.Add(1)
					http.Error(w, "unexpected mutation", 500)
					return
				}
				inspect.Add(1)
				config := map[string]any{"Tty": true, "OpenStdin": true, "AttachStdin": true, "Labels": expected.Labels}
				state := map[string]any{"Status": "running", "StartedAt": expected.StartedAt}
				body := map[string]any{"Id": expected.ContainerID, "Image": expected.ImageID, "Config": config, "State": state}
				switch changed {
				case "id":
					body["Id"] = strings.Repeat("c", 64)
				case "image":
					body["Image"] = "sha256:" + strings.Repeat("c", 64)
				case "labels":
					config["Labels"] = map[string]string{"attempt": "other"}
				case "tty":
					config["Tty"] = false
				case "stdin":
					config["OpenStdin"] = false
				case "state":
					state["Status"] = "exited"
				case "execution":
					state["StartedAt"] = "2026-09-13T12:00:01Z"
				}
				w.Header().Set("Content-Type", "application/json")
				_ = json.NewEncoder(w).Encode(body)
			}))
			defer server.Close()
			cli, err := client.New(client.WithHost("tcp://"+strings.TrimPrefix(server.URL, "http://")), client.WithAPIVersion("1.44"))
			if err != nil {
				t.Fatal(err)
			}
			defer cli.Close()
			handle, err := New(context.Background(), cli, expected)
			if err != nil {
				t.Fatal(err)
			}
			defer handle.Stop()
			if err := handle.Start(); err == nil {
				t.Fatal("changed container was attached")
			}
			if inspect.Load() != 1 || mutations.Load() != 0 {
				t.Fatalf("unexpected daemon operations: inspect=%d other=%d", inspect.Load(), mutations.Load())
			}
		})
	}
}
func TestUnusedHandleDoesNotControlContainer(t *testing.T) {
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { requests.Add(1); http.Error(w, "unexpected", 500) }))
	defer server.Close()
	cli, err := client.New(client.WithHost("tcp://"+strings.TrimPrefix(server.URL, "http://")), client.WithAPIVersion("1.44"))
	if err != nil {
		t.Fatal(err)
	}
	defer cli.Close()
	handle, err := New(context.Background(), cli, admitted())
	if err != nil {
		t.Fatal(err)
	}
	handle.Stop()
	if err := handle.Resize(80, 24); err == nil {
		t.Fatal("retired handle resized a container")
	}
	if err := handle.Signal(9); err == nil {
		t.Fatal("retired handle signaled a container")
	}
	if err := handle.Start(); err == nil {
		t.Fatal("retired handle restarted")
	}
	if requests.Load() != 0 {
		t.Fatal("retiring unused handle controlled the container")
	}
}

func TestChangedExecutionRefusesControl(t *testing.T) {
	expected := admitted()
	var mutations atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "GET" {
			mutations.Add(1)
			http.Error(w, "unexpected", 500)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"Id": expected.ContainerID, "Image": expected.ImageID, "Config": map[string]any{"Tty": true, "OpenStdin": true, "AttachStdin": true, "Labels": expected.Labels}, "State": map[string]any{"Status": "running", "StartedAt": "2026-09-13T12:00:01Z"}})
	}))
	defer server.Close()
	cli, err := client.New(client.WithHost("tcp://"+strings.TrimPrefix(server.URL, "http://")), client.WithAPIVersion("1.44"))
	if err != nil {
		t.Fatal(err)
	}
	defer cli.Close()
	handle, err := New(context.Background(), cli, expected)
	if err != nil {
		t.Fatal(err)
	}
	defer handle.CancelWait()
	// Only the inspect path should execute; no connection I/O is supplied.
	handle.started = true
	handle.connection = &client.ContainerAttachResult{}
	if err := handle.Signal(9); err == nil {
		t.Fatal("signaled a replacement execution")
	}
	if err := handle.Resize(80, 24); err == nil {
		t.Fatal("resized a replacement execution")
	}
	if mutations.Load() != 0 {
		t.Fatal("changed execution received a control operation")
	}
}

func TestFailedRecheckClosesAttachment(t *testing.T) {
	expected := admitted()
	var inspections atomic.Int32
	closed := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == "POST" && strings.HasSuffix(r.URL.Path, "/attach") {
			connection, buffer, err := w.(http.Hijacker).Hijack()
			if err != nil {
				t.Error(err)
				return
			}
			_, _ = buffer.WriteString("HTTP/1.1 101 UPGRADED\r\nContent-Type: application/vnd.docker.raw-stream\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n\r\n")
			_ = buffer.Flush()
			go func() { defer connection.Close(); var b [1]byte; _, _ = connection.Read(b[:]); close(closed) }()
			return
		}
		if r.Method != "GET" {
			http.Error(w, "unexpected mutation", 500)
			return
		}
		image := expected.ImageID
		if inspections.Add(1) > 1 {
			image = "sha256:" + strings.Repeat("c", 64)
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"Id": expected.ContainerID, "Image": image, "Config": map[string]any{"Tty": true, "OpenStdin": true, "AttachStdin": true, "Labels": expected.Labels}, "State": map[string]any{"Status": "running", "StartedAt": expected.StartedAt}})
	}))
	defer server.Close()
	cli, err := client.New(client.WithHost("tcp://"+strings.TrimPrefix(server.URL, "http://")), client.WithAPIVersion("1.44"))
	if err != nil {
		t.Fatal(err)
	}
	defer cli.Close()
	handle, err := New(context.Background(), cli, expected)
	if err != nil {
		t.Fatal(err)
	}
	defer handle.Stop()
	startError := handle.Start()
	if startError == nil {
		t.Fatal("changed container survived attachment recheck")
	}
	if inspections.Load() != 2 {
		t.Fatalf("attachment was not rechecked: %v", startError)
	}
	select {
	case <-closed:
	case <-time.After(time.Second):
		t.Fatal("failed recheck leaked the attached connection")
	}
	if handle.Stdout() != nil {
		t.Fatal("failed attachment published an output stream")
	}
}

func TestCanceledWaitDoesNotProveContainerExit(t *testing.T) {
	entered := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" || !strings.HasSuffix(r.URL.Path, "/wait") {
			http.Error(w, "unexpected control", 500)
			return
		}
		close(entered)
		<-r.Context().Done()
	}))
	defer server.Close()
	cli, err := client.New(client.WithHost("tcp://"+strings.TrimPrefix(server.URL, "http://")), client.WithAPIVersion("1.44"))
	if err != nil {
		t.Fatal(err)
	}
	defer cli.Close()
	handle, err := New(context.Background(), cli, admitted())
	if err != nil {
		t.Fatal(err)
	}
	defer handle.CancelWait()
	handle.started = true
	handle.connection = &client.ContainerAttachResult{}
	done := make(chan error, 1)
	go func() { done <- handle.Wait() }()
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("wait was not dispatched")
	}
	handle.CancelWait()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("canceled wait: %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("wait did not cancel")
	}
	handle.mu.Lock()
	stopped := handle.stopped
	handle.mu.Unlock()
	if stopped {
		t.Fatal("cancellation was recorded as container exit")
	}
}
