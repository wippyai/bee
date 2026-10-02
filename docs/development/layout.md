# Repository layout audit

`make lint` runs the permanent placement check in `build/layout_check.py`.
Production consists of the host `src/` and 41 component `modules/*/src/` roots.
The only root spelling exception is the public SDK: `application` exports
`bee.app`. Hyphenated component names expand into namespace nesting; all child
folders match their namespace. `src/host` is the host's documented desktop-owner
component, not a module wiring folder. No component index lives under `host/`.

The audit corrects `bee.git_worktree` to `bee.git.worktree` and moves
`src/threads_hive` to `src/threads/hive` without changing that host namespace.
Threads' owner and waiter actors and Harness's carrier actor live in `service/`.
Callable method sources for Threads, Harness, drivers, Gateway, Hive, telemetry,
Sync and Git worktree live in
`binding/`; module roots publish their shared contracts and public bindings.
Placement's process-runner library declares its local source in `service/`.
Threads' public reply and record types and Harness's shared execution types live
at their component roots rather than in `records/`, `service/` or `carrier/`.
The saved-profile contract and public binding also live at the Harness root.
The complete identity map is `build/layout_identity_moves.json`; Placement 8,
Sync 8 and Gateway 16 migrate their owned saved executable references and
telemetry `owner_ref.service_id` values. The service remains the operation's exact
namespace; unrelated namespace strings and opaque state remain intact.

Module requirements carry host selections through `bee.deps` parameters.
Module defaults do not name host entries, and host policy grants enter callable
methods through requirements with empty policy underlays. Module-owned default
resources remain replaceable resources, not authorization. The host still owns
admission, selected roots, process hosts, environment and application grants.
The Harness admission append requirement has no default: an empty-array default
becomes an invalid nested binding when independently packed modules link.
Lint rejects array defaults on append requirements; host selection supplies the
reviewed binding, and the application journey fixture edits that host selection.

Application entries, renderers, screen models and rendering helpers live under
component `app/` namespaces. The public rendering kit remains in `application`;
core desktop and terminal sources implement the desktop shell. Placement's
process-local native terminal facade is an executor contract, not an application
screen: it consumes the caller's terminal grant. Docker's short window adapter
selects its backend; it does not duplicate the native facade. Retained
presentation's executor selects the admitted application loop under its owner
lifetime and terminal grant. These adapters have actual boundary roles.

The shared clock is registered once as `bee.values:clock`. The audit removes
three dead sources: the unregistered Sessions worker forwards an unused
superseded journal protocol; the unreferenced JSONL alias only returns
`stream_json`; the unreferenced application launch decoder predates the used
Sessions protocol and Harness admission decoder. The obsolete Go Modules UI runner duplicates the active Python source/pack
acceptance; that Python gate retains its search, UTF-8 editing, readme, parameter,
plan, cancellation, confirmation and receipt scenarios. Its duplicate PTY and
terminal decoder implementations are removed. No identical production Lua
implementations remain. The similarly named status files are a per-thread I/O
adapter and a session's collection of readers. Driver locate measures a CLI;
Harness locate probes an admitted descriptor; Sessions locate caches candidate
readiness. Their inputs, authority and responsibilities differ.

Reachability starts at dependency/requirement wiring, services, bindings,
application definitions, metadata commands and references in documentation,
native sources and tests. Source constants add dynamic registry edges. The
check reports no orphan Lua sources, unreachable entries or
dangling Bee imports/requirement targets. It also checks component root indexes,
local source declarations, application identities, process placement and exact
Lua duplicates. Semantic ownership and dynamic names still require review;
the script does not claim to prove arbitrary runtime reachability.

Disposable test overlays live under `tests/` as required by the packaging rules.
Their scenario/suite folder names group independent compositions; each overlay
reuses the identities it tests rather than defining a production namespace.
There are 67 unit overlay manifests and 69 acceptance overlay manifests,
including 42 unit suite paths whose grouping differs from the declared
namespace. They do not introduce a production `src/` divergence. The native
host's `bee.harness.host:environment` has no source index: the native component
registers it at boot, as documented in the conventions. All overlay namespaces
are also checked for underscores. Generated/copy-staged reference app and Hub
probe sources stay outside production and are checked in their fixture builds.

