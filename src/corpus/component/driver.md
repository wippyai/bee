# Bee driver

bee/driver is the shared Lua contract and implementation for external CLI
drivers. It defines declarative launches, protocol normalization, saved
preferences, configuration delivery, and host-evidence-based location. It does
not execute a process, read credentials, or write thread records.

## Install

Install this package with bee/threads and one provider component. The host
selects which provider bindings are active, the executable each binding may
use, its credential projections, launch policy, resources, and MCP ceiling.
Installing a component alone grants none of those things.

## Provider contract

A provider binding implements four Lua methods:

| Method | Result |
|---|---|
| prepare | A declarative launch for a new turn or window |
| dispatch | A declarative continuation input |
| normalize | Thread observations and an optional terminal outcome |
| configure | Bounded argv literals and private-home configuration files |

Placement validates the returned launch, measures the selected executable, and
runs it. The carrier writes accepted observations through Threads. A process
exit alone never establishes a successful turn.

External CLI bindings also implement `bee.driver:locate_facet`. Its `locate`
method evaluates host-probed executable presence and version, platform support,
and provider login-file existence. Results are `ready`, `missing`,
`unconfigured`, `incompatible`, or `unknown`. Login contents are never read;
file existence is evidence of setup only, not proof that a login is valid.

The six external CLI packages use the shared `bee.driver:universal`
implementation. Each contributes a strict `bee.driver.cli_descriptor` registry
entry with executable and version probe, login evidence path, launch templates,
option and flag templates, JSON paths, and a codec ID. The host validates the
descriptor before using it. CLI-specific configuration rendering remains in
the provider package where formats and hook protocols differ.

Each observed wire protocol has one shared codec: Claude stream-json, Codex
JSONL, OpenCode JSON events, Agy stream-json, Grok streaming-json, and Muse
record JSONL. Claude and Agy both use newline-delimited JSON but have different
event schemas and terminal reports; OpenCode has no terminal event and uses
process EOF; Grok and Muse also use distinct event envelopes. The codec
registry selects these implementations by descriptor ID. `driver-wippy` is a
separate non-CLI driver and does not use this external-driver registry.

A window launch may declare `login`: a provider identifier, a display-only
sign-in command and bounded alternative file paths relative to its selected
provider home. Placement uses their existence to return a typed advisory
notice; a login declaration grants no filesystem or credential authority.

## Saved profiles

A saved profile contains a title, a launch definition, bounded scalar options,
selected MCP tools, and persistent instructions. The host policy declares which
option names and values are allowed. The shared profile format does not give any
option provider-specific meaning; a provider validates the options it consumes.

Instructions are persistent guidance separate from a turn's brief and dynamic
context. The host may append a reviewed instruction-builder result before a
launch is prepared. A profile cannot select executable paths, credentials,
permissions, or arbitrary configuration files.

## Configuration delivery

configure receives copied host-selected provider data and an optional scoped
gateway descriptor without token bytes. It returns bounded argv literals and
unique safe-relative files with digests. Placement rechecks the host-selected
inputs, materializes admitted secrets only into declared fields, and records the
resulting delivery before starting the process.

Provider-specific command syntax, profile options, authentication, hook wire
formats, and MCP configuration belong in that provider's component guide and
Lua package.

`bee.driver:types.AUTHENTICATION_STATUS` is the shared release gate for
executable-backed provider login acceptance. `unproven` records that the
configured provider executables have not all been exercised through placement;
it does not decide whether a login is valid or admit a launch.

An activated driver profile may declare a typed Git writable-roots adapter.
Native placement reads that choice from the pinned profile, then uses it only
when the granted workdir is writable and the launch arguments select the
adapter's edit-capable CLI mode. Configure replies and launch callers cannot
select the adapter or its paths. Placement discovers Git metadata and checks
the exact directories against host-admitted write roots before asking the CLI
to use its provider-specific option.
