# bee.hive.host

This namespace owns Bee's default Hive process composition. It starts one
`bee.hive.supervisor:main` service on the protected
`bee.hive:supervisor_host` with an empty `configured_nodes` list. That default
is portable and offline: it provides local supervisor routing without putting
transport credentials or network settings in the registry.

An admitted host composition may replace the service input with configured peer
node IDs and, when the host has a desktop owner, a validated `desktop` value.
Peer IDs are durable admission data supplied by the host. TLS, seeds, ports,
and native membership configuration remain runtime or host configuration and
are never registry service input.
