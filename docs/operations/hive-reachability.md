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
| `explicit/external` | An IP from `BEE_HIVE_ADDRESSES` |

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

`BEE_MESH_ADDRESS` selects the one IP address a node advertises to the runtime mesh. It must be a non-loopback IP assigned to that Bee host. Set it before starting each owner and on the joining `bee hive join` command:

```sh
BEE_MESH_ADDRESS=192.168.1.20 bee start
BEE_MESH_ADDRESS=192.168.1.21 bee hive join 'INVITE'
```

Replace the example addresses with each machine's assigned, mutually reachable IP. The owner binds on all interfaces in the selected IP family and advertises the selected address. Local clients retain loopback aliases. Without this variable, the mesh defaults to `127.0.0.1`; that is suitable for same-host use but not a remote mesh. Changing an owner's selected address requires restarting that owner with the new environment.

`BEE_HIVE_ADDRESSES` takes comma-separated external IP addresses, with no ports or host names. Set it for `bee hive invite` when the listener is reachable through a host address or port forward:

```sh
BEE_HIVE_ADDRESSES=198.51.100.25 bee hive invite
```

Replace the example with an address that reaches the inviter's join listener. Each explicit candidate uses the listener's current port, so forward that same TCP port. At invite time, the variable adds listener candidates. Its IPs also go into a mesh certificate when Bee creates a fresh leaf. It never changes the runtime's advertised mesh address. Set `BEE_MESH_ADDRESS` separately on both owners and keep that address reachable.

## Tailscale

When `tailscale` or `tailscale.exe` is on `PATH`, `bee hive invite` reads its status and can add the assigned Tailscale IP and MagicDNS name as candidates. Put the local Tailscale IP in `BEE_MESH_ADDRESS` on each owner and on the join command. MagicDNS can locate the invite listener, but the runtime mesh still advertises the literal IP selected by `BEE_MESH_ADDRESS`. Both nodes must be online on the same tailnet, with the join listener, internode TCP and gossip UDP allowed.

## WSL2

Bee detects WSL2 NAT when its default interface has a `172.16.0.0/12` address and prints that guest address plus the live join, gossip and internode ports with its invite. Mirrored networking gives the WSL guest a directly reachable network path. In Windows PowerShell, set `%UserProfile%\.wslconfig` to:

```ini
[wsl2]
networkingMode=mirrored
```

Then run this in Windows PowerShell and restart Bee in WSL:

```powershell
wsl --shutdown
```

Select the reachable IP assigned inside WSL as `BEE_MESH_ADDRESS` for the owner and the join command.

With NAT, set `BEE_MESH_ADDRESS` to the WSL guest IP and add the Windows host's reachable IP to `BEE_HIVE_ADDRESSES` before minting an invite. The invite warning prints these Windows commands with the live values filled in. Run them in PowerShell as Administrator; replace the angle-bracketed placeholders when using this template:

```powershell
netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=<JOIN_PORT> connectaddress=<WSL_GUEST_IP> connectport=<JOIN_PORT>
netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=<TRANSPORT_PORT> connectaddress=<WSL_GUEST_IP> connectport=<TRANSPORT_PORT>
New-NetFirewallRule -DisplayName "Bee Hive TCP" -Direction Inbound -Action Allow -Protocol TCP -LocalPort <JOIN_PORT>,<TRANSPORT_PORT>
New-NetFirewallRule -DisplayName "Bee Hive UDP" -Direction Inbound -Action Allow -Protocol UDP -LocalPort <GOSSIP_PORT>
```

Windows `portproxy` forwards TCP only. The firewall rule opens the UDP gossip port on Windows but does not forward it. The peer also needs a route to the runtime's single advertised mesh address. TCP forwarding alone therefore does not complete a Hive path; use mirrored networking or a setup that forwards every required transport and keeps the advertised address reachable.

## Docker and virtual machines

An invite can include a `scope=vm` interface candidate, but a bridge or guest address is normally reachable only inside that network. `BEE_MESH_ADDRESS` must be assigned inside Bee's network namespace and reachable by the other peer. Publish or forward the live join TCP listener plus the runtime's internode TCP and gossip UDP paths; keep the address Bee advertises reachable after restart. `BEE_HIVE_ADDRESSES` adds an invite IP at the listener's existing port and does not configure those runtime paths.

## Proposal: runtime multipath mesh

The runtime currently advertises one mesh address per node. `bee hive peers` reports supervisor-session state and has no live path report. Runtime reconnect uses its configured address and recorded gossip seeds; it does not retry a pool of authenticated candidates. The join channel does not trigger a reverse connect.

A runtime extension can exchange bounded, typed gossip and internode candidates, race and retry identity-pinned paths, report the active route, and allow a reverse dial after invite authentication. Until then, each node's single `BEE_MESH_ADDRESS` must stay reachable for the mesh session and reconnects.
