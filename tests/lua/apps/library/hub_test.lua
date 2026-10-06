-- MIT. The Library's Hub model only describes Hub calls and retains no authority itself.
local test = require("test")
local model = require("model")
local function ok(value: unknown): model.Reply return {ok = true, code = nil, message = nil, value = value, replayed = false} end
local function define_tests()
    test.describe("Library Hub model", function()
        test.it("discovers typed defaults without submitting them and rejects stale requirements", function()
            local state = model.new()
            model.select(state, "acme/app")
            model.select_version(state, "1.0.0")
            local value = {component = "acme/app", version = "1.0.0", digest = string.rep("a", 64),
                requirements = {requirements = {
                    {id = "acme.app:enabled", has_default = true, default = false, has_selected = false,
                        targets = {{entry = "acme.app:config", path = ".enabled"}}},
                    {id = "acme.app:name", has_default = true, default = "", has_selected = false, targets = {}},
                }, missing = {}}}
            model.apply_inspect(state, ok(value))
            test.eq(#state.requirements, 2)
            test.eq(state.requirements[1].json, "false")
            test.eq(state.requirements[2].json, '""')
            test.eq(state.requirements[1].origin, "Default")
            test.eq(#state.parameters, 0)
            test.is_nil(model.set_parameter(state, state.requirements[1].id, "true"))
            test.eq(state.parameters[1].value, true)
            model.select_version(state, "2.0.0")
            test.eq(#state.requirements, 0)
            model.apply_inspect(state, ok(value))
            test.is_nil(state.requirements_digest)
            test.eq(#state.requirements, 0)
        end)
        test.it("opens the keyword filter on the catalog phase, where the footer advertises it", function()
            test.is_true(model.keyword_phase("catalog"))
            for _, phase in ipairs({"installed", "details", "operations", "plan", "confirm", "result"}) do
                test.is_false(model.keyword_phase(phase))
            end
        end)
        test.it("keeps keyword browsing separate from text search and emits only facade intents", function()
            local state = model.new()
            local catalog = model.catalog_intent(state)
            test.eq(catalog.operation, "catalog")
            test.eq(catalog.request and catalog.request.keyword, "bee")
            test.is_nil(catalog.request and catalog.request.query)
            model.set_keyword(state, "")
            model.set_query(state, "docker")
            catalog = model.catalog_intent(state)
            test.eq(catalog.request and catalog.request.keyword, "")
            test.eq(catalog.request and catalog.request.query, "docker")
        end)
        test.it("rejects malformed catalog counters and object keys without replacing valid state", function()
            local state = model.new()
            model.apply_catalog(state, ok({total = 1, items = {{component = "acme/valid", title = "Valid", description = "", latest_version = "1.0.0"}}}))
            local original = state.catalog[1]
            local malformed = {
                {total = "2", items = {{component = "acme/replacement"}}},
                {total = 1.5, items = {{component = "acme/replacement"}}},
                {total = 0 / 0, items = {{component = "acme/replacement"}}},
                {total = math.huge, items = {{component = "acme/replacement"}}},
                {[1] = "unexpected object key"},
            }
            for _, value in ipairs(malformed) do
                model.apply_catalog(state, ok(value))
                test.eq(#state.catalog, 1)
                test.eq(state.catalog[1].component, original.component)
                test.eq(state.total, 1)
                test.neq(state.notice, "")
            end
        end)
        test.it("accepts JSON parameter values with their native types and invalidates a displayed plan", function()
            local state = model.new()
            model.select(state, "userspace/docker")
            model.select_version(state, "0.5.12")
            test.is_nil(model.set_parameter(state, "userspace.docker:port", "8080"))
            test.eq(state.parameters[1].value, 8080)
            model.apply_plan(state, ok({digest = string.rep("a", 64), ready = true, base_revision = 7, modules = {}, missing = {}, migrations = {}, starts = {}, capabilities = {},
                request = {action = "install", component = "userspace/docker", version = "0.5.12", migration_policy = "none",
                    parameters = {{name = "userspace.docker:port", value = 8080}}}}))
            test.not_nil(state.plan)
            test.is_nil(model.set_parameter(state, "userspace.docker:enabled", "false"))
            test.is_nil(state.plan)
            test.not_nil(model.set_parameter(state, "userspace.docker:bad", "not-json"))
        end)
        test.it("rejects malformed plan revisions and collections without replacing the displayed plan", function()
            local state = model.new()
            model.select(state, "acme/app")
            model.select_version(state, "1.0.0")
            local valid: {[string]: unknown} = {digest = string.rep("a", 64), ready = true, base_revision = 7,
                modules = {}, missing = {}, migrations = {}, starts = {}, capabilities = {},
                request = {action = "install", component = "acme/app", version = "1.0.0",
                    migration_policy = "none", parameters = {}}}
            model.apply_plan(state, ok(valid))
            test.not_nil(state.plan)
            local accepted_digest = state.plan and state.plan.digest
            local missing_revision: {[string]: unknown} = {digest = string.rep("b", 64), ready = true,
                modules = {}, missing = {}, migrations = {}, starts = {}, capabilities = {}, request = valid.request}
            local malformed: {unknown} = {
                missing_revision,
                {digest = string.rep("b", 64), ready = true, base_revision = "8", modules = {}, missing = {}, migrations = {}, starts = {}, capabilities = {}, request = valid.request},
                {digest = string.rep("b", 64), ready = true, base_revision = 7.5, modules = {}, missing = {}, migrations = {}, starts = {}, capabilities = {}, request = valid.request},
                {digest = string.rep("b", 64), ready = true, base_revision = 0 / 0, modules = {}, missing = {}, migrations = {}, starts = {}, capabilities = {}, request = valid.request},
                {digest = string.rep("b", 64), ready = true, base_revision = math.huge, modules = {}, missing = {}, migrations = {}, starts = {}, capabilities = {}, request = valid.request},
                {digest = string.rep("b", 64), ready = "yes", base_revision = 8, modules = {}, missing = {}, migrations = {}, starts = {}, capabilities = {}, request = valid.request},
                {digest = string.rep("b", 64), ready = true, base_revision = 8, modules = {[1] = {}, [3] = {}}, missing = {}, migrations = {}, starts = {}, capabilities = {}, request = valid.request},
                {[1] = "malformed object key"},
            }
            for _, value in ipairs(malformed) do
                model.apply_plan(state, ok(value))
                test.eq(state.plan and state.plan.digest, accepted_digest)
                test.neq(state.notice, "")
            end
        end)
        test.it("hydrates a Bee component directly from its host-selected root", function()
            local state = model.new()
            model.select(state, "bee/files")
            model.set_action(state, "update")
            model.begin_update_hydration(state)
            model.apply_installed(state, ok({version = 4, modules = {{component = "bee/files", version = "1.0.0", source = "hub", direct = true, used_by = {}}},
                roots = {{id = "bee.deps:files", component = "bee/files", version = "1.0.0", managed = true,
                    parameters = {{name = "target_workspace_root", value = "bee.env:files_root"}}}}}))
            test.eq(#state.parameters, 1)
            test.eq(state.parameters[1].value, "bee.env:files_root")
            test.eq(state.selected, "bee/files")
            test.eq(state.action, "update")
        end)
        test.it("requires the Hub management result instead of inferring authority from the root ID", function()
            local state = model.new()
            model.apply_installed(state, ok({modules = {}, roots = {{id = "bee.hub.deps:root", component = "acme/app",
                version = "1.0.0", parameters = {}}}}))
            test.eq(state.installed_read, "error")
            test.eq(state.notice, "Invalid installed inventory: installed inventory contains an invalid root")
        end)
        test.it("hydrates an update from the installed root's typed parameters", function()
            local state = model.new()
            model.select(state, "acme/app")
            model.select_version(state, "2.0.0")
            model.apply_installed(state, ok({modules = {{component = "acme/app", version = "1.2.0", source = "hub", direct = true, used_by = {}}},
                roots = {{id = "host:acme", component = "acme/app", version = "1.2.0", managed = false, parameters = {{name = "acme.app:port", value = 1}}},
                    {id = "bee.hub.deps:5f89da0438fa1b1767532b58bd38cda2396f39889ab9e492e7f8f20d22fc9e9f", component = "acme/app", version = "1.2.0", managed = true,
                        parameters = {{name = "acme.app:enabled", value = true}, {name = "acme.app:port", value = 8080}}}}}))
            test.eq(#state.parameters, 0)
            model.set_action(state, "update")
            test.eq(#state.parameters, 2)
            test.eq(state.parameters[1].name, "acme.app:enabled")
            test.eq(state.parameters[1].value, true)
            test.eq(state.parameters[2].value, 8080)
            model.begin_update_hydration(state)
            test.is_nil(model.inspect_intent(state))
            local intent, loading_problem = model.plan_intent(state)
            test.is_nil(intent)
            test.eq(loading_problem, "installed settings are still loading; retry after the inventory read completes")
            model.apply_installed(state, ok({modules = {}, roots = {{id = "bee.hub.deps:5f89da0438fa1b1767532b58bd38cda2396f39889ab9e492e7f8f20d22fc9e9f", component = "acme/app", version = "1.2.0", managed = true,
                parameters = {{name = "acme.app:enabled", value = true}, {name = "acme.app:port", value = 8080}}}}}))
            intent = model.plan_intent(state)
            test.not_nil(intent)
            if intent and intent.request then test.eq(intent.request.parameters[2].value, 8080) end
        end)
        test.it("reads installed host roots whose parameters address requirements by bare name", function()
            local state = model.new()
            model.select(state, "acme/store")
            model.apply_installed(state, ok({modules = {{component = "acme/store", version = "0.1.0", source = "hub", direct = true, used_by = {}}},
                roots = {{id = "host:dependency_store", component = "acme/store", version = "0.1.0", managed = false, parameters = {{name = "target_db", value = "host:db"}}}}}))
            test.eq(state.installed_read, "ready")
            test.eq(#state.installed_roots, 1)
            test.eq(state.installed_roots[1].parameters[1].name, "target_db")
        end)
        test.it("reads Hub availability for the installed Bee pack set and clears stale status", function()
            local state = model.new()
            model.apply_updates(state, ok({modules = {
                {component = "bee/bee", installed_version = "1.0.0", available_version = "2.0.0", update_available = true},
                {component = "bee/application", installed_version = "1.0.0", available_version = "1.0.0", update_available = false},
            }, bee_update = {installed_version = "1.0.0", available_version = "2.0.0", update_available = true,
                needs_new_binary = true, reason = "needs a newer Bee binary: native/launch requires 2.0.0"}, catalog_error = ""}))
            test.eq(state.update_status, "ready")
            test.eq(#state.pack_updates, 2)
            test.eq(state.bee_update and state.bee_update.needs_new_binary, true)
            test.eq(state.pack_updates[1].component, "bee/bee")
            model.begin_updates(state)
            test.eq(state.update_status, "pending")
            test.eq(#state.pack_updates, 0)
            test.is_nil(state.bee_update)
            model.apply_updates(state, {ok = false, code = "UNAVAILABLE", message = "Hub offline", value = nil, replayed = false})
            test.eq(state.update_status, "error")
            test.eq(state.notice, "UNAVAILABLE: Hub offline")
            test.eq(#state.pack_updates, 0)
            test.is_nil(state.bee_update)
        end)
        test.it("preserves edited and intentionally cleared values across inventory refresh", function()
            local state = model.new()
            model.select(state, "acme/app")
            local installed = {modules = {}, roots = {{id = "bee.hub.deps:5f89da0438fa1b1767532b58bd38cda2396f39889ab9e492e7f8f20d22fc9e9f", component = "acme/app", version = "1.2.0", managed = true,
                parameters = {{name = "acme.app:enabled", value = true}, {name = "acme.app:port", value = 8080}}}}}
            model.apply_installed(state, ok(installed))
            model.set_action(state, "update")
            test.is_nil(model.set_parameter(state, "acme.app:port", "9090"))
            model.apply_installed(state, ok(installed))
            test.eq(#state.parameters, 2)
            test.eq(state.parameters[2].value, 9090)

            model.remove_parameter(state, "acme.app:enabled")
            model.apply_installed(state, ok(installed))
            test.eq(#state.parameters, 1)
            test.eq(state.parameters[1].name, "acme.app:port")
            test.eq(state.parameters[1].value, 9090)
        end)
        test.it("keeps update details visible and reports malformed installed roots", function()
            local state = model.new()
            model.select(state, "acme/app")
            model.select_version(state, "2.0.0")
            model.set_action(state, "update")
            model.apply_installed(state, ok({modules = {}, roots = {{id = "bad", component = "not a component", version = "2.0.0", parameters = {}}}}))
            test.eq(state.phase, "details")
            test.eq(state.notice, "Invalid installed inventory: installed inventory contains an invalid root")
            local intent, problem = model.plan_intent(state)
            test.is_nil(intent)
            test.eq(problem, "installed settings could not be read; retry the inventory read before updating")
        end)
        test.it("binds confirmation to the immutable plan digest and clears it when the request changes", function()
            local state = model.new()
            model.select(state, "userspace/docker")
            model.select_version(state, "0.5.12")
            model.apply_plan(state, ok({digest = string.rep("b", 64), ready = true, base_revision = 7, modules = {}, missing = {}, migrations = {}, starts = {}, capabilities = {},
                request = {action = "install", component = "userspace/docker", version = "0.5.12", migration_policy = "none", parameters = {}}}))
            test.is_nil(model.confirm(state))
            local intent, problem = model.confirm_intent(state)
            test.is_nil(problem)
            test.not_nil(intent)
            if intent then test.eq(intent.operation, "apply"); test.eq(intent.expected_digest, string.rep("b", 64)) end
            model.set_policy(state, "up")
            test.is_nil(state.plan)
            test.is_nil(model.confirm_intent(state))
        end)
        test.it("retires reviewed plans when leaving the confirmation flow", function()
            local state = model.new()
            model.select(state, "userspace/docker")
            model.select_version(state, "0.5.12")
            model.apply_plan(state, ok({digest = string.rep("b", 64), ready = true, base_revision = 7, modules = {},
                missing = {}, migrations = {}, starts = {}, capabilities = {},
                request = {action = "install", component = "userspace/docker", version = "0.5.12",
                    migration_policy = "none", parameters = {}}}))
            test.is_nil(model.confirm(state))
            model.show(state, "plan")
            test.not_nil(state.plan)
            test.is_nil(model.confirm(state))
            model.show(state, "installed")
            test.is_nil(state.plan)

            model.select(state, "userspace/docker")
            model.show(state, "details")
            model.show(state, "plan")
            test.is_nil(state.plan)
        end)
        test.it("requires a fresh measured reply before confirming a replanned request", function()
            local state = model.new()
            model.select(state, "userspace/docker")
            model.select_version(state, "0.5.12")
            local value = {digest = string.rep("b", 64), ready = true, base_revision = 7,
                modules = {}, missing = {}, migrations = {}, starts = {}, capabilities = {},
                request = {action = "install", component = "userspace/docker", version = "0.5.12", migration_policy = "none", parameters = {}}}
            model.apply_plan(state, ok(value))
            model.begin_plan(state)
            test.is_nil(state.plan)
            test.eq(state.phase, "plan")
            test.eq(model.confirm(state), "prepare a plan first")
            model.apply_plan(state, ok(value))
            test.is_nil(model.confirm(state))
        end)
        test.it("accepts normalized uninstall plans and keeps the public request versionless", function()
            local state = model.new()
            model.select(state, "userspace/docker")
            model.set_action(state, "uninstall")
            local value = {digest = string.rep("d", 64), ready = true, base_revision = 7,
                modules = {}, missing = {}, migrations = {}, starts = {}, capabilities = {},
                request = {action = "uninstall", component = "userspace/docker", version = "",
                    parameters = {}, migration_policy = "block"}}
            model.apply_plan(state, ok(value))
            test.not_nil(state.plan)
            test.is_nil(model.confirm(state))
            local intent = model.confirm_intent(state)
            test.not_nil(intent)
            if intent and intent.request then
                test.is_nil(intent.request.version)
                test.is_nil(intent.request.parameters)
            end
            model.set_policy(state, "leave")
            model.apply_plan(state, ok(value))
            test.is_nil(state.plan)
        end)
        test.it("ignores a delayed plan for an earlier request", function()
            local state = model.new()
            model.select(state, "userspace/docker")
            model.select_version(state, "0.5.12")
            model.set_action(state, "update")
            model.apply_installed(state, ok({modules = {}, roots = {}}))
            model.apply_plan(state, ok({digest = string.rep("c", 64), ready = true, base_revision = 7, modules = {}, missing = {}, migrations = {}, starts = {}, capabilities = {},
                request = {action = "install", component = "userspace/docker", version = "0.5.12", parameters = {}, migration_policy = "none"}}))
            test.is_nil(state.plan)
            test.eq(state.notice, "Those changes were for an earlier choice and were ignored")
        end)
        test.it("requires a completed receipt before presenting a successful operation", function()
            local state = model.new()
            model.apply_result(state, ok({state = "failed", message = "transaction failed"}))
            test.not_nil(state.result)
            if state.result then test.is_false(state.result.ok) end
            model.apply_result(state, ok({state = "recovery_required", message = "check status"}))
            test.not_nil(state.result)
            if state.result then test.is_false(state.result.ok) end
            model.apply_result(state, ok({state = "published", message = "publication is not completion"}))
            if state.result then test.is_false(state.result.ok) end
            model.apply_result(state, ok({}))
            if state.result then test.is_false(state.result.ok) end
            model.apply_result(state, ok({state = "complete", message = "done"}))
            if state.result then test.is_true(state.result.ok) end
        end)
        test.it("binds paged operation history to actor-owned receipt fields and sorts newest first", function()
            local state = model.new()
            local intent = model.operation_history_intent(state)
            test.eq(intent.operation, "status")
            test.eq(intent.request and intent.request.page, 1)
            test.is_nil(intent.expected_digest)
            model.apply_history(state, ok({page = 1, total = 26, page_size = 25, operations = {
                {digest = string.rep("a", 64), component = "bee/old", action = "install", state = "complete", message = "old", baseline_revision = 2},
                {digest = string.rep("b", 64), component = "bee/new", action = "update", state = "published", message = "new", baseline_revision = 9,
                    request = {action = "update", component = "bee/new", version = "1.0.0", parameters = {}, migration_policy = "none"},
                    migration_work = {entries = {}, rows = {{id = "bee.new:01", target_db = "app:db", module = "bee/new", status = "applied"}}}},
            }}))
            test.eq(state.operation_total, 26)
            test.eq(state.operation_page_size, 25)
            test.eq(state.operations[1].component, "bee/new")
            test.eq(#state.operations[1].migration_work, 1)
            local selected, selected_problem = model.select_operation(state, state.operations[1].digest)
            test.not_nil(selected)
            test.is_nil(selected_problem)
            local selected_status = model.status_intent(state)
            test.eq(selected_status and selected_status.expected_digest, state.operations[1].digest)
        end)
        test.it("keeps old receipts view-only and refuses blind recovery", function()
            local state = model.new()
            model.apply_history(state, ok({page = 1, total = 2, page_size = 25, operations = {
                {digest = string.rep("c", 64), component = "bee/old", action = "install", state = "published", message = "old"},
                {digest = string.rep("d", 64), component = "bee/done", action = "update", state = "complete", message = "done", baseline_revision = 3,
                    request = {action = "update", component = "bee/done", version = "1.0.0", parameters = {}, migration_policy = "none"}},
            }}))
            local _, problem = model.select_operation(state, string.rep("c", 64))
            test.is_nil(problem)
            test.eq(model.recover(state), "this operation has no stored request for recovery")
            local _, done_problem = model.select_operation(state, string.rep("d", 64))
            test.is_nil(done_problem)
            test.eq(model.recover(state), "only prepared, published or recovery-required operations can be recovered")
        end)
        test.it("reviews prepared and published recovery with the exact stored request and digest", function()
            for _, phase in ipairs({"prepared", "published", "recovery_required"}) do
                local state = model.new()
                local digest = string.rep("e", 64)
                local request = {action = "install", component = "bee/recover", version = "1.2.3", parameters = {{name = "bee.recover:flag", value = true}}, migration_policy = "up"}
                local reply = ok({page = 1, total = 1, page_size = 25, operations = {{digest = digest, component = "bee/recover", action = "install", state = phase, message = "review", baseline_revision = 11, request = request}}})
                model.apply_history(state, reply)
                request.version = "9.9.9"
                local selected, select_problem = model.select_operation(state, digest)
                test.not_nil(selected)
                test.is_nil(select_problem)
                test.is_nil(model.recover(state))
                local intent, problem = model.confirm_intent(state)
                test.is_nil(problem)
                test.not_nil(intent)
                if intent and intent.request then
                    test.eq(intent.expected_digest, digest)
                    test.eq(intent.request.version, "1.2.3")
                    test.eq(intent.request.parameters[1].value, true)
                end
                model.select_version(state, "9.9.9")
                test.is_nil(model.confirm_intent(state))
            end
        end)
        test.it("separates usable apps from developer packages and sorts usable apps first", function()
            local state = model.new()
            model.apply_installed(state, ok({modules = {
                {component = "bee/terminal", version = "0.4.6", source = "builtin", direct = true, used_by = {}},
                {component = "userspace/calc", version = "1.0.0", source = "hub", direct = true, used_by = {}},
            }, roots = {}}))
            test.eq(model.component_status(state, "bee/terminal"), "built-in")
            test.eq(model.component_status(state, "userspace/calc"), "installed")
            test.is_nil(model.component_status(state, "userspace/editor"))

            test.is_false(model.is_library({component = "wippy/arbitrary", title = "Library", description = "library", latest_version = "1.0.0", application = true}))
            test.is_true(model.is_library({component = "bee/console", title = "App", description = "app", latest_version = "1.0.0", application = false}))
            test.is_nil(model.component_status(state, "bee/settings"))
            -- Only declared installed libraries are classified; unknown packages stay visible.
            test.is_false(model.is_library({component = "bee/terminal", title = "Terminal", description = "", latest_version = "0.4.6"}))
            test.is_false(model.is_library({component = "userspace/calc", title = "Calculator", description = "App", latest_version = "1.0.0"}))
            test.is_true(model.is_library({component = "wippy/test", title = "Test Framework", description = "Testing framework", latest_version = "0.4.19", application = false}))
            test.is_true(model.is_library({component = "wippy/terminal", title = "Terminal", description = "Terminal library components", latest_version = "0.4.6", application = false}))
            test.is_true(model.is_library({component = "wippy/migration", title = "Migrations", description = "Migration utilities", latest_version = "0.3.19", application = false}))
            test.is_true(model.is_library({component = "bee/sync", title = "Sync", description = "Workspace sync protocol", latest_version = "0.1.0", application = false}))

            -- Catalog contains mixed apps and developer packages
            model.apply_catalog(state, ok({total = 5, items = {
                {component = "wippy/test", title = "Test Framework", description = "BDD framework", latest_version = "0.4.19", application = false},
                {component = "wippy/terminal", title = "Terminal", description = "Terminal library", latest_version = "0.4.6", application = false},
                {component = "userspace/editor", title = "Editor", description = "Text editor app", latest_version = "2.0.0"},
                {component = "bee/terminal", title = "Terminal", description = "Terminal app", latest_version = "0.4.6"},
                {component = "userspace/calc", title = "Calculator", description = "Calculator app", latest_version = "1.0.0"},
            }}))

            -- By default, developer packages are hidden and only usable apps are visible
            test.is_false(state.developer_packages)
            test.eq(#state.catalog, 3)
            -- Sorted: built-in app first (bee/terminal), installed app second (userspace/calc), uninstalled app third (userspace/editor)
            test.eq(state.catalog[1].component, "bee/terminal")
            test.eq(state.catalog[2].component, "userspace/calc")
            test.eq(state.catalog[3].component, "userspace/editor")
            test.eq(state.selected, "bee/terminal")

            -- Enable developer packages filter
            model.set_developer_packages(state, true)
            test.is_true(state.developer_packages)
            test.eq(#state.catalog, 5)
            test.eq(state.catalog[1].component, "bee/terminal")
            test.eq(state.catalog[2].component, "userspace/calc")
            test.eq(state.catalog[3].component, "userspace/editor")
            -- Developer packages appear after usable apps
            test.eq(state.catalog[4].component, "wippy/terminal")
            test.eq(state.catalog[5].component, "wippy/test")

            -- Toggle back off
            model.toggle_developer_packages(state)
            test.is_false(state.developer_packages)
            test.eq(#state.catalog, 3)

            -- Setting search query reveals developer packages matching query
            model.set_query(state, "test")
            test.eq(state.query, "test")
            test.eq(#state.catalog, 5)
        end)
    end)
end
return test.run_cases(define_tests)
