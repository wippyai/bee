-- MIT. Unit tests for the native Wippy in-process agent driver.
-- Tests stand-in OpenAI-compatible chat endpoint:
-- 1. Multi-turn tool calls and execution with grant isolation
-- 2. Streaming SSE accumulation of content and tool arguments
-- 3. Cancellation receipts and terminal state
-- 4. Restart, checkpoint continuation and epoch fencing
local test = require("test")
local principals = require("principals")
local bounds = require("bounds")
local system = require("system")
local json = require("json")
local registry = require("registry")
local funcs = require("funcs")
local security = require("security")
local harness = require("harness")
local events = require("events")
local channel = require("channel")
local time = require("time")

type Object = {[string]: unknown}
type Reply = {ok: boolean, error: {code: string, message: string, retryable: boolean}?, value: unknown}
type InboxInvoker = (string, Object) -> (unknown, string?)
local WORKSPACE_ID = string.rep("a", 32)

local THREAD_POLICIES = {
    "bee.threads:client_test_policy",
    "bee.security.threads:thread_create_policy",
    "bee.security.threads:thread_observe_policy",
    "bee.security.threads:thread_lifecycle_policy",
    "bee.security.threads:thread_carrier_policy",
    "bee.harness.security:carrier_policy",
    "bee.driver.wippy.test:test_http_policy",
}

local function listener_ready(status: string, details: string?): boolean
    return status == "running" and details ~= nil and details:match("^service listening on [%d%.]+:%d+$") ~= nil
end

local function get_mock_url(): string
    local reference = "bee.driver.wippy.test:mock_listener"
    local subscription, subscription_error = events.subscribe("supervisor", "service.update")
    if subscription_error or not subscription then error("subscribe to mock listener state: " .. tostring(subscription_error)) end
    local updates = subscription:channel()
    local state, state_error = system.supervisor.state(reference)
    if state_error or not state then
        subscription:close()
        error("read mock listener state: " .. tostring(state_error))
    end
    local deadline = time.after("30s")
    while not listener_ready(state.status, state.details) do
        if state.status ~= "starting" and state.status ~= "running" then
            subscription:close()
            error("mock listener entered " .. state.status)
        end
        local selected = channel.select({updates = updates:case_receive(), deadline = deadline:case_receive()})
        if not selected.ok or selected.channel == deadline then
            subscription:close()
            error("timed out waiting for mock listener address")
        end
        local raw_event = selected.value
        if type(raw_event) == "table" then
            local event = assert(bounds.object(raw_event))
            if event.system == "supervisor" and event.kind == "service.update" and event.path == reference then
                state, state_error = system.supervisor.state(reference)
                if state_error or not state then
                    subscription:close()
                    error("read mock listener state: " .. tostring(state_error))
                end
            end
        end
    end
    subscription:close()
    local details = state.details
    if not details then error("mock listener address detail unavailable") end
    local addr = details:match("^service listening on ([%d%.]+:%d+)$")
    if not addr then
        error("failed to parse listener addr from: " .. details)
    end
    return "http://" .. addr .. "/v1"
end

