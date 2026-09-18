# Runtime upstream cutover

Bee PR #6 removes the published `runtime/` directory and selects Wippy main commit
`fdad09cef2b766e17b95c52c0aa01183601a9243` without patch inputs. The Go builder
configuration lives in `wippy.build.json`; its pin is `build/builder.lock.json`.
Runtime PRs #653, #667, #668, #677, #683, #684 and #686–#689 are merged.
The existing native module's minimum runtime commit is retained in main's ancestry.

The full source/pack suite, native module integration and standalone acceptance
passed on Linux amd64 with no runtime directory. The tested runtime tree is
identical to merged upstream. The final pin was also rebuilt from the official
repository URL and passed standalone acceptance. Artifacts and logs are in
`dist/release-local/upstream-migration/`.

## Parallel checkout

Builder PR #5 removed runtime patch support and merged as
`e80e35b6f9301ca01a366b4d1de3eddcf8f3e97d`. Bee PR #7 selects that revision for
development setup, native releases and Hub publication. Do not copy that pin
into this shared checkout while its experimental manifest still requires patches;
complete the upstream transition below first.

Builder PR #6 subsequently improved command guidance and paths containing spaces;
Bee PR #8 selects `67a04357e73b43c35d354c5bb17b3261a9802ea3` and expands standalone
acceptance to every default app. The installed baseline passes with no network,
source checkout or pre-existing state. See `dist/release-local/setup-audit/PROOF.md`
for the final binary and full audit evidence. The same shared-checkout restriction
applies to this newer pin.

The shared checkout still has uncommitted host/Hive runtime work. Its manifest and
patches were preserved while the published repository was cleaned up. These include
actor provenance, cluster listeners, application launch and command-host changes
appended to the foundation patch. The earlier foundation, application-host,
license-pin and publication changes are already upstream.

Before publishing this work, rebase its runtime changes onto the new upstream
commit and prepare focused Wippy PRs for Rodrigo. Select the merged upstream commit
in Bee afterward. Keep the patch stack out of Bee's release manifest. Preserve all
host/Hive acceptance checks and the local work while making that transition.

Wippy owns runtime behavior and supported boot APIs. The Go builder configures the
selected runtime, native components and embedded packs. Bee's runtime integration
is a thin command entrypoint; application source and native module implementations
retain their own ownership.

## Local desktop candidate refresh (2026-09-10)

The global executable was updated at the user's explicit request to the tested
selection candidate. Its installed-binary acceptance passes. It remains separate
from the release manifest above; see [current evidence](STATUS_RUNTIME_GATE.md).

The runtime PR inventory for this local desktop is:

| PR | Purpose | Refreshed head | Current validation |
|---|---|---|---|
| #702 | Preserve explicit host on pack launch | `f508933421` | Scoped race pass; hosted CI running |
| #705 | Nonblocking terminal event reader and fragmented input | `a544d7264e` | Terminal/TTY race and lint pass; hosted CI running |
| #717 | Typed Future response channel | `91502bb273` | Hosted CI green |
| #718 | Receiver-local typed process listeners | `fde337321d` | Process race and lint pass; compiler refresh underway |
| #719 | Bounded native scrollback | `2ed20c2b66` | Hosted CI green |
| #720 | Native plain-text extraction | `cb68870109` | Hosted CI green |
| #722 | Explicit physical clipboard submission | `6f5f54aab5` | Hosted CI green |
| #724 | Typed native channel select cases | `be1fa1e749` | Hosted CI green |

All runtime entries are open PRs assigned to skhaz. #702/#705/#718 now merge
runtime main `d78a66c74b` without rewriting their existing commits. Go-Lua #44
and #45 are merged; compiler main is `0525373712e159c6268790ad8864d8638789c020`.
The user redirected this lane to Bee. An uncommitted `go.mod`/`go.sum` update
in `/tmp/wippy-pr718` selects that public compiler revision; it has not been
validated or pushed. The runtime owner can pick it up. The published #718 head
still uses merged #44.

After upstream review/merge, select the resulting runtime main commit without
patches or local compiler replacements, build a new candidate, and run the
coherent foundation and standalone checks. Paused #716 and the cluster lane's
monitor work are not prerequisites for the local selection build and must not
be folded into it. Public auto-attachment and remote launch remain separate gates.

## Corrected base-mode requirement (user direction, 2026-09-10)

