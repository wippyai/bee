-- MIT. The Sessions catalog delegates route availability to host driver locate.
local test = require("test")
local principals = require("principals")
local bounds = require("bounds")
local catalog = require("catalog")
local registry = require("registry")
local funcs = require("funcs")
local machine = require("machine")
local materialization = require("materialization")
local admission = require("admission")

type Object = {[string]: unknown}
type Candidate = {ref: string, kind: string, status: string, reasons: {string}}
type Page = {items: {Candidate}, next: string?, complete: boolean, unavailable_count: integer,
    diagnostics: {Object}}

local function listed(include_unavailable: boolean?): Page
    local page, failure = catalog.list({kind = "definition", include_unavailable = include_unavailable}, "catalog-test-workspace")
    if not page then error(failure and failure.message or "Sessions catalog returned no page") end
    return page
end

local function define_tests()
    test.describe("Sessions catalog route readiness", function()
        test.it("retains a saved profile's identity and title beside its definition", function()
            local saved = assert(funcs.call("bee.harness.binding:call", {operation = "put", workspace_id = "saved-profile-workspace",
                profile_id = "catalog-saved-selection", expected_revision = 0, idempotency_key = "catalog-saved-selection",
                profile = {schema_revision = "bee.agent-profile@3", name = "Selected container profile", definition_ref = "bee.driver.claude.profiles:default_window", driver_binding_ref = "bee.driver.claude.binding:binding", provider = {}, bee = {mcp = {}}}}))
            test.is_true((assert(bounds.object(saved))).ok == true)
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
            local binding = assert(registry.get("bee.threads.binding:journal_local"))
            local data = assert(bounds.object(binding.data))
            for _, contract in ipairs(principals.objects(data.contracts)) do
                if contract.contract == "bee.threads:journal" then
                    for name, target in pairs(assert(bounds.object(contract.methods))) do
                        assert(type(target) == "string")
                        local entry = registry.get(target)
                        if not entry then error("journal operation is missing: " .. name) end
                        test.eq(entry.kind, "function.lua")
                    end
                end
            end
        end)
        test.it("offers installed interactive drivers and options before login", function()
            local ref = "bee.driver.claude.descriptor:cli"
            local original = assert(registry.get(ref))
            local edited = assert(registry.get(ref))
            local data = assert(bounds.object(edited.data))
            data.login_evidence = {command = "fixture login", any_of = {{kind = "file_exists", paths = {".fixture-no-login"}}}}
            local options = assert(bounds.object(data.options))
            local fields = assert(bounds.object(options.fields))
            local model = assert(bounds.object(fields.model))
            model.support = {config_schema_ref = "fixture:model"}
            local changes = assert(registry.snapshot()):changes()
            changes:update(edited)
            assert(changes:apply())
            local ok, failure = pcall(function()
                local probe = assert(bounds.object(assert(funcs.call("bee.harness.binding:locate_probe",
                    {binding_ref = "bee.driver.claude.binding:binding", profile_id = "window"}))))
                local result = assert(bounds.object(probe.result))
                test.eq(result.status, "unconfigured")
                local capabilities = assert(bounds.object(result.capabilities))
                local model_capability = assert(bounds.object(capabilities["provider.model"]))
                test.eq(model_capability.supported, true)
                local found = false
                for _, candidate in ipairs(listed(false).items) do
                    if candidate.ref == "bee.driver.claude.profiles:default_window" then
                        test.eq(candidate.status, "ready")
                        found = true
                    end
                end
                test.is_true(found, "installed signed-out interactive driver is hidden")
            end)
            local restore = assert(registry.snapshot()):changes()
            restore:update(original)
            assert(restore:apply())
            if not ok then error(tostring(failure)) end
        end)
        test.it("leaves PTY authentication to the CLI and probes headless login", function()
            local ref = "bee.driver.claude.descriptor:cli"
            local original = assert(registry.get(ref))
            local edited = assert(registry.get(ref))
            local data = assert(bounds.object(edited.data))
            data.login_evidence = {command = "fixture login", any_of = {{kind = "auth_status",
                argv = {"--version"}, success_exit_code = 0, timeout_ms = 3000}}}
            local changes = assert(registry.snapshot()):changes()
            changes:update(edited)
            assert(changes:apply())
            local ok, failure = pcall(function()
                local function login(profile: string): Object
                    local probe = assert(bounds.object(assert(funcs.call("bee.harness.binding:locate_probe",
                        {binding_ref = "bee.driver.claude.binding:binding", profile_id = profile}))))
                    return assert(bounds.object(assert(bounds.object(probe.result)).login))
                end
                test.is_nil(login("window").exists)
                test.eq(login("session").exists, true)
            end)
            local restore = assert(registry.snapshot()):changes()
            restore:update(original)
            assert(restore:apply())
            if not ok then error(tostring(failure)) end
        end)
        test.it("keeps an existing machine login ready in the default launch home", function()
            local found: Candidate? = nil
            for _, candidate in ipairs(listed(true).items) do
                if candidate.ref == "bee.driver.claude.profiles:default_window" then found = candidate end
            end
            test.not_nil(found)
            if found and found.status ~= "ready" then error(table.concat(found.reasons, "; ")) end
            test.eq(found and found.status, "ready")
            local entry = assert(registry.get("bee.driver.claude.profiles:default_window"))
            local definition = assert(bounds.object(entry.data))
            assert(type(definition.binding_ref) == "string" and type(definition.profile_id) == "string" and type(definition.policy_ref) == "string")
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
                if candidate.ref == "bee.driver.claude.profiles:default_window" then claude = candidate end
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
