# Runtime main cutover

September 11 check: runtime main is
`865a96dc5620f1435ff6b23939e5c89cd9a4a260`. The existing Bee toolchain
uses `674b58a1a117fa79398f723c4311201cca8472e1`.

Runtime #696 is merged as `4af7666d3984e5a1ec0ad0a703dbc694a28160cb`.
Process-tree supervision and exit channels therefore exist upstream; the old
Bee candidate's missing process identity is not evidence that main lacks them.
Production cleanup still requires executable acceptance on the refreshed build.

A toolchain build against main with Bee's pinned native module fails because
that module imports the old `api/application`, `application`, and
`application/statelock` packages. These are not present on main.
The latest #703 also does not preserve those packages: it instead adds
`cmd/app.Options.Launch`, a callback receiving `LaunchRequest` and a single-use
synchronous `runOwner(OwnerOptions)` callback. `OwnerOptions.Prepare` runs under
the state lock; returned resources close after runtime shutdown and before
unlock. Discovery, authentication and client admission remain application-owned.
Bee must adopt this contract, not restore the old package layout.

Current PR heads checked:

- #703: `d6937ee4f6931348f7e31399dc9390a54c34c800`, open against main.
- #726: `291f5c6b708c80afe5da07f3223767573b4d183f`, open against #703's branch,
  selecting embedded defaults through executable options.

Both are assigned to Rodrigo (`skhaz`). They are not merged by this lane.
The standalone builder's generated application options must wire Bee's launch
callback as part of the same cutover. Native project-directory selection,
client-only invocation, state exclusion and owner resource lifetimes must pass
the existing executable tests on that wiring before installation.

Main's membership Start still calls joinWithRetry synchronously when seeds are
configured. Refreshing the runtime does not yet establish local-first automatic
Hive convergence. That remains a separate native membership requirement.

Builder #7 already supplies explicit composition (`native[].launch: true`) and
`application.baseline: embedded`. Head checked:
`d2d451ba83455ee022857be83f422fec66dd9d76`, assigned to Rodrigo. It constructs
the host once and assigns that concrete host's Launch method to runtime options.
Bee's factory must therefore return its concrete host type. No additional
builder callback mechanism is needed.

The validation candidate uses unchanged #726 and builder #7 heads while Bee's
native migration is developed. This is not a main-only release pin; the final
main cutover remains contingent on the corresponding merges and executable
acceptance. The failed main-only build remains recorded above.

## Project default state directory

The revised runtime resolves StateDir before Launch and forbids runOwner from
redirecting it. Bee's per-project default therefore must be selected at the
executable entry, before app.Run opens state. A plain executable-selected default
state-directory option, with explicit --state-dir retaining precedence, is enough
for Bee to compute its existing protected per-CWD path. The corresponding builder
wiring should select this value explicitly from the native host. This requirement
does not call for a second lock, recursive app.Run or a helper process just to
rewrite arguments. Native callback migration can proceed independently, but the
per-project executable acceptance must remain pending until this is wired.

## Validation of the callback migration

Bee native commit `447f015b08bf924452192713cf71d1cb5965f263` replaces the old
launch plan with `cmd/app` callbacks and exposes the concrete host's `Launch`
method. Its focused launch race tests and vet pass against unchanged #726.
The follow-up native checkpoint `2a652f89754ce9e010a71110d0332b258d179d25`
migrates the obsolete test imports and proves state contention through the actual
runtime runner. Its local-owner race tests and vet pass. The complete native
toolchain now builds with that checkpoint, unchanged #726 and builder #7;
managed-window acceptance passes all three tests. This proves window input,
resize, close, duplicate admission and foreign-owner refusal. Its cleanup remains
explicitly pending; it does not prove production process-group reclamation.

A separate core-only runtime main build succeeds and lints Bee source. It cannot
run the native-window acceptance: boot stops because that diagnostic toolchain
omits the `bee.hive.activation` native handler. This is a composition limitation,
not evidence that the window tests passed or failed their behavioral assertions.
The complete native toolchain above resolves that composition gate.

## Stale local node recovery

Native checkpoint `3e895bae936f894503638e0a851db42234453ccc` additionally
recovers a stale local descriptor after an abrupt node exit. Only a failure
before authenticated native mesh admission permits a detached contender;
`cmd/app` remains the sole state-lock arbiter. Refused or uncertain desktop
operations are not replayed. Cancellation retains its error identity.
Same-machine authentication has a two-second bound, disarmed after connection;
the existing remote-node lifetime policy is unchanged.

