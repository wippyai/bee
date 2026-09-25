-- SPDX-License-Identifier: MIT
-- The host starts one managed agent in the desktop's own workspace with the
-- person's written spec as its brief, waits for the attempt to end and prints
-- what the agent reported over its bound thread. The operator holds no
-- delivery, approval or overlay authority: the agent's gateway tools and the
-- shipped host profiles are the whole path.
local funcs = require("funcs")
local security = require("security")
local process = require("process")
local channel = require("channel")
local time = require("time")
local json = require("json")
local io = require("io")
local env = require("env")
local bounds = require("bounds")

type Object = {[string]: unknown}

local DEFINITION = "bee.workspace_app_probe:agent"
local THREAD = "workspace-app-authoring"
local ACTOR = "bee.workspace_app.operator"

local executor = funcs.new()

-- The operator stands in for the Agent window, which runs under a principal
-- bound to its workspace; launch setup and grants are authorized only there.
local function bind(workspace_id: string)
    local actor, actor_error = security.new_actor(ACTOR, {workspace_id = workspace_id})
    if not actor then error("bind operator: " .. tostring(actor_error)) end
    local bound, bound_error = funcs.new():with_actor(actor)
    if not bound then error("bind operator: " .. tostring(bound_error)) end
    executor = bound
end

local function reply(target: string, request: unknown): Object
    local result, err = executor:call(target, request)
    if err then error(target .. ": " .. tostring(err)) end
    local answer = bounds.object(result)
    if not answer or answer.ok ~= true then error(target .. ": " .. tostring(json.encode(answer))) end
    return answer
end

local function call(target: string, request: unknown): Object
    local value = bounds.object(reply(target, request).value)
    if not value then error("missing value from " .. target) end
    return value
end

local function required(id: string): string
    local value = bounds.text(env.get(id), 65536)
    if not value or value == "" then error(id .. " is not set") end
    return value
end

local function listener_ready()
    for _ = 1, 150 do
        local raw, address_error = funcs.call("bee.gateway.registry:address", {})
        local address = not address_error and bounds.object(raw) or nil
        if address and type(address.address) == "string" then return end
        time.sleep("100ms")
    end
    error("MCP listener did not become ready")
end

local function await_exit(pid: string)
    local monitored, monitor_error = process.monitor(pid)
    if not monitored then error(tostring(monitor_error)) end
    local events = process.events()
    if not events then error("process events unavailable") end
    local deadline = time.after("1200s")
    while true do
        local selected = channel.select({events:case_receive(), deadline:case_receive()})
        if not selected.ok or selected.channel == deadline then error("managed attempt exceeded 1200s") end
        local event = selected.value
        if event.kind == process.event.EXIT and tostring(event.from) == pid then
            if event.result and event.result.error then error("managed carrier failed: " .. tostring(event.result.error)) end
            return
        end
    end
end

-- The scripted agent writes its report as one stderr line; the carrier keeps
-- stderr on the bound thread as a stream observation. A live provider writes
-- none, and its work is judged by the staged plan alone.
local function agent_report(): Object?
    local cursor = 0
    for _ = 1, 64 do
        local page = call("bee.threads.service:read_after", {thread_id = THREAD, cursor = cursor, limit = 64})
        for _, raw in ipairs((page.records or {}) :: {unknown}) do
            local record = bounds.object(raw)
            local body = record and bounds.object(record.body)
            local data = body and bounds.object(body.data)
            local content = data and bounds.object(data.content)
            local text = content and bounds.text(content.text, 65536)
            if record and record.kind == "observation" and data and data.code == "stderr" and text then
                local start = text:find("gateway:", 1, true)
                if start then
                    local decoded, decode_error = json.decode(text:sub(start + 8))
                    local report = bounds.object(decoded)
                    if decode_error or not report then error("agent report is unreadable: " .. text) end
                    return report
                end
            end
        end
        if page.has_more ~= true then break end
        local next_cursor = bounds.count(page.scanned_through)
        if not next_cursor or next_cursor <= cursor then error("invalid thread page progress") end
        cursor = next_cursor
    end
    return nil
end

local function main()
    local workspace_id = required("bee.workspace_app_probe:workspace")
    local brief = required("bee.workspace_app_probe:brief")
    bind(workspace_id)
    listener_ready()
    local plan = call("bee.harness.launch:resolve", {definition_ref = DEFINITION})
    reply("bee.harness.launch:setup", {workspace_id = workspace_id, definition_ref = DEFINITION,
        expected_plan_digest = plan.plan_digest})
    call("bee.threads.service:create", {thread_id = THREAD, idempotency_key = "create-" .. THREAD,
        title = "Tally, from its written spec"})
    local started = call("bee.harness.launch:start", {request_id = "workspace-app-author",
        definition_ref = DEFINITION, workspace_id = workspace_id, thread_id = THREAD, brief = brief})
    await_exit(tostring(started.carrier))
    local report = agent_report()
    io.print("WORKSPACE_APP_AUTHORED " .. (report and tostring(json.encode(report)) or "{}"))
end

return {main = main}
