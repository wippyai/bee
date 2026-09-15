-- SPDX-License-Identifier: MIT
-- Live-provider proof through the managed caller-thread route.
local funcs = require("funcs")
local registry = require("registry")
local process = require("process")
local channel = require("channel")
local time = require("time")
local json = require("json")
local bounds = require("bounds")
local sql = require("sql")
type Object = {[string]: unknown}
local function reply(target: string, request: unknown): Object
    local result, err = funcs.call(target, request)
    if err then error(target .. ": " .. tostring(err)) end
    local reply = bounds.object(result)
    if not reply then error("missing reply from " .. target) end
    if reply.ok ~= true then error(target .. ": " .. tostring(json.encode(reply.error))) end
    return reply
end
local function call(target: string, request: unknown): Object
    local result = bounds.object(reply(target, request).value)
    if not result then error("missing value from " .. target) end
    return result
end
local function main()
    local actor = "bee.research.probe"
    local marker = "bee-mcp-" .. tostring(time.now():unix_nano())
    local thread = "research-live"
    local definition = "bee.driver.agy:research_batch"
    local policy = registry.get("bee:launch_policy_agy_batch")
    if not policy then error("Agy batch policy unavailable") end
    local data = bounds.object(policy.data)
    if not data then error("Agy policy data missing") end
    data.gateway_tools = {"thread_read", "thread_message"}
    data.gateway_surface = {tools = {}, traits = {
        {id = "research:read", title = "Research reader", prompt = "Read this research thread.", tools = {"thread_read"}},
        {id = "research:record", title = "Research recorder", prompt = "Record results in the research thread.", tools = {"thread_message"}}},
        base_tools = {"thread_read"}, active_traits = {}, fixed_context = {project = "live-mcp-probe"}, dynamic_keys = {"experiment"}}
    local changes = registry.snapshot():changes()
    changes:update(policy)
    local applied, apply_error = changes:apply()
    if not applied then error(tostring(apply_error)) end
    local listener: Object? = nil
    for _ = 1, 150 do
        local raw, address_error = funcs.call("bee.gateway:address", {})
        if not address_error then listener = bounds.object(raw) end
        if listener and type(listener.address) == "string" then break end
        time.sleep("100ms")
    end
    if not listener or type(listener.address) ~= "string" then error("native MCP listener did not become ready") end
    local plan = call("bee.harness.launch:resolve", {definition_ref = definition})
    reply("bee.harness.launch:setup", {workspace_id = "research-workspace", definition_ref = definition, expected_plan_digest = plan.plan_digest})
    call("bee.threads.service:create", {thread_id = thread, idempotency_key = "create-live", title = "Live Gemini MCP proof"})
    local args = {idempotency_key = marker, message_id = marker, message_kind = "progress", recipient_ids = {actor}, content = {text = marker}}
    local brief = "Use only Bee MCP tools for this task. Read session, then select both research:read and research:record traits with the current revision and context {experiment: baseline}. "
        .. "Then use call_tool to call thread_message with these exact arguments: " .. tostring(json.encode(args))
        .. ". Do not use shell or change files. After the tool succeeds, answer DONE."
    local started = call("bee.harness.launch:start", {request_id = "live-agent", definition_ref = definition, workspace_id = "research-workspace", thread_id = thread, brief = brief})
    local pid = tostring(started.carrier)
    local monitored, monitor_error = process.monitor(pid)
    if not monitored then error(tostring(monitor_error)) end
    local events = process.events()
    if not events then error("process events unavailable") end
    local deadline = time.after("180s")
    while true do
        local selected = channel.select({events:case_receive(), deadline:case_receive()})
        if not selected.ok or selected.channel == deadline then error("live Gemini carrier exceeded 180s") end
        local event = selected.value
        if event.kind == process.event.EXIT and tostring(event.from) == pid then
            if event.result and event.result.error then error("live carrier failed: " .. tostring(event.result.error)) end
            break
        end
    end
    local cursor = 0
    local found = false
    for _ = 1, 64 do
        local page = call("bee.threads.service:read_after", {thread_id = thread, cursor = cursor, limit = 64})
        local records = page.records
        if type(records) ~= "table" then error("thread page records missing") end
        for _, raw_record in ipairs(records) do
            local record = bounds.object(raw_record)
            if not record then error("malformed thread record") end
            if record.kind == "message" then
                local body = bounds.object(record.body)
                if not body then error("malformed message body") end
                if body.message_id == marker and body.sender_id == actor and record.producer_id == actor
                    and record.action_id == started.action_id and record.attempt_id == started.attempt_id then
                    found = true
                end
            end
        end
        if page.has_more ~= true then break end
        local next_cursor = bounds.count(page.scanned_through)
        if not next_cursor or next_cursor <= cursor then error("invalid page progress") end
        cursor = next_cursor
    end
    if not found then error("Gemini did not commit the requested MCP message") end
    local db, db_error = sql.get("bee.gateway:db")
    if not db then error(tostring(db_error)) end
    local rows, query_error = db:query("SELECT s.active_json, s.context_json FROM bee_gateway_surfaces s JOIN bee_gateway_bindings b ON b.binding_id = s.binding_id WHERE b.attempt_id = ?", {started.attempt_id})
    db:release()
    if not rows or query_error or #rows ~= 1 then error("missing single binding selection") end
    local selected = bounds.object(rows[1])
    if not selected then error("invalid selection row") end
    local active_json = bounds.text(selected.active_json)
    local context_json = bounds.text(selected.context_json)
    if not active_json or not context_json then error("missing selection JSON") end
    local active_raw, active_error = json.decode(active_json)
    local active = bounds.ids(active_raw, true)
    local context_raw, context_error = json.decode(context_json)
    local context = bounds.object(context_raw)
    if active_error or not active or #active ~= 2 then error("Gemini did not select both traits") end
    table.sort(active)
    if active[1] ~= "research:read" or active[2] ~= "research:record" then error("wrong selected traits") end
    if context_error or not context or context.experiment ~= "baseline" then error("Gemini did not select the requested context") end
    print("BEE_AGY_LIVE_MCP_PASS")
    return {ok = true, action_id = started.action_id, attempt_id = started.attempt_id}
end
return {main = main}
