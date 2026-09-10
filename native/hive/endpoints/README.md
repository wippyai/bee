# Invitation endpoint selection

`endpoints.Select` derives bounded, deterministic address candidates from live
listener endpoints, interface addresses and optional DNS/IP hints. Public Hive
setup does not call it yet.

The listener owner supplies `Params.Listeners` and keeps those sockets open.
Selection preserves their actual ports and rejects port zero. It does not bind
sockets, enumerate interfaces, resolve DNS or establish reachability. The caller
must authenticate a peer before trusting an advertised endpoint.

`ModeExport` includes LAN, global unicast and overlay addresses such as
`100.70.10.28`. It excludes loopback, wildcard, multicast and link-local addresses.
`ModeLocalOnly` additionally permits loopback. Scoped interface addresses are
filtered, so an ordinary IPv6 link-local interface cannot hide another usable
interface. Explicit scoped listeners or overrides are rejected. Zones are
checked before IPv4-mapped IPv6 normalization.

Wildcard listeners expand only to eligible interface addresses of the same
address family. An IPv6 wildcard alone does not establish dual-stack support.
An exact bind contributes only its bound address. Explicit DNS/IP overrides are
additional administrator-supplied hints and retain the bound port; they cannot
prove that NAT, routing or forwarding makes that address reachable.

Results preserve gossip/internode transport identity, deduplicate addresses and
format IPv6 with brackets. Input counts and string lengths are bounded. Unknown
modes, empty results and more than 64 distinct candidates return errors; results
are never silently truncated. Ordering is by transport, then DNS, overlay,
global, private and loopback categories, then address and port. It is a stable
ordering, not a measurement of network preference.

The package uses only the Go standard library. Native package checks include
race tests and vet. Enrollment, invitation redemption, peer authentication and
workspace authorization are separate integration work.
