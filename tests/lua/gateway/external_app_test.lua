-- SPDX-License-Identifier: MIT
local test = require("test")
local process = require("process")
local system = require("system")
local channel = require("channel")
local time = require("time")
local tty = require("tty")
local client = require("client")
local sql = require("sql")
local json = require("json")
local bounds = require("bounds")
local external = require("external")
local gateway = require("gateway")
local funcs = require("funcs")
local security = require("security")
local app_scope = require("app_scope")
local function call(operation: string, request: {[string]: unknown}): {[string]: unknown}
    return assert(client.call(assert(system.node.id()), operation, request))
end
local function shows(view: tty.Viewport, width: integer, height: integer)
    local updates = assert(view:updates())
    local deadline = time.after("10s")
    while true do
        local snapshot = view:snapshot()
        if snapshot and snapshot.width == width and snapshot.height == height and #snapshot.rows == height
            and tty.text.plain(table.concat(snapshot.rows)):find("No external clients", 1, true) then
            for _, row in ipairs(snapshot.rows) do test.eq(tty.text.width(row), width) end
            return
        end
        local selected = channel.select({updates:case_receive(), deadline:case_receive()})
        assert(selected.channel ~= deadline, "MCP clients does not render after terminal input")
    end
end
local function await_text(view: tty.Viewport, needle: string, present: boolean?)
    local updates = assert(view:updates())
    local deadline = time.after("10s")
    while true do
        local snapshot = view:snapshot()
        local found = snapshot and tty.text.plain(table.concat(snapshot.rows)):find(needle, 1, true) ~= nil
        if found == (present ~= false) then return end
        local selected = channel.select({updates:case_receive(), deadline:case_receive()})
        assert(selected.channel ~= deadline, "MCP clients screen has no " .. needle .. ":\n" ..
            (snapshot and tty.text.plain(table.concat(snapshot.rows, "\n")) or "No screen"))
    end
end
local function key(view: tty.Viewport, kind: string, value: string?)
    assert(view:send({type = "key", action = "press", key_type = kind, key = value or ""}))
