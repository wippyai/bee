# Dependency notice review

The release inventory reads the executable's Go build metadata and collects root
license documents for linked modules. It includes the Go standard-library license
and preserves runtime patch sources separately. Common text-document formats are
accepted; source files such as `license_test.go` are excluded. The inventory is
an input to release review, including any separate terms in bundled native source.

The Linux amd64 artifact reports no linked Go modules without root license files.
This is an inventory result; target acceptance and license review remain release gates.

The owner selected MPL-2.0 for the registry protocol and generated bindings.
Bee pins the bindings to `v0.0.2-0.20260908140534-f6e2910c835f` through the
checksummed `runtime/patches/registry-license.patch`. The downloaded module differs
from `v0.0.1` only by `LICENSE`, `NOTICE`, and `README.md`; generated Go code is
identical. [Bindings PR #1](https://github.com/wippyai/module-registry-proto-go/pull/1)
and [runtime PR #683](https://github.com/wippyai/runtime/pull/683) remain under
review. The protocol-source repository is archived, so its separate prepared
license change cannot be pushed yet.

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
