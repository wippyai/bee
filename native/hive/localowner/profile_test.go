//go:build meshclient

// SPDX-License-Identifier: MIT

package localowner

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/pem"
	"errors"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	machineconfig "github.com/wippyai/bee/native/hive/config"
	"github.com/wippyai/bee/native/hive/rendezvous"
	clusterapi "github.com/wippyai/runtime/api/cluster"
	app "github.com/wippyai/runtime/cmd/app"
)

func privateDirectory(t *testing.T) string {
	t.Helper()
	directory := filepath.Join(t.TempDir(), "private")
	if err := os.Mkdir(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	return directory
}

func joinedProfileTLS(t *testing.T) (string, string, string) {
	t.Helper()
	now := time.Now()
	rootPublic, rootPrivate, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	root := &x509.Certificate{
		SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "joined profile test root"},
		NotBefore: now.Add(-time.Minute), NotAfter: now.Add(time.Hour), IsCA: true,
		BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign,
	}
	rootDER, err := x509.CreateCertificate(rand.Reader, root, root, rootPublic, rootPrivate)
	if err != nil {
		t.Fatal(err)
	}
	leafPublic, leafPrivate, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	leaf := &x509.Certificate{
		SerialNumber: big.NewInt(2), Subject: pkix.Name{CommonName: "joined profile test owner"},
		NotBefore: now.Add(-time.Minute), NotAfter: now.Add(time.Hour),
		KeyUsage:              x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth, x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		IPAddresses:           []net.IP{net.ParseIP("127.0.0.1"), net.ParseIP("::1")},
	}
	leafDER, err := x509.CreateCertificate(rand.Reader, leaf, root, leafPublic, rootPrivate)
	if err != nil {
		t.Fatal(err)
	}
	keyDER, err := x509.MarshalPKCS8PrivateKey(leafPrivate)
	if err != nil {
		t.Fatal(err)
	}
	directory := t.TempDir()
	certPath, keyPath, caPath := filepath.Join(directory, "owner.pem"), filepath.Join(directory, "owner.key"), filepath.Join(directory, "ca.pem")
	for path, data := range map[string][]byte{
		certPath: pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: leafDER}),
		keyPath:  pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER}),
		caPath:   pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: rootDER}),
	} {
		if err := os.WriteFile(path, data, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return certPath, keyPath, caPath
}

func TestMissingMachineProfileKeepsLocalOwner(t *testing.T) {
	configuration := privateDirectory(t)
	state := privateDirectory(t)
	owner, err := New(Options{Node: "local-node", Lifetime: time.Minute, ConfigDirectory: configuration})
	if err != nil {
		t.Fatal(err)
	}
	resources, err := owner.PrepareOwner(context.Background(), app.LaunchRequest{StateDir: state})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = resources.Close() })
	for key, expected := range map[string]any{
		"cluster.name":                     "local-node",
		"relay.node_name":                  "local-node",
		"cluster.membership.bind_addr":     "127.0.0.1",
		"cluster.membership.join_addrs":    "",
		"cluster.internode.advertise_addr": "127.0.0.1",
		"cluster.internode.advertise_port": 0,
	} {
		actual, ok := resources.Config.Get(key)
		if !ok || actual != expected {
			t.Fatalf("%s = %#v, present %v; want %#v", key, actual, ok, expected)
		}
	}
	if _, err := os.Stat(filepath.Join(configuration, machineconfig.ConfigFileName)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("missing profile was created: %v", err)
	}
}

func TestCorruptMachineProfileFailsWithoutReplacement(t *testing.T) {
	configuration := privateDirectory(t)
	state := privateDirectory(t)
	path := filepath.Join(configuration, machineconfig.ConfigFileName)
	original := []byte(`{"version":1,"revision":1,"hive":null,"workspaces":[]}`)
	if err := os.WriteFile(path, original, 0o600); err != nil {
		t.Fatal(err)
	}
	owner, err := New(Options{Node: "local-node", Lifetime: time.Minute, ConfigDirectory: configuration})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = owner.PrepareOwner(context.Background(), app.LaunchRequest{StateDir: state}); !errors.Is(err, machineconfig.ErrMalformedDocument) {
		t.Fatalf("expected malformed profile, got %v", err)
	}
	after, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(after) != string(original) {
		t.Fatal("corrupt machine profile was replaced")
	}
}

