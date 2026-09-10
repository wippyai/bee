//go:build meshclient

// SPDX-License-Identifier: MIT
package mesh

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/wippyai/bee/native/hive/rendezvous"
	stackpkg "github.com/wippyai/runtime/cluster"
	"github.com/wippyai/runtime/cluster/internode"
)

func TestLocalTLSFailureRetiresEnrollmentWithoutClientCallback(t *testing.T) {
	for _, mode := range []string{"invalid-certificate", "plaintext-owner"} {
		t.Run(mode, func(t *testing.T) {
			ctx, dir, _, _, _ := localOwner(t)
			record := filepath.Join(dir, rendezvous.EnrollmentFileName)
			before, readErr := os.ReadFile(record)
			if readErr != nil {
				t.Fatal(readErr)
			}
			transport := internode.ManagerTLSConfig{Enabled: true, CertFile: "missing-cert", KeyFile: "missing-key", CAFile: "missing-ca"}
			if mode == "plaintext-owner" {
				transport, _ = clientTestTLSCerts(t, "client", "unused")
			}
			deadline, cancel := context.WithTimeout(ctx, 2*time.Second)
			defer cancel()
			called := false
			err := Local(deadline, LocalConfig{Directory: dir, TLS: transport}, func(context.Context, *stackpkg.Stack, rendezvous.Descriptor) error { called = true; return nil })
			if err == nil || called {
				t.Fatalf("TLS failure entered client callback: called=%v err=%v", called, err)
			}
			after, readErr := os.ReadFile(record)
			if readErr != nil {
				t.Fatal(readErr)
			}
			if !bytes.Equal(before, after) {
				t.Fatal("failed client changed owner enrollment")
			}
		})
	}
}

func TestSameAccountMissingCredentialsDoesNotEnroll(t *testing.T) {
	ctx, dir, _, _, _ := localOwner(t)
	record := filepath.Join(dir, rendezvous.EnrollmentFileName)
	before, err := os.ReadFile(record)
	if err != nil {
		t.Fatal(err)
	}
	called := false
	err = SameAccount(ctx, dir, func(context.Context, *stackpkg.Stack, rendezvous.Descriptor) error { called = true; return nil })
	if err == nil || called {
		t.Fatalf("missing credentials admitted client: %v", err)
	}
	after, err := os.ReadFile(record)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(before, after) {
		t.Fatal("missing TLS credentials changed enrollment")
	}
}

func TestSameAccountLoadsOwnerCredential(t *testing.T) {
	ctx, dir, _, enrollment, descriptor := localOwnerTransport(t, internode.ManagerTLSConfig{}, true)
	called := false
	var clientNode string
	err := SameAccount(ctx, dir, func(ctx context.Context, stack *stackpkg.Stack, owner rendezvous.Descriptor) error {
		called = true
		clientNode = stack.Membership.LocalNode().ID
		if owner.Execution != descriptor.Execution || owner.Node != descriptor.Node {
			t.Error("wrong owner execution")
		}
		if _, ok := ctx.Deadline(); !ok {
			t.Error("client lost finite lifetime")
		}
		return nil
	})
	if err != nil || !called {
		t.Fatalf("automatic TLS connection failed: called=%v err=%v", called, err)
	}
	if _, ok := enrollment.Resolve(ctx, descriptor.Execution, clientNode); ok {
		t.Fatal("client enrollment retained after exit")
	}
}
