-- MIT. In-process runner for native Wippy agent driver.
local json = require("json")
local registry = require("registry")
local funcs = require("funcs")
local security = require("security")
local bounds = require("bounds")
local client = require("client")
local types = require("types")

local M = {}
local CARRIER_OPS = "bee.threads.carrier"
local THREADS = "bee.threads.service"

M.MAX_TURNS = 16
M.MAX_TOOL_CALLS_PER_TURN = 16
M.MAX_TOOL_OUTPUT_BYTES = 8192
M.MAX_TEXT_BYTES = 32768
M.MAX_CHECKPOINT_BYTES = 60000
M.MAX_ENDPOINT_BYTES = 512
M.CHECKPOINT_REVISION = "bee.carrier.checkpoint@1"

local function call_func(target: string, request: unknown): (unknown, string?)
    local ok, reply, err = pcall(function()
        return funcs.call(target, request)
    end)
    if not ok then return nil, tostring(reply) end
    if err then return nil, tostring(err) end
    return reply, nil
end

local function reply_value(reply: unknown): {[string]: unknown}?
    if type(reply) ~= "table" then return nil end
    local object = reply :: {[string]: unknown}
    if object.ok ~= true then return nil end
    if type(object.value) ~= "table" then return nil end
    return object.value :: {[string]: unknown}
end

local function reply_error(reply: unknown, fallback: string): string
    local object = type(reply) == "table" and (reply :: {[string]: unknown}) or {}
    local err = object.error
    if type(err) == "table" then
        local detail = err :: {[string]: unknown}
        if type(detail.message) == "string" then return detail.message :: string end
        if type(detail.code) == "string" then return detail.code :: string end
    end
    return fallback
end

local function is_cancelled(thread_id: string, attempt_id: string): boolean
    local res = call_func(CARRIER_OPS .. ":cancel_status", {thread_id = thread_id, attempt_id = attempt_id})
    local val = reply_value(res)
    if val then
        if val.state == "cancelling" or val.state == "ended" then
            return true
        end
    end
    return false
end

local function model_id(value: unknown): string?
    local model = bounds.text(value, 128)
    if not model or model == "" or not model:match("^[A-Za-z0-9][A-Za-z0-9._:-]*$") then return nil end
    return model
end

-- The endpoint is a host-selected chat destination: https to a named host,
-- or plain http to the loopback address only, mirroring the managed
-- provider endpoint rule. The key itself is never read here.
local function endpoint(value: unknown): (string?, string?)
    local url = bounds.text(value, M.MAX_ENDPOINT_BYTES)
    if not url or url == "" or url:find("%s") then return nil, "endpoint must be one bounded URL" end
    local scheme, host, rest = url:match("^(https?)://([^/]+)(.*)$")
    if not scheme or not host then return nil, "endpoint must be an http(s) URL with a host" end
    if rest:find("[?#]") then return nil, "endpoint carries no query or fragment" end
    if scheme == "http" and not host:match("^127%.0%.0%.1:%d+$") then
        return nil, "plain http is permitted only for the 127.0.0.1 loopback fixture"
    end
    return url, nil
end

function M.decode_host_config(value: unknown): (types.HostConfig?, string?)
    local object = bounds.object(value == nil and {} or value)
    if not object then return nil, "host_config must be an object" end
    local unknown_field = bounds.fields(object, {"endpoint", "credential_ref", "model", "timeout_ms", "stream", "admitted_delegates", "max_turns"})
    if unknown_field then return nil, "host_config: " .. unknown_field end
    local url, url_error = endpoint(object.endpoint)
    if not url then return nil, "host_config: " .. tostring(url_error) end
    local credential_ref: string? = nil
    if object.credential_ref ~= nil then
        credential_ref = bounds.id(object.credential_ref)
        if not credential_ref then return nil, "host_config: credential_ref is not an identifier" end
    end
    local model: string? = nil
    if object.model ~= nil then
        model = model_id(object.model)
        if not model then return nil, "host_config: model is not a bounded model identifier" end
    end
    local timeout_ms = 30000
    if object.timeout_ms ~= nil then
        local timeout = bounds.integer(object.timeout_ms)
        if not timeout then return nil, "host_config: timeout_ms must be an integer" end
        timeout_ms = math.floor(math.min(120000, math.max(1000, timeout)))
    end
    if object.stream ~= nil and type(object.stream) ~= "boolean" then
        return nil, "host_config: stream must be a boolean"
    end
    local admitted: {string} = {}
    if object.admitted_delegates ~= nil then
        local delegates, delegates_error = bounds.ids(object.admitted_delegates, true)
        if not delegates then return nil, "host_config: admitted_delegates: " .. tostring(delegates_error) end
        admitted = delegates
    end
    local max_turns = M.MAX_TURNS
    if object.max_turns ~= nil then
        local turns = bounds.integer(object.max_turns)
        if not turns or turns < 1 or turns > M.MAX_TURNS then
            return nil, "host_config: max_turns must be between 1 and " .. tostring(M.MAX_TURNS)
        end
        max_turns = turns
    end
    return {
        endpoint = url,
        credential_ref = credential_ref,
        model = model,
        timeout_ms = timeout_ms,
        stream = object.stream == true,
        admitted_delegates = admitted,
        max_turns = max_turns,
    }, nil
