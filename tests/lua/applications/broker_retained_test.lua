-- SPDX-License-Identifier: MIT
local test = require("test")
local process = require("process")
local channel = require("channel")
local security = require("security")
local bounds = require("bounds")
local appearance = require("appearance")
local fixture = require("fixture")
local harness = require("harness")
local identity = require("identity")
local interaction = require("interaction")
local WORKSPACE = string.rep("e", 32)
local function define_tests()
    test.describe("Retained application fault isolation", function()
        test.it("keeps the broker ready and reports an exact alias rejection and an unavailable app", fixture.case(function(scope: fixture.State)
            local owner = tostring(process.pid())
            local instance = "retained-invalid"
            local attester = harness.principal("retained-attester", {"bee.security.threads:application_thread_alias_policy"}, WORKSPACE)
            test.is_true((attester:call("register_app_alias", {
                stable = assert(identity.stable(WORKSPACE, "bee.console.app:app")).id,
                instance = "bee.application:" .. WORKSPACE .. ":" .. instance,
                workspace_id = WORKSPACE, definition_id = "bee.console.app:app"})).ok)
            local questions = assert(process.listen("bee.interaction.state", {message = true}))
            scope.cleanup[#scope.cleanup + 1] = function() assert(process.unlisten(questions)) end
            local broker = tostring(assert(process.with_context({["bee.workspace_owner"] = owner,
                ["bee.workspace_id"] = WORKSPACE}):with_scope(security.new_scope({
                assert(security.policy("bee.security.desktop:broker_policy")),
                assert(security.policy("bee.security:core_spawn_boundary"))}))
                :spawn_monitored("bee.apps:broker", "bee:workers", owner, appearance.defaults(), {
                    {instance_id = instance, definition_id = "bee.settings.app:app"},
                    {instance_id = "retained-missing", definition_id = "removed.app:app"}})))
            scope.brokers[broker] = true
            test.eq(tostring(scope.catalogs:receive():from()), broker)
            local ready, reported = false, false
            while not ready or not reported do
                local selected = channel.select({scope.ready:case_receive(), questions:case_receive(), scope.events:case_receive()})
                test.is_true(selected.ok)
                if selected.channel == scope.events then
                    local event = selected.value
                    if event.kind == process.event.EXIT and tostring(event.from) == broker then
                        scope.brokers[broker] = nil
                        error("retained record killed broker: " .. tostring(event.result and event.result.error))
                    end
                elseif selected.channel == scope.ready then ready = true
                else
                    local specs = assert(interaction.snapshot(selected.value:payload():data()))
                    if #specs == 2 then
                        local messages: {[string]: string} = {}
                        for _, spec in ipairs(specs) do messages[spec.instance_id] = spec.message end
                        test.eq(messages[instance], "application instance is attested for another app")
                        test.eq(messages["retained-missing"], "Retained application is not admitted: removed.app:app")
                        reported = true
                    end
                end
            end
            assert(process.send(broker, "bee.app.request", {version = 1, request_id = "retained-good", op = "open",
                workspace_id = WORKSPACE, definition_id = "bee.settings.app:app"}))
            while true do
                local selected = channel.select({scope.replies:case_receive(), scope.events:case_receive()})
                assert(selected.ok and selected.channel == scope.replies, "broker exited during independent open")
                local reply = assert(bounds.object(selected.value:payload():data()))
                if reply.request_id == "retained-good" then test.eq(reply.error_code, ""); break end
            end
        end))
    end)
end
return test.run_cases(define_tests)
