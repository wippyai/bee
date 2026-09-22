# Bee Codex driver

Install bee/driver-codex with bee/driver and bee/threads. It supplies Codex CLI
profiles, stream normalization, launch declarations, and the configuration
renderer for the shared driver contract.

The host supplies a read-only executable environment and a launch policy for
each route. Installing this component does not activate Codex, expose a user
home, copy credentials, or grant MCP tools.

## Named configuration profile

When a host policy declares the bounded text option config_profile, this
component validates the value as a plain Codex profile name and invokes
codex --profile <name>. Codex loads $CODEX_HOME/<name>.config.toml on top of
its normal configuration. A private Bee home never copies that file, so a launch
that needs it is refused before it starts unless it inherits the user's Codex
home.

## Provider configuration

The normal window uses the user's existing Codex login. A host may instead
select a reviewed provider configuration for a private home. The component
renders only that provider's approved model, reasoning effort, developer
instructions, scoped MCP connection, and hook configuration; credentials stay
with the host credential path. Codex reads batch briefs from stdin, so those
launches declare end-of-file input and placement closes stdin after writing the
brief.
