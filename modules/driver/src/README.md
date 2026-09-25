# Bee driver

bee/driver is the shared Lua contract for managed harness components. It
defines declarative launches, protocol normalization, saved preferences, and
configuration delivery. It does not execute a process, read credentials, or
write thread records.

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
