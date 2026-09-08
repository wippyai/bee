# Releasing Bee

Bee launches through its own executable. The embedded application can be a
recoverable base version or a first-install bootstrap. Hub publication follows
publication of a validated GitHub release; no Hub launch entry point is required.

| Deliverable | Repository | Tag | Artifact |
|---|---|---|---|
| Bee executable | wippyai/bee | `vMAJOR.MINOR.PATCH` | Binary and provenance archive per platform |
| Native Go module | wippyai/bee | `native/vMAJOR.MINOR.PATCH` | Source from `native/` |
| Builder CLI | wippyai/builder | `vMAJOR.MINOR.PATCH` | CLI archive per platform |

The native module uses Go's nested-module tag convention. A major version of
2 or higher requires changing its Go module and import paths first. Native
module releases do not release the desktop; application releases do not change
the pinned native module automatically.

## Local release

```sh
make release BEE_VERSION=0.1.0-dev BEE_MODE=base
```

This builds pinned tools, runs the foundation and native checks, packs the
application, assembles Bee, runs executable acceptance, and packages the result
under `dist/release/`. Use `BEE_MODE=bootstrap` to seed only the first deployment.
Packing requires Wippy syntax and strict type checking. The lint command explicitly
enables the type system and strict mode; validation failures stop the build.
The manifest records the selected version, mode and pack hash; review its diff.
See [native distribution](NATIVE_DISTRIBUTION.md) for prerequisites and update
semantics. Local builds create no Git tags or GitHub releases.

## Pull requests and release tags

Main requires `Bee CI` and `Native module CI`, one approving review, resolved
conversations and an up-to-date branch. Stale approvals are dismissed. These
rules include administrators. Force pushes and branch deletion are disabled;
merge with squash or rebase.

PR and main checks run Linux amd64 with the full foundation suite. Release tags
and manual runs assemble and exercise Linux and macOS, each on amd64 and arm64.
Linux amd64 also dry-runs the Hub publication packer without upload credentials.
Both Linux targets run executable acceptance with networking disabled. Native
module checks run on every Bee target, with a separate Linux module gate.
Windows desktop support requires replacing the current Bash/POSIX terminal
assumptions; it is outside this release matrix. Builder has Windows CLI builds.

After merging, select a version and create its tag on the reviewed main commit.
The workflow verifies ancestry. Tag updates and deletions are blocked. Passing
checks produce a **draft** GitHub release with checksummed assets. Review the
assets, dependency notices and release notes before publishing. Module tags
produce an archive containing only the `native/` tree. GitHub also provides its
standard repository source downloads.

A manual Bee workflow run accepts a preview version and base/bootstrap choice
and uploads artifacts. Tag releases use base mode. Change that release policy
through a reviewed workflow change if a product needs bootstrap-only releases.

## Contents and publication prerequisites

Production packs select `src/`; architecture acceptance checks loaded entries
and the source/pack boundary. Tests, local databases, credentials and development
stores must stay outside the application pack. The release archive contains the
binary, provenance, effective Go module files, available dependency notices and
runtime patch sources. Runtime patches retain their upstream MPL-2.0 license.

Resolve missing dependency notices before a stable public release. Signing and
Hub credentials require separate configuration. Keep private keys in
restricted secret storage; never attach them to releases or embed them in packs.
Hub updates can replace compatible Lua application packs after publication;
native module changes require a new Bee binary.

The [dependency notice review](DEPENDENCY_NOTICES.md) records the remaining
linked-module notices and their source evidence.

## Hub publication

```sh
make native-tools
make hub-check BEE_VERSION=0.1.0-dev
```

The preflight runs strict lint and Wippy's actual publication packer with
`--dry-run`. It validates the `bee/bee` application module without uploading.
Production source selection and test exclusions come from `wippy.yaml` and
the runtime publisher. `make hub-publish BEE_VERSION=…` runs that preflight and
publishes an immutable protected version through the native Wippy CLI.

`.github/workflows/hub.yml` runs when an application GitHub release is published.
It requires a semantic version tag on main, a published release and a successful
native tag workflow for the same commit. Native-module tags do not trigger it.
Manual dispatch retries an existing published application release through the
same checks. Failure stays visible; the workflow never substitutes a mutable label
or increments the version automatically.

Configure repository secret `WIPPY_HUB_TOKEN` with permission to publish `bee/bee`.
Pre-create the module in the Hub `bee` organization, or grant module-creation
permission for its first publication.
The runtime receives it as `WIPPY_TOKEN` only for publication. The repository has
no Hub secret configured yet. Set repository variable `BEE_HUB_VISIBILITY` to
`public` or `private` for first-time module creation; the default is private.
Existing module visibility is preserved. Local publication accepts the equivalent
`HUB_VISIBILITY` variable and Wippy's normal credential store or token environment.

The local dry run passed. No Hub version has been uploaded, and authenticated
publication plus a real Bee Hub update remain unverified. The local executable
continues to start from its embedded pack while credentials are prepared.
