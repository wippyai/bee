// SPDX-License-Identifier: MIT

package rendezvous

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

func enrollmentFor(t *testing.T) (*Enrollment, string, []byte) {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "discovery")
	e, err := NewEnrollment(dir)
	if err != nil {
		t.Fatal(err)
	}
	secret := bytes.Repeat([]byte{17}, 32)
	if err := e.Initialize(context.Background(), sample().Execution, secret); err != nil {
		t.Fatal(err)
	}
	return e, dir, secret
}

func TestLocalEnrollmentFencesOwnerAndClientCleanup(t *testing.T) {
	e, _, secret := enrollmentFor(t)
	ctx := context.Background()
	execution := sample().Execution
	key := ed25519.PublicKey(bytes.Repeat([]byte{2}, 32))
	other := ed25519.PublicKey(bytes.Repeat([]byte{3}, 32))
	s, err := e.Register(ctx, execution, "client", key)
	if err != nil || !bytes.Equal(s.GossipKey(), secret) {
		t.Fatal("register", err)
	}
	if _, err := e.Register(ctx, execution, "client", key); err != nil {
		t.Fatal("retry", err)
	}
	if err := e.Initialize(ctx, execution, secret); err != nil {
		t.Fatal("bootstrap retry", err)
	}
	if err := e.Initialize(ctx, execution, bytes.Repeat([]byte{9}, 32)); !errors.Is(err, ErrBootstrapConflict) {
		t.Fatal("bootstrap conflict", err)
	}
	if _, err := e.Register(ctx, execution, "client", other); !errors.Is(err, ErrPeerConflict) {
		t.Fatal("conflict", err)
	}
	if err := e.Remove(ctx, execution, "client", other); !errors.Is(err, ErrPeerConflict) {
		t.Fatal("foreign cleanup", err)
	}
	if resolved, ok := e.Resolve(ctx, execution, "client"); !ok || !bytes.Equal(resolved, key) {
		t.Fatal("wrong approved key")
	}
	// Snapshot readers cannot mutate either the file or the snapshot itself.
	copy := s.GossipKey()
	copy[0]++
	copyKey, _ := s.PeerKey("client")
	copyKey[0]++
	if !bytes.Equal(s.GossipKey(), secret) {
		t.Fatal("secret alias")
	}
	if own, _ := s.PeerKey("client"); !bytes.Equal(own, key) {
		t.Fatal("key alias")
	}
	if err := e.Remove(ctx, execution, "client", key); err != nil {
		t.Fatal(err)
	}
	if _, ok := e.Resolve(ctx, execution, "client"); ok {
		t.Fatal("removed key still approved")
	}
	if err := e.Remove(ctx, execution, "client", key); err != nil {
		t.Fatal("remove retry", err)
	}
	replacement := strings.Repeat("b", 32)
	if err := e.Initialize(ctx, replacement, secret); err != nil {
		t.Fatal(err)
	}
	if _, err := e.Register(ctx, execution, "client", key); !errors.Is(err, ErrOwnerChanged) {
		t.Fatal("stale register", err)
	}
	if err := e.Remove(ctx, execution, "client", key); !errors.Is(err, ErrOwnerChanged) {
		t.Fatal("stale cleanup", err)
	}
	if _, ok := e.Resolve(ctx, execution, "client"); ok {
		t.Fatal("retired owner source remained usable")
	}
}

func TestEnrollmentConcurrentRegistrationPreservesEveryKey(t *testing.T) {
	e, _, _ := enrollmentFor(t)
	var workers sync.WaitGroup
	for i := range 24 {
		workers.Go(func() {
			key := ed25519.PublicKey(bytes.Repeat([]byte{byte(i)}, 32))
			if _, err := e.Register(context.Background(), sample().Execution, fmt.Sprintf("client-%d", i), key); err != nil {
				t.Error(err)
			}
		})
	}
	workers.Wait()
	s, err := e.Read(context.Background(), sample().Execution)
	if err != nil || len(s.peers) != 24 {
		t.Fatalf("lost enrollment: %d %v", len(s.peers), err)
	}
	for i := range 24 {
		key, ok := s.PeerKey(fmt.Sprintf("client-%d", i))
		if !ok || !bytes.Equal(key, bytes.Repeat([]byte{byte(i)}, 32)) {
			t.Fatal("wrong key", i)
		}
	}
}

