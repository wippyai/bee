# Bee agents

`bee/agents` is the default managed-agent kit for a Bee host. It composes the
Agent window and harness with credential projection, native placement, resource
associations, the external turn executor, shared driver contracts, and the
built-in Claude, Codex, agy, Grok, Muse, OpenCode, and Wippy drivers. The
kernel can omit this package; its known `bee <provider>` commands then identify
`bee/agents` as the install target.

Each component owns its default host requirements and policy declarations.
Assemblies can replace requirement targets without editing Bee's kernel
composition. The `bee/agents` dependency composes the same defaults in a normal
Bee installation.

The Agent catalog discovers bindings through `meta.type: harness.driver`,
`driver_id` and `profiles_ref`, then validates their `bee.driver:driver`
contract and callable method targets from the same registry snapshot. A driver
can live in its author's package and bind functions in another namespace.
Discovery reports compatibility separately from host activation.

To add a driver, an agent authors the binding, typed prepare/dispatch/normalize/
configure functions, matching profile declaration, launch definition and, for
a CLI, its descriptor and provider renderer. The person admits that exact
binding through `bee.harness.launch:harness_activation`, together with the
existing host-selected launch policy, executable, placement, resources,
credentials and gateway permissions. Metadata and package installation grant
none of these permissions. See the [driver contract](../../driver/src/README.md).

An admitted target or descriptor change is resolved for new sessions; running
executions retain their existing route. Agents author overlay candidates through
the governed authoring path; people review and approve the destination's exact
candidate before its owner applies it. Approved overlays may update a built-in
binding's targets or descriptor configuration, or add a driver in its own
package namespace. The destination's existing governance rules apply to each
changed candidate. Newly authored overlay drivers also require exact host
binding activation before they can run.