end

function M.resolve_agent(pinned: registry.Snapshot, agent_ref: string, host_config: types.HostConfig?): ({[string]: unknown}?, string?)
    local resolver = require("agent_resolver")
    local closure, code, err = resolver.resolve(pinned, agent_ref)
    if not closure then return nil, err or code or "agent resolve failed" end

    local model_map: {[string]: string} = {}
    if host_config and host_config.model then
        if closure.model then model_map[closure.model] = host_config.model end
    elseif closure.model then
        model_map[closure.model] = closure.model
    end

    -- Delegates are admitted by the host configuration, never by the agent
    -- definition itself: self-admission would bypass the host policy.
    local admitted_delegates: {string} = {}
    if host_config and host_config.admitted_delegates then
        for _, ref in ipairs(host_config.admitted_delegates) do
            admitted_delegates[#admitted_delegates + 1] = ref
        end
    end

    local checked, route_code, route_err = resolver.check_route(closure, {
        driver_id = "wippy",
        model_map = model_map,
        admitted_delegates = admitted_delegates,
    })
    if not checked then return nil, route_err or route_code or "route check failed" end

    return closure :: {[string]: unknown}, nil
end

-- A tool runs under a fresh per-attempt actor narrowed to the tool's own
-- declared scopes: the agent's grants only, never ambient authority. Every
-- narrowing failure denies instead of falling back to a wider executor.
function M.execute_tool(tool_entry: {[string]: unknown}, args: {[string]: unknown}, caller_id: string, workspace_id: string?): (boolean, unknown)
    local tool_ref = bounds.id(tool_entry.ref)
    if not tool_ref then
        return false, {code = "DENIED", message = "tool reference is not an identifier"}
    end
    local raw_scopes = tool_entry.scopes
    if raw_scopes ~= nil and type(raw_scopes) ~= "table" then
        return false, {code = "DENIED", message = "tool scopes must be a list"}
    end
    local scope_names, scopes_error = bounds.ids(raw_scopes == nil and {} or raw_scopes, true)
    if not scope_names then
        return false, {code = "DENIED", message = "tool scopes: " .. tostring(scopes_error)}
    end

    local policies: {security.Policy} = {}
    for _, name in ipairs(scope_names) do
        local pol, _ = security.policy(name)
        if not pol then
            return false, {code = "DENIED", message = "tool scope " .. name .. " is not admitted"}
        end
        policies[#policies + 1] = pol
    end

    local actor, actor_err = security.new_actor(caller_id, {workspace_id = workspace_id or ""})
    if not actor then
        return false, {code = "DENIED", message = "actor creation failed: " .. tostring(actor_err)}
    end

    local acted, act_err = funcs.new():with_actor(actor)
    if not acted then
        return false, {code = "DENIED", message = "actor attachment failed: " .. tostring(act_err)}
    end

    local executor = acted
    if #policies > 0 then
        local scope = security.new_scope(policies)
        local scoped, scope_err = executor:with_scope(scope)
        if not scoped then
            return false, {code = "DENIED", message = "scope attachment failed: " .. tostring(scope_err)}
        end
        executor = scoped
    end

    local reply, call_err = executor:call(tool_ref, args)
    if call_err then
        return false, {code = "FAILED", message = tostring(call_err)}
    end
    return true, reply
end

local function truncate_text(value: string, limit: integer): string
    if #value <= limit then return value end
    return value:sub(1, limit) .. "...[truncated]"
end

local function encode_tool_output(output: unknown): string
    local encoded, encode_err = json.encode(output)
    if not encoded then return '{"code":"FAILED","message":"tool output is not encodable: ' .. tostring(encode_err) .. '"}' end
    return truncate_text(encoded, M.MAX_TOOL_OUTPUT_BYTES)
end

local function checkpoint_fits(messages: {types.Message}): boolean
    local encoded, _ = json.encode({messages = messages})
    return encoded ~= nil and #encoded <= M.MAX_CHECKPOINT_BYTES
end

-- History keeps tool calls decoded flat; the chat endpoint receives the
-- OpenAI wire shape, so resumed histories stay valid payloads.
local function wire_messages(messages: {types.Message}): {{[string]: unknown}}
    local out: {{[string]: unknown}} = {}
    for _, msg in ipairs(messages) do
        if msg.tool_calls and #msg.tool_calls > 0 then
            local calls: {{[string]: unknown}} = {}
            for _, tc in ipairs(msg.tool_calls) do
                calls[#calls + 1] = {
                    id = tc.id,
                    type = "function",
                    ["function"] = {
                        name = tc.name,
                        arguments = tc.arguments,
                    },
                }
            end
            out[#out + 1] = {role = msg.role, content = msg.content, tool_calls = calls}
        elseif msg.tool_call_id then
            out[#out + 1] = {role = msg.role, tool_call_id = msg.tool_call_id, content = msg.content}
        else
            out[#out + 1] = {role = msg.role, content = msg.content}
        end
    end
    return out
end

function M.run(request: types.RunRequest): types.RunResult
    local thread_id = request.thread_id
    local action_id = request.action_id
    local attempt_id = request.attempt_id
    local agent_ref = request.agent_ref
    local brief = request.brief or ""
    local workspace_id = request.workspace_id or "default"
    local idempotency_key = request.idempotency_key or (attempt_id .. "-run")

    local initial_receipt: types.RunReceipt = {
        scope = "attempt",
        thread_id = thread_id,
        action_id = action_id,
        attempt_id = attempt_id,
        state = "running",
        idempotency_key = idempotency_key,
    }
    local function fail_run(message: string): types.RunResult
        return {ok = false, error = message, outcome = "failed", thread_id = thread_id, action_id = action_id, attempt_id = attempt_id, receipt = initial_receipt}
    end

    -- 1. Claim carrier epoch
    local claim_res, claim_err = call_func(CARRIER_OPS .. ":claim", {
        thread_id = thread_id,
        attempt_id = attempt_id,
        idempotency_key = idempotency_key .. "-claim",
    })
    local claim_data = reply_value(claim_res)
    if not claim_data then
        return fail_run("claim attempt: " .. reply_error(claim_res, claim_err or "claim failed"))
    end
    local epoch = math.floor(tonumber(claim_data.carrier_epoch) or 0)
    if epoch < 1 then
        return fail_run("claim attempt: carrier epoch is not positive")
    end
    -- A caller that names the epoch it saw fences entry: the claim must
    -- advance exactly from it, so an interposed claim fails instead of
    -- silently taking over another carrier's attempt.
    if request.carrier_epoch ~= nil and epoch ~= request.carrier_epoch + 1 then
        return fail_run("carrier epoch moved under attempt: observed " .. tostring(request.carrier_epoch) .. ", claimed " .. tostring(epoch))
    end
    local revision = math.floor(tonumber(claim_data.checkpoint_revision) or 0)

    if claim_data.attempt_state == "ended" then
        return {ok = true, outcome = tostring(claim_data.attempt_outcome or "succeeded"), thread_id = thread_id, action_id = action_id, attempt_id = attempt_id, receipt = initial_receipt}
    end

    -- 2. Check previous checkpoint for resume
    local messages: {types.Message} = {}
    local checkpoint_res = call_func(CARRIER_OPS .. ":checkpoint", {thread_id = thread_id, attempt_id = attempt_id})
    local checkpoint_data = reply_value(checkpoint_res)
    if checkpoint_data and type(checkpoint_data.checkpoint) == "table" then
        local saved = checkpoint_data.checkpoint :: {[string]: unknown}
        local state_val = type(saved.normalizer_state) == "table" and (saved.normalizer_state :: {[string]: unknown}) or {}
        if type(state_val.messages) == "table" then
            messages = state_val.messages :: {types.Message}
        end
    end

    -- 3. Resolve host configuration
    local raw_config: unknown = request.host_config
    if raw_config == nil then
        local conf_entry = registry.get("bee.driver.wippy:host_config")
        if conf_entry and type(conf_entry.data) == "table" then
            raw_config = conf_entry.data
        else
            raw_config = {}
        end
    end
    local host_config, config_error = M.decode_host_config(raw_config)
    if not host_config then
        return fail_run("decode host configuration: " .. tostring(config_error))
    end

    local function commit(idem: string, records: {{[string]: unknown}}, terminal: {[string]: unknown}?): (boolean, string?)
        local checkpoint: {[string]: unknown} = {
            schema_revision = M.CHECKPOINT_REVISION,
            normalizer_state = {messages = messages},
        }
        if terminal then checkpoint.terminal = terminal end
        local res, res_err = call_func(CARRIER_OPS .. ":commit", {
            thread_id = thread_id,
            attempt_id = attempt_id,
            carrier_epoch = epoch,
            expected_revision = revision,
            idempotency_key = idem,
            checkpoint = checkpoint,
            records = records,
        })
        local value = reply_value(res)
        if not value then
            return false, reply_error(res, res_err or "commit failed")
        end
        local next_revision = math.floor(tonumber(value.checkpoint_revision) or (revision + 1))
        revision = next_revision
        return true, nil
    end

    local function settle(outcome: string, answer: string?): types.RunResult
        commit(idempotency_key .. "-final", {}, {outcome = outcome, answer = answer})
        call_func(THREADS .. ":receipt", {
            thread_id = thread_id,
            action_id = action_id,
            attempt_id = attempt_id,
            carrier_epoch = epoch,
            idempotency_key = idempotency_key .. "-terminal-receipt",
            receipt = {
                scope = "attempt",
                outcome = outcome,
                evidence_refs = {},
            },
        })
        local final_receipt: types.RunReceipt = {
            scope = "attempt",
            thread_id = thread_id,
            action_id = action_id,
            attempt_id = attempt_id,
            state = "ended",
            idempotency_key = idempotency_key,
        }
        return {
            ok = outcome ~= "failed",
            outcome = outcome,
            answer = answer,
            thread_id = thread_id,
            action_id = action_id,
            attempt_id = attempt_id,
            receipt = final_receipt,
            state = "ended",
            status = "ended",
        }
    end

    -- 4. Resolve agent closure if agent_ref provided
    local closure: {[string]: unknown}? = nil
    local instructions = "You are a helpful assistant."
    local tool_schemas: {{[string]: unknown}} = {}
    local tool_map: {[string]: {[string]: unknown}} = {}

    if agent_ref and agent_ref ~= "" then
        local pinned = registry.snapshot()
        local resolved, res_err = M.resolve_agent(pinned, agent_ref, host_config)
        if not resolved then
            return fail_run("resolve agent closure: " .. tostring(res_err))
        end
        closure = resolved
        instructions = tostring(closure.instructions or instructions)

        local mem_list = closure.memory :: {string}?
        if mem_list and #mem_list > 0 and #messages == 0 then
            for _, mem_ref in ipairs(mem_list) do
                local mem_record = {
                    source = "bee",
                    body = {
                        type = "extension",
                        event_key = "memory:" .. mem_ref .. ":" .. attempt_id,
                        data = {
                            type = "extension",
                            event_name = "bee.carrier.memory",
                            event_revision = "1",
                            payload_json = json.encode({memory_ref = mem_ref, attempt_id = attempt_id}),
                        },
                    },
                }
                local committed, commit_err = commit(idempotency_key .. "-mem-" .. mem_ref, {mem_record}, nil)
                if not committed then
                    return fail_run("commit memory record: " .. tostring(commit_err))
                end
            end
        end

        local tools = closure.tools :: {{[string]: unknown}}? or {}
        for _, t in ipairs(tools) do
            local alias = tostring(t.alias)
            tool_map[alias] = t
            tool_schemas[#tool_schemas + 1] = {
                type = "function",
                ["function"] = {
                    name = alias,
                    description = t.description,
                    parameters = t.input_schema,
                },
            }
        end
    end

    if #messages == 0 then
        messages[#messages + 1] = {role = "system", content = instructions}
        if brief and #brief > 0 then
            messages[#messages + 1] = {role = "user", content = truncate_text(brief, M.MAX_TEXT_BYTES)}
        end
    end

    if not checkpoint_fits(messages) then
        return fail_run("initial checkpoint exceeds " .. tostring(M.MAX_CHECKPOINT_BYTES) .. " bytes")
    end

    local final_answer: string? = nil
    local max_turns = host_config.max_turns or M.MAX_TURNS
    local turn_sequence = 0

    while turn_sequence < max_turns do
        turn_sequence = turn_sequence + 1

        if is_cancelled(thread_id, attempt_id) then
            return settle("cancelled", final_answer)
        end

        local payload: types.ChatPayload = {
            model = (host_config.model or (closure and type(closure.model) == "string" and closure.model) or "default"),
            messages = wire_messages(messages),
            tools = #tool_schemas > 0 and tool_schemas or nil,
            stream = host_config.stream == true,
        }

        local resp, chat_err = client.chat_completions(host_config, payload, workspace_id, function()
            return is_cancelled(thread_id, attempt_id)
        end)

        if chat_err == "cancelled" or is_cancelled(thread_id, attempt_id) then
            return settle("cancelled", final_answer)
        end

        if chat_err or not resp then
            local failed = settle("failed", final_answer)
            failed.ok = false
            failed.error = "chat completions: " .. tostring(chat_err)
            return failed
        end

        if resp.tool_calls and #resp.tool_calls > 0 then
            if #resp.tool_calls > M.MAX_TOOL_CALLS_PER_TURN then
                local failed = settle("failed", final_answer)
                failed.ok = false
                failed.error = "turn requests " .. tostring(#resp.tool_calls) .. " tool calls, above the limit of " .. tostring(M.MAX_TOOL_CALLS_PER_TURN)
                return failed
            end
            local assistant_msg: types.Message = {
                role = "assistant",
                content = resp.content,
                tool_calls = resp.tool_calls,
            }
            messages[#messages + 1] = assistant_msg

            local tool_records: {{[string]: unknown}} = {}

            for _, tc in ipairs(resp.tool_calls) do
                local fn_name = tc.name
                local fn_args_str = tc.arguments
                local decoded_args: {[string]: unknown} = {}
                if #fn_args_str > 0 then
                    local dec, dec_err = json.decode(fn_args_str)
                    if not dec_err and type(dec) == "table" then
                        decoded_args = dec :: {[string]: unknown}
                    end
                end

                tool_records[#tool_records + 1] = {
                    source = "bee",
                    body = {
                        type = "extension",
                        event_key = "tool_call:" .. attempt_id .. ":" .. tostring(turn_sequence) .. ":" .. tc.id,
                        data = {
                            type = "extension",
                            event_name = "bee.carrier.output",
                            event_revision = "1",
                            payload_json = json.encode({
                                type = "tool_call",
                                id = tc.id,
                                tool = fn_name,
                                input = decoded_args,
                            }),
                        },
                    },
                }

                local matched_tool = tool_map[fn_name]
                local ok_exec, tool_output
                if matched_tool then
                    ok_exec, tool_output = M.execute_tool(matched_tool, decoded_args, attempt_id, workspace_id)
                else
                    ok_exec = false
                    tool_output = {code = "NOT_FOUND", message = "tool " .. fn_name .. " is not admitted in the agent capability grant"}
                end

                local result_payload = {
                    type = "tool_result",
                    id = tc.id,
                    tool = fn_name,
                    outcome = ok_exec and "succeeded" or "failed",
                    output = tool_output,
                }
                tool_records[#tool_records + 1] = {
                    source = "bee",
                    body = {
                        type = "extension",
                        event_key = "tool_result:" .. attempt_id .. ":" .. tostring(turn_sequence) .. ":" .. tc.id,
                        data = {
                            type = "extension",
                            event_name = "bee.carrier.output",
                            event_revision = "1",
                            payload_json = json.encode(result_payload),
                        },
                    },
                }

                messages[#messages + 1] = {
                    role = "tool",
                    tool_call_id = tc.id,
                    content = encode_tool_output(tool_output),
                }
            end

            if not checkpoint_fits(messages) then
                local failed = settle("failed", final_answer)
                failed.ok = false
                failed.error = "checkpoint exceeds " .. tostring(M.MAX_CHECKPOINT_BYTES) .. " bytes"
                return failed
            end

            local committed, commit_err = commit(idempotency_key .. "-turn-" .. tostring(turn_sequence), tool_records, nil)
            if not committed then
                local failed = settle("failed", final_answer)
                failed.ok = false
                failed.error = "commit turn records: " .. tostring(commit_err)
                return failed
            end
        else
            if resp.content then
                final_answer = truncate_text(tostring(resp.content), M.MAX_TEXT_BYTES)
                messages[#messages + 1] = {role = "assistant", content = final_answer}

                local answer_record = {
                    source = "bee",
                    body = {
                        type = "extension",
                        event_key = "answer:" .. attempt_id .. ":" .. tostring(turn_sequence),
                        data = {
                            type = "extension",
                            event_name = "bee.carrier.output",
                            event_revision = "1",
                            payload_json = json.encode({
                                type = "text",
                                text = final_answer,
                                channel = "answer",
                            }),
                        },
                    },
                }

                if not checkpoint_fits(messages) then
                    local failed = settle("failed", final_answer)
                    failed.ok = false
                    failed.error = "checkpoint exceeds " .. tostring(M.MAX_CHECKPOINT_BYTES) .. " bytes"
                    return failed
                end

                local committed, commit_err = commit(idempotency_key .. "-ans-" .. tostring(turn_sequence), {answer_record}, {outcome = "succeeded", answer = final_answer})
                if not committed then
                    local failed = settle("failed", final_answer)
                    failed.ok = false
                    failed.error = "commit answer record: " .. tostring(commit_err)
                    return failed
                end
            end

            local inbox_offer, _ = call_func(THREADS .. ":inbox_offer", {
                thread_id = thread_id,
                action_id = action_id,
                attempt_id = attempt_id,
                carrier_epoch = epoch,
            })
            local offered = reply_value(inbox_offer)
            if offered and offered.dispatch == true and offered.empty ~= true then
                local seq = math.floor(tonumber(offered.inbox_sequence) or 0)
                local rec_id = offered.record_id
                if seq < 1 or type(rec_id) ~= "string" or rec_id == "" then
                    return settle("succeeded", final_answer)
                end

                local transport_res = call_func(THREADS .. ":inbox_transport", {
                    thread_id = thread_id,
                    action_id = action_id,
                    attempt_id = attempt_id,
                    carrier_epoch = epoch,
                    inbox_sequence = seq,
                    record_id = rec_id,
                })
                if not reply_value(transport_res) then
                    return settle("succeeded", final_answer)
                end
                local ack_res = call_func(THREADS .. ":inbox_ack", {
                    thread_id = thread_id,
                    action_id = action_id,
                    inbox_sequence = seq,
                    idempotency_key = idempotency_key .. "-ack-" .. tostring(seq),
                })
                if not reply_value(ack_res) then
                    return settle("succeeded", final_answer)
                end

                local user_text: string? = nil
                if type(offered.content) == "table" then
                    local content = offered.content :: {[string]: unknown}
                    if type(content.text) == "string" and content.text ~= "" then
                        user_text = truncate_text(content.text :: string, M.MAX_TEXT_BYTES)
                    elseif type(content.artifact_ref) == "string" and content.artifact_ref ~= "" then
                        user_text = "Delivered artifact " .. truncate_text(content.artifact_ref :: string, 512) .. "."
                    end
                end
                messages[#messages + 1] = {role = "user", content = user_text or "New inbox message."}
            else
                return settle("succeeded", final_answer)
            end
        end
    end

    local exhausted = settle("failed", final_answer)
    exhausted.ok = false
    exhausted.error = "turn limit of " .. tostring(max_turns) .. " exceeded without a final answer"
    return exhausted
end

return M
