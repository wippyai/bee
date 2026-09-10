-- MIT. Real session actor remains responsive while its status owner refuses.
local test = require("test")
local process = require("process")
local security = require("security")
local channel = require("channel")
local time = require("time")
local harness = require("harness")
local function define_tests()
    test.describe("Session status event loop", function()
        test.it("reads as a member, refuses a foreign thread and still accepts shutdown", function()
            local actor_id = "bee.test.session-member"
            local principal = harness.principal(actor_id, harness.ALL)
            local thread_id = harness.thread(principal, "Session membership")
            local foreign = harness.principal("bee.test.session-foreign", harness.ALL)
            local foreign_thread = harness.thread(foreign, "Other owner")
            local workspace = "0123456789abcdef0123456789abcdef"
            local scenes = assert(process.listen("bee.desktop.scene", {message = true}))
            local events = assert(process.events())
            local policy, policy_error = security.policy("bee:session_policy")
            if not policy then error(tostring(policy_error)) end
            local scope = security.new_scope({policy})
            local owner = tostring(process.pid())
            local session = tostring(assert(process.with_options({}):with_context({["bee.workspace_owner"] = owner,
                ["bee.workspace_id"] = workspace}):with_actor(security.new_actor(actor_id)):with_scope(scope):spawn_monitored("bee.session:main", "bee:workers", owner, 80, 24, {}, nil)))
            local ok, err = pcall(function()
                local deadline = time.after("3s")
                local ready = channel.select({scenes:case_receive(), deadline:case_receive()})
                if ready.channel ~= scenes then error("Session did not become ready") end
                assert(process.send(session, "bee.desktop.command", {version = 1, op = "add", id = "tab", instance_id = "instance", workspace_id = workspace, title = "App"}))
                local added = channel.select({scenes:case_receive(), deadline:case_receive()})
                if added.channel ~= scenes then error("Session did not add tab") end
                assert(process.send(session, "bee.desktop.bindings", {version = 1, workspace_id = workspace, revision = 1,
                    items = {{tab_id = "tab", instance_id = "instance", thread_id = thread_id}}}))
                local readable = false
                while not readable do
                    local selected = channel.select({scenes:case_receive(), deadline:case_receive()})
                    if selected.channel ~= scenes then error("Member could not read status") end
                    local raw: unknown = selected.value:payload():data()
                    if type(raw) == "table" and type(raw.statuses) == "table" then
                        local item = raw.statuses[1]
                        if type(item) == "table" and type(item.value) == "table" then
                            readable = item.value.availability == "ready"
                        end
                    end
                end
                assert(process.send(session, "bee.desktop.bindings", {version = 1, workspace_id = workspace, revision = 2,
                    items = {{tab_id = "tab", instance_id = "instance", thread_id = foreign_thread}}}))
                local unavailable = false
                while not unavailable do
                    local selected = channel.select({scenes:case_receive(), deadline:case_receive()})
                    if selected.channel ~= scenes then error("Missing unavailable status") end
                    local raw: unknown = selected.value:payload():data()
                    if type(raw) == "table" and type(raw.statuses) == "table" then
                        local item = raw.statuses[1]
                        if type(item) == "table" and type(item.value) == "table" then
                            unavailable = item.value.availability == "unavailable"
                        end
                    end
                end
                assert(process.send(session, "bee.desktop.command", {version = 1, op = "shutdown"}))
                while true do
                    local selected = channel.select({events:case_receive(), deadline:case_receive()})
                    if selected.channel ~= events then error("Session shutdown blocked") end
                    if selected.value.kind == process.event.EXIT and tostring(selected.value.from) == session then
                        local result: unknown = selected.value.result
                        if type(result) == "table" and result.error ~= nil then error("Session failed: " .. tostring(result.error)) end
                        break
                    end
                end
            end)
            process.terminate(session)
            process.unlisten(scenes)
            if not ok then error(err) end
        end)
    end)
end
return require("test").run_cases(define_tests)
