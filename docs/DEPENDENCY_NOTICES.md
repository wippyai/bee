# Dependency notice review

The release inventory reads the executable's Go build metadata and collects root
license documents for linked modules. It includes the Go standard-library license
and preserves runtime patch sources separately. Common text-document formats are
accepted; source files such as `license_test.go` are excluded. The inventory is
an input to release review, including any separate terms in bundled native source.

The Linux amd64 artifact currently reports one missing root notice:

| Linked module | Pinned version | Evidence and next step |
|---|---|---|
| `github.com/wippyai/module-registry-proto-go` | `v0.0.1` | The owner selected MPL-2.0 for the source protocol and generated bindings. [Bindings PR #1](https://github.com/wippyai/module-registry-proto-go/pull/1) adds the license and notice. The protocol-source repository is archived, so its prepared change cannot be pushed yet. Merge the license changes and update the runtime dependency pin before distribution. |

The earlier module-graph inventory also listed sqlite-vec bindings and
plan9netshell. Neither is linked into this Linux executable. Other targets must
use their own executable metadata and notice review.

Upstream's comparison of the Nexus license commit against `v0.1.0` shows only
the addition of `LICENSE`; its source files are unchanged.
[Runtime PR #677](https://github.com/wippyai/runtime/pull/677) prepares that
dependency update. The downloaded module distributions also differ only by
`LICENSE`; affected Temporal and telemetry race tests passed locally. Bee applies
the dependency update through `runtime/patches/dependency-notices.patch`, with
its checksum pinned in `wippy.build.json`. Local assembly includes the MIT notice
and passes standalone desktop acceptance. The runtime source revision is unchanged.

Do not assign an upstream license based solely on the license of Bee or Wippy.
Resolve applicable terms and update the pinned inputs before public distribution.
The native `ioevents` backend retains its pinned MIT notice in
`native/licenses/notify.txt`; Bee-owned code remains MIT and runtime patches
retain MPL-2.0.
