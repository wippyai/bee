# External MCP clients

An external client is a distinct gateway subject with its own thread and
prepared attempt. Credentials use the gateway's existing hash store, listener
epoch, generation, expiry and revocation checks. The host's
`bee.gateway.external_profile` metadata defines its offered tools,
`gateway_surface.access` (`gateway_access` semantics) and `pairing_traits`.
The token grants access only to the traits the person approves.

The command reaches the running node through the same transient Hive client as
other Bee commands. It opens no MCP listener: the node's existing gateway must
listen on loopback. Denial, expiry or withdrawal ends pairing without a
credential. Configuration can be retrieved only by the requesting terminal and
only once. Pair again if that terminal loses its reply. Bee writes no
configuration or credential file.

The existing MCP `session` tool reads and selects the active surface.
`session {operation: "request_access", idempotency_key, traits, reason}` asks
Needs you for more host-offered traits; `access_status` applies the authoritative
approval. App tools, application runtime and sharing retain their built-in
consent traits. Capability and runtime leases keep their existing expiry and
use limits. No external-client tool or second authorization mechanism is added.

Every admitted tool invocation appends its name to the client's thread as that
subject. The audit record contains no request arguments, results or bearer
credential. The transcript stays available after revocation.

## How to connect

1. In the folder of a running Bee in this machine's hive, run:

```sh
bee mcp connect --name <name>
```

2. Keep that terminal open. In Bee's Needs you, approve the named client and
   its requested access. Until approval, no token is issued and no traits are active.

3. The requesting terminal prints the token and ready configurations:

- Claude Code: `claude mcp add --transport http ...` or `.mcp.json`.
- Codex: `config.toml` with `bearer_token_env_var`.

Use the printed `BEE_MCP_TOKEN` export. The configurations reference it instead
of duplicating the token.

By default, the client can read Bee's documentation, capabilities and its own
thread. Additional access requires approval in Needs you.

Connections last at most 24 hours. A listener restart also ends access.
Run the connect command again for a new connection.

To revoke access, open Sessions > MCP clients (also in Start), select the client
and choose X Revoke, then confirm. Revoke closes access immediately; its token
stops working. Revoking a pending client also withdraws its request from Needs you.
Enter Tool calls shows the client's tool-call history.
