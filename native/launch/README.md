# Native Bee launch

Component returns the native executable host and boot component. Before a
non-explicit launch opens state, it selects:

    <Bee config directory>/bee/projects/<sha256(canonical working directory)>

The runtime resolves a launch without --state to `<config directory>/bee` and
marks it not explicit; the host selects the project state under that root, and
the client route, the owner it starts and a plain `bee start` all use it. An
explicit --state is preserved unchanged. Planning does not create
directories, write receipts, inspect databases or acquire locks.

`bee hook-post ENDPOINT ACTION_ID TOKEN_ENV_OR_FILE EVENT` is planned first: it
runs the [hook POST helper](../hookpost/README.md) without project selection,
state, the client route or the retained owner.

`bee help`, `bee -h` and `bee --help` are planned next: the host prints the
command grammar and the state this invocation would use, computed from the
launch alone, and exits 0 without selecting a project or reading state.

`bee daemon` takes no arguments and runs the owner route like `bee start`, under
the owner command `bee-daemon`, with a desktop bridge that composes no folder
workspace (`desktop.folder = false`); it serves the node's catalog workspaces
to clients. A client of such a node shows a workspace picker, and Ctrl+] in a
presented desktop returns to it.

Every other ordinary launch is decoded before project selection. `bee start`
takes no arguments; `bee MODULE:ENTRY` keeps the runtime's own entry; the rest
is the client grammar (`observe`, `client`, `attach WORKSPACE DISPLAY`,
`desktops`, or an application command `NAME [ARGUMENTS...]`). A first word that
cannot name an application command (`hive.DesktopCommand.Valid`: lowercase
letter first, then lowercase letters, digits, `_` or `-`, at most 40 bytes) and
malformed route arguments fail planning, so nothing is selected, read or
started. Whether a well-formed NAME exists depends on the project's admitted
applications and managed agents; the owner resolves it after the client joins.
A client that starts an owner hands it a fresh launch identity
(`BEE_OWNER_LAUNCH`), which the owner publishes in its rendezvous descriptor;
the client's start won the state election only when the published identity is
its own. When that owner refuses the NAME it was started for, it retains no
desktop, so the client asks it to stop unless another local client is
enrolled.

`bee stop` takes no arguments. It joins the running owner as an enrolled local
client and calls the supervisor's `bee.hive.owner:stop` operation, which the
host grants through `bee.security.hive:hive_owner_stop_policy`. The supervisor answers and
forwards the stop to the owner's command process (`bee-owner` or
`bee-daemon`, named `bee.launch.command`), which accepts it only from the local
supervisor, requests the runtime's graceful shutdown and returns, so the run
the runtime waits on ends the way a termination signal ends it. The client reports
`Bee stopped` once the state lock is free, or `Bee is not running for this
project`. A desktop client that detaches (Ctrl+Q) from a running owner prints
`Bee is still running; bee stop ends it`.

The owner descriptor advertises the native client's Hive protocol revision.
A client rejects an older or incompatible descriptor before enrollment. This
also applies to `bee stop`: if the older owner cannot accept its stop operation,
the error identifies the state and tells the user to find that owner's process
with `ps -eo pid,args` and send it `kill -TERM <PID>`, wait for exit, then run
`bee` again. A running owner that does not answer a client before its bounded
startup deadline reports a timeout and the same recovery route.

`bee hive VERB` manages this node's Hive membership and is decoded before
project selection like every other command:

    bee hive invite            mint a single-use invite, print it as the one stdout line
                               and tell stderr how the other node runs bee hive join
    bee hive invites           list the invites the supervisor recorded
    bee hive revoke INVITE_ID  revoke a pending invite
    bee hive peers             list the Hive peers and their supervisor sessions
    bee hive join INVITE       join the hive the invite names
    bee hive leave NODE        retire the Hive peer NODE

`invite`, `invites`, `revoke` and `peers` are Requests from an enrolled local
client to the owner's supervisor (service `bee.hive.join`), so they start the
owner when none runs and print only their own output. An invite reads

    bee-hive://INVITE_ID:SECRET@HOST:PORT/NODE?key=FINGERPRINT

HOST:PORT is the owner's join listener (component `bee.launch.join`), bound on
the mesh advertise address with an automatically selected port and published in
the rendezvous descriptor; NODE and FINGERPRINT name the owner's node and the
sha256 of its internode identity key. The supervisor keeps only the secret's
digest; an invite lives 15 minutes, is redeemed once, and every outstanding
invite is void after an owner restart.

