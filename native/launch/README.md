# Native Bee launch

Component returns the native executable host and boot component. Before a
non-explicit launch opens state, it selects:

    <Bee config directory>/bee/projects/<sha256(canonical working directory)>

An explicit --state is preserved unchanged. Planning does not create
directories, write receipts, inspect databases or acquire locks.

The runtime owns state opening, locking, deployment history, migrations, process
ownership and application lifecycle. The native host provides the selected
default state and a read-only environment store with home, cwd, self and safe
PATH executable lookup.

Environment values are nonsecret and absolute. Executable lookup accepts only a
bare name and returns an absolute PATH result. Writes, deletes, path names and
traversal are refused.

Run the native package tests with:

    make -C native test
