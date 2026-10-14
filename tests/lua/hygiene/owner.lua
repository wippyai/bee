local system = require("system")
local time = require("time")
local registry = require("registry")
local process = require("process")
local sql = require("sql")
local bounds = require("bounds")
local supervision = require("supervision")
local events = require("events")
local boot_gate = require("boot_gate")
local exec = require("exec")
local channel = require("channel")
local json = require("json")
type Object = {[string]: unknown}
type Snapshot = {processes: {[string]: Object}, names: {[string]: string}, entries: {[string]: boolean}, pending: {[string]: boolean}, owners: {[string]: boolean}, services: {[string]: boolean}?}
local M = {}
M.Snapshot = Snapshot

local function os_processes(): {[string]: Object}
    local executor = assert(exec.get("bee.tests.hygiene:executor"))
    local child = assert(executor:exec("python3 lua/hygiene/process_guard.py snapshot"))
    local stdout = assert(child:stdout_stream())
    assert(child:start())
    local output = ""
    while true do
        local chunk = stdout:read(4096)
        if not chunk or chunk == "" then break end
        output = output .. chunk
    end
    local result = assert(child:wait())
    stdout:close()
    executor:release()
    assert(result == 0, "OS process inspection failed")
    local rows = assert(bounds.object(assert(json.decode(output))))
    local processes: {[string]: Object} = {}
    for pid, actor in pairs(rows) do processes[pid] = assert(bounds.object(actor)) end
    return processes
end

local function sync_idle()
    local replies = assert(process.listen("bee.test.hygiene.sync", {message = true}))
    local peer = tostring(assert(process.registry.lookup("bee.sync", process.registry.LOCAL)))
    assert(process.send(peer, "bee.test.sync.idle", {topic = "bee.test.hygiene.sync"}))
    local reply = assert((replies:receive()))
    assert(tostring(reply:from()) == peer)
    process.unlisten(replies)
end

local function snapshot(): Snapshot
    local value: Snapshot = {processes = os_processes(), names = {}, entries = {}, pending = {}, owners = {}, services = {}}
    for _, host in ipairs(assert(system.hosts.list())) do
        for _, actor in ipairs(assert(system.hosts.processes(host.id))) do
            value.processes[actor.pid] = {source = actor.source, parent = actor.parent}
        end
    end
    for _, entry in ipairs(assert(registry.find({}))) do
        value.entries[entry.id] = true
        if entry.kind == "process.service" then
            local data = assert(bounds.object(entry.data))
            if type(data.process) == "string" then assert(value.services)[data.process] = true end
        end
    end
    local function registered(name: string)
        local pid = process.registry.lookup(name, process.registry.LOCAL)
        if pid then value.names[name] = tostring(pid) end
    end
    for _, entry in ipairs(assert(registry.find({["meta.type"] = "bee.process.demand"}))) do
        local spec = assert(bounds.object(entry.meta.demand))
        registered(assert(bounds.id(spec.name)))
        local current = assert(system.supervisor.state(entry.id))
        if current.status == "running" or current.status == "starting" then value.owners[entry.id] = true end
    end
    local db = assert(sql.get("bee:db"))
    for _, row in ipairs(assert(db:query("SELECT attempt_id FROM bee_placement_attempts"))) do
        registered("bee.harness.carrier/" .. tostring(row.attempt_id))
    end
    for _, row in ipairs(assert(db:query("SELECT session_ref FROM bee_sessions"))) do
        registered("bee.session.window/" .. tostring(row.session_ref))
    end
    local queries = {
        tests = "SELECT run_id AS id FROM bee_node_test_runs WHERE state IN ('pending','running')",
        receipts = "SELECT receipt_key AS id FROM bee_hive_receipts WHERE reply_json IS NULL",
        subscriptions = "SELECT subscription_id AS id FROM bee_thread_subscriptions WHERE closed_at IS NULL",
        intervals = "SELECT session_ref || '/' || trait_id || '/' || generation AS id FROM bee_session_trait_intervals WHERE end_sequence IS NULL",
        hooks = "SELECT invocation_id AS id FROM bee_session_hook_invocations WHERE state='pending'",
    }
    for name, query in pairs(queries) do
        for _, row in ipairs(assert(db:query(query))) do value.pending[name .. ":" .. tostring(row.id)] = true end
    end
    for _, entry in ipairs(assert(registry.find({["meta.type"] = "bee.approvals.effect-consumer"}))) do
        local destination = entry.meta.destination
        if type(destination) == "string" then
            for _, row in ipairs(assert(db:query("SELECT event_id AS id FROM bee_approval_events WHERE acknowledged_at IS NULL AND destination = ?", {destination}))) do
                value.pending["events:" .. tostring(row.id)] = true
            end
            for _, row in ipairs(assert(db:query("SELECT approval_id AS id FROM bee_approval_effects WHERE destination = ? AND state IN ('authorized','reserved','admitted','started')", {destination}))) do
                value.pending["effects:" .. tostring(row.id)] = true
            end
        end
    end
    for _, kind in ipairs({"native", "docker"}) do
        for _, row in ipairs(assert(supervision.rows(db, kind, math.maxinteger))) do
            value.pending["placement:" .. tostring(row.attempt_id)] = true
        end
    end
    db:release()
    return value
end

