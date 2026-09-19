# Runtime integration

Bee builds Wippy from upstream commit
`7f9e7e89bc70dce15c191d279b46029f4da18810`, the reviewed head of runtime
PR [#787](https://github.com/wippyai/runtime/pull/787), selected in
`wippy.build.json`. The repository carries one composed terminal-session
identity patch and no runtime source directory.

`make setup` and standalone builds use the same Go builder and manifest. The
builder pin lives in `build/builder.lock.json`. Builder calls Wippy's application
host and registers Bee's native components through Wippy boot. Wippy owns
application deployment, Hub resolution, command dispatch and shutdown.

## Merged upstream changes

| Behavior | Upstream PR |
|---|---|
| Viewport pages and delegated terminal mounts | [#653](https://github.com/wippyai/runtime/pull/653) |
| Update a published deployment from its locked root | [#667](https://github.com/wippyai/runtime/pull/667) |
| Embedded application host and native boot components | [#668](https://github.com/wippyai/runtime/pull/668) |
| Licensed Nexus annotations | [#677](https://github.com/wippyai/runtime/pull/677) |
| Licensed registry bindings | [#683](https://github.com/wippyai/runtime/pull/683) |
| Credential-free publication dry runs | [#684](https://github.com/wippyai/runtime/pull/684) |
| CLI startup without terminal query responses | [#686](https://github.com/wippyai/runtime/pull/686) |
| Complete full-width frames and repaint after shrink | [#687](https://github.com/wippyai/runtime/pull/687) |
| Correct security SDK argument names | [#688](https://github.com/wippyai/runtime/pull/688) |
| Idempotent viewport revocation after recipient cleanup | [#689](https://github.com/wippyai/runtime/pull/689) |

The scheduler shutdown fix was already merged in
[#655](https://github.com/wippyai/runtime/pull/655). Merge commits retain the original
source revisions. The native module's minimum runtime dependency is now an ancestor
of runtime main; the assembly manifest selects the complete application runtime.

## Validation and upgrades

The #787 source and Bee's terminal-session patch pass the affected Go race and
vet gates. Bee's typed, bundle and native bootstrap checks use this exact pin;
standalone and executable acceptance must pass again before global promotion.
The generated provenance records the upstream commit and verified patch digest.

For a runtime upgrade, select a containing upstream commit, build the toolchain,
and run the same application and native acceptance gates. Update the native
module's minimum dependency when its SDK requirements change. Validate the release
matrix on Linux and macOS, amd64 and arm64, before tagging.

Experimental local host and cluster work requires separate upstream acceptance
before release adoption. The published build uses the merged runtime APIs above.
