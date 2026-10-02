# Runtime integration

Bee builds Wippy from the repository and commit recorded in
[`wippy.build.json`](../../wippy.build.json). The same manifest records Bee's Go
version and build tags. Bee builds unpatched upstream runtime sources and does
not vendor a runtime source directory.

`make setup` and standalone builds use the same builder and manifest. Wippy owns application deployment, Hub resolution, command
dispatch, state opening and shutdown; Bee registers its native components
through Wippy boot. Bee uses
`err:details().sqlite_code` to classify SQLite busy/locked errors for owned stores,
and retains the public runtime error text for diagnostics.

## Toolchain currency

The binary at `.wippy/bin/bee-wippy` derives from `wippy.build.json`; its
provenance records the manifest it was built from. `make lint`, `make test`,
`make fixture-lint` and `make check` run `build/verify_cached_toolchain.py
current` first and rebuild through `make native-tools` when the recorded
manifest inputs differ or the provenance is missing. The comparison uses file
content, not modification times. An explicit caller `WIPPY` override runs as
is with no rebuild.

## Update procedure

1. Select an upstream commit that contains the required runtime APIs.
2. Update the runtime commit in `wippy.build.json` and any necessary native
   module dependency.
3. Keep native dependency and binary identity facts aligned with the manifest.
4. Run the native pinned-runtime check and the affected upstream Go tests.
5. Run Bee's typed, pack and native acceptance checks before publishing a
   standalone build.

```sh
make -C native pinned-check
make lint
make check
make portable-deployment-check
make standalone
```

The generated provenance records the selected runtime commit.
A runtime change is ready only when the manifest, dependency identity checks and Bee's
relevant acceptance gates agree. Experimental upstream work remains outside the
published integration until its own acceptance contract exists.

## Standalone live update

Runtime #884 exposes the standalone deployment baseline as
`resolution.lock = {root_module, modules, digest}`. The entire resolution graph
requires `registry.resolution.get`; registry entry reads do not grant it.
Hub grants this read within its execution scope, inventories the implicit root
from `lock.root_module`, and reports installed versions from the live
`resolution.modules`. The original lock pins stay separate in About.

Modules updates the `bee/bee` closure through the existing approved Hub plan
and apply path. Registry history and cached artifacts restore that selection
offline. `make hub-self-update-runtime-check` tests the seeded root adapter and
continuity; `make hub-self-update-standalone-check` exercises source-free packs
and the real native desktop client on a PTY against a local fixture Hub. It
applies through Modules, retains and refreshes About on the attached terminal with unchanged
owner/client OS PIDs, verifies clean detach, and relaunches offline. The native
binary embeds the exact fixture baseline; an optional `BEE_SELF_UPDATE_BINARY`
can reuse an already sealed binary after verifying its binary and pack digests
against that baseline. `BEE_SELF_UPDATE_TARGET_DEPLOYMENT` selects an existing
sealed target instead of generating fixture versions. `BEE_SELF_UPDATE_EVIDENCE`
retains terminal frames and PID records from a successful run. Neither route publishes.

Native Hive enrollment is an owner-local registry overlay, separate from package
entries and durable history. Root replacement therefore preserves the host's
current admission while client departures still revoke terminal mounts through
the same supervision path. This native fix takes effect when the owner boots
with the updated executable; Lua package updates do not replace native code.