function M.compare(before: Snapshot, after: Snapshot, reported: {[string]: boolean}?): {string}
    local leaks: {string} = {}
    local used: {[string]: boolean} = {}
    for pid in pairs(after.processes) do if before.processes[pid] then used[pid] = true end end
    for pid, actor in pairs(after.processes) do
        local prior = before.processes[pid]
        if not prior then
            for previous_pid, previous in pairs(before.processes) do
                if not used[previous_pid] and previous.source == actor.source and (previous.parent == actor.parent or (before.services and before.services[tostring(actor.source)])) then
                    prior = previous
                    used[previous_pid] = true
                    break
                end
            end
        end
        if not prior then leaks[#leaks + 1] = "process " .. tostring(actor.source) .. " " .. pid end
    end
    for name in pairs(after.names) do if not before.names[name] then leaks[#leaks + 1] = "name " .. name end end
    for name in pairs(after.entries) do if not before.entries[name] then leaks[#leaks + 1] = "registry " .. name end end
    for name in pairs(after.pending) do if not before.pending[name] then leaks[#leaks + 1] = "pending " .. name end end
    for name in pairs(after.owners) do if not before.owners[name] then leaks[#leaks + 1] = "demand owner " .. name end end
    table.sort(leaks)
    if reported then
        local present: {[string]: boolean} = {}
        local fresh: {string} = {}
        for _, leak in ipairs(leaks) do
            present[leak] = true
            if not reported[leak] then fresh[#fresh + 1] = leak end
        end
        local retired: {string} = {}
        for leak in pairs(reported) do if not present[leak] then retired[#retired + 1] = leak end end
        for _, leak in ipairs(retired) do reported[leak] = nil end
        for leak in pairs(present) do reported[leak] = true end
        return fresh
    end
    return leaks
end

function M.reply(peer: string, leaks: {string})
    local sent, problem = process.send(peer, "bee.test.hygiene.reply", {leaks = leaks})
    assert(sent or tostring(problem) == "process not found", tostring(problem))
end

function M.main()
    assert(process.registry.register("bee.test.hygiene", process.pid(), process.registry.LOCAL))
    local requests = assert(process.listen("bee.test.hygiene", {message = true}))
    local lifecycle = assert(process.events())
    local updates = assert(events.subscribe("supervisor", "service.update"))
    assert(boot_gate.wait(function(): boolean return updates:channel():receive() ~= nil end))
    while assert(system.supervisor.state("bee:changes")).status ~= "running" do
        assert(updates:channel():receive(), "change source startup ended")
    end
    updates:close()
    local baseline: Snapshot? = nil
    local reported: {[string]: boolean} = {}
    while true do
        local message = assert((requests:receive()))
        local request = assert(bounds.object(message:payload():data()))
        if not baseline then
            local db = assert(sql.get("bee.tests.hygiene:db"))
            assert(db:execute("CREATE TABLE bee_test_suite_timings (entry_id TEXT PRIMARY KEY, seconds REAL NOT NULL, leaks_json TEXT NOT NULL, snapshots_json TEXT NOT NULL, body_seconds REAL NOT NULL, hygiene_seconds REAL NOT NULL)"))
            assert(db:execute("CREATE TABLE bee_test_memory_sessions (session TEXT PRIMARY KEY, owner TEXT NOT NULL, workspace TEXT NOT NULL)"))
            assert(db:execute("CREATE TABLE bee_test_memory_bindings (binding_id TEXT PRIMARY KEY, session TEXT NOT NULL)"))
            db:release()
            sync_idle()
            baseline = snapshot()
        end
        local inspected = time.now()
        local after: Snapshot? = nil
        if request.operation == "check" then
            local updates = assert(events.subscribe("supervisor", "service.update"))
            local monitored: {[string]: boolean} = {}
            while true do
                after = snapshot()
                local pending = false
                for name in pairs(after.pending) do if not assert(baseline).pending[name] then pending = true end end
                if pending then break end
                local draining = false
                for _, entry in ipairs(assert(registry.find({["meta.type"] = "bee.process.demand"}))) do
                    if not assert(baseline).owners[entry.id] and not reported["demand owner " .. entry.id] then
                        local spec = assert(bounds.object(entry.meta.demand))
                        local name = assert(bounds.id(spec.name))
                        local pid = process.registry.lookup(name, process.registry.LOCAL)
                        local state = assert(system.supervisor.state(entry.id))
                        if pid or state.status == "running" or state.status == "starting" or state.status == "stopping" then
                            draining = true
                            if pid and not monitored[tostring(pid)] then
                                assert(process.monitor(tostring(pid)))
                                monitored[tostring(pid)] = true
                            end
                        end
                    end
                end
                if not draining then break end
                local selected = channel.select({updates:channel():case_receive(), lifecycle:case_receive()})
                assert(selected.ok, "demand lifecycle observation ended")
            end
            for pid in pairs(monitored) do process.unmonitor(pid) end
            updates:close()
            sync_idle()
            after = snapshot()
        end
        local leaks = after and M.compare(assert(baseline), after, reported) or {}
        if request.operation == "check" then
            local identity, elapsed, body_elapsed = request.identity, request.elapsed, request.body_elapsed
            assert(type(identity) == "string" and type(elapsed) == "number" and type(body_elapsed) == "number")
            local db = assert(sql.get("bee.tests.hygiene:db"))
            local total = elapsed + time.now():sub(inspected):milliseconds() / 1000
            assert(db:execute("INSERT INTO bee_test_suite_timings VALUES (?, ?, ?, ?, ?, ?)", {identity, total, assert(json.encode(leaks)), assert(json.encode({before = assert(baseline).processes, after = assert(after).processes})), body_elapsed, total - body_elapsed}))
            db:release()
        end
        M.reply(tostring(message:from()), leaks)
    end
end
return M
