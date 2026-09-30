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
local ADAPTER_ID = "bee.driver.claude:permission_adapter"
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

local function exchange(decoded: adapter.Adapter): permissions.Exchange
    return {adapter = decoded, approver_policy = "session-tools", poll_ms = 50, ttl_ms = 60000}
end

local function labels(): permissions.Labels
    return {owner_id = "owner-1", attempt_id = "attempt-1", action_id = "action-1",
        plan_digest = string.rep("p", 64), workspace_id = "workspace-1",
        session_ref = "bs:node:workspace-1:session-1"}
end

type ApprovalState = {state: string, decision: string?, approval_id: string,
    owner_incarnation: integer, workspace_id: string}
type Script = {reads: {ApprovalState}, reads_made: integer}
type Harness = {io: permissions.IO, requested: () -> Object?, written: () -> {string}, consumed: () -> integer}

local function script_io(script: Script, calls: {[string]: integer}): Harness
    local written: {string} = {}
    local requested: Object? = nil
    local recorded_digest: string? = nil
    local consumed = 0
    local io: permissions.IO = {
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
        local outcome, err = permissions.answer(harness.io, exchange(decoded), labels(), observation())
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
        local outcome, err = permissions.answer(harness.io, exchange(decoded), labels(), observation())
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
        local outcome, err = permissions.answer(harness.io, exchange(decoded), labels(), observation())
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
        local outcome, err = permissions.answer(harness.io, exchange(decoded), labels(), observation())
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
        local outcome, err = permissions.answer(harness.io, shortened, labels(), observation())
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
        local found, ferr = permissions.scan(decoded, {observation()})
        test.eq(ferr, nil)
        test.eq(#found, 1)
        local pending, perr = permissions.request(harness.io, exchange(decoded), labels(), found[1])
        test.eq(perr, nil)
        if not pending then error("request returns a pending ask") end
        local outcome, poll_err = permissions.poll(harness.io, exchange(decoded), pending)
        test.eq(poll_err, nil)
        test.eq(outcome, "allowed")
        test.eq(calls.consume, 1)
        local written = harness.written()
        test.eq(#written, 1)
        test.eq(behavior_of(written[1]), "allow")
    end
    do
        if permissions.drive(nil) ~= nil then error("no plan means no drive") end
        local bare: permissions.TurnPlan = {request = {owner_id = "o", attempt_id = "a", action_id = "c"},
            plan_digest = string.rep("d", 64)}
        if permissions.drive(bare) ~= nil then error("no exchange means no drive") end
        local refused: permissions.TurnPlan = {exchange = {adapter = decoded, approver_policy = "p", poll_ms = 50, ttl_ms = 60000},
            exchange_refusal = "no acceptance",
            request = {owner_id = "o", attempt_id = "a", action_id = "c"}, plan_digest = string.rep("d", 64)}
        local broken = permissions.drive(refused)
        if not broken then error("refusal carries a drive") end
        test.ok((broken.broken or ""):find("refused", 1, true) ~= nil, "refusal is loud")
        local unlabelled: permissions.TurnPlan = {exchange = {adapter = decoded, approver_policy = "p", poll_ms = 50, ttl_ms = 60000},
            request = {owner_id = "o", attempt_id = "a", action_id = "c"}, plan_digest = string.rep("d", 64)}
        local unlabeled_drive = permissions.drive(unlabelled)
        if not unlabeled_drive then error("broken labels carry a drive") end
        if unlabeled_drive.broken == nil then error("broken labels are loud") end
        local good: permissions.TurnPlan = {exchange = {adapter = decoded, approver_policy = "session-tools", poll_ms = 50, ttl_ms = 60000},
            request = {owner_id = "owner-1", attempt_id = "attempt-1", action_id = "action-1",
                workspace_id = "workspace-1", session_ref = "bs:node:workspace-1:session-1"},
            plan_digest = string.rep("d", 64)}
        local drive = permissions.drive(good)
        if not drive then error("a measured plan carries a drive") end
        test.eq(drive.broken, nil)
        if not drive.exchange then error("drive carries the exchange") end
        if not drive.labels then error("drive carries the labels") end
    end
    do
        local found, ferr = permissions.scan(decoded, {observation(), observation()})
        test.eq(ferr, nil)
        test.eq(#found, 1)
        test.eq(found[1].correlation_id, "req-1")
        test.eq(found[1].tool_name, "Bash")
    end
end

return {run = run}