Launch, session, local-owner and mesh-client race tests plus vet pass on #726.
The physical restart regression kills the old node, retains its descriptor and
requires a fresh automatic launch within fifteen seconds. The complete native
toolchain builds at this checkpoint. The standalone validation build succeeds,
and its native-binary gate passes embedded startup, all current store files,
Settings recovery, Terminal, scrolling, selection/copy, command arguments and
presenter rejoin. No global executable is installed from these results.

Real Claude and Codex window acceptance also passes on the refreshed native
toolchain: broker-owned PTYs, keyboard interaction, resize, rebind and explicit
cancellation. This fixture submits no authenticated provider turn and retains
its explicit pending-cleanup policy; it is not production cleanup acceptance.

The fresh-runtime Lua run passes all 557 tests, including the process-group
absence correction and native placement identity/descendant cleanup proofs.
The gateway takeover fixture failure was reproduced by explicitly reconciling
placement after revocation: correct enforcement stopped the sleeping fixture
before it could report its HTTP denial. The fixture now cooperatively handles
TERM, makes the real request and flushes its result within the existing stop
deadline. Tests require both revocation/stop evidence and the actual HTTP 401;
production enforcement is unchanged.

The full native-client executable gate passes, including three displays, retained
applications, cold-launch contention and physical client crash/reconnect. Storage,
thread restart, resource containment and source/pack connection UI checks also
pass. The desktop smoke initially failed with a blank first frame. Twelve focused
boots and a subsequent full source/pack smoke pass do not explain that failure.
Failure-only diagnostics now retain bounded terminal output and process state;
the intermittent startup issue remains unresolved. The remaining desktop recipe
now passes, including control delivery, window retirement, native Terminal,
scrolling/selection, 161 keyboard cases, retained lifetimes, independent clients,
launcher/recovery and Inbox/Hive Manager/Timeline apps. All foundation recipes
have passing evidence in segments; this is not an uninterrupted final
`make check` or a demonstrated fix for the earlier blank frame.

Placement additionally refuses a missing provider configuration before storing
intent when the host policy selects that provider. The regression with only
that guard removed creates a stored `intended` attempt; with it restored all
557 Lua tests pass. Real Claude/Codex PTY startup/input/resize/rebind/cancellation
also pass after the guard. A separate gateway fixture proves a restricted
function scope denies actual placement DB/executor access while the privileged
control acquires both. Actor/context inheritance remains outside that proof.

## Native startup sample

The provider-guard standalone candidate passed twelve fresh-state cold launches
and twelve reconnects. First frames arrived in 1.525–1.946 seconds cold and
0.208–0.213 seconds warm, all within the four-second diagnostic bound. Each case
used disposable state and exact process-handle cleanup. No blank frame reproduced
in this local sample; it does not explain the earlier source-fixture failure or
prove behavior across remote nodes. The global installation remains unchanged.

## OS-assigned MCP listener address

Source inspection of the selected runtime found another requirement before
public per-node MCP activation: `service/http/server.go` binds the configured
address but `ensureRunning` probes `s.config.Addr`, not the bound listener's
address. With `127.0.0.1:0`, that still probes port zero. The service's current
public methods also expose no bound endpoint. This is source evidence; a
runtime-owned executable regression is still required.

The existing HTTP service should retain and expose its actual bound endpoint
through the native service surface, with readiness using that endpoint and
restart/stop retiring the old value. Bee can then bind loopback port zero and
use the current endpoint with its existing listener generation and scoped MCP
authorization. The current fixed gateway endpoint is not acceptance of automatic
multi-project MCP activation. Do not reserve and release a supposedly free port,
create another HTTP server, or let callers supply credential destinations to
work around this requirement. No runtime implementation changes are made here.

## Generic driver configuration candidate

The next source checkpoint moves provider configuration behind the shared driver
`configure` contract, selected through activation and pinned registry data.
Placement independently renders and compares the file before intent. Native
harness scope management is an explicit protected admission decision; ordinary
apps retain their scope denial. See `APPLICATION_CONTRACTS.md` and `CARRIER.md`
for the trust boundary and remaining Codex-specific gateway extension.

Validation on the unchanged candidate toolchain: all 565 unit tests pass; native
pack coverage is 14 modules / 586 entries. The standalone candidate SHA-256 is
`cd8b5f9987884934d56e72db2e86983fdd5f71ddce3ffcc5ee5734408936a753`.
Its executable gate passes embedded boot, Settings recovery, terminal,
wheel/burst scrolling, physical selection/copy, fullscreen aliases, literal
arguments and presenter rejoin. After the full unit run, `make check -o test`
passes all remaining foundation recipes, including storage, source/pack desktop
interaction, client recovery and the three thread/Hive applications. The existing
`desktop_lifecycle` fixpoint warning remains. Global Bee remains unchanged.
This does not establish per-project default state selection, authenticated
provider turns, or production process-tree cleanup.