end
local function define_tests()
    test.describe("MCP clients application", function()
        test.it("keeps policy lookup and the private owner outside the application's admitted scope", function()
            local state = assert(client.state(call("watch", {})))
            local scope = app_scope.scope("bee.gateway.app:app")
            local actor = assert(security.new_actor("bee.application:" .. state.home .. ":external-boundary",
                {workspace_id = state.home, definition_id = "bee.gateway.app:app", definition_revision = "1", execution_generation = 1}))
            test.eq(scope:evaluate(actor, "security.policy.get", "bee.gateway.security:external_withdraw_policy"), "deny")
            test.eq(scope:evaluate(actor, "security.scope.create", "custom"), "deny")
            test.neq(scope:evaluate(actor, "security.policy_group.get", "bee.gateway.security:external_owner"), "allow")
            test.neq(scope:evaluate(actor, "funcs.call", "bee.gateway.binding:external_backend"), "allow")
            local executor = funcs.new():with_actor(actor):with_scope(scope)
            local reply = assert(bounds.object(executor:call("bee.gateway.binding:external_call", {operation = "list"})))
            test.eq(reply.ok, true)
            local invalid = assert(bounds.object(executor:call("bee.gateway.binding:external_call", {operation = "list", workspace_id = "another-workspace"})))
            test.eq(invalid.ok, false)
            test.eq(assert(bounds.object(invalid.error)).code, "INVALID")
            local other = assert(security.new_actor("bee.application:" .. state.home .. ":other-boundary",
                {workspace_id = state.home, definition_id = "bee.apps.library:app", definition_revision = "1", execution_generation = 1}))
            local refused = assert(bounds.object(funcs.new():with_actor(other):with_scope(scope)
                :call("bee.gateway.binding:external_call", {operation = "list"})))
            test.eq(refused.ok, false)
            test.eq(assert(bounds.object(refused.error)).code, "DENIED")
            call("leave", {})
        end)
        test.it("handles startup, keyboard, mouse and resize events from a real viewport", function()
            local state = assert(client.state(call("watch", {})))
            local opened = call("open", {app = "bee.gateway.app:app", desktop = state.desktop})
            local id = tostring(opened.id)
            local viewport = assert(tty.attach(tostring(call("attach", {id = id}).ref)))
            local ok, failure = pcall(function()
                assert(viewport:resize(100, 24))
                shows(viewport, 100, 24)
                assert(viewport:send({type = "key", action = "press", key_type = "down", key = ""}))
                assert(viewport:send({type = "key", action = "press", key_type = "runes", key = "r"}))
                assert(viewport:resize(80, 20))
                shows(viewport, 80, 20)
                assert(viewport:send({type = "mouse", action = "press", button = "left", x = 2, y = 3}))
                assert(viewport:resize(48, 16))
                shows(viewport, 48, 16)
                assert(viewport:send({type = "key", action = "press", key_type = "up", key = ""}))
                assert(viewport:resize(120, 30))
                shows(viewport, 120, 30)
            end)
            call("close", {id = id})
            viewport:close()
            call("leave", {})
            if not ok then error(tostring(failure)) end
        end)
        test.it("withdraws Escape and records exactly one Enter decision before revoking the reviewed client", function()
            local state = assert(client.state(call("watch", {})))
            local workspace = ""
            for _, desktop in ipairs(state.desktops) do if desktop.id == state.desktop then workspace = desktop.workspace end end
            assert(workspace ~= "")
            local listening = gateway.open({address = assert(gateway.endpoint())})
            assert(listening.ok, listening.error and listening.error.message or "Gateway did not open")
            local paired = external.request({workspace_id = workspace, name = "Keyboard client", caller = "keyboard-fixture"})
            assert(paired.ok, paired.error and (paired.error.code .. ": " .. paired.error.message) or "Pairing did not answer")
            local pairing = assert(bounds.object(paired.value))
            local client_id = assert(bounds.id(pairing.client_id))
            local opened = call("open", {app = "bee.gateway.app:app", desktop = state.desktop})
            local id = tostring(opened.id)
            local viewport = assert(tty.attach(tostring(call("attach", {id = id}).ref)))
            local db = assert(sql.get("bee:db"))
            local ok, failure = pcall(function()
                assert(viewport:resize(100, 24))
                await_text(viewport, "Keyboard client")
                key(viewport, "runes", "x")
                await_text(viewport, "Enter confirms")
                key(viewport, "esc")
                await_text(viewport, "Enter confirms", false)
                local requests = assert(db:query("SELECT state FROM bee_approval_requests WHERE json_extract(proposal_json, '$.payload.target.client_id') = ?", {client_id}))
                test.eq(#requests, 1)
                test.eq(requests[1].state, "withdrawn")
                local query = [[SELECT d.assurance_json FROM bee_approval_decisions d JOIN bee_approval_requests r ON r.approval_id = d.approval_id
                    WHERE json_extract(r.proposal_json, '$.payload.target.client_id') = ?]]
                test.eq(#assert(db:query(query, {client_id})), 0)
                key(viewport, "runes", "x")
                await_text(viewport, "Enter confirms")
                key(viewport, "enter")
                await_text(viewport, "revoked")
                local decisions = assert(db:query(query, {client_id}))
                test.eq(#decisions, 1)
                local assurance = assert(bounds.object(json.decode(tostring(decisions[1].assurance_json))))
                test.eq(assurance.gesture, "enter")
                test.eq(assurance.presentation, "inline")
                await_text(viewport, "Access revoked")
                local access = assert(db:query("SELECT state FROM bee_approval_requests WHERE approval_id = ?", {pairing.approval_id}))
                test.eq(#access, 1)
                test.eq(access[1].state, "withdrawn")
                key(viewport, "enter")
                assert(viewport:resize(101, 24))
                local updates = assert(viewport:updates())
                local deadline = time.after("10s")
                while true do
                    local shown = viewport:snapshot()
                    if shown and shown.width == 101 then break end
                    local changed = channel.select({updates:case_receive(), deadline:case_receive()})
                    assert(changed.channel ~= deadline, "MCP clients does not process the repeated Enter")
                end
                test.eq(#assert(db:query(query, {client_id})), 1)
            end)
            local requester = funcs.new():with_actor(assert(security.new_actor(assert(bounds.id(pairing.subject)), {workspace_id = workspace})))
            local raw = requester:call("bee.approvals.binding:read", {approval_id = pairing.approval_id})
            local read = assert(bounds.object(raw))
            assert(read.ok == true)
            local pending = assert(bounds.object(read.value))
            local withdrew = assert(bounds.object(requester:call("bee.approvals.binding:withdraw", {approval_id = pairing.approval_id,
                expected_revision = pending.revision, proposal_digest = pending.proposal_digest, reviewed_digest = pending.reviewed_digest})))
            assert(withdrew.ok == true)
            call("close", {id = id})
            viewport:close()
            local prior: {[string]: boolean} = {}
            for _, instance in ipairs(state.running) do prior[instance.id] = true end
            for _, instance in ipairs(assert(client.state(call("list", {}))).running) do
                if instance.app == "bee.approvals.inbox.app:app" and not prior[instance.id] then call("close", {id = instance.id}) end
            end
            call("leave", {})
            db:release()
            external.revoke(client_id, workspace)
            if not ok then error(tostring(failure)) end
        end)
    end)
end
return test.run_cases(define_tests)
