# bee.git.worktree

Git metadata discovery and dedicated worktrees are a placement plugin. The
component root contains its registry index and the `git_roots`, `worktree`,
`plan`, `setup`, `cleanup`, and `binding` entries.

The host selects `bee.git.worktree:binding` through placement's
`target_workdir_preparers` requirement. Its default list is empty; Bee's host
composition selects this plugin. Registry metadata never authorizes execution.
The contract has three methods: `plan` performs read-only inspection, placement
persists its ownership state, `setup` applies that plan, and `cleanup` consumes
the recorded state. Setup and cleanup can be repeated after interruption. A
setup replay accepts an existing worktree path only when its repository, common
directory, administrative directory and backreference match the recorded plan.
The methods answer only callers holding placement's setup or cleanup action.

Without a dedicated option, setup reads the repository's `.git` and `commondir`
metadata. Physical directory resolution checks symlinks before contributing
roots. Metadata outside admitted write roots contributes no additional access.
Placement independently checks every contributed root and changed workdir.
The driver profile selects the CLI adapter; placement renders its arguments.

A launch definition can set `worktree: dedicated` (or
`options: {worktree: dedicated}`, but not both). No other options are accepted.
Simple bounded alphanumeric, underscore and hyphen attempt IDs keep their names.
Namespaced IDs (including the harness's `attempt:` prefix), dotted IDs and
longer IDs use `_` plus their SHA-256 digest. Separators and whitespace are
refused. The plugin creates `<physical-workdir>/.worktrees/<component>` and
`bee-worker-<component>`, preserving the original attempt ID in ownership state.
The working directory and Git common directory must already be write-granted.
Preexisting names and symlinked worktree parents are refused. Git receives
quoted arguments through the native executor; setup and cleanup disable hooks.

Ownership evidence records the repository, common directory, physical workdir,
worktree path, branch, original commit and fully qualified destination branch
(or original commit for detached repositories). Cleanup verifies that identity
and retains dirty, untracked, ignored, detached, switched or unmerged work.
Index flags that suppress change detection (`assume-unchanged` or
`skip-worktree`) also retain the worktree.
It uses non-forced worktree removal and safe branch deletion; command and
storage failures surface as placement evidence and failed cleanup replies. Failed
Git commands include their command, exit status and native stderr. Inspection
accepts only the documented predicate statuses (absent branch or detached HEAD);
other failures stop planning, setup or cleanup instead of being treated as absence.
An already removed worktree or branch is handled idempotently. Missing or
changed ownership evidence refuses deletion. Locked worktrees remain intact.

Placement runs cleanup on proven attempt ends, including failed startup, and
its sweep recovers ended attempts. Before child creation, an absent runner and
a durable plan without a child-creation intent prove that cleanup is safe.
An interruption during child creation without a recorded process identity
remains uncertain; placement preserves the work until absence is proven.
Retained work is reported through `workdir_preparer.retained` evidence.

The component root owns values, requirements and declarative contract wiring;
`binding/` owns the callable `plan`, `setup` and `cleanup` implementations.
Placement owns the durable preparer records and moves their old identities in
its additive migration 8, including the completed-cleanup markers used on
restart. The plugin owns no persistence ledger.
