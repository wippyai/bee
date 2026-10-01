-- MIT. The Sessions catalog delegates route availability to host driver locate.
local test = require("test")
local catalog = require("catalog")
local registry = require("registry")
local funcs = require("funcs")
local machine = require("machine")
local materialization = require("materialization")

type Object = {[string]: unknown}
type Candidate = {ref: string, kind: string, status: string, reasons: {string}}
type Page = {items: {Candidate}, next: string?, complete: boolean, unavailable_count: integer,
    diagnostics: {Object}}

local function listed(include_unavailable: boolean?): Page
    local page, failure = catalog.list({kind = "definition", include_unavailable = include_unavailable}, "catalog-test-workspace")
    if not page then error(failure and failure.message or "Sessions catalog returned no page") end
    return page :: Page
end

local function define_tests()
    test.describe("Sessions catalog route readiness", function()
        test.it("retains a saved profile's identity and title beside its definition", function()
            local saved = assert(funcs.call("bee.harness.profiles:call", {operation = "put", workspace_id = "saved-profile-workspace",
                profile_id = "catalog-saved-selection", expected_revision = 0, idempotency_key = "catalog-saved-selection",
                profile = {schema_revision = "bee.agent-profile@2", name = "Selected container profile", definition_ref = "bee.driver.claude:default_window", driver_binding_ref = "bee.driver.claude:binding", provider = {}, bee = {mcp = {}}}}))
            test.is_true((saved :: Object).ok == true)
            local page, page_fault = catalog.list({include_unavailable = true}, "saved-profile-workspace")
            if not page then error(page_fault and page_fault.message or "catalog list failed") end
            local found = false
            for _, candidate in ipairs(page.items) do
                if candidate.kind == "profile" and candidate.title == "Selected container profile" then
                    test.eq(candidate.ref, "catalog-saved-selection")
                    test.eq(candidate.title, "Selected container profile")
                    found = true
                end
            end
            test.is_true(found)
        end)
        test.it("registers every operation of the host-selected Threads journal", function()
            local binding = assert(registry.get("bee.threads:journal_local"))
            local data = binding.data :: {contracts: {{contract: string, methods: {[string]: string}}}}
            for _, contract in ipairs(data.contracts) do
                if contract.contract == "bee.threads:journal" then
                    for name, target in pairs(contract.methods) do
                        local entry = registry.get(target)
                        if not entry then error("journal operation is missing: " .. name) end
                        test.eq(entry.kind, "function.lua")
                    end
                end
            end
        end)
        test.it("keeps an existing machine login ready in the default launch home", function()
            local found: Candidate? = nil
            for _, candidate in ipairs(listed(true).items) do
                if candidate.ref == "bee.driver.claude:default_window" then found = candidate end
            end
            test.not_nil(found)
            if found and found.status ~= "ready" then error(table.concat(found.reasons, "; ")) end
            test.eq(found and found.status, "ready")
            local entry = assert(registry.get("bee.driver.claude:default_window"))
            local definition = entry.data :: {binding_ref: string, profile_id: string, policy_ref: string}
            local request: machine.Request = {thread_id = "catalog-login-thread", action_id = "catalog-login-action",
                attempt_id = "catalog-login-attempt", owner_id = "bee.test.catalog-login", owner_incarnation = 1,
                binding_ref = definition.binding_ref, profile_id = definition.profile_id, policy_ref = definition.policy_ref,
                brief = "", resources = {}, environment = {}}
            local plan, plan_error = machine.plan({
                call = function(target: string, input: unknown): (unknown, string?)
                    local reply, err = funcs.call(target, input)
                    return reply, err and tostring(err) or nil
                end,
                send = function(_target: string, _topic: string, _input: unknown) end,
                self_pid = function(): string return "catalog-login-test" end,
                now_ms = function(): integer return 0 end,
                key = function(): string return "catalog-login-key" end,
            }, request)
            if not plan then error(tostring(plan_error)) end
            test.eq(plan.placement_request.environment_refs.HOME, "bee.env:machine_home")
            test.is_nil(materialization.prepare_login_notice(plan.placement_request, "/unused-private-home"))
        end)
        test.it("hides unavailable definitions by default and explains them when requested", function()
            local ready = listed(nil)
            local explicitly_ready = listed(false)
            test.eq(#ready.items, #explicitly_ready.items)
            for _, candidate in ipairs(ready.items) do test.eq(candidate.status, "ready") end

            local all = listed(true)
            local claude: Candidate? = nil
            local unavailable = 0
            for _, candidate in ipairs(all.items) do
                if candidate.ref == "bee.driver.claude:default_window" then claude = candidate end
                if candidate.status ~= "ready" then
                    unavailable = unavailable + 1
                    test.is_true(#candidate.reasons > 0)
                end
            end
            test.not_nil(claude)
            test.eq(all.unavailable_count, unavailable)
            test.is_true(#all.items >= #ready.items)
        end)
    end)
end

return test.run_cases(define_tests)
