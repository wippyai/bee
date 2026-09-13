# Runtime patch composition

`runtime-http-port0.patch` is runtime PR
[#737](https://github.com/wippyai/runtime/pull/737), commit
`20e657b4ee1f6f3d5bd71325d540da8095a0cfce`, applied to Bee's selected runtime
`291f5c6b708c80afe5da07f3223767573b4d183f`. The upstream PR is merged. Bee still
needs the launch ABI from its selected pin, so this patch composes the upstream
HTTP fix without changing that ABI. `wippy.build.json` verifies the patch digest.

The patch preserves native HTTP listener ownership and reports the bound address
when port zero is selected. Remove this composition when the selected runtime
contains both requirements. Upstream file licenses remain unchanged.

`runtime-offline-restore-host.patch` composes runtime PRs
[#740](https://github.com/wippyai/runtime/pull/740) (`b9dc19e6e9`) and
[#741](https://github.com/wippyai/runtime/pull/741) (`b7b89f5a7d`) onto the same
selected pin. Both PRs are open, assigned to Rodrigo (`skhaz`), and unmerged.
The older pin calls its restore helper `materializeRestoreModules`; that name
is retained without importing newer dependency-reconciliation changes.
This composition preserves the application/native launch ABI and upstream
licenses. It makes startup restoration offline and supports an explicit
terminal host in command metadata. A combined candidate passed the affected
Hub, core registry and CLI race suites and lint. Bee offline upgrade acceptance
remains pending; see `docs/handoffs/OFFLINE_BOOT.md`.

`runtime-application-artifact-cache.patch` is runtime PR
[#742](https://github.com/wippyai/runtime/pull/742), commit `31bc4ad1ee`,
stacked on PR #726. It uses the existing registry vendor configuration to retain
exact installed artifacts across embedded bundle changes. Atomic publication
checks copied bytes and preserves existing artifacts and registry history.
The PR is open and assigned to Rodrigo. Its upstream MPL license is preserved.
