# Package boundaries

Bee is one Wippy application (`wippy.yaml`, module `bee`) whose source lives in
`src/`. Each component is a directory with an `_index.yaml` declaring one
namespace `bee.<component>` (child directories declare child namespaces such as
`bee.threads.sessions`). The root namespace `bee` holds the host definitions:
the worker process host, the terminal host, the OS environment storage and the
database. `bee.deps` selects the Wippy dependencies (`wippy/migration`,
`wippy/bootloader`, and the runtime's security, terminal and test modules).

`make build` packs the application, including the offline documentation
corpus, and builds one native executable, `dist/bee`, from the runtime commit
pinned in `wippy.build.json`. Registry content can install only definitions and
resources the running executable supports; it cannot add a native module to
that process.

Registry metadata describes a capability; it does not authorize it. A
component owns its domain protocol and state, and exposes it through contracts
and bindings that the host admits under its own policies.

| Component | Owns |
|---|---|
| `bee.values`, `bee.app`, `bee.ui` | Shared value contracts, the application SDK (`bee.app:client`) and the terminal UI kit (frame, appearance, text, forms, visualization, diagram, picker) |
| `bee.node`, `bee.shell`, `bee.process` | The node owner and broker, workspaces and desktops; the desktop shell display; the shared process worker library |
| `bee.apps` | Stock applications: Terminal, Settings, Library, Process Manager, Keyboard help |
| `bee.threads`, `bee.threads.sessions` | Thread records, delivery, the carrier contract and managed sessions |
| `bee.harness`, `bee.driver`, `bee.credentials`, `bee.resources`, `bee.placement`, `bee.executor` | Managed agent launch, drivers, credentials, resource grants, native and Docker placement and external executors |
| `bee.gateway`, `bee.docs` | The scoped MCP gateway and hooks; the offline documentation tool |
| `bee.approvals`, `bee.capability`, `bee.security` | Durable approvals and the inbox app, the capability catalog, host security policies |
| `bee.gov`, `bee.hub` | Governed overlays, delivery and activation; Hub inspection, planning and local apply |
| `bee.hive`, `bee.sync` | Cross-node membership and operations; owner-local feeds |
| `bee.persist`, `bee.git` | Shared database helpers; git worktree support |

Every application is a standalone process; a service must not acquire a
view-owned lifetime to appear in navigation. Moving an implementation
preserves its stable definition ID, so saved state keeps resolving it.

## Hub and governed changes

Hub search is discovery only. A local plan resolves exact dependencies against
a known registry revision, checks host-selected permissions and resources,
applies through the owning service and records a recoverable receipt. A search
result or cached artifact is not installed, admitted or authorized. A request
sent to another Bee is a destination-owned operation: the destination resolves
its own definitions, policies and resources and records its own plan and
receipt.

Governed authoring stages bounded files in a durable overlay, freezes an
immutable candidate, shows its definitions and capability effects, obtains an
exact approval, and applies through the destination owner with restart
recovery. An applied overlay is not a durable registry publication. Core
namespaces named by `bee.gov:protected_kernel` change only through the host
composition and a native upgrade, apart from the namespaces the host
explicitly opens to a time-bounded super-edit profile. A bundled baseline stays
recoverable (`bee gov` reverts a governed overlay).

Each change distinguishes staging, resolution, validation, authorization,
application, activation, verification and receipt. Intent and step outcomes are
persisted before external effects, revisions and permission ceilings are
rechecked at execution, and a changed candidate invalidates its approval.
Crash recovery reconciles uncertain effects; it never promises rollback of an
external effect or applied migration. Multi-owner changes have separate
decisions and receipts rather than a global transaction.

Credentials, enrollment secrets, active grants, live PIDs and native handles
are not portable package content. Durable publication is a separate authority
from discovery, artifact caching, local apply and Hive membership. See
[hub inspection](hub_inspection.md) and
[distributed overlay delivery](distributed_app_delivery.md).
