# Native Bee launch

Component returns the native executable host and boot component. Before a
non-explicit launch opens state, it selects:

    <Bee config directory>/bee/projects/<sha256(canonical working directory)>

The runtime resolves a launch without --state to `<config directory>/bee` and
marks it not explicit; the host selects the project state under that root, and
the client route, the owner it starts and a plain `bee start` all use it. An
explicit --state is preserved unchanged. Planning does not create
directories, write receipts, inspect databases or acquire locks.

`bee hook-post ENDPOINT ACTION_ID TOKEN_ENV_OR_FILE EVENT` is planned first: it
runs the [hook POST helper](../hookpost/README.md) without project selection,
state, the client route or the retained owner.

`bee help`, `bee -h` and `bee --help` are planned next: the host prints the
command grammar and the state this invocation would use, computed from the
launch alone, and exits 0 without selecting a project or reading state.

Every other ordinary launch is decoded before project selection. `bee start`
takes no arguments; `bee MODULE:ENTRY` keeps the runtime's own entry; the rest
is the client grammar (`observe`, `client`, `attach WORKSPACE DISPLAY`,
`desktops`, or an application command `NAME [ARGUMENTS...]`). A first word that
cannot name an application command (`hive.DesktopCommand.Valid`: lowercase
letter first, then lowercase letters, digits, `_` or `-`, at most 40 bytes) and
malformed route arguments fail planning, so nothing is selected, read or
started. Whether a well-formed NAME exists depends on the project's admitted
applications and managed agents; the owner resolves it after the client joins.

`bee version` is not answered by the host: the embedded pack version and the
pinned runtime commit are not visible to `app.Host`, so the word reaches the
owner as an application command.

The runtime owns state opening, locking, deployment history, migrations, process
ownership and application lifecycle. The native host provides the selected
default state and a read-only environment store with home, cwd, self and safe
PATH executable lookup.

Environment values are nonsecret and absolute. Executable lookup accepts only a
bare name and returns an absolute PATH result. Writes, deletes, path names and
traversal are refused.

Run the native package tests with:

    make -C native test