func TestJoinedMachineProfileSuppliesExactNativeCluster(t *testing.T) {
	configuration := privateDirectory(t)
	state := privateDirectory(t)
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	peerPublic, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	secret := make([]byte, 32)
	if _, err = rand.Read(secret); err != nil {
		t.Fatal(err)
	}
	certPath, keyPath, caPath := joinedProfileTLS(t)
	profile := machineconfig.HiveProfile{
		Mode: machineconfig.HiveModeJoined, HiveID: "hive-one", NodeID: "joined-node",
		Seeds:               []string{"192.0.2.10:4400", "192.0.2.11:4400"},
		MembershipSecret:    machineconfig.Secret(base64.StdEncoding.EncodeToString(secret)),
		InternodePrivateKey: machineconfig.Secret(base64.StdEncoding.EncodeToString(private)),
		PeerPublicKeys: map[string]string{
			"joined-node": base64.StdEncoding.EncodeToString(public),
			"seed-node":   base64.StdEncoding.EncodeToString(peerPublic),
		},
		TLSCertPath: certPath, TLSKeyPath: keyPath, TLSCAPath: caPath,
		MembershipBindAddress: "0.0.0.0", MembershipBindPort: 4400,
		MembershipAdvertiseAddress: "192.0.2.20", MembershipAdvertisePort: 4400,
		InternodeBindAddress: "0.0.0.0", InternodeBindPort: 4401,
		InternodeAdvertiseAddress: "192.0.2.20", InternodeAdvertisePort: 4401,
	}
	store, err := machineconfig.New(configuration)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = store.Update(context.Background(), 0, func(document machineconfig.Document) (machineconfig.Document, error) {
		document.Hive = profile
		return document, nil
	}); err != nil {
		t.Fatal(err)
	}
	owner, err := New(Options{Node: "ignored-local-label", Lifetime: time.Minute, ConfigDirectory: configuration})
	if err != nil {
		t.Fatal(err)
	}
	resources, err := owner.PrepareOwner(context.Background(), app.LaunchRequest{StateDir: state})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = resources.Close() })
	expected := map[string]any{
		"cluster.name":                                  "joined-node",
		"relay.node_name":                               "joined-node",
		"cluster.membership.bind_addr":                  "0.0.0.0",
		"cluster.membership.bind_port":                  4400,
		"cluster.membership.advertise_addr":             "192.0.2.20",
		"cluster.membership.advertise_port":             4400,
		"cluster.membership.join_addrs":                 "192.0.2.10:4400,192.0.2.11:4400",
		"cluster.membership.secret_key":                 base64.StdEncoding.EncodeToString(secret),
		"cluster.internode.bind_addr":                   "0.0.0.0",
		"cluster.internode.bind_port":                   4401,
		"cluster.internode.auto_port":                   false,
		"cluster.internode.advertise_addr":              "192.0.2.20",
		"cluster.internode.advertise_port":              4401,
		"cluster.internode.identity_key":                base64.RawStdEncoding.EncodeToString(private),
		"cluster.internode.trusted_peer_keys.seed-node": base64.StdEncoding.EncodeToString(peerPublic),
	}
	snapshot, ok := resources.Config.Get("cluster.internode.tls.cert_file")
	if !ok {
		t.Fatal("joined TLS snapshot missing")
	}
	snapshotPath, ok := snapshot.(string)
	if !ok || snapshotPath == certPath || filepath.Dir(snapshotPath) != filepath.Join(state, DirectoryName) {
		t.Fatalf("joined TLS snapshot path = %#v", snapshot)
	}
	for _, key := range []string{"cluster.internode.tls.key_file", "cluster.internode.tls.ca_file"} {
		value, present := resources.Config.Get(key)
		if !present || value != snapshotPath {
			t.Fatalf("%s = %#v, want execution snapshot %q", key, value, snapshotPath)
		}
	}
	for key, want := range expected {
		actual, ok := resources.Config.Get(key)
		if !ok || actual != want {
			t.Fatalf("%s = %#v, present %v; want %#v", key, actual, ok, want)
		}
	}
	raw, ok := resources.Config.Get("cluster.internode.peer_key_source")
	if !ok {
		t.Fatal("native peer key source missing")
	}
	source, ok := raw.(clusterapi.PeerKeySource)
	if !ok {
		t.Fatalf("peer key source has type %T", raw)
	}
	resolved, ok := source("seed-node")
	if !ok || !resolved.Equal(peerPublic) {
		t.Fatal("peer key source did not return the pinned peer")
	}
	clientPublic, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	enrollment, err := rendezvous.NewEnrollment(filepath.Join(state, DirectoryName))
	if err != nil {
		t.Fatal(err)
	}
	lease, _, err := enrollment.RegisterHeld(context.Background(), owner.state.execution, "physical-client", clientPublic)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = lease.Close(context.Background()) })
	resolved, ok = source("physical-client")
	if !ok || !resolved.Equal(clientPublic) {
		t.Fatal("joined owner did not accept its execution-enrolled physical client key")
	}
}
