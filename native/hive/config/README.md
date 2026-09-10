# Machine configuration

This native store remembers project/workspace locations and an optional enrollment
reference in protected `config.json`, using the stable `.config.lock` companion.
The host supplies the directory. The public launcher does not consume it yet.

`New` creates no files. `Read` returns a validated document; missing configuration
returns `os.ErrNotExist` without creating anything. `Update` checks an expected
revision while holding the private-file lock. A concurrent stale writer receives
`ErrConflict` and must read again before deciding how to retry. The callback may
change content, but the store owns schema version and revision. Callback errors
and publication uncertainty propagate to the caller.

Version 1 stores `version`, `revision`, `enrollment_ref` and `workspaces`. Each
location has `workspace_id`, `project_dir` and `runtime_state_dir`. Several
project directories may select one workspace, and several workspace IDs may
share a runtime state directory. That directory locates registry/deployment
storage; it is not a workspace database binding or permission. Paths must be
absolute and cleaned; the launch caller resolves project-directory aliases.
Reading the index does not require remembered directories to be available.

Documents are bounded to 4 MiB and 4,096 location entries. Unknown, duplicate,
missing, null and case-aliased JSON fields are rejected, as is invalid UTF-8.
Existing corrupt state is left unchanged. The enrollment reference holds no
credential and does not enable transport or admit a workspace client by itself.
There is no persistent presence flag or PID.

`make -C native check` runs native race tests and vet. The configuration tests
cover concurrent revision conflicts, corruption preservation, bounds, reopened
state, independent snapshots and multiple workspaces sharing a runtime.
`make -C native config-windows-check` compiles Windows tests and runs vet only.
OS-user protection and directory-sync limitations are those of
[`privatefile`](../../internal/privatefile/README.md); same-account native
processes are not sandboxed.
