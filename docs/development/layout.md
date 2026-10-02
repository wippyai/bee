# Repository layout audit

`make lint` runs the permanent placement check in `build/layout_check.py`.
Production consists of the host `src/` and 43 component `modules/*/src/` roots.
The only root spelling exception is the public SDK: `application` exports
`bee.app`. Hyphenated component names expand into namespace nesting; all child
folders match their namespace. `src/host` is the host's documented desktop-owner
component, not a module wiring folder. No component index lives under `host/`.

The audit corrects `bee.git_worktree` to `bee.git.worktree` and moves
`src/threads_hive` to `src/threads/hive` without changing that host namespace.
Threads' owner and waiter actors and Harness's carrier actor live in `service/`.
Callable method sources for Threads, Harness, drivers, Gateway, Hive, telemetry,
Sync and Git worktree live in
`binding/`; module roots publish shared contracts; public bindings live in `binding/`.
Placement's process-runner library declares its local source in `service/`.
Threads' public reply and record types and Harness's shared execution types live
at their component roots rather than in `records/`, `service/` or `carrier/`.
The saved-profile contract lives at the Harness root; its public binding lives in `binding/`.
The complete identity map is `build/layout_identity_moves.json`; Placement 8,
Sync 8 and Gateway 16 migrate their owned saved executable references and
telemetry `owner_ref.service_id` values. The service remains the operation's exact
namespace; unrelated namespace strings and opaque state remain intact.

The root follow-up audits all entries in `bee` and every physical component
root. `bee` retains only `definition`, `workers` and `terminal`. The 383 moved
identities (144 Lua sources in step 1) are enumerated in `build/layout_root_moves.json`;
`build/layout_identity_moves.json` also resolves earlier moves to these final
live destinations. Main’s startup progress helper and environment field now live
in `bee.app.status` and `bee.persist.env`. The persisted identity conversions
are also explicit in `build/component-inventory-migrations.json`; the generated
component inventory has no dangling requirement targets and caps root Lua at
20,851 lines. Topics and schema tags retain their baseline identities.
The persisted map covers exactly the 234 persisted identities removed from
main. Step 2 adds only nonpersisted helper relocations to the cumulative map;
the step 1 persisted map and applied migration definitions remain unchanged.
Credentials' source resolver now lives in `bee.credentials.binding:sources`;
the cumulative map resolves both earlier helper IDs to that implementation.
The host-selected source catalog and resource reference remain in
`bee.credentials.env`; the historical root map and applied SQL stay unchanged.
Shared root declarations and the exact library set are
specified in the conventions and `build/layout_roots.json`. Lint rejects new
root entries outside that set and known composition names with the wrong kind,
including host declarations that share a physical component namespace. It also
checks named approver definitions; the module-publication policy now points at
the implemented `bee.approvals.inbox.app:app` identity.

Host catalogs move to their owning security namespace, endpoint wiring to
Gateway's `api`, service instances to the owner's `service`, selected defaults
to the owner's `env`, and the shared value helpers to `bee.values`. Component
bindings, policies, resource defaults and profile declarations move to
`binding`, `security`, `env` and `profiles`. App helpers move to `app`; other
helpers join the owning concept's child, including driver configuration,
Hive exposure, governance delivery and activation, and Hub package inspection.
No forwarding implementations are introduced.

Driver role correction places shared configuration calls and option rendering
in `bee.driver.binding`, observation helpers in `bee.driver.codec`, and framing
in `bee.driver.transport`. Provider bindings retain their fixed descriptors and
provider-specific configuration. The six duplicate descriptor locate libraries
are removed; tests consume each provider's existing binding operation directly.
These M0 helper moves retain every persisted binding/profile ID, topic, schema
and applied migration. Their current destinations are recorded in the layout
identity map without rewriting owner state or immutable migration SQL.