func TestEnrollmentRejectsMalformedAndRedactsSecrets(t *testing.T) {
	e, dir, secret := enrollmentFor(t)
	s, err := e.Read(context.Background(), sample().Execution)
	if err != nil {
		t.Fatal(err)
	}
	encoded := base64.RawStdEncoding.EncodeToString(secret)
	for _, format := range []string{"%v", "%+v", "%#v", "%s", "%q"} {
		if rendered := fmt.Sprintf(format, s); strings.Contains(rendered, encoded) || strings.Contains(rendered, fmt.Sprint(secret)) {
			t.Fatal("secret disclosed")
		}
	}
	data, err := os.ReadFile(filepath.Join(dir, EnrollmentFileName))
	if err != nil {
		t.Fatal(err)
	}
	key := base64.RawStdEncoding.EncodeToString(make([]byte, 32))
	cases := []string{
		strings.Replace(string(data), `"version":2`, `"version":2,"version":2`, 1),
		strings.Replace(string(data), `"version":2`, `"Version":1`, 1),
		strings.Replace(string(data), `"version":2`, `"version":null`, 1),
		strings.Replace(string(data), `"version":2`, `"unknown":1`, 1),
		strings.Replace(string(data), `"peers":{}`, `"peers":{"client":"`+key+`","client":"`+key+`"}`, 1),
		strings.Replace(string(data), `"peers":{}`, `"peers":{"client":null}`, 1),
		string(data) + `{}`,
	}
	for _, bad := range cases {
		if _, err := decodeEnrollment([]byte(bad)); !errors.Is(err, ErrEnrollment) {
			t.Fatalf("accepted malformed record: %v", err)
		}
	}
	if err := os.WriteFile(filepath.Join(dir, EnrollmentFileName), []byte("broken"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, ok := e.Resolve(context.Background(), sample().Execution, "client"); ok {
		t.Fatal("corrupt enrollment authorized")
	}
	if _, err := e.Register(context.Background(), sample().Execution, "client", make([]byte, 32)); !errors.Is(err, ErrEnrollment) {
		t.Fatal("corrupt enrollment overwritten", err)
	}
	unchanged, _ := os.ReadFile(filepath.Join(dir, EnrollmentFileName))
	if string(unchanged) != "broken" {
		t.Fatal("failed registration changed state")
	}
}

func TestEnrollmentCapacityAndCanceledWrites(t *testing.T) {
	e, dir, _ := enrollmentFor(t)
	record := enrollmentRecord{Version: 2, Slots: map[string]int{}, Execution: sample().Execution, Secret: base64.RawStdEncoding.EncodeToString(make([]byte, 32)), Peers: map[string]string{}}
	key := base64.RawStdEncoding.EncodeToString(make([]byte, 32))
	for i := range MaxLocalPeers {
		record.Peers[fmt.Sprintf("client-%d", i)] = key
	}
	data, _ := json.Marshal(record)
	if err := os.WriteFile(filepath.Join(dir, EnrollmentFileName), data, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := e.Register(context.Background(), record.Execution, "extra", make([]byte, 32)); !errors.Is(err, ErrPeerCapacity) {
		t.Fatal("capacity", err)
	}
	if _, err := e.Register(context.Background(), record.Execution, "client-0", make([]byte, 32)); err != nil {
		t.Fatal("retry at capacity", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := e.Remove(ctx, record.Execution, "client-0", make([]byte, 32)); !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	after, _ := os.ReadFile(filepath.Join(dir, EnrollmentFileName))
	if !bytes.Equal(data, after) {
		t.Fatal("failed operation altered record")
	}
}

func TestEnrollmentVersionOneUpgradesOnlyOnMutation(t *testing.T) {
	e, dir, secret := enrollmentFor(t)
	path := filepath.Join(dir, EnrollmentFileName)
	key := bytes.Repeat([]byte{7}, 32)
	legacy, err := json.Marshal(map[string]interface{}{"version": 1, "execution": sample().Execution, "secret": base64.RawStdEncoding.EncodeToString(secret), "peers": map[string]string{"legacy": base64.RawStdEncoding.EncodeToString(key)}})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, legacy, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := e.Read(context.Background(), sample().Execution); err != nil {
		t.Fatal(err)
	}
	after, err := os.ReadFile(path)
	if err != nil || !bytes.Equal(legacy, after) {
		t.Fatal("read changed legacy file", err)
	}
	lease, state, err := e.RegisterHeld(context.Background(), sample().Execution, "new", key)
	if err != nil {
		t.Fatal(err)
	}
	defer lease.Close(context.Background())
	if preserved, ok := state.PeerKey("legacy"); !ok || !bytes.Equal(preserved, key) {
		t.Fatal("lost legacy key")
	}
	after, err = os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var upgraded enrollmentRecord
	if err := json.Unmarshal(after, &upgraded); err != nil || upgraded.Version != 2 || len(upgraded.Slots) != 1 {
		t.Fatal("invalid upgrade", err)
	}
}

func TestEnrollmentRejectsInvalidSlots(t *testing.T) {
	key := base64.RawStdEncoding.EncodeToString(make([]byte, 32))
	prefix := fmt.Sprintf(`{"version":2,"execution":%q,"secret":%q,"peers":{"a":%q,"b":%q}`, sample().Execution, key, key, key)
	for _, suffix := range []string{`}`, `,"slots":null}`, `,"slots":{"a":null}}`, `,"slots":{"a":0,"a":1}}`, `,"slots":{"a":0,"b":0}}`, `,"slots":{"unknown":0}}`, `,"slots":{"a":-1}}`, `,"slots":{"a":128}}`, `,"slots":{"a":0.5}}`} {
		if _, err := decodeEnrollment([]byte(prefix + suffix)); !errors.Is(err, ErrEnrollment) {
			t.Fatalf("accepted invalid slots %s: %v", suffix, err)
		}
	}
}
