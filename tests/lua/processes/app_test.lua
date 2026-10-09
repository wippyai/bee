local test = require("test")
local client = require("client")
local system = require("system")
local tty = require("tty")
local channel = require("channel")
local time = require("time")
local sql = require("sql")
local json = require("json")
local bounds = require("bounds")
local function call(operation: string, request: {[string]: unknown}): {[string]: unknown}
    return assert(client.call(assert(system.node.id()), operation, request))
end
local function key(view: tty.Viewport, kind: string, value: string?)
    assert(view:send({type = "key", action = "press", key_type = kind, key = value or ""}))
end
local function screen(view: tty.Viewport): string
    local snapshot = view:snapshot()
    return snapshot and tty.text.plain(table.concat(snapshot.rows, "\n")) or ""
end
local function await(view: tty.Viewport, ready: (string) -> boolean): string
    local updates = assert(view:updates())
    local deadline = time.after("10s")
    while true do
        local shown = screen(view)
        if ready(shown) then return shown end
        local changed = channel.select({updates:case_receive(), deadline:case_receive()})
        assert(changed.channel ~= deadline, "Process Manager did not reach the expected screen:\n" .. shown)
    end
end
local function selected(shown: string): string
    return shown:match("\n%s*PID%s+([^%s]+)") or ""
end
local function define_tests()
    test.describe("Process Manager confirmation", function()
        test.it("withdraws Escape and records one Enter decision for the exact stopped execution", function()
            local state = assert(client.state(call("watch", {})))
            local target = call("open", {app = "bee.tests.node:broker_probe", desktop = state.desktop, args = {arguments = {"accept"}}})
            local target_id = tostring(target.id)
            local execution = ""
            local target_pid = ""
            for _, instance in ipairs(assert(client.state(call("list", {}))).running) do
                if instance.id == target_id then execution = assert(instance.execution_id); target_pid = instance.pid end
            end
            assert(execution ~= "" and target_pid ~= "")
            local manager = call("open", {app = "bee.apps.processes:app", desktop = state.desktop})
            local id = tostring(manager.id)
            local view = assert(tty.attach(tostring(call("attach", {id = id}).ref)))
            local db = assert(sql.get("bee:db"))
            local ok, failure = pcall(function()
                assert(view:resize(120, 30))
                await(view, function(shown) return selected(shown) ~= "" end)
                key(view, "runes", "p")
                local shown = await(view, function(text) return text:find("Paused", 1, true) ~= nil end)
                for _ = 1, 2048 do
                    local prior = selected(shown)
                    if prior == target_pid then break end
                    key(view, "down")
                    shown = await(view, function(text) return selected(text) ~= prior end)
                end
                test.eq(selected(shown), target_pid)
                local query = [[SELECT d.assurance_json FROM bee_approval_decisions d JOIN bee_approval_requests r ON r.approval_id = d.approval_id
                    WHERE json_extract(r.proposal_json, '$.payload.action') = 'app.stop' AND json_extract(r.proposal_json, '$.payload.target.execution_id') = ?]]
                key(view, "delete")
                await(view, function(text) return text:find("Enter confirms", 1, true) ~= nil end)
                key(view, "esc")
                await(view, function(text) return text:find("Enter confirms", 1, true) == nil end)
                test.eq(#assert(db:query(query, {execution})), 0)
                local requests = assert(db:query("SELECT state FROM bee_approval_requests WHERE json_extract(proposal_json, '$.payload.target.execution_id') = ?", {execution}))
                test.eq(#requests, 1)
                test.eq(requests[1].state, "withdrawn")
                key(view, "delete")
                await(view, function(text) return text:find("Enter confirms", 1, true) ~= nil end)
                key(view, "enter")
                await(view, function(text) return text:find("Application ended", 1, true) ~= nil end)
                local decisions = assert(db:query(query, {execution}))
                test.eq(#decisions, 1)
                local assurance = assert(bounds.object(json.decode(tostring(decisions[1].assurance_json))))
                test.eq(assurance.gesture, "enter")
                test.eq(assurance.presentation, "inline")
                for _, instance in ipairs(assert(client.state(call("list", {}))).running) do test.neq(instance.id, target_id) end
                test.eq(#assert(db:query([[SELECT g.grant_id FROM bee_approval_grants g JOIN bee_approval_requests r ON r.approval_id = g.approval_id
                    WHERE json_extract(r.proposal_json, '$.payload.target.execution_id') = ?]], {execution})), 0)
                key(view, "enter")
                assert(view:resize(121, 30))
                await(view, function() local snapshot = view:snapshot(); return snapshot ~= nil and snapshot.width == 121 end)
                test.eq(#assert(db:query(query, {execution})), 1)
            end)
            for _, instance in ipairs(assert(client.state(call("list", {}))).running) do
                if instance.id == id or instance.id == target_id then call("close", {id = instance.id, force = true}) end
            end
            view:close()
            db:release()
            call("leave", {})
            if not ok then error(tostring(failure)) end
        end)
    end)
end
return test.run_cases(define_tests)
