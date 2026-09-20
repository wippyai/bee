-- SPDX-License-Identifier: MIT
-- One managed Agy attempt authors a Bee application through the scoped
-- Governance MCP workspace tool and reports its frozen snapshot digest on the
-- bound thread. Review findings from an earlier round reach the agent as a
-- record on that same thread before this attempt starts.
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
local publication = require("publication_service")

type Object = {[string]: unknown}

local INPUTS = "bee.agent_app_probe:inputs"
local ACTOR = "bee.agent_app.operator"
local THREAD = "agent-app-authoring"
-- The launch route and its policy are host-selected per run: the live Agy
-- attempt and the scripted fixture provider use the same production launch,
-- admission, carrier, placement and gateway path with a different far end.
local DEFAULT_DEFINITION = "bee.driver.agy:research_batch"
local ACCESS_POLICY = "local-agent-app-authoring"
local NAMESPACE = "bee.agent_app_demo"
local DEFINITION_ID = "bee.agent_app_demo:app"
local TITLE = "Agent App"
local MARKER_LINE = "AGENT APP READY"
local UPDATE_MARKER_LINE = "AGENT APP UPDATED"

-- Host instructions reach the agent as the driver's own instructions file, the
-- durable part of the brief a person writes once for this destination.
local INSTRUCTIONS = [[You author Bee registry entries through the Bee MCP tools and nothing else.
Never use a shell, a delegate, an unrelated file, or a direct registry or source write.
Read session first. Request the access the host declares, poll access_status with the
returned approval_id, and select your traits only after it is granted.
Every edit goes into your caller-owned Governance workspace through the workspace tool,
then you freeze that workspace and report the returned digest.
entries.json is a JSON list of complete registry entries. Each entry uses id, kind, an
optional meta and a required data. Put source, method, modules and imports inside data.
Inline the Lua source; a file URL is refused. Top-level YAML shorthand is not the registry API.
Omit every optional configuration field you do not fill. An empty list or an empty map
reaches the destination as neither and its preflight refuses the version with CONFIG_SHAPE.
Declare exactly the native modules and library imports your source uses.
Your own file, search and shell tools are outside this work: everything you need arrives
through the admitted read tool and the bound thread. Your transport carries one output line
at a time and refuses a line over 16384 bytes, which ends the attempt, so never echo a large
file or a long tool output.
You hold no registry publication, approval or activation capability and create no security policy.
The host lints, reviews, approves and applies your frozen artifact. Report no check you did not run.
If the same non-pending tool refusal happens twice, stop and report it rather than looping.]]

local function reply(target: string, request: unknown): Object
    local result, err = funcs.call(target, request)
    if err then error(target .. ": " .. tostring(err)) end
    local answer = bounds.object(result)
    if not answer then error("missing reply from " .. target) end
    if answer.ok ~= true then error(target .. ": " .. tostring(json.encode(answer.error or answer.message))) end
    return answer
end

local function call(target: string, request: unknown): Object
    local result = bounds.object(reply(target, request).value)
    if not result then error("missing value from " .. target) end
    return result
end

local function inputs(): Object
    local entry = registry.get(INPUTS)
    if not entry then error("acceptance inputs are unavailable") end
    local data = bounds.object(entry.data)
    if not data then error("acceptance inputs carry no data") end
    return data
end

local function text_of(value: unknown, label: string): string
    local decoded = bounds.text(value, 65536)
    if not decoded then error(label .. " is not bounded text") end
    return decoded
end

local function surface(launch_workspace: string): Object
    return {tools = {{name = "app_docs", operation = "bee.agent_app_probe:docs",
        description = "Read the Bee application authoring contract and a real example application",
        policies = {"bee.agent_app_probe:docs_policy"},
        schema = {type = "object", additionalProperties = false, required = {"topic"},
            properties = {topic = {type = "string", enum = {"contract", "client", "example", "view"}}}},
        annotations = {readOnlyHint = true, destructiveHint = false, openWorldHint = false}}},
        traits = {
            {id = "app:read", title = "Application reader", prompt = "Read the Bee application contract and this thread.",
                tools = {"thread_read", "app_docs"}},
            {id = "app:author", title = "Application author",
                prompt = "Author one Bee application in your Governance workspace and report its frozen digest.",
                tools = {"thread_message", "workspace"}}},
        base_tools = {"thread_read"}, active_traits = {}, fixed_context = {project = "agent-authored-app"},
        dynamic_keys = {"round"},
        access = {workspace_id = launch_workspace, policy = ACCESS_POLICY, traits = {"app:author"}}}
end

