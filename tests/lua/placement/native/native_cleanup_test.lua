-- MIT. Native placement cleanup regressions.
local test = require("test")
local bounds = require("bounds")
local principals = require("principals")
local process = require("process")
local channel = require("channel")
local time = require("time")
local registry = require("registry")
local service = require("service")
local store = require("store")
local protocol = require("protocol")
local native_fixture = require("native_fixture")

local function cleanup_tests()
    test.describe("Native placement cleanup", function()
        local measured = native_fixture.value(service.capabilities())
        local capability = tostring(measured.capability)
        local observation = tostring(measured.exit_observation)
        test.it("sweeps live attempts in bounded batches that make progress and survives a sweeper restart", function()
            local ids: {string} = {}
            for index = 1, 3 do
                -- Keep the children live until this case stops them. Their
                -- liveness must not depend on how fast a loaded host sweeps.
                local request = native_fixture.launch({"sh", "-c", "exec tail -f /dev/null"}, "direct_process")
                ids[index] = request.attempt_id
                native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", request))
                test.eq(native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "start", {attempt_id = ids[index]})).execution_state, "running")
            end
            -- Each sweep takes at most the bound; every live attempt is reached
            -- within a bounded number of sweeps, and an attempt a sweep settled
            -- as uncertain or exited is not swept again.
            local previous_bound = service.SWEEP_BOUND
            service.SWEEP_BOUND = 2
            local db = assert(store.open())
            local rows = assert(db:query("SELECT COUNT(*) AS total FROM bee_placement_attempts"))
            db:release()
            local retained = assert(bounds.integer(rows[1].total))
            local sweep_bound = math.ceil(retained / service.SWEEP_BOUND)
            local function touched_count(): integer
                local total = 0
                for _, id in ipairs(ids) do
                    local page = native_fixture.value(native_fixture.call(native_fixture.OWNER, "evidence", {attempt_id = id, limit = 64}))
                    for _, item in ipairs(principals.objects(page.evidence)) do
                        if tostring(item.kind):find("^reconcile%.") then
                            total = total + 1
                            break
                        end
                    end
                end
                return total
            end
            local sweeps = 0
            while sweeps == 0 or (touched_count() < 3 and sweeps < sweep_bound) do
                local swept = native_fixture.value(service.sweep())
                test.is_true((swept.reconciled) <= 2)
                for _, outcome in ipairs(principals.objects(swept.outcomes)) do
                    test.is_true(outcome.ok == true, "sweep " .. tostring(outcome.attempt_id) .. ": " .. tostring(outcome.code))
                end
                sweeps = sweeps + 1
            end
            service.SWEEP_BOUND = previous_bound
            test.eq(touched_count(), 3)
            -- The independently scheduled sweeper may have reconciled a row
            -- before this process calls sweep, including all three rows.
            local before = process.registry.lookup(service.SWEEPER_NAME)
            if not before then error("sweeper is not registered") end
            assert(process.terminate(tostring(before)))
            local restarted = native_fixture.wait_for(function()
                local now = process.registry.lookup(service.SWEEPER_NAME)
                return now ~= nil and tostring(now) ~= tostring(before)
            end, 10000)
            test.is_true(restarted)
            for _, id in ipairs(ids) do native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "stop", {attempt_id = id, mode = "forced"})) end
        end)
        if capability == "process_group" then
            test.it("records a refused cleanup with its reason", function()
                local prepared = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", native_fixture.launch({"sh", "-c", "true"}, "process_group")))
                native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "start", {attempt_id = prepared.attempt_id}))
                if not native_fixture.wait_for(function()
                    return (native_fixture.value(native_fixture.call(native_fixture.OWNER, "status", {attempt_id = prepared.attempt_id})).attempt).execution_state == "exited"
                end, 8000) then error("grouped attempt did not exit") end
                -- A stored state without its runtime completion source and
                -- without the group its child led cannot authorize cleanup.
                local db = store.open()
                if not db then error("store") end
                local completion_source = assert(store.attempt(db, prepared.attempt_id)).exit_source
                test.not_nil(completion_source)
                local recorded_row = assert(store.row(db, prepared.attempt_id))
                local recorded_group = recorded_row.pgid
                test.not_nil(recorded_group)
                local _, clear_error = db:execute("UPDATE bee_placement_attempts SET exit_source = NULL, pgid = NULL WHERE attempt_id = ?", {prepared.attempt_id})
                db:release()
                if clear_error then error("clear completion source: " .. tostring(clear_error)) end
                local refused = native_fixture.call(native_fixture.OWNER, "cleanup", {attempt_id = prepared.attempt_id})
                test.eq(refused.error and refused.error.code, "CONFLICT")
                local reason = "cleanup requires runtime completion: runtime exit not observed"
                test.eq(refused.error and refused.error.message, reason)
                local recorded = false
                local page = native_fixture.value(native_fixture.call(native_fixture.OWNER, "evidence", {attempt_id = prepared.attempt_id, limit = 64}))
                for _, item in ipairs(principals.objects(page.evidence)) do
                    if item.kind == "cleanup.refused" and item.detail == reason then recorded = true end
                end
                test.is_true(recorded, table.concat(native_fixture.kinds(prepared.attempt_id), ","))
                local after = native_fixture.value(native_fixture.call(native_fixture.OWNER, "status", {attempt_id = prepared.attempt_id})).attempt
                test.eq(after.cleanup_state, "pending")
                -- Restore the observed proof after the missing-proof assertion so preparers can retire.
                db = assert(store.open())
                assert(db:execute("UPDATE bee_placement_attempts SET exit_source = ?, pgid = ? WHERE attempt_id = ?", {completion_source, recorded_group, prepared.attempt_id}))
                db:release()
                local cleaned = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "cleanup", {attempt_id = prepared.attempt_id}))
                test.eq(cleaned.cleanup_state, "complete")
            end)
            test.it("keeps a lost owner's outcome uncertain while its group has members, without reconstructing PID authority", function()
                local request = native_fixture.launch({"sh", "-c", "sleep 8"}, "process_group")
                local prepared = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", request))
                native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "start", {attempt_id = prepared.attempt_id}))
                local db = store.open()
                if not db then error("store") end
                local row = store.row(db, prepared.attempt_id)
                local runner = tostring(row and row.runner_pid)
                local _, clear_error = db:execute("UPDATE bee_placement_attempts SET runner_pid = NULL WHERE attempt_id = ?", {prepared.attempt_id})
                db:release()
                if clear_error then error("clear runner: " .. tostring(clear_error)) end
                local before = native_fixture.value(native_fixture.call(native_fixture.OWNER, "status", {attempt_id = prepared.attempt_id}))
                local live = before.liveness
                test.is_false(live.observed, "a missing owner must not trigger PID inspection")
                test.eq(native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "reconcile", {attempt_id = prepared.attempt_id})).execution_state, "uncertain")
                assert(process.monitor(runner))
                local events = assert(process.events())
                assert(process.terminate(runner))
                local deadline = time.after("5s")
                while true do
                    local selected = channel.select({events:case_receive(), deadline:case_receive()})
                    assert(selected.ok and selected.channel == events, "runner EXIT not delivered")
                    local event = selected.value
                    if event.kind == process.event.EXIT and tostring(event.from) == runner then break end
                end
                -- The runner's exit ends the child it owned; the empty
                -- recorded group, not the pid, proves the tree gone.
                local outcome = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "reconcile", {attempt_id = prepared.attempt_id}))
                test.eq(outcome.execution_state, "exited")
                test.eq(outcome.exit_source, "reconcile")
                test.is_true(native_fixture.has(native_fixture.kinds(prepared.attempt_id), "group.ended"))
                local cleaned = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "cleanup", {attempt_id = prepared.attempt_id}))
                test.eq(cleaned.cleanup_state, "complete")
                process.unmonitor(runner)
            end)
            test.it("removes the grandchild with the group on stop", function()
                local request = native_fixture.launch({"sh", "-c", "sleep 8 & echo child:$!; wait"}, "process_group")
                local prepared = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", request))
                local outputs = assert(process.listen(protocol.TOPIC_OUTPUT, {message = true}))
                native_fixture.call(native_fixture.OWNER, "attach", {attempt_id = prepared.attempt_id, recipient = process.pid(), generation = 1})
                native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "start", {attempt_id = prepared.attempt_id}))
                local grandchild = ""
                local deadline = time.after("10s")
                while grandchild == "" do
                    local selected = channel.select({outputs:case_receive(), deadline:case_receive()})
                    if not selected.ok or selected.channel == deadline then break end
                    local data = assert(bounds.object(selected.value:payload():data()))
                    grandchild = tostring(data.data or ""):match("child:(%d+)") or ""
                end
                test.neq(grandchild, "")
                local stopped = native_fixture.call(native_fixture.OWNER, "stop", {attempt_id = prepared.attempt_id, mode = "forced"})
                if not stopped.ok then
                    local status = native_fixture.value(native_fixture.call(native_fixture.OWNER, "status", {attempt_id = prepared.attempt_id})).attempt
                    local page = native_fixture.value(native_fixture.call(native_fixture.OWNER, "evidence", {attempt_id = prepared.attempt_id, limit = 64}))
                    local lines: {string} = {}
                    for _, item in ipairs(principals.objects(page.evidence)) do lines[#lines + 1] = tostring(item.kind) .. ": " .. tostring(item.detail) end
                    error("stop refused: " .. tostring(stopped.error and stopped.error.message) .. "; execution " .. status.execution_state .. " exit " .. tostring(status.exit and status.exit.code) .. " exit_source " .. tostring(status.exit_source) .. " grandchild alive " .. tostring(native_fixture.alive(grandchild)) .. "; evidence: " .. table.concat(lines, " | "))
                end
                if not native_fixture.wait_for(function()
                    return (native_fixture.value(native_fixture.call(native_fixture.OWNER, "status", {attempt_id = prepared.attempt_id})).attempt).execution_state == "exited"
                end, 8000) then error("forced stop did not end the child") end
                test.eq(native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "reconcile", {attempt_id = prepared.attempt_id})).execution_state, "exited")
                test.is_true(native_fixture.wait_for(function() return not native_fixture.alive(grandchild) end, 5000))
                -- The stop intent is on record before the runner's exit
                -- observation, however fast the runner sees the kill land.
                local order: {string} = {}
                for _, item in ipairs(principals.objects(native_fixture.value(native_fixture.call(native_fixture.OWNER, "evidence", {attempt_id = prepared.attempt_id, limit = 64})).evidence)) do
                    if item.kind == "stop.requested" or item.kind == "child.exited" then order[#order + 1] = tostring(item.kind) end
                end
                test.eq(table.concat(order, ","), "stop.requested,child.exited")
                local cleaned = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "cleanup", {attempt_id = prepared.attempt_id}))
                test.eq(cleaned.cleanup_state, "complete")
                process.unlisten(outputs)
            end)
        end
    end)
end

return {cleanup = native_fixture.suite(cleanup_tests)}
