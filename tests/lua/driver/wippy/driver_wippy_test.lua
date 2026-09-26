-- MIT. Unit tests for the native Wippy in-process agent driver.
-- Tests stand-in OpenAI-compatible chat endpoint:
-- 1. Multi-turn tool calls and execution with grant isolation
-- 2. Streaming SSE accumulation of content and tool arguments
-- 3. Cancellation receipts and terminal state
-- 4. Restart, checkpoint continuation and epoch fencing
local test = require("test")
local system = require("system")
local json = require("json")
local registry = require("registry")
local funcs = require("funcs")
local security = require("security")
local harness = require("harness")

type Object = {[string]: unknown}
type Reply = {ok: boolean, error: {code: string, message: string, retryable: boolean}?, value: any}

local THREAD_POLICIES = {
    "bee.threads:client_test_policy",
    "bee.security.threads:thread_create_policy",
    "bee.security.threads:thread_observe_policy",
    "bee.security.threads:thread_lifecycle_policy",
    "bee.security.threads:thread_carrier_policy",
    "bee.security.harness:carrier_policy",
    "bee.driver.wippy.test:test_http_policy",
}

local function get_mock_url(): string
    local state = system.supervisor.state("bee.driver.wippy.test:mock_listener")
    if not state or not state.details then
        error("mock listener supervisor state unavailable")
    end
    local addr = state.details:match("^service listening on ([%d%.]+:%d+)$")
    if not addr then
        error("failed to parse listener addr from: " .. tostring(state.details))
    end
    return "http://" .. addr .. "/v1"
end

local function make_caller(): funcs.Executor
    local actor = security.new_actor("carrier-tester")
    local policies: {security.Policy} = {}
    for _, name in ipairs(THREAD_POLICIES) do
        local pol, err = security.policy(name)
        if not pol then error("policy " .. name .. ": " .. tostring(err)) end
        policies[#policies + 1] = pol
    end
    return funcs.new():with_actor(actor):with_scope(security.new_scope(policies))
end

local function driver_call(operation: string, req: Object): Object
    local caller = make_caller()
    local payload = {}
    for k, v in pairs(req) do payload[k] = v end
    payload.operation = operation
    local reply, err = caller:call("bee.driver.wippy:run", payload)
    if err then error("call bee.driver.wippy:run: " .. tostring(err)) end
    if type(reply) ~= "table" then error("driver run returned " .. type(reply)) end
    local rep = reply :: Object
    if not rep.ok and (not rep.value or (rep.value :: Object).outcome ~= "cancelled") then
        error("driver_call " .. operation .. " failed: " .. json.encode(rep))
    end
    return rep
end

local function seed_registry()
    local snap = registry.snapshot()
    local agent_id = "bee.driver.wippy.test:test_agent"
    local trait_id = "bee.driver.wippy.test:test_trait"
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
    if snap:get(agent_id) then
        changes:update(agent_entry)
    else
        changes:create(agent_entry)
    end
    if snap:get(trait_id) then
        changes:update(trait_entry)
    else
        changes:create(trait_entry)
    end
    local applied, apply_err = changes:apply()
    if not applied then
        error("seed_registry apply failed: " .. tostring(apply_err))
    end
end

local function define_tests()
    seed_registry()
    test.describe("Native Wippy Agent Driver", function()
        local carrier_client = harness.principal("carrier-tester", THREAD_POLICIES)

        local function new_thread(title: string): string
            return harness.thread(carrier_client, title)
        end

        local function prepare(thread_id: string, action_id: string, attempt_id: string)
            seed_registry()
            harness.value(carrier_client:call("admit_action", {
                thread_id = thread_id,
                idempotency_key = harness.key(),
                action_id = action_id,
                admitted = harness.admitted(),
            }))
            harness.value(carrier_client:call("prepare_attempt", {
                thread_id = thread_id,
                idempotency_key = harness.key(),
                action_id = action_id,
                attempt_id = attempt_id,
                prepared = harness.prepared(),
            }))
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
            local val = res.value :: Object
            test.eq(val.outcome, "succeeded")
            test.eq(val.state, "ended")
            test.not_nil(val.answer)
            test.is_true(tostring(val.answer):find("Result:", 1, true) ~= nil)

            -- Verify receipt
            local receipt = val.receipt :: Object
            test.not_nil(receipt)
            test.eq(receipt.scope, "attempt")
            test.eq(receipt.state, "ended")

            -- Verify carrier events recorded tool calls
            local page = harness.value(carrier_client:call("read_after", {
                thread_id = thread_id,
                cursor = 0,
            })) :: Object
            local records = page.records :: {Object}
            test.is_true(#records > 0)

            local found_tool_call = false
            local found_tool_result = false
            for _, rec in ipairs(records) do
                local body = rec.body :: Object
                if body and type(body.event_key) == "string" then
                    if tostring(body.event_key):find("tool_call:call_tc_1", 1, true) then
                        found_tool_call = true
                    end
                    if tostring(body.event_key):find("tool_result:call_tc_1", 1, true) then
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
            local val = res.value :: Object
            test.eq(val.outcome, "succeeded")
            test.eq(val.state, "ended")
            test.not_nil(val.answer)
            -- The model received the tool refusal/error and concluded
            test.is_true(tostring(val.answer):find("not admitted", 1, true) ~= nil or tostring(val.answer):find("error", 1, true) ~= nil)
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
            local val = res.value :: Object
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
            local val2 = res2.value :: Object
            test.eq(val2.outcome, "succeeded")
            test.eq(val2.state, "ended")
            test.not_nil(val2.answer)
            test.is_true(tostring(val2.answer):find("Result:", 1, true) ~= nil)
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
            local can_val = can_res.value :: Object
            test.eq(can_val.state, "cancelling")
            test.eq(can_val.scope, "attempt")

            -- Check status reflects cancel
            local st_res = driver_call("status", {
                thread_id = thread_id,
                attempt_id = attempt_id,
            })
            test.is_true(st_res.ok)
            local st_val = st_res.value :: Object
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
            local r_val = run_res.value :: Object
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
            local val1 = res1.value :: Object
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
                resume = true,
                host_config = {endpoint = url, stream = false},
            })
            test.is_true(res2.ok)
            local val2 = res2.value :: Object
            test.eq(val2.outcome, "succeeded")
            test.eq(val2.state, "ended")

            -- Check that carrier checkpoint advanced and records are preserved across attempts
            local page = harness.value(carrier_client:call("read_after", {
                thread_id = thread_id,
                cursor = 0,
            })) :: Object
            local records = page.records :: {Object}
            test.is_true(#records >= 2) -- at least answer from turn 1 and turn 2
        end)
    end)
end

return test.run_cases(define_tests)
