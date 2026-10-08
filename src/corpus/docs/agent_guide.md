# Working on Bee

Bee is a Wippy application: Lua registry entries under `src/`, a small Go
native layer under `native/`, and Lua suites under `tests/`. Read the
repository `README.md` and the [documentation map](docs/readme) before changing
anything.

Bee-owned code and artwork are MIT. Preserve the upstream license for Wippy and
other dependencies when changing or copying runtime code. Registry metadata
describes capabilities; it never grants them. Native Terminal runs with the
operating system user's authority.

## Layout

Each component is one folder `src/<component>/` that holds its own
`_index.yaml` and is the namespace `bee.<component>`. Its subfolders are child
namespaces, one per concern:

| Folder | Holds |
|---|---|
| `binding/` | contract bindings other components call |
| `env/` | env entries that name resources and executables |
| `security/` | policies the component's entries run under |
| `service/` | long-lived processes |
| `persist/`, `migrations/` | the component's stores and their migrations |
| `types/` | shared type definitions |

The component list and what each owns is in [the system map](docs/system_map);
each has a page under `component/`. Shared kits: `src/app` is the application
SDK (`bee.app:client`), `src/ui` the frame, appearance, text and visualization
kits (`bee.ui:frame`, `bee.ui:appearance`, `bee.ui.viz:viz`), `src/values` the
shared bounds, canonical JSON and reply decoding. Applications that ship with
Bee live in `src/apps/<name>`; each application's UI sits in its own
namespace. Use [the visual style](docs/app_style) and
[the UI brand book](docs/ui_brand_book) for presentation, and the
[toolkit](toolkit) for compact, tested examples. Applications use public
contracts such as `bee.app:client`; they do not import private broker or
store modules.

Each store belongs to one component. Registry configuration, thread records,
approvals, resources, credentials and node state remain owned by their
components even when stores share a SQLite file. Never edit an applied
migration, alter a migration checksum, query another component's tables, or
reset a database to hide a migration failure. Use the owner's operation for
every state change.

Use typed values for every decoded message and request. Validate versions,
identities, strings, arrays, state and request IDs before changing state. A PID
is an execution address, not a credential. Authenticate the message sender and
the relevant instance, token or operation grant. A successful send means
queued; it does not mean ready, committed or stopped. Timeouts can leave an
unknown result and must not cause a blind retry.

## Build and test

```sh
make tools        # install the pinned builder and build the matching wippy toolchain
make lint         # corpus check, then lint of src and of the tests workspace
make test         # run every Lua suite in tests/ against the composed source
make test TESTS=bee.docs:corpus_test    # run selected test entries by id
make build        # pack the application and build dist/bee
make install      # install dist/bee as ~/.local/bin/bee, keeping the previous as bee.prev
```

`make e2e` drives two hive nodes and a display through the built binary and
`make footprint` checks a headless node's resident memory and live heap.
`make runtime-pin RUNTIME_VERSION=<commit>` and
`make native-pin NATIVE_VERSION=<commit>` move the release build's pins in
`wippy.build.json`. `RUNTIME_SOURCE=<path>` builds against a local runtime
checkout.

Suites are `function.lua` entries with `meta: {type: test, suite: bee}` in
`tests/lua/<component>/_index.yaml`. `make test` first composes a copy of
`src` with test-only seams (`tests/compose.py`), starts from fresh run state
and runs under a clean environment: fixture executables from
`tests/fixtures/harness/bin` stand in for the agent CLIs, and the suites never
reach the person's home, PATH or provider credentials. Heavy gates (`e2e`,
`footprint`, binary builds) run on release tags; pushes and pull requests run
lint and the Lua suites. Documentation changes run `make lint`, which checks
the corpus manifest; regenerate its byte counts and digests with
`python3 tools/corpus.py`.

Keep binaries, registry stores, credentials, fixture data and temporary
databases out of the pack. A new test entry belongs in the suite folder of the
component it covers.

## Governed delivery

An agent authors an application or a driver as an overlay, freezes it and
requests delivery. Preflight checks the frozen pack against the rules in the
authoring guide the overlay tool returns, a person approves the exact version
and the permissions it adds, and the owning component applies it.
Installed metadata describes a capability; it never grants one. Hub discovery
or installation alone does not publish an admission binding or grant an
application authority. See [governance](component/gov),
[Hub](component/hub) and [package boundaries](docs/package_boundaries).

When changing a behavior, update the relevant contract page and run the suites
of that owner. Preserve stable definition IDs independently of versions.
Carry expected revisions and recovery information in activation requests.
Do not describe a proposal as a callable API.

## Managed agent containment

Managed CLIs run with the operating system user's authority. A session's batch
worker uses a private retained home containing only the provider login,
configuration and conversation state its driver declares and the credential
broker projects; the batch launch policy admits no host HOME inheritance. Each CLI
further runs under its own permission control where one exists. These controls
are CLI permissions, not operating system confinement: a managed CLI can read
any file the OS user can read outside its workdir. Treat the brief, workdir
and home as the containment boundary and keep Hive keys, Bee state and other
provider logins outside every granted folder and home. Placement is described
in [placement](component/placement) and [native placement](component/placement:native),
credential projection in [credentials](component/credentials).

Each driver declares its provider login evidence as a path relative to the
provider home. Missing evidence yields a typed `LOGIN_REQUIRED` notice from
placement's prepare step and the agent window shows the provider's own sign-in
command; Bee checks existence only and leaves sign-in to the provider.

| Driver | Login | Ambient configuration |
|---|---|---|
| Claude Code | `.claude/.credentials.json` | `.claude/settings.json`; `.claude.json` onboarding marker |
| Codex | `.codex/auth.json` | `.codex/config.toml` |
| Agy | `.gemini/antigravity-cli/antigravity-oauth-token` | `.gemini/antigravity-cli/cache/onboarding.json` |
| Grok | `.grok/auth.json` | `.grok/config.toml` |
| Muse | `.config/muse/auth.json` | `.config/muse/settings.json` |
| OpenCode | `.local/share/opencode/auth.json` | `.config/opencode/opencode.json`, `.config/opencode/towers.key` |

Only a provider's login file may be returned to its original path after the
child exits, and only when the source digest is unchanged; provider
configuration and other home files are not copied back.

Hub applications install through the Library's governed delivery path. Packages
of type `application`, packages declaring `bee.app`, and packages requesting
capabilities share overlay delivery's preflight, person approval and activation
owner. `app.database` provisions the application's migration database;
`agent.tools` offers its granted functions, `tests` runs its associated tests
by definition ID, and declared menus place it in the shell. Library packages
and `bee/bee` self-update retain Hub dependency-root publication.
