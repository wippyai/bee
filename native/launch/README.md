# Native Bee launch

`Component()` returns one concrete value that is both the executable's
`app.Host` and its native boot component. It has two small responsibilities:

* Before a non-explicit launch opens state, select
  `<Bee config directory>/bee/projects/<sha256(canonical working directory)>`.
* During boot, register a read-only environment storage with `home`, `cwd`,
  `self`, and safe executable lookups through the host `PATH`.

The runtime remains responsible for state opening, locking, deployment
history, migrations, process ownership and application lifecycle. An explicit
`--state` is passed through unchanged. Planning does not create directories,
write receipts, inspect databases or acquire locks.

Older Bee versions wrote `project-state.json` at the default state root. The
host reads that file only for compatibility. A valid receipt whose canonical
project matches the current directory keeps the old root; a valid receipt for
another project, an absent receipt, or a fresh root selects the hashed project
directory. A malformed receipt fails closed. The host never creates a new
receipt.

The host environment is nonsecret and read-only. `home`, `cwd` and `self` must
be absolute paths. Executable lookup accepts only a bare name and returns an
absolute `PATH` result; writes, deletes, path names and traversal are refused.

Run the focused native checks with a runtime checkout containing the pinned
`Plan.DefaultState` change:

```sh
make -C native launch-check LAUNCH_RUNTIME=/absolute/runtime
```
