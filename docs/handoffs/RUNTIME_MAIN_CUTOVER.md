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
