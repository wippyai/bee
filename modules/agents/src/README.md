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
