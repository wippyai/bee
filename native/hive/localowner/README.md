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

`ClientPolicy()` returns an unpublished native security policy for one prepared
owner execution. The host may attach it only to the Hive supervisor's isolated
scope. Its single action, `bee.desktop.local_client`, takes the actual native
sender PID as resource and checks the supervisor actor, native client host,
current protected enrollment and owner lifetime. Unknown clients, foreign actors,
retired enrollment and replaced executions are denied. Other actions are left
undefined. A positive answer permits desktop admission to proceed; it is not a
viewport/input grant. The native Hive service can receive it through Desktop.ClientPolicy and forks
its sealed lifecycle frame before adding it. Public launch does not select this
configuration yet. No new Lua module or runtime change is required.

`DesktopService(policies, application)` connects the prepared execution and its
local-client policy to the existing native Hive service. The host still selects
all policy IDs and supplies the protected activation entry. Reserved/tooling
startup leaves activation disabled. It does not install a public CLI route.

The actual-source composition probe uses the same module plan and database
bindings as Bee. It first passed fresh-node discovery, catalog, observer grant
and detach without a static client allowlist. The stronger Terminal control and
retained-content variant also passes: actual native viewport input/output, a shell
variable retained across detach/rejoin, and stale mount input denied. Run it with:

```
BEE_OWNER_TEST_WIPPY=/absolute/toolchain make -C native local-owner-check \
  LOCAL_OWNER_TEST_RUN=TestFreshClientDesktopComposition \
  MESH_RUNTIME=/absolute/reviewed/runtime
```

Without the explicit toolchain environment variable, this integration test skips;
the original owner-lifetime and policy tests still run. A skipped integration test
is not public startup or desktop acceptance.

For a native-only checkpoint, set `BEE_OWNER_TEST_SOURCE` to an absolute Bee
checkout containing `src/`, `build/modules.json` and `wippy.build.json`. The probe
snapshots these inputs before boot and logs the selected source root. Its result
proves that explicit native/application combination, not the checkpoint's older
application source or a released executable.

The physical-client integration now uses Bee's `launch.StartOwner` and
`NewOwnerLauncher` against the real standalone argument parser. It no longer
starts the owner through a custom `exec.CommandContext` test route. The client
then uses actual `application.Run` lock-busy attachment, with invalid deployment
bindings/failing owner hooks to detect accidental owner startup. Fixture cleanup
explicitly aborts only the child it created; client detach never does so.
