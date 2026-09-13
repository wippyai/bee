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
unmerged. Stable application-cache integration is still under validation.

Required release evidence: fresh offline boot, offline restart, and a changed
embedded bundle restoring an installed dependency from an older deployment,
with registry data and exact module identities preserved. The generic runtime
tests pass for host selection and offline cache-miss behavior. They do not yet
establish this combined Bee executable acceptance. No global installation is
claimed by this handoff.