Placement 9 migrates the remaining saved binding identity and exact cleanup
markers, plus request/grant references. Sync 9 and Gateway 17 migrate stored
reference scalars, including Gateway's policy column. Resources 4 and
Credentials 7 move owner-local root/source/materializer columns. These new
blocks cover the 508 step 1 cumulative moves, including identities from before the
first layout refactor. Shared identity literals keep the captured migration
definitions within the existing artifact size bound; their expanded SQL and
checksums remain unchanged. Migration 8/16 and all older SQL remain
byte-for-byte intact. Digests, incarnations and grants
are preserved; migrations do not select additional authority. Cleanup state
remains opaque, and a colliding binding key refuses the entire owner transaction.

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
the desktop component and core terminal sources implement the desktop shell. Placement's
process-local native terminal facade is an executor contract, not an application
screen: it consumes the caller's terminal grant. Docker's short window adapter
selects its backend; it does not duplicate the native facade. Retained
presentation's executor selects the admitted application loop under its owner
lifetime and terminal grant. These adapters have actual boundary roles.

Shared bounds, canonical JSON, clock conversions and reply decoding are
registered once in `bee.values`; production and fixture consumers import them
directly. Threads retains its domain bounds and Sync retains its own canonical
limits. The obsolete Threads canonical forwarding source is removed.
The audit removes
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
There are 69 unit overlay manifests and 76 acceptance overlay manifests,
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

Workspace catalog operations live in `bee.workspace.binding`, SQL repositories
in `bee.workspace.persist`, and checkpoint/selection decoders in
`bee.workspace.types`. The durable catalog contract, extension and local binding
retain their `bee.workspace.catalog` identities. Host-selected requirements link
the existing store and catalog entries to resources and execution policies; the
extraction uses the existing catalog and migration runner.

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
| `tests/fixtures/gateway_clock/_index.yaml` | `bee.gateway` |
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
| `tests/fixtures/workspace_component/_index.yaml` | `bee.componentproof` |
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
| `tests/lua/persist/_index.yaml` | `bee.persist` |
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
| `tests/lua/session/_index.yaml` | `bee.desktop.service` |
| `tests/lua/sessions/_index.yaml` | `bee.tests.sessions` |
| `tests/lua/settings/_index.yaml` | `bee.settings` |
| `tests/lua/status_reader/_index.yaml` | `bee.status.reader` |
| `tests/lua/storage/_index.yaml` | `bee.storage` |
| `tests/lua/storage/databases/_index.yaml` | `bee.workspace.db` |
| `tests/lua/sync/_index.yaml` | `bee.sync` |
| `tests/lua/terminal/_index.yaml` | `bee.terminal` |
| `tests/lua/threads/_index.yaml` | `bee.threads` |
| `tests/lua/timeline/_index.yaml` | `bee.threads.timeline` |
| `tests/lua/values/_index.yaml` | `bee.values` |
| `tests/lua/workspace_catalog/_index.yaml` | `bee.workspace.catalog` |
| `tests/lua/workspaces/_index.yaml` | `bee.workspace.manager` |

Borrowed fixture sources are staged from their current owners: the thread
journal borrows the desktop reducer; native identity borrows Placement identity;
Hub migration probes borrow the Hub adapter and binding beside their fixture
index; performance research borrows Values canonical JSON; placement-publication
borrows native materialization and its test runner; reference applications borrow
the documented examples. Agent-author probes point at Timeline's `app/` sources.
| `tests/fixtures/hub_inspect/security/gov/_index.yaml` | `bee.security.gov` |
| `tests/fixtures/hub_inspect/sync/env/_index.yaml` | `bee.sync.env` |
| `tests/fixtures/hub_manage/security/gov/_index.yaml` | `bee.security.gov` |
| `tests/fixtures/hub_manage/sync/env/_index.yaml` | `bee.sync.env` |
| `tests/fixtures/hub_preview/sync/env/_index.yaml` | `bee.sync.env` |

