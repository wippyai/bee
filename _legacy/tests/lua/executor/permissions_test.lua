-- MIT. Executor permission tests: a Claude control_request observed during
-- a session turn becomes one approval naming session, workspace, tool and
-- effect; an approved decision is consumed and answered allow, a denied or
-- expired one is answered deny, and a timeout never means consent.
local test = require("test")
local json = require("json")
local hash = require("hash")
local permissions = require("permissions")
local adapter = require("adapter")
local canonical = require("canonical")
local bounds = require("bounds")

type Object = {[string]: unknown}
type Labels = {owner_id: string, attempt_id: string, action_id: string, plan_digest: string,
    workspace_id: string, session_ref: string}
type Exchange = permissions.Exchange
type IO = {request_approval: (Object) -> (Object?, string?), read_approval: (string) -> (Object?, string?),
    consume: (string, string, string, integer) -> (boolean, string?, integer?),
    revalidate: (string, string, integer) -> (boolean, string?), write_stdin: (string, string) -> (boolean, string?),
    wait_ms: (integer) -> (), now_ms: () -> integer, waiting: () -> boolean}
type TurnPlan = {exchange: Exchange?, exchange_refusal: string?, plan_digest: string,
    request: {owner_id: string, attempt_id: string, action_id: string, workspace_id: string?, session_ref: string?}}
