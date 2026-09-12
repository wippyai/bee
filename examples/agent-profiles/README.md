# Host-defined Agent profiles

Bee's `agent` command opens a native Agent window. It lists only launch
definitions whose policy contains a host-selected absolute executable binding.
After a user selects one, Bee validates provider configuration through that
driver's existing contract before creating launch work. The selected program
runs in the retained Bee PTY; it is not an emulated chat UI.

There is no runtime API to install this fragment, publish a module, or activate
an overlay. A host building Bee today can append the entries in
[`host-agent-profiles.yaml`](host-agent-profiles.yaml) to the `entries:` list in
`src/_index.yaml` before packing. This is a build-time, host-owned choice. Do
not give an application registry write permission to make these records live.

Before adding the fragment, resolve each installed binary to a literal absolute
path and replace both `REPLACE` paths. The picker refuses a policy with no
absolute executable binding. The carrier applies the matching policy key only
after the driver prepares its executable. Replace the Codex model with the reviewed model
the host intends to use. The example selects the existing native placement with
`process_group` cleanup and independent exit observation; do not weaken either
value to make a host pass.

The example has no credentials and no gateway tools. It supplies the source
composition required to make the existing Claude Code and Codex window profiles
available to `bee agent`; it does not claim an authenticated provider turn.
API-key authentication additionally requires all of these existing protected
steps:

1. Add an `env.variable` source for `ANTHROPIC_API_KEY` or `OPENAI_API_KEY` to
   the host's `bee:credential_sources` allowlist, scoped to the intended
   workspace and Agent-window audience.
2. Add the corresponding credential name to that launch definition's
   `credentials` list.
3. Define the workspace credential through an already-authorized workspace
   manager before launch. Bee has no public credential-setup screen or
   self-service registry mutation route yet.

Scoped MCP also remains unavailable for this example because the production
composition does not start the gateway listener. Docker placement is not
implemented. Do not add `gateway_tools`, gateway hooks, a Docker declaration,
or a permission exchange until their host services and acceptance gates exist.

After reviewing and merging the fragment into a host source tree, build that
tree with the normal `make pack`/native packaging flow. Start the resulting Bee
and run `bee agent`; its profile picker lists the configured entries. An
existing running owner must be restarted to load the newly packed source.
