# Releasing Bee

Bee launches through its own executable. The embedded application is the
recoverable deployment source for first install and update. Hub publication
happens from a tag's validated draft release, before that release is published;
no Hub launch entry point is required.

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
make release BEE_VERSION=0.1.0-dev
```

This builds pinned tools, runs the foundation and native checks, packs and proves
the source-free deployment, assembles Bee, runs executable acceptance (including
Linux network-isolated boot), and packages the result under `dist/release/`.
Packing requires Wippy syntax and strict type checking. The lint command explicitly
enables the type system and strict mode; validation failures stop the build.
The generated `dist/bee.bundle.build.json` records the selected version and every
physical pack hash. Review `dist/portable-deployment/wippy.lock` and its vendor
set with `make portable-deployment-check`. Packing leaves the input runtime
manifest unchanged.
See [native distribution](native.md) for prerequisites and update
semantics. Local builds create no Git tags or GitHub releases.

## Pull requests and release tags

Main requires `Bee CI` and `Native module CI`, one approving review, resolved
conversations and an up-to-date branch. Stale approvals are dismissed. These
rules include administrators. Force pushes and branch deletion are disabled;
merge with squash or rebase.

The validation job runs `make repository-check` before application assembly:
actionlint checks workflows, and Gitleaks scans history and current files with
redacted output and a Wippy Hub token rule. Native-module tags run the same checks.
On a release tag the validation job also checks the tag against the version
pattern and main ancestry, then runs `make native-pin-check
NATIVE_PIN_COMMIT="$GITHUB_SHA"`: the native pin in `wippy.build.json` must name
the tagged commit's own `native/` tree. The builder rejects a local module
replacement, so the pin is the only input that selects the native source; a pin
one revision behind the tag would assemble and ship stale native code, and the
gate stops the tag before anything is built.
Dependabot groups weekly Actions and native Go dependency updates to limit PR runs.
Actions default to read-only permissions and require full commit pins. Checkout
steps do not retain credentials in Git configuration.

PR and main checks run Linux amd64 with the full foundation suite. Release tags
and manual runs assemble and exercise Linux and macOS, each on amd64 and arm64.
A single pack job seals the application packs once; every target assembles its
executable from those packs, and the pack job dry-runs their Hub publication
without upload credentials.
Each Linux target proves the source-free portable deployment and runs executable
acceptance with networking disabled. Native module checks run on every Bee target,
with a separate Linux module gate.
Windows desktop support requires replacing the current Bash/POSIX terminal
assumptions; it is outside this release matrix. Builder has Windows CLI builds.

After merging, an administrator selects a version and creates its tag on the
reviewed main commit.
The workflow verifies ancestry. Tag updates and deletions are blocked. Passing
checks produce a **draft** GitHub release with checksummed assets. Publish the
Hub modules from it and run the post-publication check (see
[Release procedure](#release-procedure)), then review the assets, dependency
notices and release notes before publishing the release. Module tags
produce an archive containing only the `native/` tree. GitHub also provides its
standard repository source downloads.

The tagged commit's complete message must contain no GitHub Actions skip
directive, including `[skip ci]`. A skipped tag-push workflow produces no assets
and cannot satisfy the Hub publication gate.

A manual Bee workflow run accepts a preview version and uploads artifacts.

## Release procedure

A Bee application release proceeds in this order:

1. An administrator tags the reviewed main commit (`vMAJOR.MINOR.PATCH`).
2. The `Native Bee` tag workflow runs `make check`, builds every target and
   creates a **draft** GitHub release carrying `bee-deployment.tar.gz`.
3. The Hub modules are published from that draft release's deployment: the
   **Bee Hub publication** workflow for the tag, or `make hub-publish-release
   TAG=vX` locally (see [Hub publication](#hub-publication)).
4. The post-publication check installs a real Hub package into that same
   deployment; both paths run it right after publishing.
5. The draft release is reviewed and published.

`make check` cannot prove step 4: the release deployment re-resolves every
locked `bee/*` module from the Hub at the release version, which holds only
after step 3.

Bee application releases use tags of the form `vMAJOR.MINOR.PATCH` (with an
optional `-identifier` prerelease suffix). Create the tag on the reviewed main
commit; the validation job refuses a tag that is not a semantic version on main
or whose native pin does not name the tagged tree. A prerelease-suffixed tag
produces a prerelease; a bare version produces a stable release. The native Go
module is released separately under `native/vMAJOR.MINOR.PATCH` and never moves
the latest-release pointer.

The `Native Bee` workflow runs five jobs:

- `validate` (ubuntu-24.04) checks the tag, the native pin, then selects the
  platform matrix: PRs and main run Linux amd64 only; tags and manual runs add
  Linux arm64, macOS amd64 and macOS arm64.
- `pack` (ubuntu-24.04) runs `make native-pack` at the selected version, then
  `make hub-check` against the resulting deployment. It uploads the sealed pack
  set (`sealed-packs`) for the targets and the portable deployment as
  `bee-deployment.tar.gz` with its `.sha256`.
- `build` runs once per target. On every target it builds the pinned toolchain,
  verifies the runner architecture, restores the sealed pack set, runs the
  native module checks, and assembles the standalone executable from those packs
  with `make standalone-sealed`, so every target embeds identical pack bytes.
  Linux amd64 additionally runs the full foundation suite; each
  Linux target proves the source-free portable deployment and boots the
  executable with networking disabled; each macOS target runs the standalone
  desktop check. Targets other than Linux amd64 run `make installer-check`
  directly (Linux amd64 already covers it inside `make check`). Each target then
  packages `dist/bee` into an archive with checksums and uploads it.
- `required` (`Bee CI`) fails unless the pack job and every matrix target succeeded, so a single
  target cannot be silently skipped or excused.
- `release` runs only for `v*` tags. It downloads every target artifact, verifies
  each archive against its `.sha256`, and creates a **draft** GitHub release with
  `--verify-tag --draft --generate-notes`. Stable tags are marked `--latest`;
  prerelease tags are marked `--prerelease --latest=false`.

Artifacts accumulate in two places. During the run each target uploads an Actions
artifact named `bee-<goos>-<goarch>`; the release job then attaches
`bee-<goos>-<goarch>.tar.gz` and its `.sha256` to the draft release, together with
`install.sh` and the pack job's `bee-deployment.tar.gz` and `.sha256`. Each archive contains the executable `bee`, `bee.provenance.json`,
`bee.LICENSES.txt`, the effective `bee.go.mod` and `bee.go.sum`, and
`bee.runtime-patches.tar.gz`. The provenance sidecar records the sealed
application manifest, including every physical pack hash and the pinned native
module version.

### Verifying a downloaded archive

Download the archive and its checksum document from the release, then verify the
bytes before trusting the binary:

```sh
sha256sum -c bee-linux-amd64.tar.gz.sha256
tar -tzf bee-linux-amd64.tar.gz
tar -xOzf bee-linux-amd64.tar.gz bee.provenance.json
```

The checksum document names the archive, so `sha256sum -c` fails on a mismatched
or renamed file. The extracted `bee.provenance.json` records the exact pack hashes
and native module version the archive was assembled from; compare the native
`version` against the tag's `native/` tree.

### Installer selection

`install.sh` selects the archive for the running host: `uname -s` maps to
`linux` or `darwin` and `uname -m` to `amd64` or `arm64`. It downloads
`bee-<platform>-<arch>.tar.gz` and `.sha256` from
`releases/latest/download` for the latest stable release, or from
`releases/download/v<version>` when `--version` names a release (prereleases are
selected explicitly this way). It verifies the archive against the checksum
document, extracts the `bee` member, and replaces the destination through a
temporary file. `make installer-check` covers this selection, checksum and
failure-preservation behavior. No PowerShell installer ships in this repository,
so `install.ps1` is not part of the release assets or checks.

## Contents and publication prerequisites

Production packs select `src/`; architecture acceptance checks loaded entries
and the source/pack boundary. Tests, local databases, credentials and development
stores must stay outside the application pack. The release archive contains the
binary, provenance, effective Go module files, available dependency notices and
any runtime patch sources the manifest lists. Runtime patches retain their upstream MPL-2.0 license.

Resolve missing dependency notices before a stable public release. Signing and
Hub credentials require separate configuration. Keep private keys in
restricted secret storage; never attach them to releases or embed them in packs.
Hub updates can replace compatible Lua application packs after publication;
native module changes require a new Bee binary.

See [dependency notices](dependencies.md) for the release inventory and
notice requirements.

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
make standalone BEE_VERSION=0.1.0-dev
make hub-check BEE_VERSION=0.1.0-dev
```

Hub publication uploads the sealed packs of the release deployment, never a
repack of the source. `build/release-source.sh` stages the source `make
native-pack` packs: the release lock names `bee/bee` and every `bee/*` module
at `BEE_VERSION`, each module's `wippy.yaml` carries that version, and every
`ns.dependency` on a sibling Bee module is pinned to it. Development keeps
`0.1.0-dev`; only the staged copy changes.

`build/hub-publish.sh` reads `dist/portable-deployment` (`BEE_DEPLOYMENT`
selects another). It requires every lock row to be a Bee module at
`BEE_VERSION`, every Bee module to be locked, and every vendor pack to match
its lock hash. It then runs `wippy publish --wapp` with each module's own
`wippy.yaml` for identity and metadata, in dependency order (`tsort` over
sibling `ns.dependency` entries) with `bee/bee` last. `make hub-check` dry-runs
each upload, prints the lock hash beside the `Digest:` the publisher reports,
and fails when any pair differs. `make hub-publish BEE_VERSION=…` runs that
check and uploads each immutable protected version with `--create`, so a
module the Hub does not have yet is registered with `HUB_VISIBILITY`. The Hub
therefore serves exactly the bytes the release executable's deployment lock
pins, and online resolution of a released deployment finds each locked module
at its locked digest. `make hub-publish-script-check` exercises the script
against a mocked publisher.

### Publishing a release to the Hub

`make hub-publish-release TAG=vX` publishes one GitHub release's modules from
that release's own deployment archive. `build/hub-release.sh` downloads
`bee-deployment.tar.gz`, `bee-linux-amd64.tar.gz` and their `.sha256`
documents with `gh release download` (a draft release requires push access),
verifies both checksums, extracts the deployment to
`dist/hub-release/deployment` (`HUB_RELEASE_DIR` selects another directory)
and requires its lock to name exactly the packs and hashes the executable's
`bee.provenance.json` records. `HUB_RELEASE_ASSETS` names a directory already
holding those four assets instead of downloading them. The target then runs
`make hub-publish` for every Bee module at the tag's version from that
deployment, then `make hub-release-install-check` against it.
`make hub-check-release TAG=vX` restores and dry-runs only;
`make hub-release-script-check` exercises the restore against a mocked GitHub
CLI.

`make hub-release-install-check BEE_DEPLOYMENT=DIR BEE_VERSION=X` is the
post-publication check. It refuses a directory without a release lock or a
lock that pins any `bee/*` module at another version, then launches the Modules
app on a copy of that deployment and installs a real Hub package through the
production facade. The installation resolves every locked `bee/*` module from
the Hub; a failure names each module that is missing from the Hub or whose Hub
digest differs from the lock. `make check` keeps the Modules scenarios that do
not depend on the release being published: the fixture Hub flows in source and
packed launches, the real Hub install into the source workspace, and authored
publication.

Publication resolves credentials as `wippy publish` does: `WIPPY_TOKEN`, then
the repository's `.wippy/credentials.yaml`, then the user's `wippy auth login`
store. An authenticated CLI needs no token variable. The dry run needs no
credential.

`.github/workflows/hub.yml` runs on manual dispatch with an application tag,
while its release is still a draft. It requires a semantic version tag on main,
an existing release for that tag and a successful native tag workflow for the
same commit, then runs `make hub-release-restore` and `make
hub-release-publish`: the same restore, publication and post-publication check
as `make hub-publish-release`, and a failure of any of them fails the workflow.
Only the restore step receives the GitHub token, which has `contents: write`
because draft releases are visible only with push access, and `actions: read`
to inspect the completed build run. Only the publication step receives the Hub
token. Native-module tags do not trigger it. A retry dispatches the same tag
again. Failure stays visible; the workflow never substitutes a mutable label
or increments the version automatically.

Configure `WIPPY_HUB_TOKEN` in the GitHub `hub` environment with permission to
create and publish modules in the Hub `bee` organization. Limit that
environment to the `main` branch and `v*` tags;
release-tag creation is restricted to administrators. Keep the token out of
repository-wide secrets, which same-repository PR workflows can access.
After replacing the token, run the **Hub credential and publication check**
workflow on main. It validates authentication and publish authorization without
creating an upload, and separately runs `make hub-check` for the requested
version without the credential.
The runtime receives it as `WIPPY_TOKEN` only for publication. Set repository
variable `BEE_HUB_VISIBILITY` to
`public` or `private` for first-time module creation; the workflow default is
public (Bee is MIT), and local `make hub-publish` and `make hub-publish-release`
default to private; pass `HUB_VISIBILITY=public` to match the workflow.
Existing module visibility is preserved.

Actual publication requires a Hub credential and creates only the selected
immutable version. Run `make hub-check-release` before publishing and verify
the resulting release artifact through the normal update path.

## Distribution access

Bee is public, so published GitHub release assets and the documented installer
are available anonymously. The pinned Builder action must also be resolvable by
public Bee workflows; organization-only action sharing is insufficient while
Builder remains private. Verify that dependency before creating a release tag.

The repository uses the organization code of conduct, local contribution and
security policies, issue forms, and CODEOWNERS. The documentation lives in `docs/`;
there is no separate GitHub Pages site. See [repository setup](../development/github.md) for
settings and credential boundaries.
