# Dependency notice review

The release inventory reads the executable's Go build metadata and collects root
license documents for linked modules. It includes the Go standard-library license
and preserves runtime patch sources separately. Common text-document formats are
accepted; source files such as `license_test.go` are excluded. The inventory is
an input to release review, including any separate terms in bundled native source.

The Linux amd64 artifact currently reports these missing root notices:

| Linked module | Pinned version | Evidence and next step |
|---|---|---|
| `github.com/nexus-rpc/nexus-proto-annotations` | `v0.1.0` | The pinned distribution has no root license. Upstream added MIT in commit `835bd8d49cb45c8efa22614164b90335f7e56918`; evaluate a pin to licensed source. |
| `github.com/wippyai/module-registry-proto-go` | `v0.0.1` | The pinned distribution has no root license. The generated and source protocol repositories report no declared license; their owner must select and publish the applicable terms. |

The earlier module-graph inventory also listed sqlite-vec bindings and
plan9netshell. Neither is linked into this Linux executable. Other targets must
use their own executable metadata and notice review.

Upstream's comparison of the Nexus license commit against `v0.1.0` shows only
the addition of `LICENSE`; its source files are unchanged.

Do not assign an upstream license based solely on the license of Bee or Wippy.
Resolve applicable terms and update the pinned inputs before public distribution.
The native `ioevents` backend retains its pinned MIT notice in
`native/licenses/notify.txt`; Bee-owned code remains MIT and runtime patches
retain MPL-2.0.
