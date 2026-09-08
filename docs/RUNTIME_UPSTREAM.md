# Runtime upstream work

Bee's release manifest still applies runtime patches. These changes must land in
Wippy before Bee can build from an upstream commit alone. The Go builder already
supports assembly without patches; it calls the runtime's application host and
registers Bee's native components through Wippy boot.

`make setup` and standalone builds now use `wippy.build.json` through the same Go
builder. The builder pin lives in `build/builder.lock.json`. The separate setup
script and runtime lock have been removed.

## Upstream dependencies

| Required behavior | Upstream change |
|---|---|
| Viewport pages and delegated terminal mounts | [#653](https://github.com/wippyai/runtime/pull/653) |
| Update a published deployment from its locked root | [#667](https://github.com/wippyai/runtime/pull/667) |
| Embedded application host and native boot components | [#668](https://github.com/wippyai/runtime/pull/668), stacked on #667 |
| Licensed Nexus annotations | [#677](https://github.com/wippyai/runtime/pull/677) |
| Licensed registry bindings | [#683](https://github.com/wippyai/runtime/pull/683), stacked on #677 |
| Credential-free publication dry runs | [#684](https://github.com/wippyai/runtime/pull/684) |
| CLI startup without terminal query responses | [#686](https://github.com/wippyai/runtime/pull/686) |
| Complete full-width frames and repaint after shrink | [#687](https://github.com/wippyai/runtime/pull/687) |
| Correct security SDK argument names | [#688](https://github.com/wippyai/runtime/pull/688) |
| Idempotent viewport revocation after recipient cleanup | [#689](https://github.com/wippyai/runtime/pull/689), stacked on #653 |

The foundation patch also carries the scheduler shutdown fix already merged in
[#655](https://github.com/wippyai/runtime/pull/655). Updating the runtime pin removes
that duplicate. This table covers the published Bee build; experimental local host
and cluster changes require their own upstream acceptance before release adoption.

## Removing the patch dependency

1. Merge the upstream changes, preserving the base-before-dependent order above.
2. Pin a containing runtime `main` commit in `wippy.build.json` and update the native
   module's runtime dependency. Publish a native module version and pin it in Bee.
3. Delete `runtime.patches` from the manifest and remove the `runtime/` directory.
4. Run `make setup`, `make check`, `make native-check`, `make standalone` and
   `make native-binary-check` from a clean checkout. Verify the build provenance
   contains the selected upstream commit and no patch inputs.
5. Validate the release matrix on Linux and macOS, amd64 and arm64, before tagging.

The resulting repository owns application source, native components and build
configuration. Runtime changes are maintained and tested in Wippy. Hub publication
and deployment updates continue through the runtime's canonical application host.

## Local validation

The four newly extracted fixes passed their affected Go package race suites and
pinned golangci-lint v2.13.2. The full-width and shrink regression tests fail against
upstream main and pass with the fix. Rodrigo is requested as reviewer on each PR.

The consolidated Go setup built Bee locally. Typed lint and standalone acceptance
passed embedded boot, Settings recovery, native terminal execution and presenter
rejoin. This build still uses the existing manifest patches; it verifies the setup
consolidation and does not establish completion of the upstream migration.
