# Hive reachability

Hive has two network paths. Invite redemption uses a TCP listener and TLS 1.3. The runtime mesh uses UDP gossip and TCP internode TLS. A successful invite proves the first path; the selected mesh address and both mesh transports must remain reachable for a peer session and reconnects.

## Invite endpoints

`bee hive invite` asks the running owner's supervisor for a single-use invite that expires after 15 minutes. The owner prints one `bee-hive://` line on stdout. An owner restart voids outstanding invites.

The invite names one primary IP endpoint for the owner's TCP join listener and may carry up to eight alternate endpoints as URL-escaped `&c=KIND,SCOPE,ENDPOINT` fields. These are typed route hints:

| Kind and scope | Endpoint source |
|---|---|
| `interface/lan` | Active non-virtual network interfaces |
| `interface/vm` | Virtual interfaces such as Docker or VM networks |
| `tailnet/tailnet` | An assigned Tailscale IP |
| `magicdns/tailnet` | The node's Tailscale MagicDNS name |

The primary address and every alternate use the join listener's live TCP port. Candidates locate the listener; they do not grant authority. The invite's identity-key fingerprint authenticates the hive node.

`bee hive join INVITE` requires the joining node's owner to be stopped. A node that already joined a hive or has peers cannot join another. The joiner races TLS handshakes to the primary and all candidates, presenting its own identity certificate in each handshake. It sends the single-use secret only over the first connection whose TLS peer key matches the invite fingerprint. A wrong service or an unverified path never receives the secret. An uncertain redemption is not replayed on another endpoint.

After redemption, the hive node pins the joiner's identity key and certifies its mesh key. The joiner records the authenticated TCP path; for a non-loopback path, it uses that path's IP with the returned gossip port as its initial mesh seed. It starts its owner and waits up to 60 seconds for the supervisors to establish a session.

## Reading peer state and join failures

`bee hive peers` reports peer IDs and supervisor-session state:

| Session | Meaning |
|---|---|
| `established` | The supervisor hello exchange completed. |
| `pending` | A supervisor hello exchange is in progress. |
| `none` | There is no established or pending supervisor exchange. |

This command does not report the live internode socket address or prove that a particular network route will survive reconnect. Check it on both nodes when a join does not reach a session.

Common errors identify different stages:

- `join failed; candidates tried` lists each endpoint and its connection or TLS failure. Check that the invite is current, its listener port is reachable, and the candidate belongs to the intended network. An identity mismatch means the endpoint reaches a different service or node; mint an invite from the intended hive.
- `invite refused` means the join listener reached the hive supervisor, which rejected redemption. On the inviter, use `bee hive invites` to check whether the invite is used, revoked, or expired. Invites also become unknown after an owner restart.
- `joined the hive of NODE, but no session was established` means redemption completed but the supervisor session did not establish before the 60-second wait ended. Check `bee hive peers` on both nodes, the selected mesh addresses, UDP gossip and TCP internode reachability. Check membership state before issuing another invite because the first invite may already be consumed.

## Selecting addresses

No environment variable selects an address. Each node picks the address it
advertises to the runtime mesh itself, in this order:

1. a Tailscale address, when `tailscale status --json` reports one;
2. the first non-virtual network interface address (Docker, `veth`, bridge, VM
   and VirtualBox interfaces are skipped);
3. `127.0.0.1`, when the node has nothing else.

The pick is written to `hive/advertise` under the state directory and read back
on the next boot. A boot whose interfaces no longer carry the stored address
repicks and rewrites it, so a DHCP lease change or a Tailscale interface coming
up or going away never advertises a stale address. The owner binds its mesh and
invite listener on all interfaces of the pick's family and publishes loopback
aliases in the local rendezvous descriptor for same-machine clients.

A running owner republishes a changed address through the runtime's membership
metadata, and rewrites each pinned peer's `.addr` seed from cluster
`NodeJoined`, `NodeLeft` and `NodeUpdated` events, so a peer that restarts at a
new address is seeded there on the next boot. Neither side needs a restart to
learn the new internode endpoint.

### Joining from behind NAT

The hive node reports the IP it saw on the authenticated join TCP connection.
The joiner adopts that address when this host owns it; otherwise it records the
address in `hive/nat` and publishes `internode_dial=out` in its membership
metadata, so the peer keeps the connection open instead of dialing an address
it cannot reach. The join listener and internode TCP paths therefore work from
a NATed guest without any environment variable, port proxy or firewall rule.

Memberlist gossip is the remaining gap. The runtime carries gossip over UDP in
both directions, so a NATed peer and its inviter can lose each other after a
probe interval until the runtime's gossip-over-internode hook lands. That hook
is runtime work, not Bee work.

## Tailscale

When `tailscale` or `tailscale.exe` is on `PATH`, `bee hive invite` reads its
status and adds the assigned Tailscale IP and MagicDNS name as candidates, and
the owner prefers the Tailscale address as its advertised mesh address. Both
nodes must be online on the same tailnet, with the join listener, internode TCP
and gossip UDP allowed. Nothing needs to be configured by hand.

## WSL2

Bee detects WSL2 NAT when its default interface carries a `172.16.0.0/12`
address. The invite then prints an informational notice rather than
instructions: Bee needs no environment variable and no Windows port proxy,
because it advertises the address its inviter observed and dials out over the
authenticated join path. The notice states the one remaining runtime
limitation, that memberlist gossip still uses UDP in both directions.

Mirrored networking removes that limitation and is the complete answer for a
NATed peer. In Windows PowerShell set `%UserProfile%\.wslconfig` to:

```ini
[wsl2]
networkingMode=mirrored
```

then run `wsl --shutdown` and restart Bee.

## Docker and virtual machines

An invite can include a `scope=vm` interface candidate, but a bridge or guest
address is normally reachable only inside that network. Bee's own pick skips
virtual interfaces, so a node with a reachable LAN or Tailscale address
advertises that instead. A container with only a bridge address picks it and,
because the inviter's observed address is not assigned locally, marks itself
NATed and dials out. The same gossip limitation as WSL2 applies.

## Proposal: runtime multipath mesh

The runtime currently advertises one mesh address per node. `bee hive peers` reports supervisor-session state and has no live path report. Runtime reconnect uses its configured address and recorded gossip seeds; it does not retry a pool of authenticated candidates. The join channel does not trigger a reverse connect.

A runtime extension can carry gossip over the authenticated internode link, let a node state its dial direction, and report per-peer transport state. Bee already sets the dial direction in membership metadata and republishes changed addresses; the runtime hooks that consume them are tracked separately. Until the gossip hook lands, a NATed peer depends on mirrored networking or on a forwarded UDP path for a complete mesh.
