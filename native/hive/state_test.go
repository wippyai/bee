// SPDX-License-Identifier: MIT

package hive

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"
	app "github.com/wippyai/runtime/cmd/app"
)

func TestNodeStartIgnoresFolderState(t *testing.T) {
	for _, mode := range []string{"standalone", "hive"} {
		for _, kind := range []string{"fresh", "existing", "custom"} {
			t.Run(mode+"/"+kind, func(t *testing.T) {
				dir := isolatedConfig(t)
				if mode == "hive" {
					require.NoError(t, Init(dir))
				}
				project := t.TempDir()
				projectIgnore := filepath.Join(project, ".gitignore")
				require.NoError(t, os.WriteFile(projectIgnore, []byte("project-rule\n"), 0o600))
				state := filepath.Join(project, ".bee")
				require.NoError(t, os.Mkdir(state, 0o700))
				if kind != "fresh" {
					require.NoError(t, os.WriteFile(filepath.Join(state, "bee.db"), []byte("state"), 0o600))
				}
				want := "*"
				ignore := filepath.Join(state, ".gitignore")
				if kind == "custom" {
					want = "custom-rule\n!keep\n"
					require.NoError(t, os.WriteFile(ignore, []byte(want), 0o640))
				}
				for range 2 {
					plan, err := Component().Plan(t.Context(), app.Launch{Command: "bee", State: state, Op: app.OpRun})
					require.NoError(t, err)
					require.NotNil(t, plan.Prepare)
					_, _, err = plan.Prepare(t.Context())
					require.NoError(t, err)
					data, err := os.ReadFile(ignore)
					require.NoError(t, err)
					require.Equal(t, want, string(data))
				}
				data, err := os.ReadFile(projectIgnore)
				require.NoError(t, err)
				require.Equal(t, "project-rule\n", string(data))
				if kind == "custom" {
					info, err := os.Stat(ignore)
					require.NoError(t, err)
					require.Equal(t, os.FileMode(0o640), info.Mode().Perm())
				}
				pending, err := filepath.Glob(filepath.Join(state, ".gitignore-*"))
				require.NoError(t, err)
				require.Empty(t, pending)
			})
		}
	}
}
