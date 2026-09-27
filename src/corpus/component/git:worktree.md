# bee.git_worktree

Git worktree and repository metadata preparation plugin for Bee placement.

| Slice | Responsibility |
|---|---|
| `bee.git_worktree` | `git_roots`: pure discovery of Git metadata directories (`.git` and `commondir`) without spawning Git; `worktree`: dedicated worktree and branch creation, unmerged status verification and cleanup; `setup`: workdir preparer setup handler; `cleanup`: workdir preparer cleanup handler; `binding`: contract binding for `bee.placement:workdir_preparer` |

## Extension point integration

This package implements the `bee.placement:workdir_preparer` contract binding:
- `meta.type`: `bee.placement.workdir_preparer`
- `contracts`: `bee.placement:workdir_preparer` (`setup` and `cleanup`)

The host authorizes this binding by including `bee.git_worktree:binding` in its placement
`target_workdir_preparers` configuration. Registry metadata alone never authorizes execution.

## Operations

### Repository metadata discovery

When a launch definition does not ask for a dedicated worktree, `setup` inspects the working
directory for a repository or worktree `.git` marker. It resolves the exact Git directory and
common directory using filesystem reads only. The detected directories are contributed as
extra writable roots within the host-admitted write roots.

### Dedicated worktree creation

When a launch definition requests a dedicated worktree (`options.worktree = "dedicated"`),
`setup` creates a dedicated branch (`bee-worker-<attempt_id>`) and a separate worktree under
`<workdir>/.worktrees/<attempt_id>`. It returns the worktree as the attempt's working directory,
contributes the worktree's Git directories as extra writable roots, and records state for cleanup.

### Cleanup

When the attempt exits, placement invokes `cleanup`:
1. If the worktree has uncommitted changes (`git status --porcelain` is non-empty), the worktree
   is retained and reported as evidence (`workdir_preparer.retained`).
2. If the worker branch has unmerged commits (`git merge-base --is-ancestor` fails), the worktree
   is retained and reported as evidence (`workdir_preparer.retained`).
3. If the worktree has no unmerged or uncommitted changes, it is removed cleanly via
   `git worktree remove` and the temporary worker branch is deleted.
