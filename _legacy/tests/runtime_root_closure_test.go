// SPDX-License-Identifier: MIT
package hub

import (
	"context"
	"crypto/sha256"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"
	"github.com/wippyai/runtime/api/payload"
	regapi "github.com/wippyai/runtime/api/registry"
	"github.com/wippyai/runtime/system/registry/topology"
	"github.com/wippyai/wapp"
	"go.uber.org/zap"
)

type beeRootClosureDependency struct {
	Component string `json:"component"`
	Version   string `json:"version"`
}

// A Bee release changes both the application and its nested pack versions.
func TestBeeDeploymentRootUpdateChangesNestedVersions(t *testing.T) {
	ctx := newTestContext()
	directory := t.TempDir()
	lockPath := filepath.Join(directory, "wippy.lock")
	vendor := filepath.Join(directory, "vendor")
	workerID := regapi.NewID("deployment.modules", "worker")
	type selection struct{ module, version string }
	artifacts := make(map[selection][]byte)
	digests := make(map[selection]string)
	for _, version := range []string{"1.0.0", "2.0.0"} {
		for _, name := range []string{"app", "worker"} {
			entries := []wapp.Entry{{ID: wapp.NewID("acme."+name, "definition"), Kind: regapi.NamespaceDefinition}}
			if name == "app" {
				entries = append(entries, wapp.Entry{ID: wapp.NewID(workerID.NS, workerID.Name),
					Kind: regapi.NamespaceDependency, Data: beeRootClosureDependency{"acme/worker", version}})
			}
			selected := selection{"acme/" + name, version}
			artifact := buildWappBytes(t, entries)
			artifacts[selected] = artifact
			digests[selected] = fmt.Sprintf("sha256:%x", sha256.Sum256(artifact))
		}
	}
	require.NoError(t, os.MkdirAll(filepath.Join(vendor, "acme"), 0o700))
	for _, name := range []string{"app", "worker"} {
		require.NoError(t, os.WriteFile(filepath.Join(vendor, "acme", name+"-1.0.0.wapp"),
			artifacts[selection{"acme/" + name, "1.0.0"}], 0o600))
	}
	require.NoError(t, os.WriteFile(lockPath, []byte(fmt.Sprintf(`directories:
  modules: vendor
modules:
  - name: acme/app
    version: 1.0.0
    hash: %s
    root: true
  - name: acme/worker
    version: 1.0.0
    hash: %s
`, digests[selection{"acme/app", "1.0.0"}], digests[selection{"acme/worker", "1.0.0"}])), 0o600))

	client := &fakeHub{
		getManifest: func(_ context.Context, org, module, version string) (*ModuleManifest, error) {
			selected := selection{org + "/" + module, version}
			artifact, found := artifacts[selected]
			if !found {
				return nil, fmt.Errorf("unexpected manifest %s@%s", selected.module, selected.version)
			}
			manifest := &ModuleManifest{Org: org, Name: module, Version: version, VersionID: version,
				Digest: digests[selected], SizeBytes: uint64(len(artifact)), URL: "memory://" + module + "@" + version}
			if module == "app" {
				manifest.Dependencies = []ManifestDep{{Org: "acme", Name: "worker", Version: version,
					Constraint: version, Digest: digests[selection{"acme/worker", version}]}}
			}
			return manifest, nil
		},
		downloadFile: func(_ context.Context, url, destination string) error {
			for selected, artifact := range artifacts {
				if url == "memory://"+selected.module[len("acme/"):]+"@"+selected.version {
					if err := os.MkdirAll(filepath.Dir(destination), 0o700); err != nil {
						return err
					}
					return os.WriteFile(destination, artifact, 0o600)
				}
			}
			return fmt.Errorf("unexpected download %s", url)
		},
	}
	handler, err := NewDependencyHandler(DependencyHandlerOptions{Hub: client, Logger: zap.NewNop(),
		Resolver: topology.NewResolver(), LockPath: lockPath, VendorDir: vendor})
	require.NoError(t, err)
	baseline := regapi.State{
		ownedEntry(regapi.Entry{ID: workerID, Kind: regapi.NamespaceDependency,
			Registry: regapi.EntryMetadata{Root: true},
			Data:     payload.New(beeRootClosureDependency{"acme/worker", "1.0.0"})}, "acme/app"),
		ownedEntry(regapi.Entry{ID: regapi.NewID("acme.app", "definition"), Kind: regapi.NamespaceDefinition}, "acme/app"),
		ownedEntry(regapi.Entry{ID: regapi.NewID("acme.worker", "definition"), Kind: regapi.NamespaceDefinition}, "acme/worker"),
	}
	root := regapi.Entry{ID: regapi.NewID("deployment.packages", "application"), Kind: regapi.NamespaceDependency,
		Data: payload.New(beeRootClosureDependency{"acme/app", "2.0.0"})}
	result, err := handler.Expand(ctx, regapi.Operation{Kind: regapi.EntryUpdate, Entry: root}, baseline)
	require.NoError(t, err, "the new application owns the nested 2.0.0 declaration; its old 1.0.0 declaration cannot constrain the new closure")
	require.NotNil(t, result.Resolution)
	require.Equal(t, "2.0.0", resolutionModuleVersion(result.Resolution, "acme/app"))
	require.Equal(t, "2.0.0", resolutionModuleVersion(result.Resolution, "acme/worker"))
}
