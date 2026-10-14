-- SPDX-License-Identifier: MIT
local test = require("test")
local sql = require("sql")
local process = require("process")
local events = require("events")
local channel = require("channel")
local time = require("time")
local system = require("system")
local bounds = require("bounds")
local dispatch = require("dispatch")
local demand = require("demand")
local resources = require("resources")
local principals = require("principals")
local function stopped(id: string, updates: events.Subscription)
    local deadline = time.after("10s")
    while true do
        local owner = assert(system.supervisor.state(id))
        if owner.desired == "stopped" and (owner.status == "stopped" or owner.status == "exited") then return end
        local selected = channel.select({updates:channel():case_receive(), deadline:case_receive()})
        assert(selected.channel ~= deadline, "consumer owner does not stop: " .. tostring(owner.status))
    end
end
local function define_tests()
    test.describe("Registered effect consumer demand", function()
        for _, target in ipairs({
            {destination = "gateway.installation", name = "bee.gateway.external", service = "bee.gateway.service:external_service"},
            {destination = "gateway.publication", name = "bee.gateway.external", service = "bee.gateway.service:external_service"},
            {destination = "gov.activation", name = "bee.gov.activation_worker", service = "bee.gov.service:activation_service"},
            {destination = "credentials.configuration", name = "bee.approvals.configuration_effect_worker", service = "bee.credentials.service:configuration_service"},
        }) do
            test.it("starts the absent owner for " .. target.destination .. " and drains it again", function()
                local updates = assert(events.subscribe("supervisor", "service.update"))
                local accepted = assert(process.listen(demand.ACCEPTED, {message = true}))
                local db = assert(sql.get("bee.approvals:effect_demand_db"))
                local ok, failure = pcall(function()
                    test.eq(process.registry.lookup(target.name, process.registry.LOCAL), nil)
                    test.eq(assert(resources.consumer(target.destination)).worker_name, target.name)
                    assert(db:execute("CREATE TABLE IF NOT EXISTS bee_approval_events (seq INTEGER PRIMARY KEY, event_id TEXT, approval_id TEXT, revision INTEGER, destination TEXT, acknowledged_at INTEGER)"))
                    assert(db:execute("DELETE FROM bee_approval_events"))
                    assert(db:execute("INSERT INTO bee_approval_events VALUES (1, 'demand-event', 'demand-approval', 2, ?, NULL)", {target.destination}))
                    test.eq(assert(dispatch.deliver(db, nil)), 1)
                    local selected = channel.select({accepted:case_receive(), time.after("10s"):case_receive()})
                    test.eq(selected.channel, accepted, "absent consumer wake is lost")
                    local supervisor = assert(process.registry.lookup(demand.SUPERVISOR, process.registry.LOCAL))
                    test.eq(tostring(selected.value:from()), tostring(supervisor))
                    local receipt = assert(bounds.object(selected.value:payload():data()))
                    test.eq(receipt.name, target.name)
                    test.eq(receipt.request_id, "demand-event")
                    test.is_true(type(receipt.pid) == "string")
                    stopped(target.service, updates)
                    test.eq(process.registry.lookup(target.name, process.registry.LOCAL), nil)
                end)
                db:release(); process.unlisten(accepted); updates:close()
                if not ok then error(tostring(failure)) end
            end)
        end
        test.it("recovers configuration effects and unacknowledged receipts through boot backlog discovery", function()
            local updates = assert(events.subscribe("supervisor", "service.update"))
            local deliveries = assert(process.listen("bee.test.effect_delivery", {message = true}))
            assert(process.registry.register("bee.test.effect_delivery"))
            local db = assert(sql.get("bee:db"))
            local requester = principals.caller("configuration-backlog-" .. principals.key(), {"bee.security.approvals:approval_request_policy"})
            local probe = principals.caller("bee.credentials.configuration_worker", {
                "bee.process:backlog_policy", "bee.credentials.security:configuration_effect_owner_policy",
                "bee.credentials.security:configuration_discovery_policy"})
            assert(process.registry.register("bee.test.effect_dispatch"))
            local id: string? = nil
            local event = "configuration-backlog-" .. principals.key()
            local function pending(): boolean
                local value, problem = probe:call("bee.credentials.service:backlog")
                test.is_nil(problem)
                return value == true
            end
            local function recover(label: string)
                test.eq(process.registry.lookup("bee.approvals.configuration_effect_worker", process.registry.LOCAL), nil, label .. " before recovery")
                assert(process.send(tostring(assert(process.registry.lookup(demand.SUPERVISOR, process.registry.LOCAL))), demand.TOPIC, {action = "bee.test.boot_backlog"}))
                local deadline = time.after("10s")
                while true do
                    local selected = channel.select({deliveries:case_receive(), deadline:case_receive()})
                    test.eq(selected.channel, deliveries, "configuration boot backlog is lost")
                    local value = assert(bounds.object(selected.value:payload():data()))
                    if value.name == "bee.approvals.configuration_effect_worker" then
                        test.eq(tostring(selected.value:from()), tostring(assert(process.registry.lookup(demand.SUPERVISOR, process.registry.LOCAL))))
                        test.eq(#assert(bounds.array(value.requests, 64)), 0)
                        test.is_true(assert(bounds.integer(value.generation)) > 0)
                        break
                    end
                end
                stopped("bee.credentials.service:configuration_service", updates)
                test.eq(process.registry.lookup("bee.approvals.configuration_effect_worker", process.registry.LOCAL), nil, label .. " after quiet stop")
            end
            local ok, failure = pcall(function()
                test.is_false(pending())
                local raw, problem = requester:call("bee.approvals.binding:request", {
                    workspace_id = "configuration-backlog", idempotency_key = principals.key(), request_kind = "permission",
                    policy = "configuration-setup", contract_version = 2, presentation = "inbox",
                    continuation = {destination = "credentials.configuration", effect_id = event, context = {}},
                    proposal = {kind = "operation", ref = "bee.credentials.binding:configuration_setup", revision = "1",
                        input_digest = string.rep("a", 64), payload = {workspace_id = "configuration-backlog", provider = "synthetic", base_path = "config.json"}},
                    prompt = {text = "Synthetic configuration backlog"}})
                test.is_nil(problem)
                local reply = assert(bounds.object(raw))
                test.eq(reply.ok, true)
                id = assert(bounds.id(assert(bounds.object(reply.value)).approval_id))
                test.is_false(pending(), "pending review does not start an effect owner")
                assert(db:execute("UPDATE bee_approval_requests SET state = 'decided', decision = 'denied', decider_id = 'configuration-backlog-approver', decided_at = updated_at WHERE approval_id = ?", {id}))
                test.is_true(pending())
                recover("effect queue")
                assert(db:execute("UPDATE bee_approval_requests SET effect_completed_at = updated_at, effect_result_json = '{\"ok\":false}' WHERE approval_id = ?", {id}))
                test.is_false(pending())
                local tx = assert(db:begin())
                for index = 1, 64 do
                    assert(tx:execute("INSERT INTO bee_approval_events (event_id, approval_id, revision, kind, destination, body_json, created_at, acknowledged_at) SELECT ?, approval_id, revision, 'approval.denied', 'credentials.configuration', '{}', updated_at, updated_at FROM bee_approval_requests WHERE approval_id = ?", {event .. "-ack-" .. tostring(index), id}))
                end
                assert(tx:commit())
                test.is_false(pending())
                assert(db:execute("INSERT INTO bee_approval_events (event_id, approval_id, revision, kind, destination, body_json, created_at) SELECT ?, approval_id, revision, 'approval.denied', 'credentials.configuration', '{}', updated_at FROM bee_approval_requests WHERE approval_id = ?", {event, id}))
                test.is_true(pending(), "completed receipt still needs its event acknowledged")
                recover("receipt event")
                assert(db:execute("UPDATE bee_approval_events SET acknowledged_at = created_at WHERE event_id = ?", {event}))
                test.is_false(pending())
            end)
            if id then assert(db:execute("UPDATE bee_approval_requests SET effect_completed_at = updated_at, effect_result_json = '{\"ok\":false}' WHERE approval_id = ?", {id})) end
            assert(db:execute("UPDATE bee_approval_events SET acknowledged_at = created_at WHERE event_id = ?", {event}))
            process.registry.unregister("bee.test.effect_dispatch")
            process.registry.unregister("bee.test.effect_delivery")
            process.unlisten(deliveries); db:release(); updates:close()
            if not ok then error(tostring(failure)) end
        end)
        test.it("retains completed boot gates across repeated demand for every owner", function()
            local updates = assert(events.subscribe("supervisor", "service.update"))
            local accepted = assert(process.listen(demand.ACCEPTED, {message = true}))
            local db = assert(sql.get("bee:db"))
            local function starts(): integer
                local rows = assert(db:query("SELECT COUNT(*) AS count FROM bee_test_recovery_starts"))
                return assert(bounds.integer(rows[1].count))
            end
            local before = starts()
            local boot = assert(system.supervisor.state("wippy.bootloader:bootloader.service")).started_at
            test.is_true(before > 0)
            local ok, failure = pcall(function()
                for _, target in ipairs({
                    {name = "bee.gov.activation_worker", service = "bee.gov.service:activation_service"},
                    {name = "bee.node.tests", service = "bee.node.service:tests_service"},
                    {name = "bee.gateway.external", service = "bee.gateway.service:external_service"},
                    {name = "bee.placement.docker/image", service = "bee.placement.docker.service:image_owner_service"},
                    {name = "bee.placement.sweeper", service = "bee.placement.native.service:sweeper_service"},
                    {name = "bee.approvals.configuration_effect_worker", service = "bee.credentials.service:configuration_service"},
                }) do
                    for index = 1, 3 do
                        assert(demand.dispatch(target.name, {request_id = "boot-gate-" .. tostring(index)}))
                        local selected = channel.select({accepted:case_receive(), time.after("10s"):case_receive()})
                        test.eq(selected.channel, accepted, target.name)
                        stopped(target.service, updates)
                        test.eq(starts(), before, target.name .. " demand reruns boot restoration")
                        test.eq(assert(system.supervisor.state("wippy.bootloader:bootloader.service")).started_at, boot,
                            target.name .. " demand reruns the bootloader")
                        test.eq(assert(system.supervisor.state("bee:changes")).status, "running")
                    end
                end
            end)
            db:release(); process.unlisten(accepted); updates:close()
            if not ok then error(tostring(failure)) end
        end)
    end)
end
return test.run_cases(define_tests)