local function make_caller(): funcs.Executor
    local actor = security.new_actor("carrier-tester", {workspace_id = WORKSPACE_ID})
    local policies: {security.Policy} = {}
    for _, name in ipairs(THREAD_POLICIES) do
        local pol, err = security.policy(name)
        if not pol then error("policy " .. name .. ": " .. tostring(err)) end
        policies[#policies + 1] = pol
    end
    return funcs.new():with_actor(actor):with_scope(security.new_scope(policies))
end

local function raw_call(target: string, req: Object): Object
    local caller = make_caller()
    local request = req
    if target == "bee.driver.wippy.binding:run" and req.operation == "run" and req.workspace_id == nil then
        local scoped: Object = {}
        for key, value in pairs(req) do scoped[key] = value end
        scoped.workspace_id = WORKSPACE_ID
        request = scoped
    end
    local reply, err = caller:call(target, request)
    if err then error("call " .. target .. ": " .. tostring(err)) end
    if type(reply) ~= "table" then error(target .. " returned " .. type(reply)) end
    return assert(bounds.object(reply))
end

local function one_chunk(value: string): (integer) -> (string?, string?)
    local delivered = false
    return function(_: integer): (string?, string?)
        if delivered then return nil, nil end
        delivered = true
        return value, nil
    end
end

local function inbox_offer(): Object
    return {thread_id = "thread-1", action_id = "action-1", inbox_sequence = 1, record_id = "record-1",
        payload_digest = string.rep("a", 64), message_id = "message-1", message_kind = "notification",
        content = {text = "follow up"}, sender_action_id = "sender-action", sender_thread_id = "sender-thread",
        sender_node_id = "sender-node", state = "offered", dispatch = true, offer_count = 1}
end

local function inbox_reply(value: unknown): Object
    return {ok = true, value = value}
end

local function inbox_call(fail_at: string?, failure: unknown, call_error: string?): InboxInvoker
    return function(operation: string, _: Object): (unknown, string?)
        if operation == fail_at then return failure, call_error end
        if operation == "inbox_offer" then return inbox_reply(inbox_offer()), nil end
        if operation == "inbox_transport" then
            return inbox_reply({record_id = "record-1", inbox_sequence = 1, state = "transport_accepted"}), nil
        end
        return inbox_reply({record_id = "record-1", inbox_sequence = 1, state = "acknowledged"}), nil
    end
end

local function driver_call(operation: string, req: Object): Object
    local payload = {}
    for k, v in pairs(req) do payload[k] = v end
    payload.operation = operation
    local rep = raw_call("bee.driver.wippy.binding:run", payload)
    if not rep.ok and (not rep.value or (assert(bounds.object(rep.value))).outcome ~= "cancelled") then
        error("driver_call " .. operation .. " failed: " .. json.encode(rep))
    end
    return rep
end

local function seed_registry()
    local snap = registry.snapshot()
    local agent_id = "bee.driver.wippy.test:test_agent"
    local trait_id = "bee.driver.wippy.test:test_trait"
    local wrapper_trait_id = "bee.driver.wippy.test:wrapper_trait"
    local wrapper_agent_id = "bee.driver.wippy.test:wrapper_agent"
    local memory_agent_id = "bee.driver.wippy.test:memory_agent"
    local delegate_id = "bee.driver.wippy.test:helper_agent"
    local delegate_agent_id = "bee.driver.wippy.test:delegate_agent"
    local key_id = "bee.driver.wippy.test:api_key"
    local changes = snap:changes()
    local agent_entry = {
        id = agent_id,
        kind = "registry.entry",
        meta = {type = "agent.gen1", title = "Test Reviewer", test_support = true},
        data = {
            prompt = "Review the supplied change.",
            traits = {trait_id},
            tools = {"bee.driver.wippy.test:test_tool"},
            delegates = {},
            memory = {},
            context = {repo = "workspace"},
            model = "default",
            tuning = {},
            declinable = {},
        }
    }
    local trait_entry = {
        id = trait_id,
        kind = "registry.entry",
        meta = {type = "agent.trait", title = "Test Trait", test_support = true},
        data = {
            prompt = "Follow instructions.",
            tools = {"bee.driver.wippy.test:test_tool"},
            context = {repo = "workspace"},
        }
    }
    local wrapper_trait_entry = {
        id = wrapper_trait_id,
        kind = "registry.entry",
        meta = {type = "agent.trait", title = "Wrapper Trait", test_support = true},
        data = {
            prompt = "Wrap every answer.",
            tools = {},
            wrappers = {"bee.driver.wippy.test:wrapper"},
            context = {},
        }
    }
    local wrapper_agent_entry = {
        id = wrapper_agent_id,
        kind = "registry.entry",
        meta = {type = "agent.gen1", title = "Wrapper Agent", test_support = true},
        data = {
            prompt = "Review with wrappers.",
            traits = {wrapper_trait_id},
            tools = {},
            delegates = {},
            memory = {},
            context = {},
            tuning = {},
            declinable = {},
        }
    }
    local memory_agent_entry = {
        id = memory_agent_id,
        kind = "registry.entry",
        meta = {type = "agent.gen1", title = "Memory Agent", test_support = true},
        data = {
            prompt = "Remember the facts.",
            traits = {},
            tools = {},
            delegates = {},
            memory = {"facts"},
            context = {},
            tuning = {},
            declinable = {},
        }
    }
    local delegate_entry = {
        id = delegate_id,
        kind = "registry.entry",
        meta = {type = "agent.gen1", title = "Helper Agent", test_support = true},
        data = {
            prompt = "Help out.",
            traits = {},
            tools = {},
            delegates = {},
            memory = {},
            context = {},
            tuning = {},
            declinable = {},
        }
    }
    local delegate_agent_entry = {
        id = delegate_agent_id,
        kind = "registry.entry",
        meta = {type = "agent.gen1", title = "Delegating Agent", test_support = true},
        data = {
            prompt = "Delegate the work.",
            traits = {},
            tools = {},
            delegates = {delegate_id},
            memory = {},
            context = {},
            tuning = {},
            declinable = {},
        }
    }
    local key_entry = {
        id = key_id,
        kind = "registry.entry",
        meta = {type = "test_support", title = "API Key", test_support = true},
        data = {api_key = "secret-xyz-test-key"},
    }
    local entries = {agent_entry, trait_entry, wrapper_trait_entry, wrapper_agent_entry,
        memory_agent_entry, delegate_entry, delegate_agent_entry, key_entry}
    for _, entry in ipairs(entries) do
        if snap:get(entry.id) then
            changes:update(entry)
        else
            changes:create(entry)
        end
    end
    local applied, apply_err = changes:apply()
    if not applied then
        error("seed_registry apply failed: " .. tostring(apply_err))
    end
end

    local function define_tests()
    seed_registry()
    test.describe("Native Wippy Agent Driver", function()
        local carrier_client = harness.principal("carrier-tester", THREAD_POLICIES, WORKSPACE_ID)

        local function new_thread(title: string): string
            return harness.thread(carrier_client, title)
        end

        local function prepare(thread_id: string, action_id: string, attempt_id: string)
            seed_registry()
            local admitted = harness.admitted()
            admitted.principal_id = carrier_client.id
            harness.value(carrier_client:call("admit_action", {
                thread_id = thread_id,
                idempotency_key = harness.key(),
                action_id = action_id,
                admitted = admitted,
            }))
            harness.value(carrier_client:call("prepare_attempt", {
                thread_id = thread_id,
                idempotency_key = harness.key(),
                action_id = action_id,
                attempt_id = attempt_id,
                prepared = harness.prepared(),
            }))
        end

        local function has_attempt_event(thread_id: string, prefix: string): boolean
            local page = assert(bounds.object(harness.value(carrier_client:call("read_after", {thread_id = thread_id, cursor = 0}))))
            for _, record in ipairs(principals.objects(page.records)) do
                local body = record.body
                if type(body) == "table" then
                    local event_key = (assert(bounds.object(body))).event_key
                    if type(event_key) == "string" and event_key:find(prefix, 1, true) then return true end
                end
            end
            return false
        end

        test.it("executes multi-turn conversation with tool calls and commits observations", function()
            local url = get_mock_url()
            local thread_id = new_thread("Tool Calls Thread")
            local action_id = "act-tc-1"
            local attempt_id = "att-tc-1"
            prepare(thread_id, action_id, attempt_id)

            local res = driver_call("run", {
                thread_id = thread_id,
                action_id = action_id,
                attempt_id = attempt_id,
                agent_ref = "bee.driver.wippy.test:test_agent",
                brief = "Please call_tool FileReport for review",
                host_config = {
                    endpoint = url,
                    model = "default",
                    stream = false,
                },
            })

            test.is_true(res.ok)
            local val = assert(bounds.object(res.value))
            test.eq(val.outcome, "succeeded")
            test.eq(val.state, "ended")
            test.not_nil(val.answer)
            test.is_true(tostring(val.answer):find("Result:", 1, true) ~= nil)
            test.is_true(tostring(val.answer):find("nonstream-review-done", 1, true) ~= nil)

            -- Verify receipt
            local receipt = assert(bounds.object(val.receipt))
            test.not_nil(receipt)
            test.eq(receipt.scope, "attempt")
            test.eq(receipt.state, "ended")

            -- Verify carrier events recorded tool calls
            local page = assert(bounds.object(harness.value(carrier_client:call("read_after", {
                thread_id = thread_id,
                cursor = 0,
            }))))
            local records = principals.objects(page.records)
            test.is_true(#records > 0)

            local found_tool_call = false
            local found_tool_result = false
            for _, rec in ipairs(records) do
                local body = assert(bounds.object(rec.body))
                if body and type(body.event_key) == "string" then
                    if tostring(body.event_key):find("tool_call:att-tc-1:1:call_tc_1", 1, true) then
                        found_tool_call = true
                    end
                    if tostring(body.event_key):find("tool_result:att-tc-1:1:call_tc_1", 1, true) then
                        found_tool_result = true
                    end
                end
            end
            test.is_true(found_tool_call)
            test.is_true(found_tool_result)
        end)

        test.it("enforces grant isolation when model requests an unadmitted tool", function()
            local url = get_mock_url()
            local thread_id = new_thread("Grant Isolation Thread")
            local action_id = "act-gi-1"
            local attempt_id = "att-gi-1"
            prepare(thread_id, action_id, attempt_id)

            -- Request with prompt triggering unadmitted tool call in mock server
            local res = driver_call("run", {
                thread_id = thread_id,
                action_id = action_id,
                attempt_id = attempt_id,
                agent_ref = "bee.driver.wippy.test:test_agent",
                brief = "Please call_unadmitted_tool",
                host_config = {
                    endpoint = url,
                    model = "default",
                    stream = false,
                },
            })

            test.is_true(res.ok)
            local val = assert(bounds.object(res.value))
            test.eq(val.outcome, "succeeded")
            test.eq(val.state, "ended")
            test.not_nil(val.answer)
            -- The model received the typed tool refusal and concluded
            test.is_true(tostring(val.answer):find("NOT_FOUND", 1, true) ~= nil)
            test.is_true(tostring(val.answer):find("not admitted", 1, true) ~= nil)
        end)

        test.it("streams SSE tokens and accumulates tool calls and content", function()
            local url = get_mock_url()

            -- 1. Plain streaming
            local thread_id = new_thread("Streaming Plain Thread")
            local action_id = "act-sp-1"
            local attempt_id = "att-sp-1"
            prepare(thread_id, action_id, attempt_id)

            local res = driver_call("run", {
                thread_id = thread_id,
                action_id = action_id,
                attempt_id = attempt_id,
                agent_ref = "bee.driver.wippy.test:test_agent",
                brief = "Just a standard greeting",
                host_config = {
                    endpoint = url,
                    model = "default",
                    stream = true,
                },
            })

            test.is_true(res.ok)
            local val = assert(bounds.object(res.value))
            test.eq(val.outcome, "succeeded")
            test.eq(val.state, "ended")
            test.eq(val.answer, "Streamed answer success!")

            -- 2. Streaming with tool calls
            local thread_id2 = new_thread("Streaming Tool Call Thread")
            local action_id2 = "act-stc-1"
            local attempt_id2 = "att-stc-1"
            prepare(thread_id2, action_id2, attempt_id2)

            local res2 = driver_call("run", {
                thread_id = thread_id2,
                action_id = action_id2,
                attempt_id = attempt_id2,
                agent_ref = "bee.driver.wippy.test:test_agent",
                brief = "Please call_tool FileReport via stream",
                host_config = {
                    endpoint = url,
                    model = "default",
                    stream = true,
                },
            })

            test.is_true(res2.ok)
            local val2 = assert(bounds.object(res2.value))
            test.eq(val2.outcome, "succeeded")
            test.eq(val2.state, "ended")
            test.not_nil(val2.answer)
            test.is_true(tostring(val2.answer):find("Result:", 1, true) ~= nil)
        end)

        test.it("rejects malformed SSE frames, incomplete streams, missing DONE and read errors", function()
            local partial = 'data: {"choices":[{"index":0,"delta":{"content":"partial"}}]}\n\n'
            local closed = false
            local response, read_error = client.consume_stream(one_chunk(partial), function() closed = true end, nil)
            test.is_nil(response)
            test.is_true(tostring(read_error):find("before [DONE]", 1, true) ~= nil)
            test.is_true(closed)

            closed = false
            local incomplete, incomplete_error = client.consume_stream(one_chunk(partial:sub(1, -3)), function() closed = true end, nil)
            test.is_nil(incomplete)
            test.is_true(tostring(incomplete_error):find("incomplete frame", 1, true) ~= nil)
            test.is_true(closed)

            closed = false
            local oversized, oversized_error = client.consume_stream(one_chunk(string.rep("x", client.MAX_SSE_FRAME_BYTES + 1)),
                function() closed = true end, nil)
            test.is_nil(oversized)
            test.is_true(tostring(oversized_error):find("frame SSE stream", 1, true) ~= nil)
            test.is_true(closed)

            closed = false
            local stream_oversized, stream_size_error = client.consume_stream(one_chunk(string.rep("x", client.MAX_STREAM_BYTES + 1)),
                function() closed = true end, nil)
            test.is_nil(stream_oversized)
            test.is_true(tostring(stream_size_error):find("SSE stream exceeds", 1, true) ~= nil)
            test.is_true(closed)

            local read_count = 0
            closed = false
            local failed, stream_error = client.consume_stream(function(_: integer): (string?, string?)
                read_count = read_count + 1
                if read_count == 1 then return partial, nil end
                return nil, "fixture read failed"
            end, function() closed = true end, nil)
            test.is_nil(failed)
            test.is_true(tostring(stream_error):find("fixture read failed", 1, true) ~= nil)
            test.is_true(closed)
        end)

        test.it("rejects malformed tool arguments before any tool event is committed", function()
            local thread_id = new_thread("Malformed Tool Arguments")
            local action_id, attempt_id = "act-bad-args", "att-bad-args"
            prepare(thread_id, action_id, attempt_id)
            local res = raw_call("bee.driver.wippy.binding:run", {
                operation = "run", thread_id = thread_id, action_id = action_id, attempt_id = attempt_id,
                agent_ref = "bee.driver.wippy.test:test_agent", brief = "call_tool_bad_arguments",
                host_config = {endpoint = get_mock_url(), stream = true},
            })
            test.is_false(res.ok)
            test.eq((assert(bounds.object(res.value))).outcome, "failed")
            test.is_false(has_attempt_event(thread_id, "tool_call:" .. attempt_id .. ":"))
            test.is_false(has_attempt_event(thread_id, "tool_result:" .. attempt_id .. ":"))
        end)

        test.it("rejects a prospective checkpoint over its bound before tool execution", function()
            local thread_id = new_thread("Large Tool Checkpoint")
            local action_id, attempt_id = "act-large-checkpoint", "att-large-checkpoint"
            prepare(thread_id, action_id, attempt_id)
            local res = raw_call("bee.driver.wippy.binding:run", {
                operation = "run", thread_id = thread_id, action_id = action_id, attempt_id = attempt_id,
                agent_ref = "bee.driver.wippy.test:test_agent", brief = "call_tool_large_checkpoint",
                host_config = {endpoint = get_mock_url(), stream = false},
            })
            test.is_false(res.ok)
            test.eq((assert(bounds.object(res.value))).outcome, "failed")
            test.is_true(tostring((assert(bounds.object(res.error))).message):find("prospective tool checkpoint", 1, true) ~= nil)
            test.is_false(has_attempt_event(thread_id, "tool_call:" .. attempt_id .. ":"))
            test.is_false(has_attempt_event(thread_id, "tool_result:" .. attempt_id .. ":"))
        end)

        test.it("decodes checkpoint revision, message variants and terminal fields exactly", function()
            local valid = {schema_revision = runner.CHECKPOINT_REVISION,
                normalizer_state = {messages = {{role = "user", content = "resume"}}}}
            local decoded, decode_error = runner.decode_checkpoint(valid)
            if not decoded then error(tostring(decode_error)) end
            test.eq(decoded.messages[1].role, "user")

            local wrong_revision = {schema_revision = "bee.carrier.checkpoint@9", normalizer_state = {messages = {}}}
            test.is_nil(runner.decode_checkpoint(wrong_revision))
            local unknown_message = {schema_revision = runner.CHECKPOINT_REVISION,
                normalizer_state = {messages = {{role = "user", content = "x", extra = true}}}}
            test.is_nil(runner.decode_checkpoint(unknown_message))
            local malformed_tool = {schema_revision = runner.CHECKPOINT_REVISION,
                normalizer_state = {messages = {{role = "assistant", tool_calls = {{id = "call-1", kind = "function",
                    name = "FileReport", arguments = "[]"}}}}}}
            test.is_nil(runner.decode_checkpoint(malformed_tool))
            local malformed_terminal = {schema_revision = runner.CHECKPOINT_REVISION,
                normalizer_state = {messages = {}}, terminal = {outcome = "succeeded", unexpected = true}}
            test.is_nil(runner.decode_checkpoint(malformed_terminal))
            local sparse = {schema_revision = runner.CHECKPOINT_REVISION,
                normalizer_state = {messages = {[1] = {role = "user", content = "x"}, [3] = {role = "user", content = "y"}}}}
            test.is_nil(runner.decode_checkpoint(sparse))
            local oversized = {schema_revision = runner.CHECKPOINT_REVISION,
                normalizer_state = {messages = {{role = "user", content = string.rep("x", 30000)},
                    {role = "assistant", content = string.rep("y", 30000)}}}}
            test.is_nil(runner.decode_checkpoint(oversized))
        end)

        test.it("preserves inbox offer, transport and acknowledgement failures", function()
            local offer_error = runner.process_inbox("thread-1", "action-1", "attempt-1", 1, "run-key",
                inbox_call("inbox_offer", nil, "offer transport failed"))
            test.eq(offer_error.kind, "failed")
            if offer_error.kind ~= "failed" then error("offer failure was not retained") end
            test.eq(offer_error.outcome, "failed")
            test.is_true(offer_error.message:find("offer inbox", 1, true) ~= nil)

            local malformed_offer = runner.process_inbox("thread-1", "action-1", "attempt-1", 1, "run-key",
                inbox_call("inbox_offer", inbox_reply({empty = true, unexpected = true}), nil))
            test.eq(malformed_offer.kind, "failed")

            local transport_error = runner.process_inbox("thread-1", "action-1", "attempt-1", 1, "run-key",
                inbox_call("inbox_transport", nil, "transport connection lost"))
            if transport_error.kind ~= "failed" then error("transport failure was not retained") end
            test.eq(transport_error.outcome, "uncertain")

            local transport_refusal = runner.process_inbox("thread-1", "action-1", "attempt-1", 1, "run-key",
                inbox_call("inbox_transport", {ok = false, value = nil, error = {code = "DENIED", message = "not admitted", retryable = false}}, nil))
            if transport_refusal.kind ~= "failed" then error("transport refusal was not retained") end
            test.eq(transport_refusal.outcome, "failed")

            local malformed_transport = runner.process_inbox("thread-1", "action-1", "attempt-1", 1, "run-key",
                inbox_call("inbox_transport", inbox_reply({record_id = "other", inbox_sequence = 1, state = "transport_accepted"}), nil))
            if malformed_transport.kind ~= "failed" then error("malformed transport receipt was not retained") end
            test.eq(malformed_transport.outcome, "uncertain")

            local ack_error = runner.process_inbox("thread-1", "action-1", "attempt-1", 1, "run-key",
                inbox_call("inbox_ack", nil, "ack transport failed"))
            if ack_error.kind ~= "failed" then error("acknowledgement failure was not retained") end
            test.eq(ack_error.outcome, "uncertain")

            local ack_refusal = runner.process_inbox("thread-1", "action-1", "attempt-1", 1, "run-key",
                inbox_call("inbox_ack", {ok = false, value = nil, error = {code = "DENIED", message = "ack refused", retryable = false}}, nil))
            if ack_refusal.kind ~= "failed" then error("acknowledgement refusal was not retained") end
            test.eq(ack_refusal.outcome, "uncertain")

            local delivered = runner.process_inbox("thread-1", "action-1", "attempt-1", 1, "run-key", inbox_call(nil, nil, nil))
            test.eq(delivered.kind, "item")
            if delivered.kind ~= "item" then error("valid inbox item was not returned") end
            test.eq(delivered.content.text, "follow up")
        end)

        test.it("honors cancel receipts, intent and status", function()
            local thread_id = new_thread("Cancel Thread")
            local action_id = "act-can-1"
            local attempt_id = "att-can-1"
            prepare(thread_id, action_id, attempt_id)

            -- Cancel operation via driver
            local can_res = driver_call("cancel", {
                thread_id = thread_id,
                attempt_id = attempt_id,
            })
            test.is_true(can_res.ok)
            local can_val = assert(bounds.object(can_res.value))
            test.eq(can_val.state, "cancelling")
            test.eq(can_val.scope, "attempt")

            -- Check status reflects cancel
            local st_res = driver_call("status", {
                thread_id = thread_id,
                attempt_id = attempt_id,
            })
            test.is_true(st_res.ok)
            local st_val = assert(bounds.object(st_res.value))
            test.eq(st_val.scope, "attempt")
            test.is_true(st_val.state == "cancelling" or st_val.state == "ended")

            -- Running the cancelled attempt aborts promptly
            local url = get_mock_url()
            local run_res = driver_call("run", {
                thread_id = thread_id,
                action_id = action_id,
                attempt_id = attempt_id,
                agent_ref = "bee.driver.wippy.test:test_agent",
                brief = "Should not finish",
                host_config = {
                    endpoint = url,
                    model = "default",
                    stream = false,
                },
            })

            -- Result is cancelled
            local r_val = assert(bounds.object(run_res.value))
            test.eq(r_val.outcome, "cancelled")
            test.eq(r_val.state, "ended")
        end)

        test.it("restarts and continues existing thread with epoch fencing", function()
            local url = get_mock_url()
            local thread_id = new_thread("Restart Thread")

            -- Turn 1: Attempt 1
            local action_id1 = "act-rst-1"
            local attempt_id1 = "att-rst-1"
            prepare(thread_id, action_id1, attempt_id1)

            local res1 = driver_call("run", {
                thread_id = thread_id,
                action_id = action_id1,
                attempt_id = attempt_id1,
                agent_ref = "bee.driver.wippy.test:test_agent",
                brief = "First turn greeting",
                host_config = {endpoint = url, stream = false},
            })
            test.is_true(res1.ok)
            local val1 = assert(bounds.object(res1.value))
            test.eq(val1.outcome, "succeeded")
            test.eq(val1.state, "ended")

            -- Turn 2: Attempt 2 on the same thread (continuation / restart)
            local action_id2 = "act-rst-2"
            local attempt_id2 = "att-rst-2"
            prepare(thread_id, action_id2, attempt_id2)

            local res2 = driver_call("run", {
                thread_id = thread_id,
                action_id = action_id2,
                attempt_id = attempt_id2,
                agent_ref = "bee.driver.wippy.test:test_agent",
                brief = "Second turn follow-up",
                host_config = {endpoint = url, stream = false},
            })
            test.is_true(res2.ok)
            local val2 = assert(bounds.object(res2.value))
            test.eq(val2.outcome, "succeeded")
            test.eq(val2.state, "ended")

            -- Check that carrier checkpoint advanced and records are preserved across attempts
            local page = assert(bounds.object(harness.value(carrier_client:call("read_after", {
                thread_id = thread_id,
                cursor = 0,
            }))))
            local records = principals.objects(page.records)
            test.is_true(#records >= 2) -- at least answer from turn 1 and turn 2
        end)

        test.it("completes a long tool-call sequence without a default turn ceiling", function()
            local url = get_mock_url()
            local thread_id = new_thread("Long Thread")
            local action_id = "act-long-1"
            local attempt_id = "att-long-1"
            prepare(thread_id, action_id, attempt_id)

            local res = driver_call("run", {
                thread_id = thread_id,
                action_id = action_id,
                attempt_id = attempt_id,
                agent_ref = "bee.driver.wippy.test:test_agent",
                brief = "Please call_tool_long",
                host_config = {endpoint = url, stream = false},
            })
            test.is_true(res.ok)
            local val = assert(bounds.object(res.value))
            test.eq(val.outcome, "succeeded")
            test.eq(val.state, "ended")
            test.eq(val.answer, "long-run-completed")
            test.is_true(has_attempt_event(thread_id, "tool_call:att-long-1:18:"))
        end)

        test.it("refuses more tool calls per turn than admitted", function()
            local url = get_mock_url()
            local thread_id = new_thread("Many Calls Thread")
            local action_id = "act-many-1"
            local attempt_id = "att-many-1"
            prepare(thread_id, action_id, attempt_id)

            local res = raw_call("bee.driver.wippy.binding:run", {
                operation = "run",
                thread_id = thread_id,
                action_id = action_id,
                attempt_id = attempt_id,
                agent_ref = "bee.driver.wippy.test:test_agent",
                brief = "Please call_tool_many at once",
                host_config = {endpoint = url, stream = false},
            })
            test.is_false(res.ok)
            local val = assert(bounds.object(res.value))
            test.eq(val.outcome, "failed")
            local rep_err = assert(bounds.object(res.error))
            test.is_true(tostring(rep_err.message):find("tool_calls", 1, true) ~= nil)
        end)

        test.it("fences run entry on a moved carrier epoch", function()
            local url = get_mock_url()
            local thread_id = new_thread("Fence Thread")
            local action_id = "act-fence-1"
            local attempt_id = "att-fence-1"
            prepare(thread_id, action_id, attempt_id)

            local res = raw_call("bee.driver.wippy.binding:run", {
                operation = "run",
                thread_id = thread_id,
                action_id = action_id,
                attempt_id = attempt_id,
                agent_ref = "bee.driver.wippy.test:test_agent",
                brief = "First turn greeting",
                carrier_epoch = 999,
                host_config = {endpoint = url, stream = false},
            })
            test.is_false(res.ok)
            local val = assert(bounds.object(res.value))
            test.eq(val.outcome, "failed")
            test.is_true(tostring((assert(bounds.object(res.error))).message):find("carrier epoch moved", 1, true) ~= nil)
        end)

        test.it("refuses invalid host configuration with typed errors", function()
            local url = get_mock_url()
            local thread_id = new_thread("Host Config Thread")
            local action_id = "act-hc-1"
            local attempt_id = "att-hc-1"
            prepare(thread_id, action_id, attempt_id)

            local plain = raw_call("bee.driver.wippy.binding:run", {
                operation = "run",
                thread_id = thread_id,
                action_id = action_id,
                attempt_id = attempt_id,
                agent_ref = "bee.driver.wippy.test:test_agent",
                brief = "First turn greeting",
                host_config = {endpoint = "http://example.com/v1", stream = false},
            })
            test.is_false(plain.ok)
            test.is_true(tostring((assert(bounds.object(plain.error))).message):find("plain http", 1, true) ~= nil)

            local cred = raw_call("bee.driver.wippy.binding:run", {
                operation = "run",
                thread_id = thread_id,
                action_id = action_id,
                attempt_id = attempt_id,
                agent_ref = "bee.driver.wippy.test:test_agent",
                brief = "First turn greeting",
                host_config = {endpoint = url, stream = false,
                    credential_ref = "bee.driver.wippy.test:missing_cred"},
            })
            test.is_false(cred.ok)
            test.is_true(tostring((assert(bounds.object(cred.error))).message):find("resolve credential", 1, true) ~= nil)

            local unknown = raw_call("bee.driver.wippy.binding:run", {
                operation = "run",
                thread_id = thread_id,
                action_id = action_id,
                attempt_id = attempt_id,
                agent_ref = "bee.driver.wippy.test:test_agent",
                brief = "First turn greeting",
                host_config = {endpoint = url, stream = false, bogus_field = 1},
            })
            test.is_false(unknown.ok)
            test.is_true(tostring((assert(bounds.object(unknown.error))).message):find("unknown field", 1, true) ~= nil)
        end)

        test.it("validates run, status, wait and cancel requests", function()
            local url = get_mock_url()
            test.eq((assert(bounds.object(raw_call("bee.driver.wippy.binding:run", {operation = "run", thread_id = "t"}).error))).code, "INVALID")
            test.eq((assert(bounds.object(raw_call("bee.driver.wippy.binding:run", {operation = "bogus"}).error))).code, "INVALID")
            test.eq((assert(bounds.object(raw_call("bee.driver.wippy.binding:run", {operation = "wait", thread_id = "t", attempt_id = "a", wait_ms = -1}).error))).code, "INVALID")
            test.eq((assert(bounds.object(raw_call("bee.driver.wippy.binding:run", {operation = "run", thread_id = "t", action_id = "a", attempt_id = "b", workspace_id = 42}).error))).code, "INVALID")
            test.eq((assert(bounds.object(raw_call("bee.driver.wippy.binding:run", {operation = "status", thread_id = "t", attempt_id = "a", workspace_id = "extra"}).error))).code, "INVALID")
            test.eq((assert(bounds.object(raw_call("bee.driver.wippy.binding:run", {operation = "cancel", thread_id = "t", attempt_id = "a", wait_ms = "soon"}).error))).code, "INVALID")

            local thread_id = new_thread("Validate Thread")
            local action_id = "act-val-1"
            local attempt_id = "att-val-1"
            prepare(thread_id, action_id, attempt_id)

            local res = driver_call("run", {
                thread_id = thread_id,
                action_id = action_id,
                attempt_id = attempt_id,
                agent_ref = "bee.driver.wippy.test:test_agent",
                brief = "Just checking status flow",
                host_config = {endpoint = url, stream = false},
            })
            local val = assert(bounds.object(res.value))
            test.eq(val.answer, "Standard answer: Just checking status flow")

            local st = driver_call("status", {thread_id = thread_id, attempt_id = attempt_id})
            local st_val = assert(bounds.object(st.value))
            test.eq(st_val.state, "ended")
            test.eq(st_val.answer, "Standard answer: Just checking status flow")

            local waited = driver_call("wait", {thread_id = thread_id, attempt_id = attempt_id, wait_ms = 50})
            test.eq((assert(bounds.object(waited.value))).state, "ended")
        end)

        test.it("resolves credentials by reference and never sends the reference as the key", function()
            test.is_nil(client.resolve_key(nil))
            local key, key_error = client.resolve_key("bee.driver.wippy.test:api_key")
            test.eq(key, "secret-xyz-test-key")
            test.is_nil(key_error)
            local missing, missing_error = client.resolve_key("bee.driver.wippy.test:missing_cred")
            test.is_nil(missing)
            test.is_true(tostring(missing_error):find("not in the registry", 1, true) ~= nil)

            local url = get_mock_url()
            local thread_id = new_thread("Credential Thread")
            local action_id = "act-cred-1"
            local attempt_id = "att-cred-1"
            prepare(thread_id, action_id, attempt_id)

            local res = driver_call("run", {
                thread_id = thread_id,
                action_id = action_id,
                attempt_id = attempt_id,
                agent_ref = "bee.driver.wippy.test:test_agent",
                brief = "First turn greeting",
                host_config = {endpoint = url, stream = false,
                    credential_ref = "bee.driver.wippy.test:api_key"},
            })
            test.is_true(res.ok)
            test.eq((assert(bounds.object(res.value))).outcome, "succeeded")
        end)

        test.it("denies tool execution when a declared scope is not admitted", function()
            local ok_exec, denied = runner.execute_tool(
                {ref = "bee.driver.wippy.test:test_tool", scopes = {"bee.driver.wippy.test:missing_policy"}},
                {}, "att-scope-1", "default")
            test.is_false(ok_exec)
            test.eq((assert(bounds.object(denied))).code, "DENIED")
        end)

        test.it("refuses unproven trait capabilities but admits memory on the native route", function()
            seed_registry()
            local snap = registry.snapshot()
            local refused, refuse_err = runner.resolve_agent(snap, "bee.driver.wippy.test:wrapper_agent", {endpoint = "http://127.0.0.1:9/v1"})
            test.is_nil(refused)
            test.is_true(tostring(refuse_err):find("wrappers", 1, true) ~= nil)

            local memory_agent, memory_err = runner.resolve_agent(snap, "bee.driver.wippy.test:memory_agent", {endpoint = "http://127.0.0.1:9/v1"})
            test.not_nil(memory_agent)
            test.is_nil(memory_err)
        end)

        test.it("refuses delegates the host never admitted", function()
            seed_registry()
            local snap = registry.snapshot()
            local refused, refuse_err = runner.resolve_agent(snap, "bee.driver.wippy.test:delegate_agent", {endpoint = "http://127.0.0.1:9/v1"})
            test.is_nil(refused)
            test.is_true(tostring(refuse_err):find("not admitted by the host policy", 1, true) ~= nil)

            local admitted, admit_err = runner.resolve_agent(snap, "bee.driver.wippy.test:delegate_agent",
                {endpoint = "http://127.0.0.1:9/v1", admitted_delegates = {"bee.driver.wippy.test:helper_agent"}})
            test.not_nil(admitted)
            test.is_nil(admit_err)
        end)

        test.it("refuses placement launch and decodes normalize and configure honestly", function()
            local prepared = raw_call("bee.driver.wippy.binding:prepare", {profile_id = "session", brief = "hello"})
            test.is_false(prepared.ok)
            test.is_true(tostring(prepared.error):find("in-process", 1, true) ~= nil)
            local unshaped = raw_call("bee.driver.wippy.binding:prepare", {bogus = true})
            test.is_false(unshaped.ok)

            local no_resume = raw_call("bee.driver.wippy.binding:dispatch", {profile_id = "session"})
            test.is_false(no_resume.ok)
            test.is_true(tostring(no_resume.error):find("resume_ref", 1, true) ~= nil)
            local dispatched = raw_call("bee.driver.wippy.binding:dispatch", {profile_id = "session", resume_ref = "resume-1"})
            test.is_false(dispatched.ok)
            test.is_true(tostring(dispatched.error):find("in-process", 1, true) ~= nil)

            local normalized = raw_call("bee.driver.wippy.binding:normalize", {index = 0,
                envelope = {observations = {{source = "bee", body = {type = "note"}}}}})
            test.is_true(normalized.ok)
            test.eq(#(principals.objects(normalized.observations)), 1)

            local finished = raw_call("bee.driver.wippy.binding:normalize", {index = 1, eof = true})
            test.is_true(finished.ok)

            local bad_envelope = raw_call("bee.driver.wippy.binding:normalize", {index = 0, envelope = {observations = {{source = "stream"}}}})
            test.is_false(bad_envelope.ok)
            local unknown_state = raw_call("bee.driver.wippy.binding:normalize", {index = 0, eof = true,
                state = {resumed = false, terminal = nil, unexpected = true}})
            test.is_false(unknown_state.ok)
            local bad_state_flag = raw_call("bee.driver.wippy.binding:normalize", {index = 0, eof = true,
                state = {resumed = "yes"}})
            test.is_false(bad_state_flag.ok)

            local configured = raw_call("bee.driver.wippy.binding:configure", {fixture = false})
            test.is_true(configured.ok)
            local delivery = assert(bounds.object(configured.delivery))
            test.eq(#(principals.items(delivery.arguments)), 0)
            test.eq(#(principals.items(delivery.files)), 0)

            local provided = raw_call("bee.driver.wippy.binding:configure", {fixture = false, provider_ref = "bee:gateway_endpoint"})
            test.is_false(provided.ok)
        end)
    end)
end

return test.run_cases(define_tests)
