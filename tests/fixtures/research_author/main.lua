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
local io = require("io")
local base64 = require("base64")
local artifact = require("artifact")
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
    for _, topic in ipairs({"source", "corpus", "authoring", "application", "model", "view"}) do
        local document = call("bee.research.probe:docs", {topic = topic})
        if type(document.content) ~= "string" or #document.content == 0 then error("empty research document " .. topic) end
    end
    local actor = "bee.research.probe"
    local marker = "bee-research-author-" .. tostring(time.now():unix_nano())
    local thread = "research-performance"
    local definition = "bee.driver.agy:research_batch"
    local policy = registry.get("bee:launch_policy_agy_batch")
    if not policy then error("Agy batch policy unavailable") end
    local data = bounds.object(policy.data)
    if not data then error("Agy policy data missing") end
    data.gateway_tools = {"thread_read", "thread_message", "overlay", "research_docs"}
    data.gateway_surface = {tools = {{name = "research_docs", operation = "bee.research.probe:docs", description = "Read the fixed research source and Bee authoring contracts",
        policies = {"bee.research.probe:docs_policy"}, schema = {type = "object", additionalProperties = false, required = {"topic"},
            properties = {topic = {type = "string", enum = {"source", "corpus", "authoring", "application", "model", "view", "proposal", "review"}}}},
        annotations = {readOnlyHint = true, destructiveHint = false, openWorldHint = false}}}, traits = {
        {id = "research:read", title = "Research reader", prompt = "Read this research thread.", tools = {"thread_read", "research_docs"}},
        {id = "research:record", title = "Research recorder", prompt = "Author a candidate and dashboard in your caller-owned overlay, then report its frozen digest.", tools = {"thread_message", "overlay"}}},
        base_tools = {"thread_read"}, active_traits = {}, fixed_context = {project = "live-mcp-probe"}, dynamic_keys = {"experiment"},
        access = {policy = "live-research", traits = {"research:record"}}}
    local changes = registry.snapshot():changes()
    changes:update(policy)
    local approvers = registry.get("bee:approver_policies")
    if not approvers then error("approval policies missing") end
    local approver_data = bounds.object(approvers.data)
    if not approver_data then error("approval policy data missing") end
    approver_data.policies = {{name = "live-research", approvers = {actor}, max_ttl_ms = 180000}}
    changes:update(approvers)
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
    local brief = "Use Bee MCP for research documents and all authoring. You may read your harness's own tool-output files when a tool response directs you there. "
        .. "Do not read unrelated files, use shell or delegates, or write source files or registry entries directly. "
        .. "If the same non-pending tool refusal happens twice, stop and report it; do not loop or invent results. "
        .. "Read session, request research:record access using retry key author-access, reason Author the performance dashboard. "
        .. "The test operator will approve that exact access request; poll access_status until granted. Select research:read and research:record with current revision and context {experiment: baseline}. "
        .. "Use research_docs to read source, corpus, authoring, application, model and view. Your task is to optimize the supplied canonical JSON encoder, fixing its native-runtime large-integer formatting bug and preserving exact output. "
        .. "Author a small working Bee dashboard app that reads real canonical-json@1 measurements from durable thread messages and draws baseline/candidate bars, values, units and correctness. Never invent measurements. "
        .. "Follow the supplied app example for lifecycle, resize and thread subscription, but keep only what the dashboard needs. Do not change core or create security policies. "
        .. "Create the caller-owned overlay research-performance at revision 0, then write entries.json as a list of complete inline-source registry entries. All entry IDs must start with bee.research.demo:. "
        .. "Required entries: bee.research.demo:canonical (library.lua exporting encode), bee.research.demo:app (process.lua with Bee app metadata); optional own model/view libraries. "
        .. "Use overlay operation put with exact expected_revision and a new idempotency_key per changed write. Freeze once complete. "
        .. "Finally call thread_message with idempotency_key and message_id " .. marker
        .. ", message_kind progress, recipient_ids [bee.research.probe], and content {text: the frozen snapshot digest, artifact_ref: the frozen snapshot digest}. "
        .. "The host will separately review, lint, approve and apply; do not claim tests or benchmarks you did not run. Answer DONE after the thread message succeeds."
    local review = call("bee.research.probe:docs", {topic = "review"})
    if type(review.content) == "string" and #review.content > 0 then
        brief = "Repair the previous Gemini-authored research artifact using Bee MCP for all authoring. You may read the harness's own saved tool-output files when directed there. "
            .. "No shell, unrelated files, delegates or direct source/registry writes. Stop after two identical non-pending refusals. "
            .. "Read session; request research:record access with key repair-access; poll access_status until granted by the test operator. "
            .. "Select research:read and research:record with current revision and context {experiment: baseline}. "
            .. "Read research_docs topics proposal, review, authoring and corpus. Fix ALL review findings while preserving the candidate optimization and actual dashboard behavior; do not replace it with a stub or fabricated measurements. "
            .. "This is a fresh overlay. Create research-performance at revision 0, write the corrected complete entries.json using expected_revision 1 and retry key repaired-entries, then freeze at the returned revision. "
            .. "Report the frozen digest using thread_message with idempotency_key and message_id " .. marker
            .. ", message_kind progress, recipient_ids [bee.research.probe], and content {text: the frozen digest, artifact_ref: the frozen digest}. "
            .. "Do not claim tests passed; the host will lint and review before approving. Answer DONE only after the message succeeds."
    end
    local started = call("bee.harness.launch:start", {request_id = "live-agent", definition_ref = definition, workspace_id = "research-workspace", thread_id = thread, brief = brief})
    local pid = tostring(started.carrier)
    local monitored, monitor_error = process.monitor(pid)
    if not monitored then error(tostring(monitor_error)) end
    local events = process.events()
    if not events then error("process events unavailable") end
    local deadline = time.after("300s")
    local approved = false
    local inbox_cursor = 0
    while true do
        local tick = time.after("200ms")
        local selected = channel.select({events:case_receive(), deadline:case_receive(), tick:case_receive()})
        if not selected.ok or selected.channel == deadline then error("live Gemini carrier exceeded 300s") end
        if selected.channel == tick then
            -- This is the test operator, not the MCP subject scope. It approves
            -- only this exact live attempt's expected capability through inbox.
            local inbox = call("bee.approvals.binding:inbox", {workspace_id = "research-workspace", after_seq = inbox_cursor})
            local entries = inbox.changes
            if type(entries) ~= "table" then error("inbox changes missing") end
            for _, raw in ipairs(entries) do
                local change = bounds.object(raw)
                local request = change and bounds.object(change.request)
                local proposed = request and bounds.object(request.proposal)
                local payload = proposed and bounds.object(proposed.payload)
                local traits = payload and bounds.ids(payload.traits, true)
                if request and request.state == "pending" then
                    if approved or request.requester_id ~= actor or request.thread_id ~= thread or not proposed
                        or proposed.action_id ~= started.action_id or proposed.ref ~= started.attempt_id
                        or not traits or #traits ~= 1 or traits[1] ~= "research:record" then error("unexpected access request") end
                    call("bee.approvals.binding:decide", {approval_id = request.approval_id, expected_revision = request.revision,
                        proposal_digest = request.proposal_digest, decision = "approved"})
                    approved = true
                end
            end
            local next_cursor = bounds.count(inbox.next_seq)
            if not next_cursor then error("inbox cursor missing") end
            inbox_cursor = next_cursor
        end
        local event = selected.value
        if selected.channel == events and event.kind == process.event.EXIT and tostring(event.from) == pid then
            if event.result and event.result.error then error("live carrier failed: " .. tostring(event.result.error)) end
            break
        end
    end
    local cursor = 0
    local found = false
    local frozen_digest: string? = nil
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
                    local content = bounds.object(body.content)
                    if not content or type(content.artifact_ref) ~= "string" then error("missing authored snapshot digest") end
                    frozen_digest = content.artifact_ref
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
    if not approved then error("Gemini did not request access through the approval inbox") end
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
    if not frozen_digest then error("missing frozen artifact") end
    local file = call("bee.gov.binding:overlay_call", {operation = "read", overlay_id = "research-performance",
        path = "entries.json", snapshot_digest = frozen_digest})
    if type(file.content_base64) ~= "string" then error("missing authored entries") end
    local source, decode_error = base64.decode(file.content_base64)
    if not source then error(tostring(decode_error)) end
    local entries, parse_error = json.decode(source)
    if not entries then error(tostring(parse_error)) end
    local measured, measure_error = artifact.create(entries)
    if not measured then error(tostring(measure_error)) end
    local has_canonical, has_app = false, false
    for _, entry in ipairs(measured.entries) do
        if not tostring(entry.id):match("^bee%.research%.demo:") then error("foreign authored entry") end
        if entry.kind ~= "library.lua" and entry.kind ~= "process.lua" then error("unadmitted authored entry kind") end
        if entry.id == "bee.research.demo:canonical" and entry.kind == "library.lua" then has_canonical = true end
        if entry.id == "bee.research.demo:app" and entry.kind == "process.lua" then has_app = true end
    end
    if not has_canonical or not has_app then error("missing candidate or dashboard") end
    io.print("RESEARCH_AUTHORED " .. tostring(json.encode({snapshot_digest = frozen_digest, artifact_digest = measured.digest,
        entries = measured.entries, action_id = started.action_id, attempt_id = started.attempt_id})))
    return {ok = true, action_id = started.action_id, attempt_id = started.attempt_id}
end
return {main = main}
