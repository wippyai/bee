# Runtime integration

Bee builds Wippy from the repository and commit recorded in
[`wippy.build.json`](../../wippy.build.json). The same manifest records Bee's Go
version, build tags and, when present, the exact patch bytes applied to the
runtime. Bee does not vendor a runtime source directory.

Bee builds from unpatched runtime main; the manifest lists no patches. `make setup` and standalone builds use the same builder
and manifest. Wippy owns application deployment, Hub resolution, command
dispatch, state opening and shutdown; Bee registers its native components
through Wippy boot.

## Update procedure

1. Select an upstream commit that contains the required runtime APIs.
2. Update the runtime commit in `wippy.build.json` and any necessary native
   module dependency.
3. Bee builds from unpatched upstream commits. A patch entry is a last resort
   for an unmerged upstream change: record its checksum in the manifest, keep it
   minimal and retain upstream license notices.
4. Run the native pinned-runtime check and the affected upstream Go tests.
5. Run Bee's typed, pack and native acceptance checks before publishing a
   standalone build.

```sh
make -C native patched-check
make lint
make check
make portable-deployment-check
make standalone
```

The generated provenance records the selected runtime commit and any patch digests.
A runtime change is ready only when the manifest, patch checks and Bee's
relevant acceptance gates agree. Experimental upstream work remains outside the
published integration until its own acceptance contract exists.
