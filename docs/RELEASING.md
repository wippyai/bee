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

Native Go pins must resolve from a retained main commit or a module release tag.
After squash-merging a module change, pin its merged revision before deleting the
feature branch; Go does not resolve short pseudo-version hashes through PR refs.
Verify the pin with an empty module cache. The current pin uses the merged main
revision and contains the same native source as the original development pin.

## Local release

```sh
make release BEE_VERSION=0.1.0-dev BEE_MODE=base
```

This builds pinned tools, runs the foundation and native checks, packs the
application, assembles Bee, runs executable acceptance, and packages the result
under `dist/release/`. Use `BEE_MODE=bootstrap` to seed only the first deployment.
Packing requires Wippy syntax and strict type checking. The lint command explicitly
enables the type system and strict mode; validation failures stop the build.
The generated `dist/bee.bundle.build.json` records the selected version, mode and
every pack hash. Review `build/modules.json` for ownership and the generated
bundle's `ownership.json` for entry coverage. Packing leaves the input runtime
manifest unchanged. Current runtime cutover gates still apply; see
`handoffs/STATUS_RUNTIME_GATE.md` before attempting a release.
See [native distribution](NATIVE_DISTRIBUTION.md) for prerequisites and update
semantics. Local builds create no Git tags or GitHub releases.

## Pull requests and release tags

Main requires `Bee CI` and `Native module CI`, one approving review, resolved
conversations and an up-to-date branch. Stale approvals are dismissed. These
rules include administrators. Force pushes and branch deletion are disabled;
merge with squash or rebase.

The validation job runs `make repository-check` before application assembly:
actionlint checks workflows, and Gitleaks scans history and current files with
redacted output and a Wippy Hub token rule. Native-module tags run the same checks.
Dependabot groups weekly Actions and native Go dependency updates to limit PR runs.
Actions default to read-only permissions and require full commit pins. Checkout
steps do not retain credentials in Git configuration.

PR and main checks run Linux amd64 with the full foundation suite. Release tags
and manual runs assemble and exercise Linux and macOS, each on amd64 and arm64.
Linux amd64 also dry-runs the Hub publication packer without upload credentials.
Both Linux targets run executable acceptance with networking disabled. Native
module checks run on every Bee target, with a separate Linux module gate.
Windows desktop support requires replacing the current Bash/POSIX terminal
assumptions; it is outside this release matrix. Builder has Windows CLI builds.

After merging, an administrator selects a version and creates its tag on the
reviewed main commit.
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

## Binary installer

Application releases also attach the repository's `install.sh`. It downloads
the latest stable application release by default; `--version` can select a
published prerelease. Native-module releases never update GitHub's latest-release
pointer. Application tags with a prerelease suffix are marked as prereleases.
The installer downloads
published binaries for Linux/macOS on amd64/arm64, verifies the matching archive
checksum, and replaces the executable through a temporary file in the destination
directory. `make installer-check` covers installation and failure preservation;
the full `make check` includes it. The installer does not change workspace data.

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
The publication job grants its GitHub token `contents: read` and `actions: read`
to inspect the release and its completed build run.
Manual dispatch retries an existing published application release through the
same checks. Failure stays visible; the workflow never substitutes a mutable label
or increments the version automatically.

Configure `WIPPY_HUB_TOKEN` in the GitHub `hub` environment with permission to
publish `bee/bee`. Limit that environment to the `main` branch and `v*` tags;
release-tag creation is restricted to administrators. Keep the token out of
repository-wide secrets, which same-repository PR workflows can access.
After replacing the token, run the **Hub credential check** workflow on main.
It validates authentication and publish authorization without creating an upload.
Pre-create the module in the Hub `bee` organization, or grant module-creation
permission for its first publication.
The runtime receives it as `WIPPY_TOKEN` only for publication. Set repository
variable `BEE_HUB_VISIBILITY` to
`public` or `private` for first-time module creation; the default is private.
Existing module visibility is preserved. Local publication accepts the equivalent
`HUB_VISIBILITY` variable and Wippy's normal credential store or token environment.

The local dry run passed with an empty home/config directory and no token.
Bee carries the checksummed runtime fix from
[PR #684](https://github.com/wippyai/runtime/pull/684), so pack-only publication
validation does not request credentials. Linux CI runs this preflight before
the foundation suite. Actual publication retains its authentication requirement.
The deployment token passed the live Hub publish authorization checks for
`bee/bee` on 2026-09-08, and Hub reported organization role `owner`. Those probes
omitted the version and upload payload, so they created no publication. A completed
upload and a real Bee update remain acceptance gates for the first release.

## Distribution access

Both repositories are currently private. GitHub releases inherit repository
visibility: anonymous downloads and the documented public installer command
require a public Bee repository. Builder action sharing is enabled for the Wippy
organization. Decide public visibility before announcing an OSS release.

The repository uses the organization code of conduct, local contribution and
security policies, issue forms, and CODEOWNERS. The documentation lives in `docs/`;
there is no separate GitHub Pages site. See [repository setup](GITHUB.md) for
settings and credential boundaries.