Sessions admission and catalog implementations live in `bee.sessions.binding`;
its pull scheduler and turn workers live in `bee.sessions.service`, and selected
executor/driver routing lives in `bee.sessions.executor`. Threads remains the
journal owner. Sessions has no empty persistence, migrations or traits children.
The former Sessions owner library and its nonpersisted move-map entries are
removed; existing public function and binding IDs resolve directly to the owner
source without a forwarding layer.

## Component root placement map

Every name in a row moves from the source namespace to the owning child shown.
The root declarations and shared libraries that remain are listed in the
conventions and `build/layout_roots.json`.

| Source namespace | Owning child namespace | Moved entries |
|---|---|---|
| `bee.approvals.inbox` | `bee.approvals.inbox.app` | `client`, `source_config`, `sources`, `workspaces` |
| `bee.approvals.inbox` | `bee.approvals.inbox.security` | `client_policy` |
| `bee.app` | `bee.app.status` | `startup_progress` |
| `bee.approvals` | `bee.approvals.env` | `database_ref`, `db`, `db_path`, `environment`, `node_identity_migration_source`, `policies_ref`, `resources` |
| `bee.approvals` | `bee.approvals.persist` | `identity_migration` |
| `bee.approvals` | `bee.approvals.binding` | `local`, `service` |
| `bee.approvals` | `bee.approvals.types` | `runtime_lease` |
| `bee.console` | `bee.console.app` | `command` |
| `bee.credentials` | `bee.credentials.env` | `credential_sources`, `database_ref`, `db`, `db_path`, `environment`, `materializer_ref`, `node_identity_migration_source`, `sources_ref` |
| `bee.credentials` | `bee.credentials.binding` | `local`, `sources` |
| `bee.docs` | `bee.docs.binding` | `corpus` |
| `bee.docs` | `bee.docs.env` | `corpus_ref`, `resources` |
| `bee.driver.agy` | `bee.driver.agy.binding` | `binding`, `configuration`, `launch`, `protocol`, `locate` |
| `bee.driver.agy` | `bee.driver.agy.descriptor` | `command` |
| `bee.driver.agy` | `bee.driver.agy.credentials` | `credential_format` |
| `bee.driver.agy` | `bee.driver.agy.profiles` | `default_window`, `profiles`, `research_batch` |
| `bee.driver.agy` | `bee.driver.agy.env` | `executable` |
| `bee.driver.agy` | `bee.driver.agy.security` | `launch_policy_agy_batch`, `launch_policy_agy_window` |
| `bee.driver.claude` | `bee.driver.claude.env` | `api_key`, `config_home`, `executable` |
| `bee.driver.claude` | `bee.driver.claude.binding` | `binding`, `launch`, `protocol`, `locate` |
| `bee.driver.claude` | `bee.driver.claude.descriptor` | `command` |
| `bee.driver.claude` | `bee.driver.claude.credentials` | `credential_format` |
| `bee.driver.claude` | `bee.driver.claude.profiles` | `default_window`, `profiles`, `research_batch` |
| `bee.driver.claude` | `bee.driver.claude.security` | `launch_policy_claude_batch`, `launch_policy_claude_window` |
| `bee.driver.claude` | `bee.driver.claude.permission` | `permission_adapter` |
| `bee.driver.codex` | `bee.driver.codex.binding` | `binding`, `configuration`, `launch`, `protocol`, `locate` |
| `bee.driver.codex` | `bee.driver.codex.descriptor` | `command`, `default_provider` |
| `bee.driver.codex` | `bee.driver.codex.env` | `config_home`, `executable` |
| `bee.driver.codex` | `bee.driver.codex.credentials` | `credential_format` |
| `bee.driver.codex` | `bee.driver.codex.profiles` | `default_window`, `named_batch`, `profiles`, `research_batch` |
| `bee.driver.codex` | `bee.driver.codex.security` | `launch_policy_codex_batch`, `launch_policy_codex_named_batch`, `launch_policy_codex_window` |
| `bee.driver.grok` | `bee.driver.grok.binding` | `binding`, `configuration`, `launch`, `protocol`, `locate` |
| `bee.driver.grok` | `bee.driver.grok.descriptor` | `command` |
| `bee.driver.grok` | `bee.driver.grok.credentials` | `credential_format` |
| `bee.driver.grok` | `bee.driver.grok.profiles` | `default_window`, `profiles`, `research_batch` |
| `bee.driver.grok` | `bee.driver.grok.env` | `executable` |
| `bee.driver.grok` | `bee.driver.grok.security` | `launch_policy_grok_batch`, `launch_policy_grok_window` |
| `bee.driver.muse` | `bee.driver.muse.binding` | `binding`, `configuration`, `launch`, `protocol`, `locate` |
| `bee.driver.muse` | `bee.driver.muse.descriptor` | `command` |
| `bee.driver.muse` | `bee.driver.muse.credentials` | `credential_format` |
| `bee.driver.muse` | `bee.driver.muse.profiles` | `default_window`, `profiles`, `research_batch` |
| `bee.driver.muse` | `bee.driver.muse.env` | `executable` |
| `bee.driver.muse` | `bee.driver.muse.security` | `launch_policy_muse_batch`, `launch_policy_muse_window` |
| `bee.driver.opencode` | `bee.driver.opencode.binding` | `binding`, `configuration`, `launch`, `protocol`, `locate` |
| `bee.driver.opencode` | `bee.driver.opencode.descriptor` | `command` |
| `bee.driver.opencode` | `bee.driver.opencode.credentials` | `credential_format` |
| `bee.driver.opencode` | `bee.driver.opencode.profiles` | `default_window`, `profiles`, `research_batch` |
| `bee.driver.opencode` | `bee.driver.opencode.env` | `executable` |
| `bee.driver.opencode` | `bee.driver.opencode.security` | `launch_policy_opencode_batch`, `launch_policy_opencode_window` |
| `bee.driver.wippy` | `bee.driver.wippy.binding` | `binding`, `client` |
| `bee.driver.wippy` | `bee.driver.wippy.env` | `host_config` |
| `bee.driver.wippy` | `bee.driver.wippy.profiles` | `profiles` |
| `bee.driver.wippy` | `bee.driver.wippy.service` | `runner` |
| `bee.driver` | `bee.driver.codec` | `codec_registry` |
| `bee.driver` | `bee.driver.descriptor` | `descriptor`, `schema_values` |
| `bee.driver` | `bee.driver.profiles` | `instructions`, `preferences`, `profile`, `profile_access` |
| `bee.driver` | `bee.driver.locate` | `locate`, `login_evidence`, `probe_capture` |
| `bee.driver` | `bee.driver.permission` | `permission_request_hook` |
| `bee.driver` | `bee.driver.binding` | `configuration`, `option_render`, `resolver`, `universal` |
| `bee.driver.kit` | `bee.driver.binding` | `quote`, `toml` |
| `bee.driver.kit` | `bee.driver.codec` | `events`, `normalize` |
| `bee.driver.kit` | `bee.driver.transport` | `framing` |
| `bee.files` | `bee.files.app` | `gitignore`, `source`, `syntax`, `tree` |
| `bee.files` | `bee.files.env` | `workspace_root_ref` |
| `bee.gateway` | `bee.gateway.api` | `address_value`, `mcp` |
| `bee.gateway` | `bee.gateway.env` | `approval_consume_policy_ref`, `approval_request_policy_ref`, `configuration`, `database_ref`, `db`, `db_path`, `endpoint_ref`, `environment`, `hook_executable`, `install_configuration_ref`, `listener_ref`, `publish_configuration_ref`, `tool_application_open_policy_ref`, `tool_components_policy_ref`, `tool_delivery_policy_ref`, `tool_docs_policy_ref`, `tool_hub_publish_policy_ref`, `tool_install_policy_ref`, `tool_message_policy_ref`, `tool_overlay_policy_ref`, `tool_publish_policy_ref`, `tool_read_policy_ref`, `tool_session_policy_ref` |
| `bee.gateway` | `bee.gateway.catalog` | `catalog`, `context`, `json_schema`, `profile_scope`, `session_bundle`, `session_tools`, `sessions`, `surface` |
| `bee.gateway` | `bee.gateway.hooks` | `hooks` |
| `bee.git.worktree` | `bee.git.worktree.binding` | `binding`, `git_roots`, `worktree` |
| `bee.git.worktree` | `bee.git.worktree.env` | `executor_ref`, `git_executor`, `host_files`, `host_files_ref` |
| `bee.git.worktree` | `bee.git.worktree.security` | `worktree_policy` |
| `bee.gov.overlays` | `bee.gov.overlays.security` | `client_policy` |
| `bee.gov` | `bee.gov.activation` | `activation_measure`, `activation_profile_decoder`, `application_admissions`, `governed_application_admission`, `headless_revert`, `lists`, `migration_work`, `preflight`, `protected_kernel`, `super_edit` |
| `bee.gov` | `bee.gov.env` | `activation_profiles_ref`, `approval_consume_policy_ref`, `approval_request_policy_ref`, `database_ref`, `db`, `db_path`, `environment`, `node_identity_migration_source`, `publication_profiles_ref`, `workspace_folder_policy_ref`, `workspace_folder_read_ref` |
| `bee.gov` | `bee.gov.delivery` | `artifact`, `candidate`, `delivery`, `delivery_protocol`, `hub_resolver`, `lease_model`, `materializer`, `overlay_resolver`, `publication_profile_decoder`, `resolver`, `staging_resources` |
| `bee.gov` | `bee.gov.capability` | `capability_files`, `capability_gateway`, `capability_grants`, `capability_request` |
| `bee.gov` | `bee.gov.binding` | `delivery_local`, `overlay_local` |
| `bee.gov` | `bee.gov.workspace` | `workspace`, `workspace_applications`, `workspace_protocol` |
| `bee.harness` | `bee.harness.env` | `carrier_host_ref` |
| `bee.harness` | `bee.harness.api` | `gateway_hook`, `gateway_hook_mcp`, `gateway_hook_status` |
| `bee.harness` | `bee.harness.launch` | `harness_activation`, `harness_setup` |
| `bee.harness` | `bee.harness.binding` | `profiles_local` |
| `bee.hive.manager` | `bee.hive.manager.security` | `client_policy`, `viewer_policy` |
| `bee.hive.manager` | `bee.hive.manager.app` | `directory`, `names` |
| `bee.hive.telemetry` | `bee.hive.telemetry.binding` | `sampling` |
| `bee.hive` | `bee.hive.exposure` | `catalog` |
| `bee.hive` | `bee.hive.binding` | `client`, `output` |
| `bee.hive` | `bee.hive.security` | `principals` |
| `bee.hive` | `bee.hive.workspace` | `workspace_query` |
| `bee.host.processes` | `bee.host.processes.app` | `probe` |
| `bee.hub.modules` | `bee.hub.modules.security` | `client_policy`, `hub_policy`, `publication_policy`, `self_update_policy` |
| `bee.hub` | `bee.hub.package` | `binary_identity`, `graph`, `inspection`, `inventory`, `inventory_reader`, `native_compat`, `plan`, `requirements`, `result`, `semver` |
| `bee.hub` | `bee.hub.activation` | `host_resources`, `installation`, `migration_work`, `migrations` |
| `bee.hub` | `bee.hub.env` | `process_host_ref`, `publish_configuration_ref`, `publish_executor_ref` |
| `bee.hub` | `bee.hub.publication` | `publish_executor`, `publishing` |
| `bee.node` | `bee.node.env` | `database_ref`, `db`, `db_path`, `environment`, `resources` |
| `bee.persist` | `bee.persist.env` | `startup_progress` |
| `bee.persist` | `bee.persist.persist` | `database`, `ledger`, `transaction` |
| `bee.placement.docker` | `bee.placement.docker.env` | `boot_environment`, `environment`, `environment_configuration` |
| `bee.placement.docker` | `bee.placement.docker.profiles` | `coding`, `coding_recipe` |
| `bee.placement.docker` | `bee.placement.docker.binding` | `spec` |
| `bee.placement.native` | `bee.placement.native.env` | `admitted_roots_ref`, `configuration`, `database_ref`, `db`, `db_path`, `environment`, `executor_ref`, `host_files_ref`, `placement_admitted_roots`, `placement_executor`, `placement_host_files`, `placement_path`, `placement_resource_mode`, `placement_workdir_preparers`, `resource_mode_ref`, `resources`, `root`, `root_path`, `root_ref`, `runner_host_ref`, `workdir_preparers_ref` |
| `bee.placement.native` | `bee.placement.native.binding` | `process_backend` |
| `bee.placement` | `bee.placement.profiles` | `native`, `paths`, `profiles` |
| `bee.placement` | `bee.placement.binding` | `resolver` |
| `bee.resources` | `bee.resources.env` | `database_ref`, `db`, `db_path`, `environment`, `node_identity_migration_source`, `resource_roots`, `resources`, `roots_ref` |
| `bee.resources` | `bee.resources.binding` | `local`, `resources_workspace_extension` |
| `bee.sessions` | `bee.sessions.executor` | `driver_route`, `executor_registry`, `executor_selection` |
| `bee.sessions` | `bee.sessions.binding` | `threads_journal` |
| `bee.sessions` | `bee.sessions.env` | `threads_journal_ref` |
| `bee.settings` | `bee.settings.app` | `build_info` |
| `bee.sync` | `bee.sync.values` | `bounds`, `canonical`, `version` |
| `bee.sync` | `bee.sync.env` | `database_ref`, `db`, `db_path`, `environment`, `exports_ref`, `resources` |
| `bee.threads.timeline` | `bee.threads.timeline.security` | `client_policy` |
| `bee.threads` | `bee.threads.binding` | `approvals_local`, `authority_local`, `capabilities_report`, `carrier_local`, `delivery_local`, `journal_local`, `lifecycle_local`, `projection_local` |
| `bee.threads` | `bee.threads.env` | `database_path`, `database_ref`, `db`, `environment`, `resources` |
| `bee.workspace.manager` | `bee.workspace.manager.security` | `client_policy` |
| `bee` | `bee.security.approvals` | `approver_policies` |
| `bee` | `bee.security.capability` | `capability_catalog` |
| `bee` | `bee.values` | `clock` |
| `bee.protocol` | `bee.values` | `bounds`, `canonical`, `clock`, `reply` |
| `bee.threads.records` | `bee.values` | `canonical` |
| `bee` | `bee.env` | `docs_corpus` |
| `bee` | `bee.gateway.api` | `gateway_endpoint`, `gateway_listener`, `gateway_mcp`, `gateway_ready`, `gateway_router` |
| `bee` | `bee.gateway.service` | `gateway_installation_service`, `gateway_publication_service` |
| `bee` | `bee.gateway.binding` | `gateway_workspace_extension` |
| `bee` | `bee.gov.service` | `gov_recovery_service` |
| `bee` | `bee.hive.supervisor` | `hive_operation_adapters` |
| `bee` | `bee.hub.publication` | `hub_publication` |
| `bee` | `bee.gateway.env` | `module_installation`, `module_publication` |
| `bee` | `bee.security.gov` | `protected_kernel` |
| `bee` | `bee.sync.service` | `sync_distribution_service` |
| `bee` | `bee.sync.env` | `sync_exports` |
| `bee` | `bee.threads.service` | `thread_outbox_pump_service` |
| `bee` | `bee.placement.native.env` | `workdir_preparers` |
| `bee` | `bee.launch.service` | `workspace_hosts` |
| `bee.console` (host) | `bee.console.env` | `environment`, `executor`, `home`, `lang`, `path`, `user` |
| `bee.console` (host) | `bee.console.security` | `command_policy`, `executor_policy` |
