# Standalone module composition probe

## Adopted build workflow (2026-09-09)

The shared source now retains the 12 owner roots and removes the 16 redundant
child package declarations proved below. Slice libraries, entry IDs, permissions,
contracts and migration contents are unchanged. The Threads probe checks actual
slice libraries and still passes; source/pack architecture agrees on 502 entries.

`build/modules.json` explicitly assigns every namespace. `build/bundle.py` freezes
source and uses the existing Wippy pack API plus the pinned builder's multi-pack
input. It rejects missing/duplicate namespace ownership and multiple roots per
package, lints strictly, and verifies every pack by loading it without source and
comparing exact IDs/kinds. Content-addressed artifact generations preserve the
previous successful bundle if preparation fails. Runtime patch bytes and checksums
are preserved. `dist/bee.bundle.build.json` is replaced only after preparation;
the source build manifest and release pin are untouched.

`make native-pack` prepares this bundle; `make standalone` builds its generated
manifest. Seven packaging tests cover ownership, failed preparation, generation
reuse and changed patch input. The actual Make path builds `/tmp/bee-adopted-bundle`
on the isolated runtime candidate, and `make native-binary-check` passes, including
Gateway's state directory mapping. Evidence: `/tmp/bee-adopted-bundle-build.log`,
`/tmp/bee-adopted-bundle-native.log`, `/tmp/bee-adopted-bundle-unit.log`.

Full `make check` was attempted and stopped at four type errors in the parallel
lane's newly added `gateway_harness_test`, journal seq 483. Those four explicit
nil guards now pass staged lint; the full Lua run reaches 450 passes and 11
gateway-carrier readiness-generation failures, handed off in seq 489.
Production lint and architecture pass; remaining foundation recipes are running separately. The
default release runtime still requires the coordinated cutover. No global
executable was replaced and no independently installable packages were published.

Component filesystem assets are also supported through Wippy's existing exact
`embed` IDs in `wippy.yaml`. The bundle freezes selected module-relative file
trees, records file hashes, and accepts the expected `fs.directory` to `fs.embed`
transformation only for those entries. It never embeds host roots by wildcard.
Eight packaging regressions plus `make bundle-assets-check` pass: a valid empty
WASM module and nested template remain readable after source and loose build
files are deleted; writes fail without changing bytes. The current 12-module
`make native-pack` path also passes with this support. Evidence:
`/tmp/bee-bundle-assets-check.log` and `/tmp/bee-assets-native-pack.log`.

## Current ownership correction (2026-09-09)

Before adoption, source had 28 namespace definitions but named only 12 module owners.
`COMPONENT_LAYOUT.md` and the Threads README specify one package root with child
slices. Sixteen child slices also declare `ns.definition`; treating each as an
independent package, as the older probe below did, does not match that design.
The installed linker correctly rejects multiple definitions under one owner.

An isolated copy at `/tmp/bee-module-ownership-20260909` keeps one definition per
existing owner and removes only the redundant child-root declarations. All
operational IDs, contracts, policies, requirements and migrations are unchanged.
The Threads isolation probe checks the actual child libraries in place of its
three assertions requiring child package roots; isolation and strict lint pass.
This was the isolated proof preceding the shared declaration correction above.

The resulting 12-pack executable builds on candidate runtime `beb5c014a1` and
passes `make native-binary-check`: source-free boot, Settings recovery, Terminal,
literal alias arguments and F12. All seven subsystem stores use the selected
state directory, including Gateway. Installed registry metadata proves exact
ownership of 502 entries across 12 modules with one root each. This newer source
snapshot includes one entry added after the earlier 517-entry checkpoint;
removing 16 redundant declarations gives 502.

Package identities in this probe are `bee/bee`, `bee/approvals`,
`bee/credentials`, `bee/driver`, `bee/gateway`, `bee/harness`, `bee/hive`,
`bee/persist`, `bee/placement`, `bee/placement-native`, `bee/resources` and
`bee/threads`. `placement_native` is the source's grouping label, not a valid
builder package name; the explicit package identity uses the documented hyphen.
Provider-specific extraction remains future work.

Evidence: `/tmp/bee-module-ownership-build.log`,
`/tmp/bee-module-ownership-threads.log`, `/tmp/bee-module-ownership-lint.log`,
`/tmp/bee-module-ownership-native.log`, and the probe's `ownership-counts.json`.
The full entry-content comparison also passes: all 502 source and installed
IDs, kinds and entry payloads match. As in the older probe, only absent top-level
metadata is normalized from `null` to `{}`. Evidence is
`/tmp/bee-module-ownership-equality.log` and `registry-equality-normalized.json`.
The executable SHA-256 is
`f2a6cc1b9f52c140b6b20da912a159b0d4d789cd869a4f5659e0fb3fd8a806a3`.
The adopted workflow is described above; this temporary script remains evidence,
not a publishing convention. No release pin or global install changed.

## Historical per-namespace experiment

The frozen observer source/pack checkpoint passes all foundation gates. Packing
its entire source tree as the single installed module `bee/bee` fails embedded
linking: `module bee/bee declares multiple namespaces: bee and bee.approvals`.
There are 27 `ns.definition` roots in that snapshot. The installed linker requires
one declared root per module; plain source/pack loading did not assign that same
module ownership. This is a composition mismatch, not a reason to remove roots
or weaken linking.

