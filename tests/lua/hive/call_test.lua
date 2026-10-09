-- MIT
local test = require("test")
local registry = require("registry")
local bounds = require("bounds")
local model = require("model")
local grants = require("grants")
local outbound = require("outbound")
local protocol = require("protocol")
local system = require("system")

type Object = {[string]: unknown}
local APP = "sdk.copy:app"
local WORKSPACE = "012345678901234567890123456789ab"
local function request(): Object
    return {node = "runner", workspace_id = "project", application = APP, service = "test-sdk", operation = "run",
        arguments = {configuration = "project-ci"}, timeout = "1s", idempotency_key = "project-run-1"}
end
local function installed(target: string?): Object
    local words = assert(model.decode(assert(registry.get("bee.capability:catalog"))))
    local resolved = assert(model.resolve(words, "hive.call", {nodes = {"runner"}, workspaces = {"project"},
        applications = {target or APP}, services = {"test-sdk"}, operations = {"run"}}))
    return {workspace_id = WORKSPACE, application = APP, capabilities = resolved}
end
local function define_tests()
    test.describe("granted Hive call", function()
        test.it("preserves the source deadline across receiver queueing and caps it by the remaining TTL", function()
            test.eq(protocol.deadline(1791505000000000000, 200000000, 1791505000100000000), 1791505000100000000)
            test.eq(protocol.deadline(1000, 200, 1050), 1050)
            test.eq(protocol.deadline(1100, 200, 1050), 1050)
            test.eq(protocol.deadline(1000, 200, 5000), 1200)
            test.eq(protocol.deadline(1000, 200, nil), 1200)
            test.is_nil(protocol.deadline(1000, 200, "forged"))
            test.is_nil(protocol.deadline(1000, -1, 1050))
        end)
        test.it("materializes only the host facade permission", function()
            local words = assert(model.decode(assert(registry.get("bee.capability:catalog"))))
            local proposed = assert(grants.propose(words, "bee.tests.hive:outbound", APP, {{id = "sdk.copy:call",
                expected_kind = "security.policy", targets = {APP}, capability_request = {capability = "hive.call",
                    parameters = {nodes = {"runner"}, workspaces = {"project"}, applications = {APP},
                        services = {"test-sdk"}, operations = {"run"}}, catalog_revision = words.revision,
                    template_revision = 1, target = APP, path = ".security.policies +="}}}))
            local policy = assert(bounds.object(proposed.policies[1].data.policy))
            test.eq(policy.actions[1], "funcs.call")
            test.eq(#policy.actions, 1)
            test.eq(policy.resources[1], "bee.hive.binding:call")
            test.eq(#policy.resources, 1)
        end)
        test.it("bounds every destination field by the caller's live grant", function()
            local record = installed()
            local caller = {workspace_id = WORKSPACE, definition_id = APP}
            test.not_nil(outbound.authorize(request(), record, caller, true))
            local default_workspace = request()
            default_workspace.workspace_id = nil
            test.eq(assert(outbound.authorize(default_workspace, record, caller, true)).args.workspace_id, "project")
            for _, field in ipairs({"node", "workspace_id", "application", "service", "operation"}) do
                local changed = request()
                changed[field] = "another"
                local allowed, err = outbound.authorize(changed, record, caller, true)
                test.is_nil(allowed)
                test.contains(tostring(err), "grant")
            end
            test.is_nil(outbound.authorize(request(), record, caller, false))
            test.is_nil(outbound.authorize(request(), record, {workspace_id = "another", definition_id = APP}, true))
        end)
        test.it("bounds immutable source identities and destination-approved aliases", function()
            local caller = {workspace_id = WORKSPACE, definition_id = APP}
            local identity = request()
            identity.application = {source_node = "author", source_workspace = "project", component = "vendor/test-sdk"}
            test.not_nil(outbound.authorize(identity, installed("author/project/vendor/test-sdk"), caller, true))
            identity.application.component = "vendor/other"
            test.is_nil(outbound.authorize(identity, installed("author/project/vendor/test-sdk"), caller, true))
            local aliased = request()
            aliased.application = {alias = "project-sdk"}
            test.not_nil(outbound.authorize(aliased, installed("alias/project-sdk"), caller, true))
        end)
        test.it("rejects wildcard destinations and malformed deadlines", function()
            local words = assert(model.decode(assert(registry.get("bee.capability:catalog"))))
            test.is_nil(model.resolve(words, "hive.call", {nodes = {"*"}, workspaces = {"project"},
                applications = {APP}, services = {"test-sdk"}, operations = {"run"}}))
            for _, timeout in ipairs({"0s", "-1s", "31s", "nonsense"}) do
                local changed = request()
                changed.timeout = timeout
                test.is_nil(outbound.authorize(changed, installed(), {workspace_id = WORKSPACE, definition_id = APP}, true))
            end
        end)
        test.it("rejects untrusted senders and malformed or oversized correlated replies", function()
            local reply = {ok = true, value = {result = false, output = {type = "boolean"}, revision = "1"}}
            test.is_nil(protocol.decode_reply(reply, "attacker", "supervisor"))
            test.not_nil(protocol.decode_reply(reply, "supervisor", "supervisor"))
            test.is_nil(protocol.decode_reply({ok = true, value = {}, error = "spoof"}, "supervisor", "supervisor"))
            test.is_nil(protocol.decode_reply({ok = false}, "supervisor", "supervisor"))
            test.is_nil(protocol.decode_reply({ok = true, value = {blob = string.rep("x", 262145)}}, "supervisor", "supervisor"))
            test.is_nil(outbound.result({ok = true, value = {result = 7, output = {type = "string"}, revision = "1"}}))
            test.eq(outbound.result(reply), false)
        end)
        test.it("ignores a correlated reply from a different process", function()
            local node = assert(system.node.id())
            test.is_true(assert(protocol.call(node, "node.list", {}, "5s")).ok)
            local reply, err = protocol.call(node, "node.list", {}, "100ms", true)
            test.is_nil(reply)
            test.contains(tostring(err), "outcome unknown")
        end)
        test.it("reports an unanswered application deadline as outcome unknown", function()
            local reply, err = protocol.call(assert(system.node.id()), "parked.never", {}, "20ms", true)
            test.is_nil(reply)
            test.contains(tostring(err), "outcome unknown")
        end)
    end)
end
return test.run_cases(define_tests)
