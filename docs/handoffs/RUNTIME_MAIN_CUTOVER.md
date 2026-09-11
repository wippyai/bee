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
The complete builder composition still fails: Go module resolution loads native
local-owner test imports of the removed application packages. Those fixtures
must migrate to the real callback contract before the toolchain can build.
The candidate manifest pins this checkpoint for validation only.

A separate core-only runtime main build succeeds and lints Bee source. It cannot
run the native-window acceptance: boot stops because that diagnostic toolchain
omits the `bee.hive.activation` native handler. This is a composition limitation,
not evidence that the window tests passed or failed their behavioral assertions.
The complete native toolchain remains the next executable gate.
