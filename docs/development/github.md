# GitHub setup

Bee uses GitHub for source review, CI and release artifacts. Repository settings
must keep unreviewed changes and credentials out of ordinary pull-request jobs.

## Protection and automation

| Setting | Required configuration |
|---|---|
| Main | Pull request, code-owner review, stale approval dismissal, resolved conversations and current base |
| History | Linear history; force pushes and deletion blocked |
| Checks | `Bee CI` and `Native module CI` required before merge |
| Tags | Release-tag creation restricted to administrators; updates and deletion blocked |
| Actions token | Read-only and unable to approve pull requests |
| External actions | Pinned to a full commit SHA |
| Security | Secret scanning, push protection, dependency alerts and security updates enabled |

`CODEOWNERS`, the repository templates, [contribution guidance](../../CONTRIBUTING.md),
the organization code of conduct and [security policy](../../SECURITY.md) define
the corresponding review and reporting paths.

## Hub credential boundary

`WIPPY_HUB_TOKEN` is an Actions secret in the `hub` environment. Hub publication
and the manual credential check receive it only as `WIPPY_TOKEN` in their
request steps. The environment is limited to `main` and `v*` tags; pull-request
jobs, build assembly and ordinary workflows receive no Hub token.

`BEE_HUB_VISIBILITY` is an optional repository variable; the Hub publication
workflow defaults it to `public`. It controls first-time Hub module creation and does not change the
repository's visibility.

Checkout uses `persist-credentials: false`. Release jobs may have only the
write access needed to create draft releases; the Hub publication job has
`contents: write` only because a draft release's assets are visible solely with
push access, and it passes the GitHub token to its restore step alone. Do not add deploy keys, webhooks,
repository-wide copies of the Hub token or credentials to artifacts and logs.

After replacing the Hub token, run the **Hub credential check** workflow from
`main`. It makes an incomplete publish request that must reach version
validation; it must not create an upload or print credentials or response
bodies.

## Release boundary

Pull requests and pushes run the short `Bee CI` path: the repository check,
strict lint and the Lua unit suite. Release tags and manual runs add the sharded
`make check`, the shared pack job and every platform build under the same
required check.
Release tags must be on `main` and use the documented semantic version format.
The release workflow creates draft releases only after its required shard and
platform checks succeed. See [releasing](../operations/releasing.md) for artifact and publication
procedures.

## Native CI caches

`native.yml` pins `actions/cache` to a full commit SHA. All cache keys include
the runner OS and architecture:

| Key prefix and inputs | Cached paths | Used by |
|---|---|---|
| `toolchain-v2`: hash of the manifest's runtime and native inputs plus the builder pin, then verifier hash | `.wippy/bin` (the built runtime, its provenance and sidecars, and the builder executable) | Unit, pack, check shards and platform builds |
| `go-v1`: hash of all `go.sum` files, `native/go.mod` and the builder lock, then job name | Go's `GOCACHE` and `GOMODCACHE` | Repository check, unit, pack, check shards and platform builds |
| `lua-v2`: runtime commit, hash of all `*.lua` files, then job name | `.wippy/test-cache` (shared by disposable test homes) | Unit, pack, check shards and platform builds |

The toolchain inputs include the runtime commit, repository, Go version, tags
and patches, plus the exact native components. Application packs and data do
not enter a toolchain build, so changing them does not force a rebuild. The
builder lock names its exact source commit. The toolchain cache has no broad
restore prefix: a changed build input rebuilds it. On an exact hit,
`build/verify_cached_toolchain.py` checks those inputs, builder commit, Go
version, mode and every artifact digest before any cached binary runs. A
failed verification stops the job. On a miss, the pinned builder action builds
the toolchain and the same check runs before the result is cached. The builder
executable's digest is recorded and checked with the toolchain.

Go caches use a matching-input prefix and then an OS/architecture prefix, so
jobs can reuse downloaded modules and compiled packages as dependencies
change. Lua caches use a matching-source prefix and then a matching-runtime
prefix; the runtime's own content checks decide which restored entries remain
valid when Lua sources change. Release shards and platform builds also restore
the pack job's warm compilation artifact from the same run. Cache hits only skip setup work. Lint, unit,
pack, release checks and packaging still run. The warm push CI target is about
five minutes; actual time depends on runner load and cache transfer.

Use the repository check while changing workflow or security configuration:

```sh
make repository-check
```
