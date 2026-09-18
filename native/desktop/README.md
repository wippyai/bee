# Bee native application composition

`Component()` is the builder's single Bee factory. It composes existing local
owner bootstrap, Hive service, native client launcher and I/O events. The wrapper
loads after cluster, supervisor, Lua and dispatcher; it publishes owner discovery
at Start and stops I/O/admission before those dependencies shut down. It implements
the runtime launch-preparer contract directly, so handled foreground clients open
no application stores in their process.

The compiled host selects the exact supervisor policies, `bee-owner` lifetime
command and ordinary `bee` route. Registry activation contains no grants. Default
node name is the OS hostname in a same-machine private mesh; external enrollment
and globally unique node naming are separate unfinished work. Owner credentials
have a maximum 30-day lifetime; renewal is not implemented. Fresh desktops open
no application. `New(Options)` permits an explicitly selected initial application
for embedded hosts and acceptance tests.

The source now contains the inert `bee.hive:activation` entry, headless wait
command and named supervisor policies. Loading that activation requires this
factory or the Hive service listener even when disabled. An older ioevents-only
toolchain cannot load the updated source. Runtime candidates and native module
versions must be selected together; the release manifest is not yet cut over.

Actual-source cold start, reuse, retained shell and physical detach pass through
this composition. Standalone build/upgrade/global acceptance remain outstanding.

The host selects one runtime state directory per canonical launch folder under
its state root, so several projects on one machine keep separate state and the
owner's mesh identity is qualified by the selected project state. A request that
selected state explicitly keeps it, and state created by earlier Bee versions
stays bound to the root. The host also selects the shared same-account Hive
directory and the protected machine configuration directory; a saved joined
profile in the latter is what makes an owner join a Hive.

A generated command hook runs `bee hook-post ENDPOINT ACTION_ID TOKEN_ENV EVENT`,
which is answered before project selection and owner startup, and the
`bee.harness.host:environment` storage exposes this executable's own path.

Ordinary application launches opt into the runtime's `EmbeddedBaseline` policy:
code comes from this executable's digest-scoped bundle and authored registry
history remains in the selected state's `registry.db`. Explicit recovery keeps
its separate history. Runtime and update operations retain their existing policy.
The foreground physical client handles Ctrl+Q and Ctrl+] locally; exiting it
retains the owner and applications. The client actor honors native scheduler
cancellation so its private host shuts down without waiting for the grace timeout.