## Isolated result

`/tmp/bee-observer-standalone-20260909` contains a successful probe:

- `split-plan.json` assigns each source namespace to its nearest declared root.
- `prepare_split.py` uses the existing runtime pack exclusions to emit one pack
  per root, preserving source definitions and entry IDs. The derived `bee/*`
  module names are experimental, not published package identities.
- `split.build.json` bundles those 27 packs, with `bee/bee` as its application
  root. Existing builder multi-pack support handles embedded composition.
- The manifest maps all six subsystem database paths and `BEE_PLACEMENT_ROOT`
  under the native state directory. Otherwise approvals cannot boot from an
  empty caller directory, and placement writes `.wippy` into it.

`make split-build native-binary-check BEE_BINARY=.../dist/bee-split` passes:
embedded boot, Settings recovery, native Terminal, fullscreen aliases, literal
arguments and presenter rejoin. The standard native acceptance also requires no
`.wippy` directory in the caller's folder. Log:
`/tmp/bee-split-native-owned-state-check.log`.

The application entry IDs and host-selected permissions were preserved. No
shared manifest, runtime linker, applied migration, global installation or
published artifact was changed. This is a probe, not the adopted build workflow.

## Adoption work

The shared manifest now includes the seven state-environment mappings proved by
the isolated binary (six database paths and the placement root). Its values match
the probe exactly. This adopts only state defaults; installed pack composition
is still monolithic and remains the blocker below. `make native-bootstrap-check`
passes after this change; the isolated binary acceptance above does not imply a
new shared-tree executable has been assembled.

The later gateway component adds a seventh subsystem database. The shared
manifest now also maps `BEE_GATEWAY_DB` to `gateway.db`, and native acceptance
requires that file under the selected state directory. This brings the mapping
to seven databases plus the placement root. The earlier six-database binary
proof does not validate a newly assembled gateway-enabled executable.

Agree which declarations are separately installable module roots and choose
stable module identities. Audit dependency contracts beyond Lua imports: runtime
bindings, policy references, requirements and shared entry ownership also matter.
The audit `/tmp/bee-observer-module-boundary-audit.json` is only an import/root
inventory; it is not an extraction or dependency-closure proof.

The builder's `pack` command currently accepts one source root and explicitly
requires dependency packs to be prepared independently. A supported workflow must
produce the agreed bundle reproducibly, validate complete nonoverlapping entry
coverage and preserve explicit ownership. Do not copy the temporary Python probe
into production as an implicit module-publishing convention.

The fresh-builder fetch issue is resolved in `build/builder.lock.json`:
`70acb10175fbeb42a3a4d382677715a0c2a969e4` is available from the configured HTTPS
repository and has identical `internal/`, `cmd/`, `go.mod` and `go.sum` content
to the previously unavailable `fe458f77…` pin. Fresh bootstrap, split-bundle
assembly and native acceptance pass with the published pin; log
`/tmp/bee-published-builder-standalone-check.log`. Later upstream commits remove
runtime patch support, so they are not interchangeable with this manifest.
The earlier cached-builder result remains useful history, not the only build path.

## Registry preservation evidence

The native acceptance fixture now removes inherited subsystem database and
placement-root overrides before launch. It checks initialized SQLite files for
workspace, client layout, threads, approvals, resources, credentials and placement
under the selected `--state-dir`, in addition to rejecting caller-directory
`.wippy` pollution. Runtime environment override semantics are unchanged.
The split binary passes both ordinary acceptance and acceptance with all seven
inherited state variables pointing at unusable `/proc` paths. Logs:
`/tmp/bee-native-state-isolation-check.log` and
`/tmp/bee-native-inherited-state-check.log`.
These checks verify the isolated bundle; the shared monolithic application
manifest still requires the module-composition adoption described above.

The expanded native check also passes Test Status with explicit thread/run
arguments. It closes the view, proves completion has not yet occurred, then
observes the worker finish through a read-only journal connection. Reopen and
F12 display six passing checks; a cold restart with the same arguments leaves
exactly one run and nine events. Log: `/tmp/bee-native-test-status-check.log`.
This exercises the frozen split executable, not newer carrier work in the shared
source. No source checkout or Wippy executable is available in its launch folder.

The prototype now compares source registry output with the actual installed
binary's `runtime registry` output. All 431 IDs, kinds and complete entry
payloads match. The only normalization is top-level absent metadata: source
encodes it as `null`, installed packs as `{}`. Entry data, policy values, imports,
source content and nonempty metadata are compared without normalization.

`registry-equality-normalized.json` in the probe directory records per-entry
hashes. `/tmp/bee-split-registry-normalized-equality.log` reports no differences.
The initial unnormalized result is retained as `registry-equality.json`.
A separate installed `--registry-meta` check verifies all 431 entries are owned
by their planned module, across exactly 27 modules; counts are saved as
`registry-owner-counts.json`. This proves preservation for this bundle, not
independent installation or dependency closure for each component.
