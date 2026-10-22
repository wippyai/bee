-- MIT. Agents launch behaviour.
local test = require("test")
local principals = require("principals")
local bounds = require("bounds")
local fixture = require("fixture")
local AGENT_DEFINITION = fixture.AGENT_DEFINITION
local AGENT_POLICY = fixture.AGENT_POLICY
local AGENT_REVIEWER = fixture.AGENT_REVIEWER
local AGENT_TRAIT = fixture.AGENT_TRAIT
local fresh = fixture.fresh
local workspace_id = fixture.workspace_id
local scope = fixture.scope
local call = fixture.call
local profile_call = fixture.profile_call
local value = fixture.value
local code = fixture.code
local with_entry = fixture.with_entry
local refusal_message = fixture.refusal_message
local function define_tests()
    test.describe("Launch agents", function()
        local workspace = fixture.prepare()
        test.it("resolves an agent route to a hashed closure and admits its exact tools, prompt and mapped model", function()
            local first = assert(bounds.object(value(call("bee.tests.harness.launch:resolve", {definition_ref = AGENT_DEFINITION}))))
            test.eq(first.agent_ref, AGENT_REVIEWER)
            local digest = first.agent_digest
            test.eq(type(digest), "string")
            test.eq(#(digest), 64)
            test.eq(first.agent_model, "claude-mapped")
            local declined = principals.items(first.declined_tuning)
            test.eq(#declined, 1)
            test.eq(declined[1], "temperature")
            local agent_tools = principals.items(first.agent_tools)
            test.eq(#agent_tools, 2)
            test.eq(agent_tools[1], "FileReport")
            test.eq(agent_tools[2], "FileRead")
            local second = assert(bounds.object(value(call("bee.tests.harness.launch:resolve", {definition_ref = AGENT_DEFINITION}))))
            test.eq(second.agent_digest, digest)
            test.eq(second.plan_digest, first.plan_digest)
            local admitted = value(call("bee.tests.harness.launch:admit", {request_id = fresh("agent-admit"),
                definition_ref = AGENT_DEFINITION, workspace_id = workspace, brief = "review fixture"}))
            test.eq(admitted.plan.agent_digest, digest)
            local carrier_request = assert(bounds.object(admitted.request))
            local preferences = assert(bounds.object(carrier_request.preferences))
            local tools = principals.items(preferences.mcp_tools)
            test.eq(#tools, 2)
            test.eq(tools[1], "FileReport")
            test.eq(tools[2], "FileRead")
            test.eq((assert(bounds.object(preferences.options))).model, "claude-mapped")
            local instructions = tostring(preferences.instructions)
            test.is_true(instructions:find("Review the supplied change.", 1, true) ~= nil)
            test.is_true(instructions:find("Use the approved repository tools.", 1, true) ~= nil)
            test.is_true(instructions:find("repo: workspace", 1, true) ~= nil)
        end)
        test.it("refuses a changed agent reference before admission", function()
            local selected = assert(bounds.object(value(call("bee.tests.harness.launch:resolve", {definition_ref = AGENT_DEFINITION}))))
            with_entry(AGENT_REVIEWER, function(data) data.prompt = "Changed review prompt." end, function()
                local changed = assert(bounds.object(value(call("bee.tests.harness.launch:resolve", {definition_ref = AGENT_DEFINITION}))))
                test.neq(changed.plan_digest, selected.plan_digest)
                test.neq(changed.agent_digest, selected.agent_digest)
                local refused = call("bee.tests.harness.launch:admit", {request_id = fresh("agent-changed"), definition_ref = AGENT_DEFINITION,
                    workspace_id = workspace, brief = "review fixture", expected_plan_digest = selected.plan_digest})
                test.eq(code(refused), "CONFLICT")
            end)
        end)
        test.it("never reduces a trait to its prompt", function()
            with_entry(AGENT_TRAIT, function(data) data.wrappers = {"bee.harness.catalog:agent_wrapper"} end, function()
                local refused = call("bee.tests.harness.launch:resolve", {definition_ref = AGENT_DEFINITION})
                test.eq(code(refused), "UNSUPPORTED_CAPABILITY")
                local message = refusal_message(refused)
                test.is_true(message:find("agent_repository_trait", 1, true) ~= nil)
                test.is_true(message:find("wrappers", 1, true) ~= nil)
            end)
        end)
        test.it("refuses unknown agent fields", function()
            with_entry(AGENT_REVIEWER, function(data) data.bogus_field = true end, function()
                test.eq(code(call("bee.tests.harness.launch:resolve", {definition_ref = AGENT_DEFINITION})), "INVALID")
            end)
        end)
        test.it("refuses a model the host never mapped and a driver that takes no model", function()
            with_entry(AGENT_REVIEWER, function(data) data.model = "unmapped-model" end, function()
                local refused = call("bee.tests.harness.launch:resolve", {definition_ref = AGENT_DEFINITION})
                test.eq(code(refused), "UNSUPPORTED_CAPABILITY")
                test.is_true(refusal_message(refused):find("unmapped-model", 1, true) ~= nil)
            end)
            with_entry("bee.drivers.codex.binding:binding", function(meta) meta.accepts_model = false end, function()
                with_entry(AGENT_DEFINITION, function(data)
                    data.binding_ref = "bee.drivers.codex.binding:binding"
                    data.profile_id = "batch"
                end, function()
                    local refused = call("bee.tests.harness.launch:resolve", {definition_ref = AGENT_DEFINITION})
                    test.eq(code(refused), "UNSUPPORTED_CAPABILITY")
                    test.is_true(refusal_message(refused):find("codex", 1, true) ~= nil)
                end)
            end, "meta")
        end)
        test.it("declines only owner-permitted tuning hints", function()
            with_entry(AGENT_REVIEWER, function(data) data.tuning = {temperature = 0.2, top_k = 1} end, function()
                local refused = call("bee.tests.harness.launch:resolve", {definition_ref = AGENT_DEFINITION})
                test.eq(code(refused), "UNSUPPORTED_CAPABILITY")
                test.is_true(refusal_message(refused):find("top_k", 1, true) ~= nil)
            end)
        end)
        test.it("refuses delegates outside host admission", function()
            with_entry(AGENT_POLICY, function(data) data.agent_delegates = {} end, function()
                local refused = call("bee.tests.harness.launch:resolve", {definition_ref = AGENT_DEFINITION})
                test.eq(code(refused), "FORBIDDEN")
                test.is_true(refusal_message(refused):find("agent_helper", 1, true) ~= nil)
            end)
        end)
        test.it("refuses profile writes with tools or models outside the agent host policy", function()
            for _, profile in ipairs({
                {provider = {}, bee = {mcp = {{tool = "thread_read", scope = {}}}}},
                {provider = {model = "sneaky"}, bee = {mcp = {}}},
            }) do
                local refused = profile_call({operation = "put", workspace_id = workspace, profile_id = fresh("agent-profile"),
                    expected_revision = 0, idempotency_key = fresh("save"), profile = {schema_revision = "bee.agent-profile@3", name = "Outside ceiling",
                        definition_ref = AGENT_DEFINITION, driver_binding_ref = "bee.drivers.claude.binding:binding", provider = profile.provider, bee = profile.bee}})
                test.eq(refused.ok, false)
                test.eq(refused.code, "DENIED")
            end
        end)
        fixture.restore_host()
    end)
end
return test.run_cases(define_tests)