local function configure(launch_workspace: string, policy_ref: string, keep_executable: boolean)
    local policy = registry.get(policy_ref)
    if not policy then error("launch policy " .. policy_ref .. " unavailable") end
    local data = bounds.object(policy.data)
    if not data then error("launch policy data missing") end
    if keep_executable then
        -- The scripted provider binds its own executable, environment and
        -- tools in the fixture; only the surface and instructions are added.
        data.gateway_surface = surface(launch_workspace)
        data.instructions = INSTRUCTIONS
    else
        data.gateway_tools = {"thread_read", "thread_message", "workspace", "app_docs"}
        data.gateway_surface = surface(launch_workspace)
        data.instructions = INSTRUCTIONS
    end
    policy.data = data
    local approvers = registry.get("bee.approvals:approver_policies")
    if not approvers then error("approval policies missing") end
    local approver_data = bounds.object(approvers.data)
    if not approver_data then error("approval policy data missing") end
    local policies = approver_data.policies :: {unknown}
    local declared = false
    for _, raw in ipairs(policies) do
        local existing = bounds.object(raw)
        if existing and existing.name == ACCESS_POLICY then declared = true end
    end
    if not declared then
        policies[#policies + 1] = {name = ACCESS_POLICY, approvers = {ACTOR}, max_ttl_ms = 180000}
    end
    approver_data.policies = policies
    approvers.data = approver_data
    local changes = registry.snapshot():changes()
    if not changes:update(policy) then error("stage the Agy batch policy") end
    if not changes:update(approvers) then error("stage the approver policies") end
    local applied, apply_error = changes:apply()
    if not applied then error(tostring(apply_error)) end
end

local function listener_ready()
    for _ = 1, 150 do
        local raw, address_error = funcs.call("bee.gateway:address", {})
        local address = not address_error and bounds.object(raw) or nil
        if address and type(address.address) == "string" then return end
        time.sleep("100ms")
    end
    error("native MCP listener did not become ready")
end

local function first_brief(source_workspace: string, marker: string, round: string): string
    return "Author one small Bee desktop application through Bee MCP. "
        .. "Read session, then request access with traits [app:author], idempotency_key author-access-" .. round
        .. " and reason Author the Bee application. The host operator approves that exact request; poll access_status until it is granted. "
        .. "Select active_traits [app:read, app:author] with the current revision and context {round: \"" .. round .. "\"}. "
        .. "Read app_docs topics contract, client, example and view before you write anything. contract is the authoring contract for this destination, "
        .. "client is the application client library source, example and view are a real Bee application you may learn the conventions from. "
        .. "Create the Governance workspace " .. source_workspace .. " with operation create at expected_revision 0, "
        .. "then put path entries.json at expected_revision 1 with idempotency_key entries-" .. round
        .. ", then freeze at the revision that put returned with idempotency_key freeze-" .. round .. ". "
        .. "entries.json holds exactly one entry with id " .. DEFINITION_ID .. " and kind process.lua, with its Lua source inline in data.source. "
        .. "No other entry and no other namespace is admitted by this destination. "
        .. "The destination admits only the namespace " .. NAMESPACE .. ", only the kind process.lua, "
        .. "only the native modules tty, process, channel and json, and only the import bee.application:client. "
        .. "Its application metadata declares title " .. TITLE .. ", api_version 1, lifetime view, revision 1, instance_policy multiple, "
        .. "resume_schema agent-app.v1 and restart_policy automatic. "
        .. "The window paints three lines and nothing else: row 1 is exactly " .. MARKER_LINE .. ", "
        .. "row 2 is Count: followed by a space and the counter, row 3 is Saved: followed by a space and the counter of the last checkpoint the broker acknowledged. "
        .. "The counter starts at 0, the acknowledged counter starts at -1. Every key press that is not a release increments the counter, repaints and checkpoints. "
        .. "A close event checkpoints. A resize repaints at the new size. The checkpoint state is the JSON object {\"count\": <counter>}. "
        .. "A start whose resume_state is not empty restores the counter from it and refuses a state it did not write. "
        .. "Call client.ready once after the first paint, and leave the loop on the process CANCEL lifecycle event. "
        .. "Finally call thread_message with idempotency_key report-" .. round .. ", message_id " .. marker
        .. ", message_kind progress, recipient_ids [" .. ACTOR .. "] and content {text: the frozen digest, artifact_ref: the frozen digest}. "
        .. "Answer DONE after that message succeeds."
end

local function repair_brief(source_workspace: string, marker: string, round: string): string
    return "Your previous attempt at this Bee application was refused by the host review. "
        .. "Read the bound thread with thread_read from cursor 0: the newest message from " .. ACTOR
        .. " carries the exact findings, and the earlier messages carry the history of this work. "
        .. "Read session, then request access with traits [app:author], idempotency_key repair-access-" .. round
        .. " and reason Repair the Bee application. Poll access_status until the host operator grants it. "
        .. "Select active_traits [app:read, app:author] with the current revision and context {round: \"" .. round .. "\"}. "
        .. "Read app_docs topics contract, client, example and view again for anything the findings touch. "
        .. "Fix every finding. Keep the behaviour the earlier version already had right; do not replace the application with a stub. "
        .. "Continue in the existing Governance workspace " .. source_workspace .. ". Call workspace list first. "
        .. "If the earlier attempt ended before creating it, create it at expected_revision 0; otherwise read its current entries.json without a snapshot digest. "
        .. "Put the complete corrected entries.json at the revision returned by list or create with idempotency_key entries-" .. round
        .. ", then freeze at the revision that put returned with idempotency_key freeze-" .. round .. ". "
        .. "The artifact stays one entry with id " .. DEFINITION_ID .. " and kind process.lua, with the same destination ceilings, "
        .. "the same application metadata and the same three painted rows as before. "
        .. "Finally call thread_message with idempotency_key report-" .. round .. ", message_id " .. marker
        .. ", message_kind progress, recipient_ids [" .. ACTOR .. "] and content {text: the frozen digest, artifact_ref: the frozen digest}. "
        .. "Answer DONE after that message succeeds."
end

local function update_brief(source_workspace: string, marker: string, round: string): string
    return "Update the Bee application you already authored and that the person already applied. "
        .. "Read the bound thread with thread_read from cursor 0 so you retain the complete authoring and review history. "
        .. "Read session, then request access with traits [app:author], idempotency_key update-access-" .. round
        .. " and reason Update the Bee application. Poll access_status until the host operator grants it. "
        .. "Select active_traits [app:read, app:author] with the current revision and context {round: \"" .. round .. "\"}. "
        .. "Read app_docs topics contract and client. In the existing Governance workspace " .. source_workspace
        .. ", call workspace list, then read the current entries.json without a snapshot digest. Preserve its one application and all behaviour. "
        .. "Change the first painted line from exactly " .. MARKER_LINE .. " to exactly " .. UPDATE_MARKER_LINE
        .. " and advance meta.application.revision from 1 to 2 because the executable definition changed. "
        .. "Keep id " .. DEFINITION_ID .. ", title " .. TITLE .. ", resume_schema agent-app.v1 and every destination ceiling unchanged. "
        .. "Put the complete updated entries.json at the revision returned by list with idempotency_key entries-" .. round
        .. ", then freeze at the revision returned by put with idempotency_key freeze-" .. round .. ". "
        .. "Finally call thread_message with idempotency_key report-" .. round .. ", message_id " .. marker
        .. ", message_kind progress, recipient_ids [" .. ACTOR .. "] and content {text: the new frozen digest, artifact_ref: the new frozen digest}. "
        .. "Answer DONE after that message succeeds."
end

-- The findings a person would hand back: the host records them on the bound
-- thread, where the repairing attempt reads them like any other record.
local function deliver_findings(findings: string, round: string)
    call("bee.threads.service:record", {thread_id = THREAD, idempotency_key = "findings-" .. round,
        kind = "message", body = {message_id = "findings-" .. round, message_kind = "notification",
            recipient_ids = {}, content = {text = findings}}})
end

local function await_carrier(started: Object): boolean
    local pid = tostring(started.carrier)
    local monitored, monitor_error = process.monitor(pid)
    if not monitored then error(tostring(monitor_error)) end
    local events = process.events()
    if not events then error("process events unavailable") end
    local deadline = time.after("420s")
    local approved = false
    local running = true
    local inbox_cursor = 0
    while running do
        local tick = time.after("200ms")
        local selected = channel.select({events:case_receive(), deadline:case_receive(), tick:case_receive()})
        if not selected.ok or selected.channel == deadline then error("managed Agy carrier exceeded 420s") end
        if selected.channel == tick then
            -- The host operator, not the MCP subject scope: it approves only
            -- this exact attempt's expected capability through the inbox.
            local inbox = call("bee.approvals:inbox", {workspace_id = tostring(started.workspace_id), after_seq = inbox_cursor})
            local entries = inbox.changes
            if type(entries) ~= "table" then error("inbox changes missing") end
            for _, raw in ipairs(entries) do
                local change = bounds.object(raw)
                local request = change and bounds.object(change.request)
                local proposed = request and bounds.object(request.proposal)
                local payload = proposed and bounds.object(proposed.payload)
                local traits = payload and bounds.ids(payload.traits, true)
                if request and request.state == "pending" then
                    if approved or request.requester_id ~= ACTOR or request.thread_id ~= THREAD or not proposed
                        or proposed.action_id ~= started.action_id or proposed.ref ~= started.attempt_id
                        or not traits or #traits ~= 1 or traits[1] ~= "app:author" then error("unexpected access request") end
                    call("bee.approvals:decide", {approval_id = request.approval_id, expected_revision = request.revision,
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
            if event.result and event.result.error then error("managed carrier failed: " .. tostring(event.result.error)) end
            running = false
        end
    end
    return approved
end

-- What the attempt left on the thread: the digest it reported, or the terminal
-- outcome that explains why it reported none.
local function reported_digest(started: Object, marker: string): (string?, string, integer)
    local cursor = 0
    local digest: string? = nil
    local terminal = ""
    local sequence = 0
    for _ = 1, 64 do
        local page = call("bee.threads.service:read_after", {thread_id = THREAD, cursor = cursor, limit = 64})
        local records = page.records
        if type(records) ~= "table" then error("thread page records missing") end
        for _, raw_record in ipairs(records) do
            local record = bounds.object(raw_record)
            if not record then error("malformed thread record") end
            if record.kind == "message" then
                local body = bounds.object(record.body)
                if not body then error("malformed message body") end
                if body.message_id == marker and body.sender_id == ACTOR and record.producer_id == ACTOR
                    and record.action_id == started.action_id and record.attempt_id == started.attempt_id then
                    local content = bounds.object(body.content)
                    if not content or type(content.artifact_ref) ~= "string" then error("missing authored snapshot digest") end
                    digest = content.artifact_ref :: string
                    sequence = bounds.sequence(record.sequence) or 0
                end
            end
            if record.kind == "turn.end" or record.kind == "receipt" then
                local body = bounds.object(record.body)
                local fault = body and bounds.object(body.error)
                if fault then
                    terminal = tostring(body and body.outcome) .. ": " .. tostring(fault.code) .. ": " .. tostring(fault.message)
                end
            end
        end
        if page.has_more ~= true then break end
        local next_cursor = bounds.count(page.scanned_through)
        if not next_cursor or next_cursor <= cursor then error("invalid page progress") end
        cursor = next_cursor
    end
    return digest, terminal, sequence
end

-- What the attempt's own gateway binding admits. Tool metadata grants nothing:
-- this is the admitted ceiling the MCP calls actually execute under.
local function binding_scope(attempt_id: string): Object
    local db, db_error = sql.get("bee.gateway:db")
    if not db then error(tostring(db_error)) end
    local rows, query_error = db:query(
        "SELECT b.tools_json, s.active_json, s.context_json FROM bee_gateway_bindings b "
        .. "LEFT JOIN bee_gateway_surfaces s ON s.binding_id = b.binding_id WHERE b.attempt_id = ?", {attempt_id})
    db:release()
    if not rows or query_error or #rows ~= 1 then error("missing single binding selection") end
    local row = bounds.object(rows[1])
    if not row then error("invalid binding row") end
    local admitted_raw, admitted_error = json.decode(text_of(row.tools_json, "binding tools"))
    local admitted = bounds.ids(admitted_raw, true)
    if admitted_error or not admitted then error("invalid admitted tool set") end
    table.sort(admitted)
    -- An attempt that never selected its traits has no stored surface.
    local active: {string} = {}
    local context: Object = {}
    if type(row.active_json) == "string" and type(row.context_json) == "string" then
        local active_raw, active_error = json.decode(text_of(row.active_json, "selected traits"))
        local selected = bounds.ids(active_raw, true)
        if active_error or not selected then error("invalid selected trait set") end
        local context_raw, context_error = json.decode(text_of(row.context_json, "selected context"))
        local chosen = bounds.object(context_raw)
        if context_error or not chosen then error("invalid selected context") end
        active = selected
        context = chosen
        table.sort(active)
    end
    return {admitted_tools = admitted, active_traits = active, context = context}
end

local function main()
    local values = inputs()
    local definition = bounds.text(values.definition, 160)
    if not definition or definition == "" then definition = DEFAULT_DEFINITION end
    local policy_ref = bounds.text(values.authoring_policy, 160)
    if not policy_ref or policy_ref == "" then policy_ref = "bee:launch_policy_agy_batch" end
    local round = text_of(values.round, "round")
    local source_workspace = text_of(values.source_workspace, "source workspace")
    local launch_workspace = text_of(values.launch_workspace, "launch workspace")
    local findings = bounds.text(values.findings, 65536) or ""
    local updating = values.update == true

    configure(launch_workspace, policy_ref, definition ~= DEFAULT_DEFINITION)
    listener_ready()

    -- A scripted provider cannot read a computed marker out of the brief, so
    -- the host may pin the exact marker it will report with.
    local pinned_marker = bounds.text(values.marker, 160)
    local marker: string = (pinned_marker and pinned_marker ~= "") and pinned_marker
        or ("agent-app-" .. round .. "-" .. tostring(time.now():unix_nano()))
    local plan = call("bee.harness.launch:resolve", {definition_ref = definition})
    reply("bee.harness.launch:setup", {workspace_id = launch_workspace, definition_ref = definition,
        expected_plan_digest = plan.plan_digest})
    call("bee.threads.service:create", {thread_id = THREAD, idempotency_key = "create-" .. THREAD,
        title = "Agent-authored Bee application"})
    -- A scripted provider that learns the contract from the guide is given the
    -- plain request instead of the host's contract-bearing brief.
    local plain = bounds.text(values.brief, 65536)
    local brief = (plain and plain ~= "") and plain
        or (updating and update_brief(source_workspace, marker, round) or first_brief(source_workspace, marker, round))
    if findings ~= "" then
        deliver_findings(findings, round)
        if not (plain and plain ~= "") then brief = repair_brief(source_workspace, marker, round) end
    end

    local started = call("bee.harness.launch:start", {request_id = "agent-app-" .. round,
        definition_ref = definition, workspace_id = launch_workspace, thread_id = THREAD, brief = brief})
    started.workspace_id = launch_workspace
    local approved = await_carrier(started)

    local snapshot_digest, terminal, thread_sequence = reported_digest(started, marker)
    local scope = binding_scope(tostring(started.attempt_id))
    local report: Object = {snapshot_digest = snapshot_digest or "", action_id = started.action_id,
        attempt_id = started.attempt_id, admitted_tools = scope.admitted_tools, requested_access = approved,
        active_traits = scope.active_traits, context = scope.context, thread_id = THREAD,
        thread_sequence = thread_sequence, source_workspace = source_workspace,
        entries = {}, findings = ""}

    if not snapshot_digest then
        -- An attempt that ends without the frozen digest is reviewed like any
        -- other refused round: the host tells the agent what it observed.
        report.findings = "your attempt ended without reporting a frozen snapshot digest on the bound thread. "
            .. "Author the application through the Bee MCP tools, freeze the workspace and report the digest "
            .. "with thread_message before you answer."
        if terminal ~= "" then
            report.findings = tostring(report.findings) .. " The host observed the attempt end as " .. terminal .. "."
        end
        io.print("AGENT_APP_AUTHORED " .. tostring(json.encode(report)))
        return
    end

    -- A frozen workspace that cannot become an application is refused with the
    -- destination's own named code and remedy, exactly as publication prepare
    -- would refuse it. The remedy text comes from that product surface, not
    -- from this fixture, so the agent is handed the same words.
    local function refusal_findings(code: string, detail: string): string
        local refusal = publication.artifact_refusal(code, detail)
        local value = bounds.object(refusal.value) or {}
        return "the destination refused your frozen workspace before delivery: " .. tostring(refusal.code)
            .. ": " .. tostring(refusal.message) .. " Remedy: " .. tostring(value.remedy)
    end
    local file = call("bee.governance:workspace_call", {operation = "read", workspace_id = source_workspace,
        path = "entries.json", snapshot_digest = snapshot_digest})
    if file.workspace_id ~= source_workspace then error("workspace read returned another workspace") end
    report.workspace_revision = bounds.count(file.revision) or 0
    if type(file.content_base64) ~= "string" then
        report.findings = refusal_findings("MISSING_ARTIFACT", "the frozen workspace holds no entries.json")
    else
        local source, decode_error = base64.decode(file.content_base64 :: string)
        if not source then
            report.findings = refusal_findings("INVALID_ARTIFACT", tostring(decode_error))
        else
            local decoded, parse_error = json.decode(source)
            if not decoded then
                report.findings = refusal_findings("INVALID_ARTIFACT", "entries.json is not valid JSON: " .. tostring(parse_error))
            else
                local measured, measure_error = artifact.create(decoded)
                if not measured then
                    report.findings = refusal_findings("INVALID_ARTIFACT", tostring(measure_error))
                else
                    report.artifact_digest = measured.digest
                    report.entries = measured.entries
                end
            end
        end
    end
    io.print("AGENT_APP_AUTHORED " .. tostring(json.encode(report)))
end

return {main = main}
