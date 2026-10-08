# External MCP clients

`bee mcp connect [--name NAME]` pairs an MCP client Bee does not launch,
including Claude Code in another terminal and Codex. Run it in a folder whose
Bee node is running in the machine's hive. The command reaches that node through
the same transient Hive client as other Bee commands. It opens no MCP listener:
the node's existing gateway must listen on loopback.

Needs you names the client and the requested traits. The host's
`bee.gateway.external_profile` metadata defines its offered tools,
`gateway_surface.access` (`gateway_access` semantics) and `pairing_traits`.
The default pairing asks to read Bee's documentation, capabilities and the
client's own thread. Until approval, no token is issued and no traits are active.
Denial, expiry or withdrawal ends pairing without a credential.

Keep the requesting terminal open while the person decides. On approval, Bee
shows one token and configuration references for Claude Code `.mcp.json`,
`claude mcp add --transport http`, and Codex `config.toml` with
`bearer_token_env_var`. The printed `BEE_MCP_TOKEN` export holds that token;
the configurations reference it instead of duplicating it. Bee writes no
configuration or credential file. A configuration can be retrieved only by the
requesting terminal and only once. Pair again if that terminal loses its reply.

Each client is a distinct gateway subject with its own thread and prepared
attempt. Its credentials use the gateway's existing hash store, listener epoch,
generation, expiry and revocation checks. The default connection lasts at most
24 hours; a listener restart also fences it. Pair again for a new connection.
The token grants access only to the traits the person approves.

The existing MCP `session` tool reads and selects the active surface.
`session {operation: "request_access", idempotency_key, traits, reason}` asks
Needs you for more host-offered traits; `access_status` applies the authoritative
approval. App tools, application runtime and sharing retain their built-in
consent traits. Capability and runtime leases keep their existing expiry and
use limits. No external-client tool or second authorization mechanism is added.

Sessions has an **MCP clients** action. The same list is available from the
Start panel. It shows each named client, its status and **Tool calls**. Every
admitted tool invocation appends its name to the client's thread as that
subject. The audit record contains no request arguments, results or bearer
credential. **Revoke** closes the existing gateway binding immediately;
subsequent presentations of its token fail. The transcript stays available.
