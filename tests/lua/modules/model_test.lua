-- MIT. Modules only describes Hub calls and retains no authority itself.
local test = require("test")
local model = require("model")
local function ok(value: unknown): model.Reply return {ok = true, code = nil, message = nil, value = value, replayed = false} end
local function define_tests()
    test.describe("Modules model", function()
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
            model.apply_plan(state, ok({digest = string.rep("c", 64), ready = true, base_revision = 7, modules = {}, missing = {}, migrations = {}, starts = {}, capabilities = {},
                request = {action = "install", component = "userspace/docker", version = "0.5.12", parameters = {}, migration_policy = "none"}}))
            test.is_nil(state.plan)
            test.eq(state.notice, "plan belongs to an earlier package selection; ignored")
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
            test.eq(model.recover(state), "only published or recovery-required operations can be recovered")
        end)
        test.it("reviews recovery with the exact stored request and digest", function()
            local state = model.new()
            local digest = string.rep("e", 64)
            local request = {action = "install", component = "bee/recover", version = "1.2.3", parameters = {{name = "bee.recover:flag", value = true}}, migration_policy = "up"}
            local reply = ok({page = 1, total = 1, page_size = 25, operations = {{digest = digest, component = "bee/recover", action = "install", state = "recovery_required", message = "review", baseline_revision = 11, request = request}}})
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
        end)
    end)
end
return test.run_cases(define_tests)
