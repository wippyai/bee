# Local owner startup

This native component prepares one local owner execution through Wippy's
lock-held `LaunchPlan.PrepareOwner` hook. It provisions protected, finite-lived
TLS credentials and separate native signing/enrollment keys, then configures
Wippy's normal cluster boot on automatically allocated loopback ports. It does
not create a transport or own an application database.

The host launcher installs `PrepareOwner` in its single launch plan and includes
the component in boot. After native cluster startup, the component verifies the
live node identity and endpoints before publishing discovery hints under the
runtime state directory's `local-mesh` directory. Discovery is neither workspace
readiness nor permission to use an application. Busy-lock attachment does not run
owner preparation.

The runtime must preserve `OwnerPlan.Deadline` through bootstrap and close native
networking on execution cancellation. Normal shutdown retains the application
lock while supervised processes drain. Credentials expire within at most 30 days;
renewal is not implemented. Stale discovery files remain hints, and cleanup never
deletes a successor's files.

The package is gated by `meshclient` and is not registered in public Bee launch.
It requires the reviewed runtime candidate's owner-preparation, parent-context,
normal-boot TLS and cluster-cancellation changes. Run its real-process acceptance
with `make -C native local-owner-check MESH_RUNTIME=/path/to/runtime`. That target
uses a temporary module replacement without changing the pinned module files.
The proof connects a separate native client, discovers a Lua fixture through
native naming, and exchanges a bounded request and ordinary Lua table reply.
Lua checks the native sender node; the client checks the exact discovered PID
and request identity. This relies on native sender provenance and adds no Lua
ingress API. The runtime lane still owns the release provenance guarantee.
A separate native process service also returns success and denial through the
existing Hive envelope, exercising `client/hive` against ordinary Lua tables.
It issues no desktop grant.
Fixture permissions name only its registration and send actions. The same proof
checks transport expiry while Lua drains, and lock retention followed by release. Supervisor
admission, ordinary first/second `bee` attachment and LAN Terminal remain separate
gates.
