local test = require("test")
local registry = require("registry")
local fs = require("fs")
local json = require("json")
local hash = require("hash")
local bounds = require("bounds")
local canonical = require("canonical")
local descriptor = require("descriptor")
local adapter = require("adapter")
local exchange = require("exchange")
local grok = require("grok")
local opencode = require("opencode")
type Object = {[string]: unknown}
local function digest(value: unknown): (string?, string?)
    return hash.sha256(assert(canonical.encode(value)))
end
local function capture(path: string): string
    return assert(assert(fs.get("bee.tests.driver:fixtures")):readfile(path))
end
local function claude_request(): Object
    for line in capture("claude/stream-json-2/control.jsonl"):gmatch("[^\n]+") do
        local value = assert(bounds.object(json.decode(line)))
        if value.type == "control_request" then return value end
    end
    error("capture has no control request")
end
local function observation(provider: string, selected: adapter.Adapter): Object
    if provider == "grok" then
        local context = {permission_exchange = true, brief = "Fixture prompt."}
        local first = assert(bounds.object(grok.handle({index = 1, context = context,
            envelope = {jsonrpc = "2.0", id = "bee:init", result = {protocolVersion = 1, _meta = {currentWorkingDirectory = "/fixture"}}}})))
        local ready = assert(bounds.object(grok.handle({index = 2, context = context, state = first.state,
            envelope = {jsonrpc = "2.0", id = "bee:session", result = {sessionId = "fixture-session"}}})))
        local reply = assert(bounds.object(grok.handle({index = 3, context = context, state = ready.state,
            envelope = json.decode(capture("grok/acp-1/PermissionRequest.json"))})))
        test.eq(reply.ok, true)
        return assert(bounds.object(assert(bounds.array(reply.observations, 8))[1]))
    end
    local payload: Object
    if selected.response.correlation_field then payload = claude_request()
    else
        local hook: Object
        if provider == "agy" or provider == "muse" then hook = assert(bounds.object(json.decode(capture(provider .. "/hooks-1/PermissionRequest.json"))))
        elseif provider == "opencode" then
            local state = opencode.new()
            local found: Object? = nil
            for line in capture("opencode/http-events-1/events.jsonl"):gmatch("[^\n]+") do
                for _, row in ipairs(opencode.event(state, assert(bounds.object(json.decode(line))))) do
                    if row.hook_event_name == "PermissionRequest" then found = row end
                end
            end
            hook = assert(found)
        else
            local request = assert(bounds.object(claude_request().request))
            hook = {tool_name = request.tool_name, tool_input = request.input}
        end
        payload = {event_id = "fixture-hook", tool_name = hook.tool_name, tool_input = hook.tool_input}
    end
    return {type = "extension", event_key = "fixture-permission", data = {event_name = selected.event_name,
        event_revision = selected.event_revision, payload_json = json.encode(payload)}}
end
local function run()
    test.describe("Accepted driver permission contexts", function()
        local providers = {"claude", "codex", "agy", "grok", "muse", "opencode"}
        local accepted: {[string]: {[string]: boolean}} = {
            claude = {window = true, first_turn = true, resume = true}, codex = {window = true},
            agy = {window = true, first_turn = true, resume = true}, grok = {first_turn = true, resume = true},
            muse = {window = true, first_turn = true, resume = true}, opencode = {window = true}}

        for _, provider in ipairs(providers) do
            local driver = assert(descriptor.find_provider(registry.snapshot(), provider))
            for _, context in ipairs({"window", "first_turn", "resume"}) do
                local declared = descriptor.permission_answer(driver, context)
                test.it(provider .. " " .. context .. " declares its permission owner", function()
                    test.eq(declared.transport ~= "provider", accepted[provider][context] == true)
                    if declared.transport == "provider" then test.not_nil(declared.reason); test.is_nil(declared.adapter_ref) end
                end)
                if declared.transport ~= "provider" then
                    for _, decision in ipairs({"approved", "denied"}) do
                        test.it(provider .. " " .. context .. " answers " .. decision .. " exactly once", function()
                            local entry = assert(registry.get(assert(declared.adapter_ref)))
                            local selected = assert(adapter.decode(entry.id, assert(bounds.object(entry.data)).adapter))
                            local state: exchange.State = {request = {owner_id = "subject", action_id = "action", attempt_id = "attempt", thread_id = "thread", workspace_id = "workspace"},
                                plan_digest = string.rep("a", 64), permissions = {}, epoch = 1,
                                exchange = {adapter = selected, approver_policy = "policy", poll_ms = 10, ttl_ms = 1000}}
                            local requests, writes, consumed = 0, 0, 0
                            local proposal_digest = ""
                            local ctx: exchange.Context = {state = state, approvals = "approvals", max_consume_attempts = 3,
                                now_ms = function(): integer return 0 end, digest_of = digest, step = function(_: string) end,
                                waiting = function(): boolean return true end, settled = function(): boolean return false end,
                                revalidate = function(): string? return nil end, commit = function(_: {Object}): (boolean, string?) return true, nil end,
                                write = function(_: string, line: string): (boolean, string?) writes = writes + 1; test.not_nil((json.decode(line))); return true, nil end,
                                call = function(target: string, raw: unknown): (unknown, string?)
                                    local request = assert(bounds.object(raw))
                                    if target == "approvals:request" then
                                        requests = requests + 1
                                        test.eq(request.contract_version, 2)
                                        test.eq(assert(bounds.object(request.origin)).attempt_id, "attempt")
                                        local proposal = assert(bounds.object(request.proposal))
                                        test.not_nil(proposal.input_digest)
                                        test.not_nil(assert(bounds.object(proposal.payload)).tool_name)
                                        proposal_digest = assert(digest(proposal))
                                        return {ok = true, value = {approval_id = "approval", workspace_id = "workspace", proposal_digest = proposal_digest, owner_incarnation = 1, state = "pending"}}, nil
                                    elseif target == "approvals:consume" then consumed = consumed + 1; return {ok = true, value = {}}, nil end
                                    test.eq(target, "approvals:read")
                                    return {ok = true, value = {approval_id = "approval", workspace_id = "workspace", proposal_digest = proposal_digest, owner_incarnation = 1, state = "decided", decision = decision}}, nil
                                end}
                            local records: {Object} = {{body = observation(provider, selected)}}
                            test.eq(exchange.detect(ctx, records), 1)
                            test.is_true(exchange.advance(ctx, true))
                            test.eq(exchange.detect(ctx, records), 0)
                            test.is_true(exchange.advance(ctx, true))
                            test.eq(requests, 1); test.eq(writes, 1); test.eq(consumed, decision == "approved" and 1 or 0)
                        end)
                    end
                end
            end
        end
    end)
end
return test.run_cases(run)
