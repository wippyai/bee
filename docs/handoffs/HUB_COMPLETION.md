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
| Installed apps appear under Tools and request admission before starting | Website promise; `src/core/applications/catalog.lua` reads protected admission; broker loads bindings at startup | Hub installation alone does not grant admission or refresh the broker's bindings. Need an owner-authorized, reviewed integration and actual installed-app proof |
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
`aa45f5c`. The full combined run is active in `hub-contents-full-check.log`; its
result must be checked before claiming the final regression passed.
