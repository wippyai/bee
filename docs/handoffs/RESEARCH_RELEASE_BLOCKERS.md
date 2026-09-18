# Research release blockers — September 15

The managed Gemini measurements and recovered physical dashboard pass. The
fresh standalone executable builds, but global installation is withheld because
native acceptance found the following failures. No runtime source was edited.

## Registry/supervisor boot lock cycle

Reproduce with `make offline-boot-check BEE_BINARY=dist/bee` in the PR #11
integration checkout. The loopback-only network namespace has no external
connectivity. The first source-free Settings launch produced no terminal bytes
and exceeded its four-second UI wait. The same failure was reproduced with a
temporary diagnostic wrapper that sends SIGQUIT after the assertion, collecting
the runtime goroutines before fixture cleanup.

Evidence on this machine:

- `/tmp/bee-research-offline-client-check.log`: failing Make target.
- `/tmp/bee-native-offline-debug.log`: diagnostic reproduction.
- `/tmp/bee-native-boot-goroutines.log`: complete SIGQUIT dump.
- `/tmp/bee-native-boot-debug.py`: temporary diagnostic wrapper; not shipped.
- `/tmp/bee-research-standalone.log`: exact standalone build.

The selected runtime base is `6b40cb0f` plus the checked-in manifest patches.
The source trace and stack agree on this cycle:

1. `system/registry.(*Reg).LoadState` holds `r.mu.Lock()` across
   `transitionState`.
2. `system/registry/runner.(*BusRunner).Transition` waits for transaction commit
   acceptance through `dispatchTransaction` / `awaitWaiter.Wait` (goroutine 1).
3. The supervisor commit builds start operations and resolves dependencies:
   `Supervisor.execute` → `buildStartOperationsForRoots` →
   `resolveDependencySets` → `core.createDependencyResolver`.
4. That callback invokes `Reg.GetEntry`, blocked on `r.mu.RLock()` (goroutine
   621). The registry cannot finish its transaction while that callback waits.

This is before Bee application/UI startup. Increasing the UI deadline does not
resolve the lock cycle. Network isolation is the reproducer, not a proven cause;
an earlier source desktop smoke also emitted zero bytes but has no stack dump
linking it to this cycle. A runtime fix needs its own PR and a native boot/commit
regression. Do not add a Bee workaround or remove service dependency metadata.

## Saved-profile launch

`make native-binary-check` passes embedded boot, Settings recovery, terminal
scroll/copy, Modules, About, and selector model/vet checks. Its actual saved-profile
launch then fails waiting for `BEE_SAVED_PROFILE_GUIDANCE` after 65 seconds; an
empty desktop is visible. Evidence: `/tmp/bee-research-native-check.log`.
The cause is not established yet. This is distinct from the zero-byte boot
failure above until demonstrated otherwise.

Global Bee has not been replaced. The source/pack desktop suite continues in
`/tmp/bee-current-desktop-check.log`; it must not be reported as passing before
completion. The independent consumer fixture is still in progress.
