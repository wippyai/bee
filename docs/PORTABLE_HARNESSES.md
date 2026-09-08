# Portable harness applications

Status: proposal. Bee does not yet expose a headless harness runner or selective
workspace export. Existing acceptance harnesses remain until replacements run
inside Bee and demonstrate equivalent coverage.

A harness should be an ordinary standalone Lua application using native runtime
contracts. A desktop view observes its run; a physical terminal must not be a
requirement for execution. GitHub Actions should be able to start Bee, select a
repository's harness entry point, supply arguments, collect results and exit.
The same application should run locally with an optional desktop visualization.

## Source and local state

A repository folder contains definitions, scripts, tests and declared package
dependencies. It is reviewable source, independent of a particular workspace
database. A portable pack distributes those definitions. Packaging must preserve
registry identities and declare the compatible runtime and native modules.

Local databases retain workspace identity, run history and application state.
An eventual selective export includes chosen definitions and their declared
dependencies; optional application checkpoints need an explicit portable schema.
It must not implicitly export credentials, live PIDs, terminal grants or host
paths as authorized resources. Import resolves resources and applies the
destination host's admission policies before execution.

## Runner boundary

The runner selects an admitted entry point and validates its arguments. It owns
startup, cancellation, a bounded completion wait and cleanup. The application
reports progress and a terminal result through a versioned contract. Successful
spawn alone does not mean a successful test run. Failed startup, failed tests,
cancellation and deadline expiry must yield explicit unsuccessful CLI outcomes.

Logs and machine-readable results must remain useful without ANSI color.
Artifacts are written only to configured output locations. CI permissions and
secrets come from the host; a checked-out harness cannot grant itself authority.
Native commands retain their documented OS-user authority.

## Acceptance before adoption

Run the same fixture from a folder and a pack without a TTY. Verify success,
assertion failure, malformed arguments, cancellation, timeout, child cleanup and
artifact collection. Verify offline dependency behavior and missing native module
errors. A desktop observer must be able to show progress without owning execution.
Only replace existing acceptance coverage after its Bee counterpart passes these
checks and exercises the original behavior.
