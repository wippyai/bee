# Native Hive activation

`New(Config)` supplies a native registry listener for `bee.hive.activation`.
Only `bee.hive:activation` is accepted, and its data must be empty. The compiled
host supplies the enabled flag, configured node IDs and explicit policy IDs;
registry data cannot choose them. Configuration is copied and bounded. The zero
configuration is disabled; enabling without a policy list is refused.

The listener registers the ordinary Wippy supervised service inside the registry
transaction. Its process, host and actor are fixed. A native lifecycle requirement
on `bee.hive:supervisor_host` orders startup even without activation metadata.
Replacement uses remove/register in the same transaction and obtains a fresh
controller. There is no extra service manager or polling startup loop.

Resource validation runs at service startup, outside the registry listener's
write-locked transition. Missing or wrong-kind resources cannot start the
supervisor. A missing executable host leaves activation waiting on its native
dependency; registry commit alone does not mean ready. Launch must observe actual
supervisor readiness and report an unavailable dependency within its deadline.

This package is not selected by the native build manifest. No production
activation entry, enrollment command or public Hive startup is enabled by adding
it. Host-selected policies still require protected composition; an entry's ID or
package origin does not authorize a registry edit.

Run `make -C native hive-service-check WIPPY=/path/to/reviewed/wippy` for actual
runtime boot, strict staged Lua lint, replacement, rollback and denied startup
checks. The target uses temporary module files for test-only dependencies and
does not change the native module or build manifest. Normal native tests also
check configuration without enabling the integration build tag.

The optional `Desktop` host configuration supplies the retained desktop execution,
expiry, allowed native client nodes and optional initial application. It requires
an enabled service and the explicit `bee.hive.desktop:host_policy`; neither is
inferred from enrollment or activation metadata. Node slices are copied at both
the host configuration and Lua input boundaries. Desktop startup also depends on
`bee:workers`, so the normal runtime supervisor orders its worker host before the
bridge can spawn the retained desktop. Nil leaves the bridge disabled.

Execution expiry uses a future timestamp with millisecond precision and is
rechecked by the Lua owner. This addition is a service configuration boundary,
not public activation or an automatic local-account grant. Enabled remote
Terminal and physical-client acceptance remain required before launch uses it.

`Desktop.ClientPolicy` optionally supplies an unpublished native policy selected
by the host for fresh local clients. The service forks its sealed lifecycle frame,
adds the policy only to that child scope, and seals the child before spawning the
supervisor. Parent and sibling scopes are unchanged. Only a boolean selection is
sent to Lua; the policy and enrollment credentials are never exported. With this
selection, the desktop owner checks `bee.desktop.local_client` against the actual
native sender before normal operation, execution, session and grant validation.
An empty static node list is accepted only when the host supplies that policy.
This path is not yet selected by public launch. Native scope-isolation and config
checks do not substitute for the required real fresh-client desktop proof.
