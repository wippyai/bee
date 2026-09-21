# Runtime integration

Bee builds Wippy from the repository and commit recorded in
[`wippy.build.json`](../../wippy.build.json). The same manifest records Bee's Go
version, build tags and the exact patch bytes applied to the runtime. Bee does
not vendor a runtime source directory.

The current manifest carries the terminal-session identity and application
default-state patches. `make setup` and standalone builds use the same builder
and manifest. Wippy owns application deployment, Hub resolution, command
dispatch, state opening and shutdown; Bee registers its native components
through Wippy boot.

## Update procedure

1. Select an upstream commit that contains the required runtime APIs.
2. Update the runtime commit in `wippy.build.json` and any necessary native
   module dependency.
3. Refresh each patch checksum in the manifest. Keep patches minimal and retain
   upstream license notices.
4. Run the native patch check and the affected upstream Go tests.
5. Run Bee's typed, pack and native acceptance checks before publishing a
   standalone build.

```sh
make -C native patched-check
make lint
make check
make standalone
```

The generated provenance records the selected runtime commit and patch digests.
A runtime change is ready only when the manifest, patch checks and Bee's
relevant acceptance gates agree. Experimental upstream work remains outside the
published integration until its own acceptance contract exists.
