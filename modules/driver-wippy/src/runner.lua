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
local AGENT_RESOLVER = "bee.harness.launch:agent_resolver"

local function call_func(target: string, request: unknown): (unknown, string?)
    local ok, reply, err = pcall(function()
        return funcs.call(target, request)
    end)
    if not ok then return nil, tostring(reply) end
    if err then return nil, tostring(err) end
    return reply, nil
end

local function is_cancelled(thread_id: string, attempt_id: string): boolean
    local res, err = call_func(CARRIER_OPS .. ":cancel_status", {thread_id = thread_id, attempt_id = attempt_id})
    if res and type(res) == "table" then
        local obj = res :: {[string]: unknown}
        if obj.ok == true and type(obj.value) == "table" then
            local val = obj.value :: {[string]: unknown}
            if val.state == "cancelling" or val.state == "ended" then
                return true
            end
        end
    end
    return false
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

    local admitted_delegates: {string} = {}
    for _, d in ipairs(closure.delegates) do
        admitted_delegates[#admitted_delegates + 1] = d.ref
    end

    local checked, route_code, route_err = resolver.check_route(closure, {
        driver_id = "wippy",
        model_map = model_map,
        admitted_delegates = admitted_delegates,
    })
    if not checked then return nil, route_err or route_code or "route check failed" end

    return closure :: {[string]: unknown}, nil
end

function M.execute_tool(tool_entry: {[string]: unknown}, args: {[string]: unknown}, caller_id: string, workspace_id: string?): (boolean, unknown)
    local tool_ref = tostring(tool_entry.ref)
    local scopes = tool_entry.scopes :: {string}? or {}

    local policies: {security.Policy} = {}
    for _, name in ipairs(scopes) do
        local pol, err = security.policy(name)
        if err or not pol then
            return false, {code = "DENIED", message = "cannot load policy " .. name .. ": " .. tostring(err)}
        end
        policies[#policies + 1] = pol
    end

    local actor, actor_err = security.new_actor(caller_id, {workspace_id = workspace_id or ""})
    if not actor then
        return false, {code = "DENIED", message = "actor creation failed: " .. tostring(actor_err)}
    end

    local scope = security.new_scope(policies)
    local executor, exec_err = funcs.new():with_actor(actor)
    if not executor then return false, {code = "DENIED", message = tostring(exec_err)} end

    local scoped, scope_err = executor:with_scope(scope)
    if not scoped then return false, {code = "DENIED", message = tostring(scope_err)} end

    local reply, call_err = scoped:call(tool_ref, args)
    if call_err then
        return false, {code = "FAILED", message = tostring(call_err)}
    end
    return true, reply
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

    -- 1. Claim carrier epoch
    local claim_res, claim_err = call_func(CARRIER_OPS .. ":claim", {
        thread_id = thread_id,
        attempt_id = attempt_id,
        idempotency_key = idempotency_key .. "-claim",
    })
    if claim_err or not claim_res then
        return {ok = false, error = "claim attempt: " .. tostring(claim_err), outcome = "failed", thread_id = thread_id, action_id = action_id, attempt_id = attempt_id, receipt = initial_receipt}
    end

    local claim_data = (claim_res :: {[string]: unknown}).value :: {[string]: unknown}
    local epoch = math.floor(tonumber(claim_data.carrier_epoch) or 1)
    local revision = math.floor(tonumber(claim_data.checkpoint_revision) or 0)

    -- Check if already ended
    if claim_data.attempt_state == "ended" then
        return {ok = true, outcome = tostring(claim_data.attempt_outcome or "succeeded"), thread_id = thread_id, action_id = action_id, attempt_id = attempt_id, receipt = initial_receipt}
    end

    -- 2. Check previous checkpoint for resume
    local messages: {types.Message} = {}
    local checkpoint_res = call_func(CARRIER_OPS .. ":checkpoint", {thread_id = thread_id, attempt_id = attempt_id})
    local prev_checkpoint: {[string]: unknown}? = nil
    if checkpoint_res and type(checkpoint_res) == "table" then
        local cp_val = (checkpoint_res :: {[string]: unknown}).value :: {[string]: unknown}?
        if cp_val and type(cp_val.checkpoint) == "table" then
            prev_checkpoint = cp_val.checkpoint :: {[string]: unknown}
            local state_val = prev_checkpoint.normalizer_state :: {[string]: unknown}?
            if state_val and type(state_val.messages) == "table" then
                messages = state_val.messages :: {types.Message}
            end
        end
    end

    -- 3. Resolve host configuration
    local host_config = request.host_config
    if not host_config then
        local conf_entry = registry.get("bee.driver.wippy:host_config")
        if conf_entry and type(conf_entry.data) == "table" then
            host_config = conf_entry.data :: types.HostConfig
        else
            host_config = {endpoint = "http://127.0.0.1:8080/v1"}
        end
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
            return {ok = false, error = "resolve agent closure: " .. tostring(res_err), outcome = "failed", thread_id = thread_id, action_id = action_id, attempt_id = attempt_id, receipt = initial_receipt}
        end
        closure = resolved
        instructions = tostring(closure.instructions or instructions)

        -- Handle memory declarations
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
                revision = revision + 1
                call_func(CARRIER_OPS .. ":commit", {
                    thread_id = thread_id,
                    attempt_id = attempt_id,
                    carrier_epoch = epoch,
                    expected_revision = revision - 1,
                    idempotency_key = idempotency_key .. "-mem-" .. mem_ref,
                    checkpoint = {
                        schema_revision = "bee.carrier.checkpoint@1",
                        normalizer_state = {messages = messages},
                    },
                    records = {mem_record},
                })
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

    -- Initial messages if not resuming
    if #messages == 0 then
        messages[#messages + 1] = {role = "system", content = instructions}
        if brief and #brief > 0 then
            messages[#messages + 1] = {role = "user", content = brief}
        end
    end

    local final_answer: string? = nil
    local settled_outcome: string = "succeeded"
    local turn_sequence = 0

    -- Main execution loop
    while true do
        turn_sequence = turn_sequence + 1

        -- A. Check cancellation
        if is_cancelled(thread_id, attempt_id) then
            settled_outcome = "cancelled"
            break
        end

        -- B. Prepare ChatPayload
        local payload: types.ChatPayload = {
            model = (host_config.model or (closure and type(closure.model) == "string" and closure.model) or "default"),
            messages = messages,
            tools = #tool_schemas > 0 and tool_schemas or nil,
            stream = host_config.stream == true,
        }

        -- C. Execute Chat Completions
        local resp, chat_err = client.chat_completions(host_config, payload, function()
            return is_cancelled(thread_id, attempt_id)
        end)

        if chat_err == "cancelled" or is_cancelled(thread_id, attempt_id) then
            settled_outcome = "cancelled"
            break
        end

        if chat_err or not resp then
            settled_outcome = "failed"
            return {
                ok = false,
                error = "chat completions: " .. tostring(chat_err),
                outcome = "failed",
                thread_id = thread_id,
                action_id = action_id,
                attempt_id = attempt_id,
                receipt = initial_receipt,
            }
        end

        -- D. Process Tool Calls if returned
        if resp.tool_calls and #resp.tool_calls > 0 then
            local assistant_msg: types.Message = {
                role = "assistant",
                content = resp.content,
                tool_calls = resp.tool_calls,
            }
            messages[#messages + 1] = assistant_msg

            local tool_records: {{[string]: unknown}} = {}

            for _, tc in ipairs(resp.tool_calls) do
                local fn_obj = (type(tc["function"]) == "table" and tc["function"] or {}) :: {[string]: unknown}
                local fn_name = tostring(fn_obj.name or "")
                local fn_args_str = tostring(fn_obj.arguments or "")
                local decoded_args: {[string]: unknown} = {}
                if #fn_args_str > 0 then
                    local dec, dec_err = json.decode(fn_args_str)
                    if not dec_err and type(dec) == "table" then
                        decoded_args = dec :: {[string]: unknown}
                    end
                end

                -- Record tool.call observation via bee.carrier.output
                tool_records[#tool_records + 1] = {
                    source = "bee",
                    body = {
                        type = "extension",
                        event_key = "tool_call:" .. tc.id,
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

                -- Execute tool with grant isolation
                local matched_tool = tool_map[fn_name]
                local ok_exec, tool_output
                if matched_tool then
                    ok_exec, tool_output = M.execute_tool(matched_tool, decoded_args, attempt_id, workspace_id)
                else
                    ok_exec = false
                    tool_output = {code = "NOT_FOUND", message = "tool " .. fn_name .. " is not available"}
                end

                -- Record tool.result observation via bee.carrier.output
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
                        event_key = "tool_result:" .. tc.id,
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
                    content = json.encode(tool_output),
                }
            end

            -- Commit records & checkpoint
            revision = revision + 1
            call_func(CARRIER_OPS .. ":commit", {
                thread_id = thread_id,
                attempt_id = attempt_id,
                carrier_epoch = epoch,
                expected_revision = revision - 1,
                idempotency_key = idempotency_key .. "-turn-" .. tostring(turn_sequence),
                checkpoint = {
                    schema_revision = "bee.carrier.checkpoint@1",
                    normalizer_state = {messages = messages},
                },
                records = tool_records,
            })

            -- Continue the turn loop to get model's answer with tool results
        else
            -- E. Final content received
            if resp.content then
                final_answer = tostring(resp.content)
                messages[#messages + 1] = {role = "assistant", content = resp.content}

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
                                text = resp.content,
                                channel = "answer",
                            }),
                        },
                    },
                }

                revision = revision + 1
                call_func(CARRIER_OPS .. ":commit", {
                    thread_id = thread_id,
                    attempt_id = attempt_id,
                    carrier_epoch = epoch,
                    expected_revision = revision - 1,
                    idempotency_key = idempotency_key .. "-ans-" .. tostring(turn_sequence),
                    checkpoint = {
                        schema_revision = "bee.carrier.checkpoint@1",
                        normalizer_state = {messages = messages},
                        terminal = {outcome = "succeeded", answer = final_answer},
                    },
                    records = {answer_record},
                })
            end

            -- F. Check inbox for new turns
            local inbox_offer, _ = call_func(THREADS .. ":inbox_offer", {
                thread_id = thread_id,
                action_id = action_id,
                attempt_id = attempt_id,
                carrier_epoch = epoch,
            })
            local offered = (inbox_offer and type(inbox_offer) == "table" and (inbox_offer :: {[string]: unknown}).value) :: {[string]: unknown}?
            if offered and offered.dispatch == true and offered.empty ~= true then
                local seq = math.floor(tonumber(offered.inbox_sequence) or 1)
                local rec_id = tostring(offered.record_id or "")

                -- Accept transport
                call_func(THREADS .. ":inbox_transport", {
                    thread_id = thread_id,
                    action_id = action_id,
                    attempt_id = attempt_id,
                    carrier_epoch = epoch,
                    inbox_sequence = seq,
                    record_id = rec_id,
                })
                -- Ack
                call_func(THREADS .. ":inbox_ack", {
                    thread_id = thread_id,
                    action_id = action_id,
                    inbox_sequence = seq,
                    idempotency_key = idempotency_key .. "-ack-" .. tostring(seq),
                })

                -- Deliver as new user turn
                local user_text = "New inbox message."
                if offered.content and type(offered.content) == "table" then
                    local c = offered.content :: {[string]: unknown}
                    if type(c.text) == "string" then user_text = c.text :: string end
                elseif type(offered.text) == "string" then
                    user_text = offered.text :: string
                end

                messages[#messages + 1] = {role = "user", content = user_text}
                -- Loop back to execute next turn with inbox message
            else
                -- No more turns, settled!
                settled_outcome = "succeeded"
                break
            end
        end
    end

    -- 5. Terminal settlement
    revision = revision + 1
    call_func(CARRIER_OPS .. ":commit", {
        thread_id = thread_id,
        attempt_id = attempt_id,
        carrier_epoch = epoch,
        expected_revision = revision - 1,
        idempotency_key = idempotency_key .. "-final",
        checkpoint = {
            schema_revision = "bee.carrier.checkpoint@1",
            normalizer_state = {messages = messages},
            terminal = {outcome = settled_outcome, answer = final_answer},
        },
        records = {},
    })

    call_func(THREADS .. ":receipt", {
        thread_id = thread_id,
        action_id = action_id,
        attempt_id = attempt_id,
        carrier_epoch = epoch,
        idempotency_key = idempotency_key .. "-terminal-receipt",
        receipt = {
            scope = "attempt",
            outcome = settled_outcome,
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
        ok = settled_outcome ~= "failed",
        outcome = settled_outcome,
        answer = final_answer,
        thread_id = thread_id,
        action_id = action_id,
        attempt_id = attempt_id,
        receipt = final_receipt,
        state = "ended",
        status = "ended",
    }
end

return M