local function scan(decoded: adapter.Adapter, observations: {unknown}): ({adapter.Request}, string?)
    local found: {adapter.Request} = {}
    local seen: {[string]: boolean} = {}
    for _, event in ipairs(observations) do
        local request, err = adapter.request(decoded, event)
        if err then return {}, err end
        if request and not seen[request.permission_request_id] then
            found[#found + 1] = request; seen[request.permission_request_id] = true
        end
    end
    return found, nil
end
local function drive(plan: TurnPlan?): {broken: string?, exchange: Exchange?, labels: Labels?}?
    if not plan or not plan.exchange then return nil end
    if plan.exchange_refusal then return {broken = "permission exchange refused: " .. plan.exchange_refusal} end
    local request = plan.request
    if not request.workspace_id or not request.session_ref then return {broken = "permission exchange needs workspace and session"} end
    return {exchange = plan.exchange, labels = {owner_id = request.owner_id, attempt_id = request.attempt_id,
        action_id = request.action_id, plan_digest = plan.plan_digest, workspace_id = request.workspace_id, session_ref = request.session_ref}}
end
local function context(io: IO, declared: Exchange, labels: Labels): permissions.Context
    local state: permissions.State = {request = {owner_id = labels.owner_id, attempt_id = labels.attempt_id,
            action_id = labels.action_id, thread_id = "thread-1", workspace_id = labels.workspace_id, session_ref = labels.session_ref},
        exchange = declared, plan_digest = labels.plan_digest, epoch = 1, permissions = {}}
    return {state = state, approvals = "approvals", max_consume_attempts = permissions.MAX_CONSUME_ATTEMPTS,
        now_ms = io.now_ms, waiting = io.waiting, settled = function(): boolean return false end,
        step = function(_: string) end, revalidate = function(): string? return nil end,
        commit = function(_: {Object}): (boolean, string?) return true, nil end,
        digest_of = function(value: unknown): (string?, string?)
            local encoded, err = canonical.encode(value)
            if not encoded then return nil, err end
            return hash.sha256(encoded)
        end,
        write = io.write_stdin,
        call = function(target: string, value: unknown): (unknown, string?)
            local fields = bounds.object(value)
            if not fields then return nil, "invalid owner request" end
            local result: Object? = nil
            local err: string? = nil
            if target == "approvals:request" then result, err = io.request_approval(fields)
            elseif target == "approvals:read" then result, err = io.read_approval(tostring(fields.approval_id))
            elseif target == "approvals:consume" then
                local consumed, consume_error, current = io.consume(tostring(fields.approval_id), tostring(fields.proposal_digest),
                    tostring(fields.effect_key), bounds.count(fields.owner_incarnation) or 0)
                if not consumed then return {ok = false, error = {code = consume_error or "CONSUME", message = "consume refused"}, value = {current_incarnation = current}}, nil end
                result = {}
            end
            if err then return nil, err end
            return {ok = true, value = result}, nil
        end}
end
local function request(io: IO, declared: Exchange, labels: Labels, found: adapter.Request): (permissions.Context?, string?)
    local ctx = context(io, declared, labels)
    local payload = {request_id = found.correlation_id, request = {tool_name = found.tool_name,
        input = found.input, description = found.prompt, tool_use_id = found.acknowledgment_id}}
    local records: {Object} = {{body = {type = "extension", event_key = found.permission_request_id,
        data = {event_name = declared.adapter.event_name, event_revision = declared.adapter.event_revision, payload_json = json.encode(payload)}}}}
    local _, err = permissions.detect(ctx, records)
    if err then return nil, err end
    local ok, advance_error = permissions.advance(ctx, false)
    if not ok then return nil, advance_error end
    return ctx, nil
end
local function poll(_: IO, _: Exchange, ctx: permissions.Context): (string?, string?)
    if not ctx.waiting() then return "closed", nil end
    local ok, err = permissions.advance(ctx, true)
    if not ok then return nil, err end
    local state = ctx.state.permissions[1]
    if state.phase == "written" then return state.decision == "approved" and "allowed" or "denied", nil end
    if state.phase == "closed" then return "closed", nil end
    return "wait", nil
end
local function answer(io: IO, declared: Exchange, labels: Labels, event: unknown): (string?, string?)
    local found, err = adapter.request(declared.adapter, event)
    if not found then return nil, err end
    local ctx, request_error = request(io, declared, labels, found)
    if not ctx then return nil, request_error end
    while true do
        local outcome, poll_error = poll(io, declared, ctx)
        if outcome ~= "wait" then return outcome, poll_error end
        io.wait_ms(declared.poll_ms)
    end
end
local ADAPTER_ID = "bee.driver.claude.permission:permission_adapter"
local function adapter_table(): Object
    return {
        schema_revision = "bee.permission-adapter@2",
        event_name = "claude.control_request",
        event_revision = "stream-json-2",
        request = {correlation = "request_id", tool = "request.tool_name", input = "request.input",
            prompt = "request.description", acknowledgment = "request.tool_use_id"},
        response = {envelope = {type = "control_response", response = {subtype = "success"}},
            correlation_field = "response.request_id", decision_field = "response.response.behavior",
            allow_value = "allow", deny_value = "deny", reason_field = "response.response.message"},
        acknowledgment = {mode = "correlation_echo", event_type = "tool.result", field = "call_id"},
        deny_acknowledgment = {mode = "terminal_denial", event_type = "tool.result", field = "outcome",
            value = "failed", correlation_field = "call_id"},
        cancellation = "deny_before_close",
        proof_fixture = "control",
    }
end

local function decoded_adapter(): adapter.Adapter
    local decoded, err = adapter.decode(ADAPTER_ID, adapter_table())
    if not decoded then error("adapter decodes: " .. tostring(err)) end
    return decoded
end

local function observation(): Object
    local envelope = {type = "control_request", request_id = "req-1",
        request = {subtype = "can_use_tool", tool_name = "Bash", description = "leave a marker",
            input = {command = "touch proof.txt", description = "leave a marker"}, tool_use_id = "toolu-1"}}
    local encoded = json.encode(envelope)
    if not encoded then error("envelope encodes") end
    return {type = "extension", event_key = "claude:3:control", data = {type = "extension",
        event_name = "claude.control_request", event_revision = "stream-json-2", payload_json = encoded}}
end

local function exchange(decoded: adapter.Adapter): Exchange
    return {adapter = decoded, approver_policy = "session-tools", poll_ms = 50, ttl_ms = 60000}
end

local function labels(): Labels
    return {owner_id = "owner-1", attempt_id = "attempt-1", action_id = "action-1",
        plan_digest = string.rep("p", 64), workspace_id = "workspace-1",
        session_ref = "bs:node:workspace-1:session-1"}
end

type ApprovalState = {state: string, decision: string?, approval_id: string,
    owner_incarnation: integer, workspace_id: string}
type Script = {reads: {ApprovalState}, reads_made: integer}
type Harness = {io: IO, requested: () -> Object?, written: () -> {string}, consumed: () -> integer}

local function script_io(script: Script, calls: {[string]: integer}): Harness
    local written: {string} = {}
    local requested: Object? = nil
    local recorded_digest: string? = nil
    local consumed = 0
    local io: IO = {
        request_approval = function(fields: Object): (Object?, string?)
            requested = fields
            calls.request = (calls.request or 0) + 1
            local encoded = canonical.encode(fields.proposal)
            if not encoded then error("proposal encodes") end
            local digest = hash.sha256(encoded)
            if not digest then error("proposal digests") end
            recorded_digest = digest
            return {approval_id = "approval-1", proposal_digest = digest,
                owner_incarnation = 3, state = "pending", decision = nil,
                workspace_id = "workspace-1", expires_at = "2030-01-01T00:00:00Z"}, nil
        end,
        read_approval = function(_: string): (Object?, string?)
            script.reads_made = script.reads_made + 1
            local next_state = script.reads[math.min(script.reads_made, #script.reads)]
            calls.read = (calls.read or 0) + 1
            return {approval_id = next_state.approval_id, proposal_digest = recorded_digest,
                owner_incarnation = next_state.owner_incarnation, state = next_state.state,
                decision = next_state.decision, workspace_id = next_state.workspace_id,
                expires_at = "2030-01-01T00:00:00Z"}, nil
        end,
        consume = function(_: string, _: string, _: string, _: integer): (boolean, string?, integer?)
            consumed = consumed + 1
            calls.consume = (calls.consume or 0) + 1
            return true, nil, nil
        end,
        revalidate = function(_: string, _: string, _: integer): (boolean, string?)
            calls.revalidate = (calls.revalidate or 0) + 1
            return true, nil
        end,
        write_stdin = function(_: string, line: string): (boolean, string?)
            written[#written + 1] = line
            calls.write = (calls.write or 0) + 1
            return true, nil
        end,
        wait_ms = function(_: integer) end,
        now_ms = function(): integer return 1000 end,
        waiting = function(): boolean return true end,
    }
    return {io = io,
        requested = function(): Object? return requested end,
        written = function(): {string} return written end,
        consumed = function(): integer return consumed end}
end

local function pending_state(): ApprovalState
    return {state = "pending", decision = nil, approval_id = "approval-1",
        owner_incarnation = 3, workspace_id = "workspace-1"}
end

local function decided_state(decision: string): ApprovalState
    local state = pending_state()
    state.state = "decided"
    state.decision = decision
    return state
end

local function check_prompt_names(requested: Object?)
    if not requested then error("approval was requested") end
    test.eq(requested.request_kind, "permission")
    test.eq(requested.policy, "session-tools")
    test.eq(requested.workspace_id, "workspace-1")
    local prompt = bounds.object(requested.prompt)
    if not prompt then error("prompt is an object") end
    local text = bounds.text(prompt.text)
    if not text then error("prompt text is text") end
    test.ok(text:find("bs:node:workspace-1:session-1", 1, true) ~= nil, "prompt names the session: " .. text)
    test.ok(text:find("workspace-1", 1, true) ~= nil, "prompt names the workspace")
    test.ok(text:find("Bash", 1, true) ~= nil, "prompt names the tool")
    test.ok(text:find("touch proof.txt", 1, true) ~= nil, "prompt names the command")
    test.ok(text:find("leave a marker", 1, true) ~= nil, "prompt names the effect")
    local proposal = bounds.object(requested.proposal)
    if not proposal then error("proposal is an object") end
    test.eq(proposal.kind, "attempt")
    test.eq(proposal.ref, "attempt-1")
end

local function response_of(line: string): Object
    local decoded = bounds.object(json.decode(line))
    if not decoded then error("response is JSON") end
    return decoded
end

local function behavior_of(line: string): string
    local decoded = response_of(line)
    local response = bounds.object(decoded.response)
    if not response then error("response carries a response") end
    local inner = bounds.object(response.response)
    if not inner then error("response carries a decision") end
    test.eq(response.request_id, "req-1")
    local behavior = bounds.text(inner.behavior)
    if not behavior then error("decision is text") end
    return behavior
end

local function run()
    local decoded = decoded_adapter()
    do
        local script: Script = {reads = {pending_state(), decided_state("approved")}, reads_made = 0}
        local calls: {[string]: integer} = {}
        local harness = script_io(script, calls)
        local outcome, err = answer(harness.io, exchange(decoded), labels(), observation())
        test.eq(err, nil)
        test.eq(outcome, "allowed")
        check_prompt_names(harness.requested())
        test.eq(calls.consume, 1)
        local written = harness.written()
        test.eq(#written, 1)
        test.eq(behavior_of(written[1]), "allow")
    end
    do
        local script: Script = {reads = {decided_state("denied")}, reads_made = 0}
        local calls: {[string]: integer} = {}
        local harness = script_io(script, calls)
        local outcome, err = answer(harness.io, exchange(decoded), labels(), observation())
        test.eq(err, nil)
        test.eq(outcome, "denied")
        test.eq(calls.consume, nil)
        local written = harness.written()
        test.eq(#written, 1)
        test.eq(behavior_of(written[1]), "deny")
    end
    do
        local expired = pending_state()
        expired.state = "expired"
        local script: Script = {reads = {expired}, reads_made = 0}
        local calls: {[string]: integer} = {}
        local harness = script_io(script, calls)
        local outcome, err = answer(harness.io, exchange(decoded), labels(), observation())
        test.eq(err, nil)
        test.eq(outcome, "denied")
        test.eq(calls.consume, nil)
        local written = harness.written()
        test.eq(#written, 1)
        test.eq(behavior_of(written[1]), "deny")
    end
    do
        local script: Script = {reads = {pending_state()}, reads_made = 0}
        local calls: {[string]: integer} = {}
        local harness = script_io(script, calls)
        harness.io.waiting = function(): boolean return false end
        local outcome, err = answer(harness.io, exchange(decoded), labels(), observation())
        test.eq(err, nil)
        test.eq(outcome, "closed")
        test.eq(#harness.written(), 0)
    end
    do
        local script: Script = {reads = {pending_state()}, reads_made = 0}
        local calls: {[string]: integer} = {}
        local harness = script_io(script, calls)
        local now = 1000
        harness.io.now_ms = function(): integer return now end
        harness.io.wait_ms = function(ms: integer) now = now + ms end
        local shortened = exchange(decoded)
        shortened.ttl_ms = 100
        local outcome, err = answer(harness.io, shortened, labels(), observation())
        test.eq(err, nil)
        test.eq(outcome, "denied")
        test.eq(calls.consume, nil)
        local written = harness.written()
        test.eq(#written, 1)
        test.eq(behavior_of(written[1]), "deny")
    end
    do
        local script: Script = {reads = {decided_state("approved")}, reads_made = 0}
        local calls: {[string]: integer} = {}
        local harness = script_io(script, calls)
        local found, ferr = scan(decoded, {observation()})
        test.eq(ferr, nil)
        test.eq(#found, 1)
        local pending, perr = request(harness.io, exchange(decoded), labels(), found[1])
        test.eq(perr, nil)
        if not pending then error("request returns a pending ask") end
        local outcome, poll_err = poll(harness.io, exchange(decoded), pending)
        test.eq(poll_err, nil)
        test.eq(outcome, "allowed")
        test.eq(calls.consume, 1)
        local written = harness.written()
        test.eq(#written, 1)
        test.eq(behavior_of(written[1]), "allow")
    end
    do
        if drive(nil) ~= nil then error("no plan means no drive") end
        local bare: TurnPlan = {request = {owner_id = "o", attempt_id = "a", action_id = "c"},
            plan_digest = string.rep("d", 64)}
        if drive(bare) ~= nil then error("no exchange means no drive") end
        local refused: TurnPlan = {exchange = {adapter = decoded, approver_policy = "p", poll_ms = 50, ttl_ms = 60000},
            exchange_refusal = "no acceptance",
            request = {owner_id = "o", attempt_id = "a", action_id = "c"}, plan_digest = string.rep("d", 64)}
        local broken = drive(refused)
        if not broken then error("refusal carries a drive") end
        test.ok((broken.broken or ""):find("refused", 1, true) ~= nil, "refusal is loud")
        local unlabelled: TurnPlan = {exchange = {adapter = decoded, approver_policy = "p", poll_ms = 50, ttl_ms = 60000},
            request = {owner_id = "o", attempt_id = "a", action_id = "c"}, plan_digest = string.rep("d", 64)}
        local unlabeled_drive = drive(unlabelled)
        if not unlabeled_drive then error("broken labels carry a drive") end
        if unlabeled_drive.broken == nil then error("broken labels are loud") end
        local good: TurnPlan = {exchange = {adapter = decoded, approver_policy = "session-tools", poll_ms = 50, ttl_ms = 60000},
            request = {owner_id = "owner-1", attempt_id = "attempt-1", action_id = "action-1",
                workspace_id = "workspace-1", session_ref = "bs:node:workspace-1:session-1"},
            plan_digest = string.rep("d", 64)}
        local drive = drive(good)
        if not drive then error("a measured plan carries a drive") end
        test.eq(drive.broken, nil)
        if not drive.exchange then error("drive carries the exchange") end
        if not drive.labels then error("drive carries the labels") end
    end
    do
        local found, ferr = scan(decoded, {observation(), observation()})
        test.eq(ferr, nil)
        test.eq(#found, 1)
        test.eq(found[1].correlation_id, "req-1")
        test.eq(found[1].tool_name, "Bash")
    end
end

return test.run_cases(function()
    test.describe("External turn permission integration", function()
        test.it("preserves all executor decision, timeout, detection and admission cases with the shared engine", run)
    end)
end)