`join` runs while no owner holds the state: the owner holds `hive/owner.lock`
for its lifetime, because a node's mesh joins a hive when its owner boots. The
joiner dials the listener over TLS 1.3, accepts the listener only when its
certificate key matches FINGERPRINT, proves its own identity key with its
client certificate and then sends the secret, its node and a fresh mesh key.
The listener redeems the invite with its supervisor from the native host
`bee.hive:join_host`, pins the joiner in `hive/peers/NODE.pub`, certifies the
joiner's mesh key with the owner's authority, and returns its node, gossip
address, mesh secret and authority pool. The joiner pins the hive node, writes
`hive/joined.json`, `hive/joined.secret` and `hive/joined.pem`, starts its
owner and waits until the two supervisors hold an established session. A node
that already joined a hive, or that other nodes joined, refuses to join.

The owner grants its desktop to every pinned Hive peer by default: joining the
hive is the whole selection, so no environment variable and no restart is
needed. The bridge still requires the peer's current host enrollment and
retires its attachments when the pin is removed, so `bee hive leave NODE`
revokes the grant by retiring the pin. The grant permits the Hive Manager on a
pinned peer to control or observe this node's workspaces.

`leave` needs no owner: it removes `hive/peers/NODE.pub`, and the joined record
when NODE is the hive this node joined. The owner's enrollment publisher then
retires the peer and its session ends; the next owner boot of a node that left
its hive uses its own mesh.

Every owner boot runs its mesh over the runtime's internode TLS with the
credential `hive/mesh.pem` and pool `hive/mesh-authorities.pem`: the node's own
authority (`hive/authority.pem`) certifies a fresh leaf, or, on a joined node,
the leaf its hive node certified is used and that hive's pool is trusted beside
the node's own authority. Local clients join with the same credential.
`internode.peer_key_source` resolves local clients from `hive/trusted` and Hive
peers from `hive/peers`; the enrollment entry names them as `nodes` and `peers`.

No environment variable selects an address. An owner picks the address it
advertises to the mesh itself: a Tailscale address when `tailscale status`
reports one, otherwise the first non-virtual LAN interface address, otherwise
loopback when the node is alone. It writes the pick to `hive/advertise` and
reads it back on the next boot, repicking when the stored address is no longer
assigned locally, so a DHCP lease change or a Tailscale toggle never advertises
a stale address. The owner binds its mesh and invite listener on all interfaces
of the pick's family and publishes loopback aliases in the local rendezvous
descriptor for same-machine clients.

`bee hive invite` prints one line; `--out FILE` writes it to FILE and
`--share DIR` writes it to `DIR/bee-hive-invite.txt` in a shared folder the
person picks. Both files hold the single-use secret and are written
owner-only, atomically, and never over an existing file.

Invites carry up to eight alternate interface, tailnet and MagicDNS hints. The
joining command races TLS handshakes, authenticates the pinned identity, and
uses the first verified route for redemption. Both sides then keep the path the
join proved. The hive node reports the IP it saw on that authenticated TCP
connection; the joiner adopts it as its advertised address when this host owns
it, and otherwise records itself in `hive/nat` and publishes
`internode_dial=out` so the peer keeps the connection open instead of dialing an
address it cannot reach. The join listener records the local address a remote
peer's join arrived on in `hive/reached` and advertises it in preference to the
automatic pick, so a peer that reached the LAN address keeps using it when the
pick is a Tailscale address; a join from another node on this host is ignored.
Each side seeds the other at the proven path and reports every candidate
failure if none verifies.

A running owner republishes a changed advertise address with
`Membership.UpdateMeta` and rewrites each pinned peer's `.addr` seed from the
cluster's `NodeJoined`, `NodeLeft` and `NodeUpdated` events, so a peer that
restarts at a new address is seeded there on the next boot without a restart
of either side.

On detected WSL2 NAT the invite prints an informational notice: Bee needs no
environment variable and no Windows port proxy, because it advertises the
address its inviter observed and dials out over the authenticated join path.
The runtime still carries memberlist gossip over UDP in both directions, so
until the runtime's gossip-over-internode hook lands, mirrored networking
(`networkingMode=mirrored` in `%UserProfile%\.wslconfig`, then `wsl --shutdown`)
is the complete answer for a NATed peer.

`bee version` is not answered by the host: the embedded pack version and the
pinned runtime commit are not visible to `app.Host`, so the word reaches the
owner as an application command.

The runtime owns state opening, locking, deployment history, migrations, process
ownership and application lifecycle. The native host provides the selected
default state and a read-only environment store with home, cwd, self and safe
PATH executable lookup.

Environment values are nonsecret and absolute. Executable lookup accepts only a
bare name and returns an absolute PATH result. Writes, deletes, path names and
traversal are refused.

Run the native package tests with:

    make -C native test
