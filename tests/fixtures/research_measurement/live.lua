-- SPDX-License-Identifier: MIT
-- Live managed Gemini proof. Host policy and the reviewed MCP surface are
-- staged by the acceptance runner; this operator only observes and approves.
local funcs = require("funcs")
local registry = require("registry")
local security = require("security")
local process = require("process")
local channel = require("channel")
local time = require("time")
local json = require("json")
local io = require("io")
local bounds = require("bounds")
type Object = {[string]: unknown}
local THREAD = "research-performance"
local WORKSPACE = "research-workspace"
local DEFINITION = "bee.driver.agy:research_batch"
local APPROVAL_POLICY = "research-live-measurement"
local TRAIT = "research:measure"
local PRODUCER = "bee.research.measurement"
local function object(raw: unknown, label: string): Object
    local value = bounds.object(raw)
    if not value then error(label .. " must be an object") end
    return value
end
local function call(target: string, request: Object): Object
    local result, problem = funcs.call(target, request)
    if problem then error(target .. ": " .. tostring(problem)) end
    local reply = object(result, target .. " reply")
    if reply.ok ~= true then error(target .. ": " .. tostring(json.encode(reply.error))) end
    return object(reply.value, target .. " value")
end
local function wait_for_live_inputs()
    for _ = 1, 300 do
        local raw, address_error = funcs.call("bee.gateway:address", {})
        local address = not address_error and bounds.object(raw) or nil
        local candidate = registry.get("bee.research.demo:measure")
        if address and type(address.address) == "string" and address.address:match("^127%.0%.0%.1:%d+$")
            and candidate and candidate.kind == "function.lua" then
            return
        end
        time.sleep("100ms")
    end
    error("native MCP endpoint and reviewed measurement entry did not become ready")
end
local function valid_digest(raw: unknown): string?
    if type(raw) ~= "string" or #raw ~= 64 or not raw:match("^[0-9a-f]+$") then return nil end
    return raw
end
local function validate_measurement(raw: unknown, label: string, expected_digest: string): Object
    local measured = object(raw, label .. " measurement")
    if measured.schema ~= "bee.research.measurement@1" or measured.benchmark ~= "canonical-json@1"
        or measured.label ~= label or measured.source_sha256 ~= expected_digest or measured.units ~= "ns/op" then
        error(label .. " measurement identity or source differs")
    end
    local expected_correct = label == "candidate"
    local expected_outcome = expected_correct and "passed" or "invalid"
    if measured.correct ~= expected_correct or measured.outcome ~= expected_outcome then
        error(label .. " measurement correctness or outcome differs")
    end
    local samples = measured.samples
    if type(samples) ~= "table" or #samples ~= 7 then error(label .. " measurement must contain seven samples") end
    local count = 0
    for key, sample in pairs(samples) do
        if type(key) ~= "number" or key ~= math.floor(key) or key < 1 or key > 7 then
            error(label .. " measurement samples must be a dense seven-item array")
        end
        if type(sample) ~= "number" or sample ~= sample or sample <= 0 or sample == math.huge or sample == -math.huge then
            error(label .. " measurement sample must be positive and finite")
        end
        count = count + 1
    end
    if count ~= 7 then error(label .. " measurement samples are not dense") end
    return measured
end
local function matches_attempt(request: Object, proposal: Object?, actor: string, action_id: string, attempt_id: string): boolean
    if request.requester_id ~= actor or request.thread_id ~= THREAD or request.request_kind ~= "permission" then return false end
    if not proposal then return false end
    return proposal.action_id == action_id or proposal.ref == attempt_id
