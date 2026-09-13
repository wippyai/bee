# Offline startup acceptance

Bee startup must use embedded packs and previously installed, digest-verified
local artifacts without reaching the Hub. Dependency downloads belong to explicit
installation and update operations. Missing local content must produce a local
error; startup must not silently resolve a different version or discard overlays.

The September 12 reported failures reproduced against a private copy of the
registry with networking disabled. Changing the embedded bundle selects a new
deployment directory, while the registry retains installed dependency identities.
The corresponding artifacts existed in previous deployment vendors. Importing
their exact recorded digests cleared restore, exposing a second error: an
installed module also declared a terminal host.

Bee's four desktop/lifetime commands now declare `host: bee:terminal`. Runtime
PR [740](https://github.com/wippyai/runtime/pull/740) supports this metadata;
explicit `--host` still takes precedence. Runtime PR
[741](https://github.com/wippyai/runtime/pull/741) makes registry startup restore
offline and preserves the caller's dependency access policy. Both PRs remain
unmerged. Runtime PR [742](https://github.com/wippyai/runtime/pull/742)
provides the stable application cache using `registry.dependency_vendor_dir`.
It is stacked on PR #726, open and assigned to Rodrigo. The cache retains exact
artifacts under `state/artifact-cache/vendor` and imports older deployment
vendors without modifying their locks, artifacts or registry history.

The source `d88cbd6` candidate passes a Linux network namespace test with only
loopback available: fresh desktop (1.530 s), restart (1.242 s), changed embedded
bundle restoring the private copied installed-module registry (3.560 s), and
its restart (1.320 s). Retained artifacts remain byte-identical. The public
retained-client test also passes offline, including cold owner startup,
detach, the same live shell, F12 and warm reconnect (0.216 s).

Evidence outside the repository: `bee-evidence/0912/offline-final-desktop-proof.log`.
The fixture uses a SQLite backup and disposable stores; it never resets the
user's registry. Runtime app/core/Hub/CLI race tests and lint pass, including
missing-cache offline refusal and failed/concurrent artifact publication.
Bee strict lint and 789 unit cases pass. The current global installation and
remaining broader acceptance are tracked in `GLOBAL_BUILD.md`.
