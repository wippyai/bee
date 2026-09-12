# Hub package inspection

`bee.hub:inspect.read` reads one exact package version using the runtime Hub
reader. It returns the artifact's SHA-256 measurement and declared requirement
bindings. It inherits the caller's Hub permission and accepts no registry URL,
credentials or host path. Package entries are inspected without publishing or
starting them. Downloaded artifacts may enter the runtime's verified cache.

This is the first part of the proposed small Bee Hub installer. It is not a
dependency resolver, an approved installation plan or a public install tool.
Transitive resolution, existing-installation reconciliation, approval, guarded
publication, migrations and activation remain unimplemented here. The runtime
already owns dependency resolution; Bee must consume its exact proposed changes
before presenting them for approval. A second Lua dependency solver is not added.

Hub/system installations will use durable registry history. Authored component
changes belong to the separate database-backed overlay owner. Installing or
inspecting this component grants no publication, activation or sharing authority.