end
local function decide_exact_request(request: Object, proposal: Object?, actor: string,
    action_id: string, attempt_id: string, approved_id: string?): string
    if request.workspace_id ~= WORKSPACE or request.policy ~= APPROVAL_POLICY or request.requester_id ~= actor
        or request.thread_id ~= THREAD or request.request_kind ~= "permission" then
        error("live access request has the wrong actor, thread, workspace, kind, or policy")
    end
    if not proposal or proposal.kind ~= "attempt" or proposal.revision ~= "bee.mcp-access@1"
        or proposal.action_id ~= action_id or proposal.ref ~= attempt_id then
        error("live access request is bound to the wrong action or attempt")
    end
    local payload = bounds.object(proposal.payload)
    local traits = payload and bounds.ids(payload.traits, true) or nil
    if not payload or payload.subject ~= actor or payload.thread_id ~= THREAD
        or not traits or #traits ~= 1 or traits[1] ~= TRAIT then
        error("live access request must contain only the research:measure trait")
    end
    local approval_id = bounds.id(request.approval_id)
    if not approval_id or approved_id ~= nil then error("expected exactly one live access request") end
    if request.state ~= "pending" then error("live access request was settled before the operator decision") end
    local revision = bounds.count(request.revision)
    local digest = bounds.text(request.proposal_digest, 64)
    if not revision or revision < 1 or not digest or #digest ~= 64 or not digest:match("^[0-9a-f]+$") then
        error("live access request has an invalid revision or proposal digest")
    end
    local decided = call("bee.approvals.binding:decide", {approval_id = approval_id, expected_revision = revision,
        proposal_digest = digest, decision = "approved"})
    if decided.approval_id ~= approval_id or decided.state ~= "decided" or decided.decision ~= "approved"
        or decided.decider_id ~= actor then
        error("approval owner did not confirm the operator's exact decision")
    end
    return approval_id
end
local function observe_approval(actor: string, action_id: string, attempt_id: string,
    cursor: integer, approved_id: string?): (integer, string?)
    local page = call("bee.approvals.binding:inbox", {workspace_id = WORKSPACE, after_seq = cursor, limit = 64})
    local changes = page.changes
    if type(changes) ~= "table" then error("approval inbox changes are missing") end
    local approved = approved_id
    for _, raw in ipairs(changes) do
        local change = bounds.object(raw)
        local request = change and bounds.object(change.request) or nil
        if not request then error("malformed approval inbox change") end
        local proposal = bounds.object(request.proposal)
        if matches_attempt(request, proposal, actor, action_id, attempt_id) then
            local approval_id = bounds.id(request.approval_id)
            if approved and approval_id == approved then
                -- The inbox also projects the decision we just committed.
            elseif approved then
                error("Gemini made more than one matching access request")
            else
                approved = decide_exact_request(request, proposal, actor, action_id, attempt_id, approved)
            end
        end
    end
    local next_cursor = bounds.count(page.next_seq)
    if not next_cursor or next_cursor < cursor then error("approval inbox cursor is invalid") end
    return next_cursor, approved
end
local function measurements(thread_id: string, action_id: string, attempt_id: string): Object
    local entry = registry.get("bee.research.measurement:inputs")
    local config = entry and bounds.object(entry.data) or nil
    if not config then error("host measurement inputs are missing") end
    local baseline_digest = valid_digest(config.baseline_sha256)
    local candidate_digest = valid_digest(config.candidate_sha256)
    if not baseline_digest or not candidate_digest then error("host measurement source digests are invalid") end
    local found: {[string]: Object} = {}
    local cursor = 0
    for _ = 1, 32 do
        local page = call("bee.threads.service:read_after", {thread_id = thread_id, cursor = cursor, limit = 64,
            filter = {kinds = {"observation"}, action_id = action_id}})
        local records = page.records
        if type(records) ~= "table" then error("thread observation page is missing records") end
        for _, raw in ipairs(records) do
            local record = bounds.object(raw)
            if not record then error("malformed thread record") end
            if record.kind == "observation" and record.action_id == action_id and record.attempt_id == attempt_id
                and record.source == "mcp" and record.producer_id == PRODUCER then
                local body = bounds.object(record.body)
                local content = body and bounds.object(body.data) or nil
                if not body or body.type ~= "extension" or not content or content.type ~= "extension"
                    or content.event_name ~= "bee.research.measurement" or content.event_revision ~= "1" then
                    error("measurement observation extension identity differs")
                end
                local payload = bounds.text(content.payload_json, 16384)
                if not payload or #payload == 0 then error("measurement observation payload is missing or too large") end
                local ok, decoded = pcall(json.decode, payload)
                if not ok then error("measurement observation payload is invalid JSON") end
                local raw_measurement = bounds.object(decoded)
                if not raw_measurement then error("measurement observation payload is not an object") end
                local label = raw_measurement.label
                if label ~= "baseline" and label ~= "candidate" then error("measurement observation label is invalid") end
                if found[label] then error("duplicate " .. label .. " measurement observation") end
                local expected_digest = label == "baseline" and baseline_digest or candidate_digest
                if not expected_digest then error("expected measurement source digest missing") end
                local checked = validate_measurement(raw_measurement, label, expected_digest)
                local record_id, sequence = bounds.id(record.record_id), bounds.sequence(record.sequence)
                if not record_id or not sequence then error("measurement observation identity is invalid") end
                found[label] = {measurement = checked, record_id = record_id, sequence = sequence}
            end
        end
        if page.has_more ~= true then break end
        local next_cursor = bounds.count(page.scanned_through)
        if not next_cursor or next_cursor <= cursor then error("thread observation scan did not advance") end
        cursor = next_cursor
        if _ == 32 then error("thread observation scan exceeded its page bound") end
    end
    if not found.baseline or not found.candidate then error("expected both baseline and candidate measurement observations") end
    return {baseline = found.baseline, candidate = found.candidate}