Normal `bee` must use the executable's embedded code as the base and retain
registry overlays above it. Users must not select the embedded build with a
flag. This is the meaning required for Bee's existing `application.mode: base`.
Bootstrap mode remains a separate distribution choice.

The installed candidate does not implement this: `application.Run` first calls
`selectedDeployment(stateDir)` and seeds that directory, so an existing lock
retains older code. Only `--base` selects a bundle-qualified directory, and that
path also moves registry history into that directory. Automatically inserting
`--base` is therefore not the requested correction: it would select a separate
history instead of preserving the user's registry overlays.

The runtime owner should implement base selection in the shared launcher. Keep
workspace/client data bindings and persistent registry history stable; reconcile
embedded definitions under the existing registry overlay rules. Do not delete
registry databases, reset activation files, or add a Bee wrapper to force the
recovery flag. Overlay publication continues to require its existing owner and
authorization; embedded-first startup grants no new edit rights.

Acceptance must boot binary A in a disposable state directory, persist app/client
state and an authorized overlay, then launch binary B normally in that same
directory. B's changed embedded defaults must appear, the overlay must survive
with its intended precedence, and stored identities/migration history must remain
unchanged. Explicit bootstrap/update behavior needs separate regression coverage.
Until that lands, `bee --base` is only the installed candidate's workaround, not
the intended product workflow. The global executable has not been replaced again.

Bee's executable regression now reproduces the stale-base behavior:

```sh
make native-upgrade-check PREVIOUS_BEE=/path/to/older/bee BEE_BINARY=/path/to/current/bee
```

`tests/native_upgrade.py` boots an old binary without Hive Manager, persists
Settings, and normally boots the new binary in the same disposable state. The
installed candidate fails waiting for Hive Manager; its menu still shows Test
Status (`/tmp/bee-default-base-upgrade-red.log`). Once corrected, the probe also
requires stable workspace identity and unchanged existing migration rows. It
never uses `--base`, changes user state or writes the registry directly. This
proves base upgrade behavior only; authorized overlay preservation still requires
its separate acceptance proof. The shared physical fixture is now in
`tests/native_workspace.py` so neither executable test imports another test's
side effects.

### Native Hive owner/client TLS mismatch — 2026-09-10

The compiled Bee client builds against `/tmp/wippy-bee-client-runtime-20260909`
and requires native mutual TLS. The owner `/tmp/bee-wippy-selection-typed-candidate`
boots the typed Lua supervisor but attempts a plaintext internode handshake even
though the disposable fixture sets `cluster.internode.tls.enabled = true`.
Client diagnostics repeatedly report:

```
Inbound handshake failed: PROTOCOL_ERROR: tls: first record does not look like a TLS handshake
```

Both nodes discover each other, but Bee's request handler receives nothing and
the admitted transport send times out. Evidence:
`/tmp/bee-hive-client-transport-trace.log`. An isolated untyped-listener comparison
fails identically; production keeps the typed listener. This is not evidence of
a Lua type-filter defect. Do not disable TLS to make the fixture pass.

The runtime lane needs to supply a compatible owner build with typed listeners,
native TLS startup configuration and the shared surface transport. Bee changed
no runtime sources. Reproduce after supplying that build:

```sh
make -C native hive-desktop-client-fixture MESH_RUNTIME=/path/to/client-runtime FIXTURE_OUTPUT=/tmp/bee-hive-client-current
BEE_NATIVE_DESKTOP_DIAGNOSTICS=1 BEE_NATIVE_DESKTOP_CLIENT=/tmp/bee-hive-client-current make hive-desktop-admission-check NATIVE_WIPPY=/path/to/owner-runtime
```

Separately fixed in Bee: the native inbox discarded Lua replies normalized to Go
maps. It now accepts bounded record maps as well as JSON objects. The native
mesh/physical race suite, vet and direct actor-inbox regression pass. This fix
does not by itself establish cross-runtime attachment or public auto-join.