Policy groups add discovery edges from the selected execution scope to their
member policies. Driver commands, the Codex provider and Hub research traits
are discovered by their declared metadata types. The audit removes seven unused
policy entries (gateway inbox, thread projection/carrier clients, governance
publish, Hive spawn deny, gateway node and cross-workspace launch) and four
unused driver environment stores; their selected replacements already own
the running boundaries.

## Disposable overlay inventory

Every checked-in test `_index.yaml` declares a composition-local namespace.
The following paths group overlays rather than production namespace children:

| Overlay manifest | Declared namespace |
|---|---|
| `tests/fixtures/agent_app/_index.yaml` | `bee.agent.app.probe` |
| `tests/fixtures/agent_app/host_environment/_index.yaml` | `bee.harness.host` |
| `tests/fixtures/agent_install/_index.yaml` | `bee.hub.install.probe` |
| `tests/fixtures/app_admission/_index.yaml` | `bee.admission.probe` |
| `tests/fixtures/app_journey/_index.yaml` | `bee.app.journey.probe` |
| `tests/fixtures/app_open/_index.yaml` | `bee.app.open.probe` |
| `tests/fixtures/attachments/_index.yaml` | `bee.attachment.probe` |
| `tests/fixtures/client_storage/_index.yaml` | `bee.client.storage.probe` |
| `tests/fixtures/client_storage/client_database/_index.yaml` | `bee.client.db` |
| `tests/fixtures/client_storage/workspace_database/_index.yaml` | `bee.workspace.db` |
| `tests/fixtures/delivery_review/_index.yaml` | `bee.delivery.review.probe` |
| `tests/fixtures/desktop_apps/apps/_index.yaml` | `bee.apps` |
| `tests/fixtures/desktop_client/_index.yaml` | `bee.desktop.client.probe` |
| `tests/fixtures/docker_placement/_index.yaml` | `bee.docker.proof` |
| `tests/fixtures/docs_agent/_index.yaml` | `bee.docs.agent` |
| `tests/fixtures/gateway_container/_index.yaml` | `bee.gateway.container` |
| `tests/fixtures/governance_overlay/_index.yaml` | `bee.gov.overlay.probe` |
| `tests/fixtures/governance_overlay_composed/_index.yaml` | `bee.gov.overlay.composed.probe` |
| `tests/fixtures/governance_runtime/_index.yaml` | `bee.gov.probe` |
| `tests/fixtures/governance_workspace/_index.yaml` | `bee.gov.workspace.probe` |
| `tests/fixtures/hive_admission/_index.yaml` | `bee.hive.admission` |
| `tests/fixtures/hive_boot/_index.yaml` | `bee.hive.boot.probe` |
| `tests/fixtures/hive_desktop_admission/_index.yaml` | `bee.desktop.admission.probe` |
| `tests/fixtures/hive_feeds/_index.yaml` | `bee.feed.probe` |
| `tests/fixtures/hive_feeds/host/_index.yaml` | `bee` |
| `tests/fixtures/hive_manager_app/_index.yaml` | `bee.hive.manager.probe` |
| `tests/fixtures/hive_remote/_index.yaml` | `bee.hive.remote` |
| `tests/fixtures/hive_replica/_index.yaml` | `bee.replica.probe` |
| `tests/fixtures/hive_replica/host_environment/_index.yaml` | `bee.harness.host` |
| `tests/fixtures/hive_service_bootstrap/_index.yaml` | `bee.hive.service.bootstrap` |
| `tests/fixtures/hive_supervisor/_index.yaml` | `bee.hive.probe` |
| `tests/fixtures/hub_inspect/_index.yaml` | `bee` |
| `tests/fixtures/hub_inspect/hub_inspect_probe/_index.yaml` | `bee.hub.inspect.probe` |
| `tests/fixtures/hub_manage/_index.yaml` | `bee` |
| `tests/fixtures/hub_manage/probe/_index.yaml` | `bee.hub.manage.probe` |
| `tests/fixtures/hub_manage/security/threads/_index.yaml` | `bee.security.threads` |
| `tests/fixtures/hub_migration_runner/_index.yaml` | `probe` |
| `tests/fixtures/hub_migration_runner/migrations/_index.yaml` | `acme.app` |
| `tests/fixtures/hub_preview/_index.yaml` | `bee` |
| `tests/fixtures/hub_preview/hub_preview_probe/_index.yaml` | `bee.hub.preview.probe` |
| `tests/fixtures/identity_native/_index.yaml` | `bee.identity.probe` |
| `tests/fixtures/inbox_decide/_index.yaml` | `bee.approvals.inbox.decide.probe` |
| `tests/fixtures/inbox_leases/_index.yaml` | `bee.approvals.inbox.leases.probe` |
| `tests/fixtures/layout_upgrade/_index.yaml` | `bee.layout.fixture` |
| `tests/fixtures/legacy_workspace/_index.yaml` | `bee.workspace` |
| `tests/fixtures/live_agy_mcp/_index.yaml` | `bee.research.probe` |
| `tests/fixtures/managed_launch_fixture/_index.yaml` | `bee.fixture.terminal.launch` |
| `tests/fixtures/managed_provider_window/_index.yaml` | `bee.managed.provider.fixture` |
| `tests/fixtures/managed_window_app/_index.yaml` | `bee.managed.window.fixture` |
| `tests/fixtures/managed_window_opencode/_index.yaml` | `bee.managed.opencode.fixture` |
| `tests/fixtures/modules/gateway/src/managed/_index.yaml` | `bee.managed` |
| `tests/fixtures/modules/gateway/src/probe/_index.yaml` | `bee.gateway.probe` |
| `tests/fixtures/modules/harness/src/_index.yaml` | `bee` |
| `tests/fixtures/modules/threads/src/_index.yaml` | `bee` |
| `tests/fixtures/performance_research/_index.yaml` | `bee.research.benchmark.probe` |
| `tests/fixtures/research_author/_index.yaml` | `bee.research.probe` |
| `tests/fixtures/research_delivery/_index.yaml` | `bee.research.delivery` |
| `tests/fixtures/research_delivery/host_environment/_index.yaml` | `bee.harness.host` |
| `tests/fixtures/research_measurement/_index.yaml` | `bee.research.measurement` |
| `tests/fixtures/saved_profiles/_index.yaml` | `bee.saved.profiles.probe` |
| `tests/fixtures/sessions/src/_index.yaml` | `bee.tests.fixtures.sessions` |
| `tests/fixtures/sync_module/_index.yaml` | `bee.sync.probe` |
| `tests/fixtures/thread_journal/src/_index.yaml` | `bee.thread.demo` |
| `tests/fixtures/thread_journal/src/storage/_index.yaml` | `bee.thread.demo.storage` |
| `tests/fixtures/window_hooks/_index.yaml` | `bee.window.hooks.fixture` |
| `tests/fixtures/window_native/_index.yaml` | `bee.window.native` |
| `tests/fixtures/workspace_app_delivery/_index.yaml` | `bee.workspace.app.probe` |
| `tests/fixtures/workspace_hosts/_index.yaml` | `bee.workspace.hosts` |
| `tests/fixtures/workspace_hosts/databases/_index.yaml` | `bee.workspace.db` |
| `tests/lua/applications/_index.yaml` | `bee.apps` |
| `tests/lua/approvals/_index.yaml` | `bee.approvals` |
| `tests/lua/client/_index.yaml` | `bee.client` |
| `tests/lua/client/databases/_index.yaml` | `bee.client.db` |
| `tests/lua/credentials/_index.yaml` | `bee.credentials` |
| `tests/lua/desktop/_index.yaml` | `bee.desktop` |
| `tests/lua/docs/_index.yaml` | `bee.docs` |
| `tests/lua/driver/_index.yaml` | `bee.driver` |
| `tests/lua/driver/agy/_index.yaml` | `bee.driver.agy` |
| `tests/lua/driver/configuration/_index.yaml` | `bee.driver` |
| `tests/lua/driver/grok/_index.yaml` | `bee.driver.grok` |
| `tests/lua/driver/opencode/_index.yaml` | `bee.driver.opencode` |
| `tests/lua/driver/wippy/_index.yaml` | `bee.driver.wippy.test` |
| `tests/lua/executor/_index.yaml` | `bee.executor.external` |
| `tests/lua/files/_index.yaml` | `bee.files.test` |
| `tests/lua/frame/_index.yaml` | `bee.app.frame.test` |
| `tests/lua/gateway/_index.yaml` | `bee.gateway` |
| `tests/lua/git_worktree/_index.yaml` | `bee.git.worktree.test` |
| `tests/lua/governance/_index.yaml` | `bee.gov` |
| `tests/lua/harness/_index.yaml` | `bee.harness.catalog` |
| `tests/lua/harness/host/_index.yaml` | `bee.harness.host` |
| `tests/lua/hive/_index.yaml` | `bee.hive` |
| `tests/lua/hive_manager/_index.yaml` | `bee.hive.manager` |
| `tests/lua/hive_supervisor/_index.yaml` | `bee.hive.supervisor` |
| `tests/lua/hive_telemetry/_index.yaml` | `bee.hive.telemetry` |
| `tests/lua/host/_index.yaml` | `bee.host` |
| `tests/lua/host_policy/_index.yaml` | `bee.host.policy.test` |
| `tests/lua/host_processes/_index.yaml` | `bee.host.processes` |
| `tests/lua/hub/_index.yaml` | `bee.hub` |
| `tests/lua/hub_catalog/_index.yaml` | `bee.hub.catalog` |
| `tests/lua/hub_graph/_index.yaml` | `tests.hub.graph` |
| `tests/lua/hub_installation/_index.yaml` | `tests.hub.installation` |
| `tests/lua/hub_inventory/_index.yaml` | `tests.hub.inventory` |
| `tests/lua/hub_migration_work/_index.yaml` | `tests.hub.migration.work` |
| `tests/lua/hub_migrations/_index.yaml` | `tests.hub.migrations` |
| `tests/lua/hub_plan/_index.yaml` | `tests.hub.plan` |
| `tests/lua/hub_preview/_index.yaml` | `bee.hub.preview` |
| `tests/lua/hub_publishing/_index.yaml` | `tests.hub.publishing` |
| `tests/lua/hub_semver/_index.yaml` | `tests.hub.semver` |
| `tests/lua/inbox/_index.yaml` | `bee.approvals.inbox` |
| `tests/lua/interaction/_index.yaml` | `bee.interaction` |
| `tests/lua/launch/_index.yaml` | `bee.launch` |
| `tests/lua/managed/_index.yaml` | `bee.managed` |
| `tests/lua/modules/_index.yaml` | `tests.modules` |
| `tests/lua/overlays/_index.yaml` | `tests.overlays` |
| `tests/lua/placement/_index.yaml` | `bee.placement.native` |
| `tests/lua/placement_docker/_index.yaml` | `bee.placement.docker.tests` |
| `tests/lua/placement_publication/_index.yaml` | `bee.placement.publication.test` |
| `tests/lua/principals/_index.yaml` | `bee.test.principals` |
| `tests/lua/processes/_index.yaml` | `bee.host.processes` |
| `tests/lua/profiles/_index.yaml` | `bee.harness.profiles` |
| `tests/lua/protocol/_index.yaml` | `bee.protocol` |
| `tests/lua/protocol/admission/_index.yaml` | `bee.protocol` |
| `tests/lua/reference_apps/_index.yaml` | `bee.app.reference.test` |
| `tests/lua/resources/_index.yaml` | `bee.resources` |
| `tests/lua/session/_index.yaml` | `bee.session` |
| `tests/lua/sessions/_index.yaml` | `bee.tests.sessions` |
| `tests/lua/settings/_index.yaml` | `bee.settings` |
| `tests/lua/status_reader/_index.yaml` | `bee.status.reader` |
| `tests/lua/storage/_index.yaml` | `bee.storage` |
| `tests/lua/storage/databases/_index.yaml` | `bee.workspace.db` |
| `tests/lua/sync/_index.yaml` | `bee.sync` |
| `tests/lua/terminal/_index.yaml` | `bee.terminal` |
| `tests/lua/threads/_index.yaml` | `bee.threads` |
| `tests/lua/timeline/_index.yaml` | `bee.threads.timeline` |
| `tests/lua/workspace_catalog/_index.yaml` | `bee.workspace.catalog` |
| `tests/lua/workspaces/_index.yaml` | `bee.workspace.manager` |

Borrowed fixture sources are staged from their current owners: the thread
journal borrows the desktop reducer; native identity borrows Placement identity;
Hub migration probes borrow the Hub adapter and binding beside their fixture
index; performance research borrows shared canonical JSON from `bee.values`;
placement-publication borrows native materialization and its test runner;
reference applications borrow the documented examples. Agent-author probes
point at Timeline's `app/` sources.