end
local function run(): Object
    local current = security.actor()
    if not current then error("live measurement operator actor is missing") end
    local actor = bounds.id(current:id())
    if not actor or actor == PRODUCER then error("live measurement operator must differ from the producer") end
    wait_for_live_inputs()
    local plan = call("bee.harness.launch:resolve", {definition_ref = DEFINITION})
    local setup, setup_error = funcs.call("bee.harness.launch:setup", {workspace_id = WORKSPACE, definition_ref = DEFINITION,
        expected_plan_digest = plan.plan_digest})
    if setup_error or object(setup, "setup reply").ok ~= true then error("managed Agy setup failed: " .. tostring(setup_error)) end
    local request_id = "research-measurement-live-" .. tostring(time.now():unix_nano())
    local brief = "Use only Bee MCP tools; do not use a shell or change files. Read the current session first. "
        .. "Request exactly the research:measure access trait with idempotency_key research-measurement-access and a reason explaining that you will record the two benchmark measurements. "
        .. "Wait for the test operator to approve it, polling session access_status with the returned approval_id until granted. "
        .. "Read the session again and select research:measure using the current revision and an empty context. "
        .. "Then call call_tool for research_measure exactly once with label baseline and once with label candidate. "
        .. "Report correctness and outcomes before comparing timings. Do not claim measurements unless the tools returned them."
    local started = call("bee.harness.launch:start", {request_id = request_id, definition_ref = DEFINITION,
        workspace_id = WORKSPACE, thread_id = THREAD, brief = brief})
    local action_id, attempt_id = bounds.id(started.action_id), bounds.id(started.attempt_id)
    local pid = bounds.id(started.carrier)
    if not action_id or not attempt_id or not pid or started.thread_id ~= THREAD then
        error("managed Agy launch returned an invalid thread, action, attempt, or carrier")
    end
    local monitored, monitor_error = process.monitor(pid)
    if not monitored then error("monitor managed Agy carrier: " .. tostring(monitor_error)) end
    local events = process.events()
    if not events then error("process event channel unavailable") end
    local deadline = time.after("180s")
    local approved_id: string? = nil
    local inbox_cursor = 0
    local exited = false
    while not exited do
        local tick = time.after("200ms")
        local selected = channel.select({events:case_receive(), deadline:case_receive(), tick:case_receive()})
        if not selected.ok or selected.channel == deadline then error("managed Gemini measurement exceeded 180 seconds") end
        if selected.channel == tick then
            inbox_cursor, approved_id = observe_approval(actor, action_id, attempt_id, inbox_cursor, approved_id)
        elseif selected.channel == events then
            local event = selected.value
            if event.kind == process.event.EXIT and tostring(event.from) == pid then
                local result = bounds.object(event.result)
                if result and result.error then error("managed Agy carrier failed: " .. tostring(result.error)) end
                exited = true
            end
        end
    end
    if not approved_id then error("Gemini did not request the exact research:measure trait") end
    local results = measurements(THREAD, action_id, attempt_id)
    local report: Object = {ok = true, thread_id = THREAD, workspace_id = WORKSPACE, action_id = action_id,
        attempt_id = attempt_id, approval_id = approved_id, policy = APPROVAL_POLICY,
        measurements = results, observations = 2}
    local encoded, encode_error = json.encode(report)
    if not encoded or encode_error then error("could not encode live measurement report") end
    io.print("RESEARCH_LIVE_MEASUREMENT_PASS " .. encoded)
    return report
end
return {run = run}