Upstream status rechecked on 2026-09-10: TLS boot wiring is runtime PR
[#712](https://github.com/wippyai/runtime/pull/712), still OPEN and assigned to
`skhaz`. Its files are `boot/components/system/cluster*.go` and
`cluster/stack*.go`; its description explicitly does not require the rejected
Lua ingress API. It is stacked on #708 and asks integration to preserve #707's
TLS teardown. Native surface transport [#706](https://github.com/wippyai/runtime/pull/706)
and typed listeners [#718](https://github.com/wippyai/runtime/pull/718) are also
OPEN. Supply these capabilities in one compatible candidate; the existing Bee
owner binary cannot be repaired by merely setting `tls.enabled`. No PR was
modified, merged or retargeted by this check.

### TLS blocker superseded by runtime handoff 559

The runtime lane supplied `/tmp/bee-wippy-tls-lifecycle-candidate`. Its actual
compiled-client Hive admission/viewport/detach/rejoin check passes in
`/tmp/bee-tls-lifecycle-admission.log`. This supersedes the TLS incompatibility
above. The candidate combines the existing TLS loader, retained listener and
execution-context cleanup changes on the selection runtime; six lint issues and
broader cluster activation/load/recovery validation remain with its lane.

Bee's physical PTY check now reaches the shell, then fails after F12 with a
replacement-presenter readiness timeout. Evidence:
`/tmp/bee-physical-tls-lifecycle-check.log`. This is a new boundary under diagnosis,
not a recurrence of the TLS failure. Public owner/client preparation also needs
the launch-hook API in #703, absent from this candidate's source. No runtime
changes or global install were made by Bee during adoption.

### Physical F12 needs existing blocked-read isolation #701

The new TLS candidate reaches the physical shell and executes the initial marker,
then F12 pauses the desktop. An isolated source trace logs replacement presenter
`events` and `start` at 22.60s, but never `surface`, `monitor` or `ready`; at 25.60s
the client reports the readiness timeout. `tty.start()` is the stalled call.
Evidence: `/tmp/bee-physical-f12-trace.log`; original uninstrumented failure:
`/tmp/bee-physical-tls-lifecycle-check.log`.

The candidate's `service/terminal/tty/dispatcher.go` still has one worker shared
with blocking reads. The fixture coordinator waits in `io.readline()`. Existing
runtime [#701](https://github.com/wippyai/runtime/pull/701) describes and tests
this exact Bee F12 failure. Include that fix in the candidate; do not lengthen
Bee readiness timeouts or bypass presenter startup. Reproduction:

```sh
BEE_NATIVE_DESKTOP_CLIENT="$PWD/tests/fixtures/hive_desktop_admission/physical.py" BEE_NATIVE_DESKTOP_PHYSICAL_BINARY=/tmp/bee-hive-client-current make hive-desktop-admission-check NATIVE_WIPPY=/path/to/updated/owner-runtime
```

No runtime source was changed and no replacement global Bee was installed.
The compiled nonphysical admission/viewport proof remains passing on the supplied
TLS candidate; the physical F12 check is a separate, stronger acceptance gate.

### Fresh-client discovery and native consumer build — 2026-09-10

The physical crash probe reaches the original shell and kills its client. A
fresh node joins membership and the owner logs a connection, but the new client
never completes `OwnerSupervisor` lookup within the 15-second frame deadline.
Fixture-only phase diagnostics stop at `BEE_CLIENT_PHASE discover`; no
`supervisor-found` or admission request follows. This is not yet a monitor or
mount-revocation diagnosis. Logs: `/tmp/bee-physical-crash-tls-lifecycle-check.log`
and `/tmp/bee-physical-crash-phases.log`. Reproduce with the physical F12 command
above plus `BEE_NATIVE_DESKTOP_PHYSICAL_CRASH=1`; use
`BEE_NATIVE_DESKTOP_DIAGNOSTICS=1` and the newly built fixture for phase logs.
Do not substitute saved PIDs or reinterpret membership as supervisor discovery.

The supplied owner source was also tested as the native client dependency:

```sh
make -C native hive-client-check MESH_RUNTIME=/tmp/wippy-bee-tls-alignment-20260910
```

Compilation fails with missing `internode.NewSurfaceTransport` and
`StackConfig.InternodeTLS` (`/tmp/bee-tls-candidate-native-assembly-check.log`).
The owner executable can therefore serve the fixture while its source still
cannot assemble Bee's compiled client. The existing #706 and full #712 surfaces
cover those two imports. Public startup additionally uses existing #703 owner/
attach hooks and #709 host peer-key lookup, absent from this candidate. These
are existing contracts to integrate, not requests for new runtime APIs. Bee still
owns public launch wiring and live supervisor admission; passing runtime API
checks will not by itself complete either one.
