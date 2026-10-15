-- MIT. Admission launch behaviour.
local test = require("test")
local principals = require("principals")
local registry = require("registry")
local admission = require("admission")
local bounds = require("bounds")
local fixture = require("fixture")
local DEFINITION = fixture.DEFINITION
local POLICY = fixture.POLICY
local ROOT = fixture.ROOT
local SOURCE = fixture.SOURCE
local fresh = fixture.fresh
local workspace_id = fixture.workspace_id
local call = fixture.call
local call_as_bound = fixture.call_as_bound
local call_as_with_policies = fixture.call_as_with_policies
local call_as = fixture.call_as
local value = fixture.value
local code = fixture.code
local apply = fixture.apply
local with_entry = fixture.with_entry
local function define_tests()
    test.describe("Launch admission", function()
        local workspace = fixture.prepare()
        test.it("admits a shared caller thread only after checking membership and before acquiring launch resources", function()
            local entry = assert(registry.get(DEFINITION))
            local original = entry.data
            local changed: {[string]: unknown} = {}
            for key, item in pairs(assert(bounds.object(original))) do changed[key] = item end
            changed.allowed_overrides = {"thread"}
            changed.thread_policy = {kind = "caller"}
            local ok, failure = pcall(function()
                entry.data = changed
                apply(entry)
                local shared = fresh("research-thread")
                value(call("bee.threads.binding:create", {thread_id = shared, idempotency_key = fresh("create"), title = "Research"}))
                local admitted = value(call("bee.tests.harness.admission:admit", {request_id = fresh("shared-agent"), definition_ref = DEFINITION,
                    workspace_id = workspace, brief = "independent finding", thread_id = shared}))
                test.eq(admitted.thread_id, shared)
                test.eq((assert(bounds.object(admitted.request))).thread_id, shared)

                local foreign_owner = fresh("foreign-owner")
                local foreign_thread = fresh("foreign-thread")
                value(call_as(foreign_owner, "bee.threads.binding:create", {thread_id = foreign_thread,
                    idempotency_key = fresh("foreign-create"), title = "Foreign"}))
                local before = value(call_as(foreign_owner, "bee.threads.binding:read_after", {thread_id = foreign_thread, cursor = 0}))
                local resources_before = value(call("bee.resources.binding:list", {workspace_id = workspace}))
                local credentials_before = value(call("bee.credentials.binding:list", {workspace_id = workspace}))
                local refused = call("bee.tests.harness.admission:admit", {request_id = fresh("foreign-agent"), definition_ref = DEFINITION,
                    workspace_id = workspace, brief = "must not start", thread_id = foreign_thread})
                test.eq(code(refused), "DENIED")
                local after = value(call_as(foreign_owner, "bee.threads.binding:read_after", {thread_id = foreign_thread, cursor = 0}))
                test.eq(#(principals.items(after.records)), #(principals.items(before.records)))
                local resources_after = value(call("bee.resources.binding:list", {workspace_id = workspace}))
                local credentials_after = value(call("bee.credentials.binding:list", {workspace_id = workspace}))
                test.eq(#(principals.items(resources_after.grants)), #(principals.items(resources_before.grants)))
                test.eq(#(principals.items(credentials_after.projections)), #(principals.items(credentials_before.projections)))
            end)
            entry.data = original
            apply(entry)
            if not ok then error(tostring(failure)) end
        end)
        test.it("admits a reopened app through its active stable-family thread membership", function()
            local entry = assert(registry.get(DEFINITION))
            local original = entry.data
            local changed: {[string]: unknown} = {}
            for key, item in pairs(assert(bounds.object(original))) do changed[key] = item end
            changed.allowed_overrides = {"thread"}
            changed.thread_policy = {kind = "caller"}
            local ok, failure = pcall(function()
                entry.data = changed
                apply(entry)
                local alias_workspace = string.rep("b", 32)
                local definition_id = "bee.harness.catalog:stable_family_fixture"
                local stable = "bee.application:" .. alias_workspace .. ":" .. fresh("stable-family")
                local old_app = "bee.application:" .. alias_workspace .. ":" .. fresh("old-app")
                local reopened_app = "bee.application:" .. alias_workspace .. ":" .. fresh("reopened-app")
                local unattested_app = "bee.application:" .. alias_workspace .. ":" .. fresh("unattested-app")
                local broker = "bee.test.alias-broker"
                local alias_policies = {"bee.threads.security:app_alias_client",
                    "bee.threads.security:app_alias"}
                local function attest(instance: string)
                    value(call_as_with_policies(broker, "bee.threads.binding:register_app_alias", {
                        stable = stable, instance = instance, workspace_id = alias_workspace, definition_id = definition_id,
                    }, alias_policies))
                end
                local function retire(instance: string)
                    value(call_as_with_policies(broker, "bee.threads.binding:retire_app_alias", {
                        stable = stable, instance = instance, workspace_id = alias_workspace, definition_id = definition_id,
                    }, alias_policies))
                end
                local function workspace_call(target: string, request: {[string]: unknown})
                    request.workspace_id = alias_workspace
                    value(call(target, request))
                end
                workspace_call("bee.resources.binding:associate", {name = "project", root_ref = ROOT,
                    subpath = "", allowed_access = "write"})
                workspace_call("bee.resources.binding:associate", {name = "session", root_ref = ROOT,
                    subpath = "", allowed_access = "write"})
                workspace_call("bee.credentials.binding:define", {name = "anthropic", provider = "claude",
                    source = {kind = "env_variable", ref = SOURCE}})
                with_entry("bee.credentials.env:credential_sources", function(source_entry)
                    local sources = principals.objects(source_entry.sources)
                    local copied: {{[string]: unknown}} = {}
                    for index, source in ipairs(sources) do
                        local item: {[string]: unknown} = {}
                        for key, value in pairs(source) do item[key] = value end
                        if item.ref == SOURCE then item.audience = "*" end
                        copied[index] = item
                    end
                    source_entry.sources = copied
                end, function()
                    attest(old_app)
                    local shared = fresh("reopened-app-thread")
                    value(call_as_bound(old_app, "bee.threads.binding:create", {thread_id = shared,
                        idempotency_key = fresh("create"), title = "Research"}, alias_workspace, {}))
                    attest(reopened_app)

                    local visible = value(call_as_bound(reopened_app, "bee.threads.binding:get", {thread_id = shared},
                        alias_workspace, {}))
                    local membership = assert(bounds.object(visible.membership))
                    test.eq(membership.member_id, old_app)
                    test.eq(membership.active, true)

                    local admitted = value(call_as(reopened_app, "bee.tests.harness.admission:admit", {
                        request_id = fresh("reopened-app-launch"), definition_ref = DEFINITION,
                        workspace_id = alias_workspace, brief = "continue research", thread_id = shared,
                    }))
                    test.eq(admitted.thread_id, shared)

                    retire(old_app)
                    local reopened_thread = fresh("reopened-app-owned-thread")
                    value(call_as_bound(reopened_app, "bee.threads.binding:create", {thread_id = reopened_thread,
                        idempotency_key = fresh("create"), title = "Reopened app work"}, alias_workspace, {}))
                    test.eq(code(call_as(old_app, "bee.tests.harness.admission:admit", {
                        request_id = fresh("retired-app-launch"), definition_ref = DEFINITION,
                        workspace_id = alias_workspace, brief = "retired callers cannot launch", thread_id = reopened_thread,
                    })), "DENIED")

                    test.eq(code(call_as_bound(unattested_app, "bee.threads.binding:get", {thread_id = shared},
                        alias_workspace, {})), "DENIED")
                    test.eq(code(call_as(unattested_app, "bee.tests.harness.admission:admit", {
                        request_id = fresh("unattested-app-launch"), definition_ref = DEFINITION,
                        workspace_id = alias_workspace, brief = "must remain denied", thread_id = shared,
                    })), "DENIED")
                end)
            end)
            entry.data = original
            apply(entry)
            if not ok then error(tostring(failure)) end
        end)
        test.it("refuses caller environment before admitting a thread", function()
            for _, environment in ipairs({{}, {BEE_PROFILE_VALUE = "caller-value"}}) do
                local request_id = fresh("environment")
                local reply = call("bee.tests.harness.admission:admit", {request_id = request_id, definition_ref = DEFINITION,
                    workspace_id = workspace, brief = "ping", environment = environment})
                test.eq(code(reply), "INVALID")
                test.is_true(reply.error ~= nil and tostring(reply.error.message):find("environment", 1, true) ~= nil)
                local absent = call("bee.threads.binding:get", {thread_id = "thread:" .. request_id})
                test.eq(code(absent), "NOT_FOUND")
            end
        end)
        test.it("refuses an unlinked carrier host before admitting a thread", function()
            local entry = registry.get("bee.harness.env:carrier_host_ref")
            if not entry then error("carrier host reference") end
            local original = entry.data
            entry.data = {}
            apply(entry)
            local request_id = fresh("unlinked")
            local reply = call("bee.tests.harness.admission:start", {request_id = request_id, definition_ref = DEFINITION, workspace_id = workspace, brief = "ping"})
            entry.data = original
            apply(entry)
            test.eq(code(reply), "UNAVAILABLE")
            test.eq(reply.error and reply.error.message, "carrier process host is not linked")
            local absent = call("bee.threads.binding:get", {thread_id = "thread:" .. request_id})
            test.eq(code(absent), "NOT_FOUND")
        end)
        test.it("keeps definition and policy measurements in the selected registry generation", function()
            local pinned, pin_error = registry.snapshot()
            if not pinned then error(tostring(pin_error)) end
            local before, before_error = admission.read(pinned, DEFINITION, nil)
            if not before then error(tostring(before_error and before_error.error and before_error.error.message)) end
            local definition_entry = registry.get(DEFINITION)
            local policy_entry = registry.get(POLICY)
            if not definition_entry or not policy_entry then error("launch fixture entries") end
            local original_definition = definition_entry.data
            local original_policy = policy_entry.data
            local changed_definition: {[string]: unknown} = {}
            local changed_policy: {[string]: unknown} = {}
            for key, item in pairs(assert(bounds.object(original_definition))) do changed_definition[key] = item end
            for key, item in pairs(assert(bounds.object(original_policy))) do changed_policy[key] = item end
            changed_definition.title = "Changed launch title"
            changed_policy.stop_grace_ms = 23456
            local ok, failure = pcall(function()
                definition_entry.data = changed_definition
                policy_entry.data = changed_policy
                local changes = registry.snapshot():changes()
                changes:update(definition_entry)
                changes:update(policy_entry)
                local applied, apply_error = changes:apply()
                if not applied then error(tostring(apply_error)) end
                local retained, retained_error = admission.read(pinned, DEFINITION, nil)
                if not retained then error(tostring(retained_error and retained_error.error and retained_error.error.message)) end
                test.eq(retained.definition_digest, before.definition_digest)
                test.eq(retained.policy_digest, before.policy_digest)
                test.eq(retained.plan_digest, before.plan_digest)
                test.eq(retained.catalog_generation, before.catalog_generation)
                local current, current_error = admission.resolve(DEFINITION, nil)
                if not current then error(tostring(current_error and current_error.error and current_error.error.message)) end
                test.is_true(current.definition_digest ~= before.definition_digest)
                test.is_true(current.policy_digest ~= before.policy_digest)
                test.is_true(current.plan_digest ~= before.plan_digest)
                test.is_true(current.catalog_generation > before.catalog_generation)
                test.eq(current.binding_digest, before.binding_digest)
                test.eq(current.profile_digest, before.profile_digest)
            end)
            definition_entry.data = original_definition
            policy_entry.data = original_policy
            local restoration = registry.snapshot():changes()
            restoration:update(definition_entry)
            restoration:update(policy_entry)
            local restored, restore_error = restoration:apply()
            if not restored then error("restore launch fixture: " .. tostring(restore_error)) end
            if not ok then error(tostring(failure)) end
        end)
        test.it("resolves a definition to one measured plan without effects", function()
            local plan = value(call("bee.tests.harness.admission:resolve", {definition_ref = DEFINITION}))
            test.eq(plan.launch_id, "claude-fixture")
            test.eq(plan.mode, "batch")
            test.eq(#(plan.plan_digest), 64)
            local again = value(call("bee.tests.harness.admission:resolve", {definition_ref = DEFINITION}))
            test.eq(again.plan_digest, plan.plan_digest)
            test.eq(code(call("bee.tests.harness.admission:resolve", {definition_ref = DEFINITION, mode = "window"})), "FORBIDDEN")
            test.eq(code(call("bee.tests.harness.admission:resolve", {definition_ref = "bee.harness.catalog:nothing"})), "NOT_FOUND")
            local entry = registry.get(DEFINITION)
            if not entry then error("definition") end
            local data = assert(bounds.object(entry.data))
            local original = data.title
            data.title = "Retitled fixture"
            apply(entry)
            local moved = value(call("bee.tests.harness.admission:resolve", {definition_ref = DEFINITION}))
            test.neq(moved.plan_digest, plan.plan_digest)
            data.title = original
            apply(entry)
        end)
        test.it("fences admission to the selected plan before creating a thread", function()
            local selected = value(call("bee.tests.harness.admission:resolve", {definition_ref = DEFINITION}))
            local policy_entry = registry.get(POLICY)
            if not policy_entry then error("launch policy") end
            local original_policy = policy_entry.data
            local changed_policy: {[string]: unknown} = {}
            for key, item in pairs(assert(bounds.object(original_policy))) do changed_policy[key] = item end
            changed_policy.stop_grace_ms = 23456

            local mismatch_request = fresh("plan-fenced")
            local ok, failure = pcall(function()
                policy_entry.data = changed_policy
                apply(policy_entry)
                local changed = value(call("bee.tests.harness.admission:resolve", {definition_ref = DEFINITION}))
                test.neq(changed.plan_digest, selected.plan_digest)

                local refused = call("bee.tests.harness.admission:admit", {request_id = mismatch_request, definition_ref = DEFINITION,
                    workspace_id = workspace, brief = "ping", expected_plan_digest = selected.plan_digest})
                test.eq(code(refused), "CONFLICT")
                test.eq(code(call("bee.threads.binding:get", {thread_id = "thread:" .. mismatch_request})), "NOT_FOUND")
            end)

            policy_entry.data = original_policy
            local restoration = registry.snapshot():changes()
            restoration:update(policy_entry)
            local restored, restore_error = restoration:apply()
            if not restored then error("restore launch policy: " .. tostring(restore_error)) end
            if not ok then error(tostring(failure)) end

            local restored_plan = value(call("bee.tests.harness.admission:resolve", {definition_ref = DEFINITION}))
            test.eq(restored_plan.plan_digest, selected.plan_digest)
            local matching_request = fresh("plan-matched")
            local matching = value(call("bee.tests.harness.admission:admit", {request_id = matching_request, definition_ref = DEFINITION,
                workspace_id = workspace, brief = "ping", expected_plan_digest = selected.plan_digest}))
            local matching_plan = assert(bounds.object(matching.plan))
            test.eq(matching_plan.plan_digest, selected.plan_digest)
            test.eq(matching.thread_id, "thread:" .. matching_request)
        end)
        test.it("rejects a malformed expected plan digest", function()
            local request_id = fresh("plan-malformed")
            local refused = call("bee.tests.harness.admission:admit", {request_id = request_id, definition_ref = DEFINITION,
                workspace_id = workspace, brief = "ping", expected_plan_digest = string.rep("A", 64)})
            test.eq(code(refused), "INVALID")
            test.eq(code(call("bee.threads.binding:get", {thread_id = "thread:" .. request_id})), "NOT_FOUND")
        end)
        fixture.restore_host()
    end)
end
return test.run_cases(define_tests)
