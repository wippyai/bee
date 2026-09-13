# Hub completion audit

The target is Bee module management comparable to Kickside's Hub, implemented
inside Bee without importing Keeper. This audit distinguishes implemented APIs
from visible workflows and from application admission. It does not declare the
lane complete.

Sources reviewed: Kickside `platform/hub/src/README.md`,
`ui/src/app/useModulesPage.ts`, `ui/src/app/useInstallDialog.ts`; the public
`bee.wippy.ai` page; Bee `docs/HUB.md` and the source paths below.

| Requirement | Current evidence | Remaining work |
|---|---|---|
| Catalog, keyword `bee`, independent search, README and exact versions | `src/hub/catalog.lua`; native Modules and source/pack UI checks | Improve discoverability as more package metadata is exposed |
| Preview before installation: module state and filesystem | `src/hub/preview.lua`; `make hub-preview-check` verifies no registry revision change | Contents UI installed; native public entry navigation and separate file API/UI checks pass |
| Install/update/remove with transitive requirements and typed values | `src/hub/plan.lua`, `requirements.lua`, `service.lua`; live Hub lifecycle acceptance | Saved values are preserved with source/pack acceptance; discover available updates from Installed |
| Migration choices and restart recovery | `migrations.lua`, `migration_work.lua`, `migration_runner.lua`; real SQLite service checks | Real PostgreSQL/MySQL service acceptance remains unproven |
| Declarative Hub component and later scanner/plugin installation | `build/modules.json`, `src/hub/_index.yaml` declare the module and scoped facade | No reviewed scanner binding contract yet; package metadata must not authorize plugins |
| Installed apps appear under Tools and request admission before starting | Website promise; `src/core/applications/catalog.lua` reads protected admission; broker reconciles protected bindings by registry revision | Hub installation alone does not grant admission. Need an owner-authorized, reviewed integration and actual installed-app proof |
| Per-component overlays and approved sharing | Owned by governed authoring/activation and Hive destination admission, not by Hub artifact inspection | Not proven by successful Hub publication; coordinate with those lanes without adding parallel owners |
| Visible version/build details and preserved Bee mark | Settings About native acceptance; global `6cfa0071` | Retained owners keep the old loaded UI until owner replacement |
| No Keeper dependency, lock editing or runtime changes in this lane | Hub calls native public APIs and Bee-owned services; installer compares existing runtime/native/patch identity | Continue enforcing these constraints for every integration/build |

Kickside also exposes catalog authentication, bulk update discovery, installed
filters and an optional security scan. These are useful references, not evidence
that Bee implements them. Fake timed progress, lock-file UI and Keeper HTTP
adapters are not part of Bee's target architecture. Use actual operation receipts,
registry ownership and existing host admission instead.

Completion requires a passing combined regression on the final source and a
native workflow proving the requested module-management behavior. Narrow model
or fixture checks do not establish application activation or Hive replication.

## Regression checkpoint

The baseline combined run on `c5f636e`/docs `c88ddf0` passed 780 unit cases and
continued through storage, managed windows, threads, terminal navigation and
lifecycle. It ended with exit 2 in the shared-store desktop case: the expected
completion marker was missing, followed by a workspace-database shutdown timeout.
The exact shared-store source/pack case then passed alone. Evidence is
`hub-current-full-check.log` and `hub-shared-desktop-focused.log` in September 12
local evidence. This is a failed full run with a passing focused reproduction,
not a passing final regression. The final Contents/update source still needs its
own combined gate.

Global `6cfa0071` now contains source `ef94c84` plus acceptance-only checkpoint
`aa45f5c`. The full combined run ended with exit 2 in `hub-contents-full-check.log`: the
unit subprocess returned `context canceled` during approvals service cases,
without a failed-case assertion. The focused unit recheck passed all 787 cases in
`hub-contents-unit-recheck.log`. This does not establish full repository acceptance.

## Installed-app admission seam

The existing protected `bee:application_admission` entry selects each definition's
policies. `src/core/applications/catalog.lua` validates those bindings, and the
broker now reconciles them at registry revision changes and before new opens, preserving existing instances. Hub publication writes dependency roots and
operation receipts only. The governed workspace API stages candidates; it does
not approve or activate them. The approvals service can bind a durable decision
to an exact proposal/effect, but no admission effect owner consumes that decision.

The next integration needs a protected, owner-authorized publication operation
for an exact definition and host-selected binding, followed by catalog refresh.
An unbound installed app must remain absent from Tools and refuse direct opens.
Acceptance must show unauthorized decision/consumption denial, digest/revision
revalidation, limited execution after explicit approval and revocation of future
opens. Do not give Hub or ordinary apps direct registry publication authority,
or treat package metadata as an authorization source.

## Broker reconciliation checkpoint

Global `dac1ba49` (source `7b7f4af`) reconciles protected application bindings and scopes by registry
revision, using one snapshot and a shared admission record. The real source/pack
broker fixture passes unbound denial, host-selected grant and grant reduction,
revocation before a fresh open, missing-policy refusal, recovery after a valid
replacement, malformed-binding refusal and retained producers. Existing
source/pack detached Terminal, observer isolation, host restore, client inventory
and renderer replacement checks also pass. Evidence is
`hub-admission-check.log` and `hub-admission-attachments.log` in September 12
local evidence. Strict lint and pack pass after resetting a reproduced stale
linter cache (`hub-admission-pack-reset.log`); the pre-existing lifecycle fixpoint
warning remains. All 787 units pass, and full regression continues in
`hub-admission-full-check.log`. Complete native acceptance passed on both the
previous global and candidate, following two initial candidate startup timeouts
whose cause remains unproven. The real native Modules install/update/uninstall
cycle also passes, preserving Bee base modules. `hub-admission-global-install.json`
records the installation with unchanged runtime/native pins and retained owners.

This fixture grants registry publication only to its disposable test owner. It
does not prove Hub install-to-Tools, approval consumption, atomic publication
against competing writers, or pinning an executable to an approved artifact.
The source continues to expose no application-admission writer to Hub or apps.
The default `bee.approvals:approver_policies` is empty; the next integration also
needs explicit host-selected approvers, in addition to an effect owner. Merely
holding `bee.approvals.decide` does not authorize an inbox decision.
