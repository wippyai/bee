-- MIT. A CLI harness route is discovered from the host's activated driver
-- bindings, never from a name listed in core: an installed driver package's
-- binding routes framework agents once the host activates it, refused
-- before that, and its declared accepts_model capability alone decides
-- whether a route may carry an agent's model.
local test = require("test")
local principals = require("principals")
local bounds = require("bounds")
local registry = require("registry")
local agent_resolver = require("agent_resolver")
local ACTIVATION = "bee.harness.launch:harness_activation"
local WITH_MODEL = "bee.harness.catalog:fixture_open_cli_binding"
local WITHOUT_MODEL = "bee.harness.catalog:fixture_open_cli_no_model_binding"
local function pinned(): registry.Snapshot
    local snapshot, err = registry.snapshot()
    if not snapshot then error(tostring(err)) end
    return snapshot
end
-- Activates one fixture driver binding for the body, restoring the host's
-- activation declaration afterward whatever the body does.
local function with_activated(binding_ref: string, body: () -> ())
    local entry = assert(registry.get(ACTIVATION))
    local original = entry.data
    local data = assert(bounds.object(original))
    local bindings = principals.strings(data.bindings)
    local changed_bindings: {string} = {}
    for _, item in ipairs(bindings) do changed_bindings[#changed_bindings + 1] = item end
    changed_bindings[#changed_bindings + 1] = binding_ref
    local changed: {[string]: unknown} = {}
    for key, item in pairs(data) do changed[key] = item end
    changed.bindings = changed_bindings
    entry.data = changed
    local changes = registry.snapshot():changes()
    changes:update(entry)
    local applied, apply_error = changes:apply()
    if not applied then error("activate " .. binding_ref .. ": " .. tostring(apply_error)) end
    local ok, failure = pcall(body)
    entry.data = original
    local restore = registry.snapshot():changes()
    restore:update(entry)
    local restored, restore_error = restore:apply()
    if not restored then error("restore activation: " .. tostring(restore_error)) end
    if not ok then error(tostring(failure)) end
end
local function closure(model: string?): agent_resolver.Closure
    return {ref = "bee.harness.catalog:fixture_agent", digest = string.rep("a", 64), agent_digest = string.rep("a", 64),
        prompt = "p", context = {}, instructions = "p", traits = {}, tools = {}, tool_names = {}, delegates = {},
        memory = {}, model = model, tuning = {}, declinable = {}}
end
local function define_tests()
    test.describe("Agent resolver open CLI routes", function()
        test.it("refuses a driver package the host has not activated", function()
            local checked, code, message = agent_resolver.check_route(pinned(), closure(nil),
                {driver_id = "fixture_open_cli", model_map = {}, admitted_delegates = {}})
            test.is_nil(checked)
            test.eq(code, "INVALID")
            test.eq(message, "driver fixture_open_cli is not an activated CLI or native harness route")
        end)
        test.it("refuses an unknown driver id even when some other binding is activated", function()
            with_activated(WITH_MODEL, function()
                local checked, code = agent_resolver.check_route(pinned(), closure(nil),
                    {driver_id = "never_installed", model_map = {}, admitted_delegates = {}})
                test.is_nil(checked)
                test.eq(code, "INVALID")
            end)
        end)
        test.it("routes an installed driver package the moment the host activates its binding", function()
            with_activated(WITH_MODEL, function()
                local checked, code, message = agent_resolver.check_route(pinned(), closure(nil),
                    {driver_id = "fixture_open_cli", model_map = {}, admitted_delegates = {}})
                if not checked then error(tostring(code) .. ": " .. tostring(message)) end
                test.is_nil(checked.model)
                test.eq(#checked.declined, 0)
            end)
        end)
        test.it("maps an agent model through a route whose binding declares accepts_model", function()
            with_activated(WITH_MODEL, function()
                local checked, code, message = agent_resolver.check_route(pinned(), closure("claude-3"),
                    {driver_id = "fixture_open_cli", model_map = {["claude-3"] = "claude-3-opus"}, admitted_delegates = {}})
                if not checked then error(tostring(code) .. ": " .. tostring(message)) end
                test.eq(checked.model, "claude-3-opus")
            end)
        end)
        test.it("refuses a model through a route whose binding declares no accepts_model", function()
            with_activated(WITHOUT_MODEL, function()
                local checked, code, message = agent_resolver.check_route(pinned(), closure(nil),
                    {driver_id = "fixture_open_cli_no_model", model_map = {}, admitted_delegates = {}})
                if not checked then error(tostring(code) .. ": " .. tostring(message)) end
                local refused, refused_code, refused_message = agent_resolver.check_route(pinned(), closure("claude-3"),
                    {driver_id = "fixture_open_cli_no_model", model_map = {["claude-3"] = "claude-3-opus"}, admitted_delegates = {}})
                test.is_nil(refused)
                test.eq(refused_code, "UNSUPPORTED_CAPABILITY")
                test.eq(refused_message, "driver fixture_open_cli_no_model takes no model mapping for agent model claude-3")
            end)
        end)
    end)
end
return test.run_cases(define_tests)
