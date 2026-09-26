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

local function raw_call(target: string, req: Object): Object
    local caller = make_caller()
    local reply, err = caller:call(target, req)
    if err then error("call " .. target .. ": " .. tostring(err)) end
    if type(reply) ~= "table" then error(target .. " returned " .. type(reply)) end
    return reply :: Object
end

local function driver_call(operation: string, req: Object): Object
    local payload = {}
    for k, v in pairs(req) do payload[k] = v end
    payload.operation = operation
    local rep = raw_call("bee.driver.wippy:run", payload)
    if not rep.ok and (not rep.value or (rep.value :: Object).outcome ~= "cancelled") then
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
            test.is_true(tostring(val.answer):find("nonstream-review-done", 1, true) ~= nil)

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
            local val = res.value :: Object
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

        test.it("stops a runaway tool-call loop at the turn limit", function()
            local url = get_mock_url()
            local thread_id = new_thread("Loop Thread")
            local action_id = "act-loop-1"
            local attempt_id = "att-loop-1"
            prepare(thread_id, action_id, attempt_id)

            local res = raw_call("bee.driver.wippy:run", {
                operation = "run",
                thread_id = thread_id,
                action_id = action_id,
                attempt_id = attempt_id,
                agent_ref = "bee.driver.wippy.test:test_agent",
                brief = "Please call_tool_loop forever",
                host_config = {endpoint = url, stream = false, max_turns = 3},
            })
            test.is_false(res.ok)
            local val = res.value :: Object
            test.eq(val.outcome, "failed")
            test.eq(val.state, "ended")
            local rep_err = res.error :: Object
            test.is_true(tostring(rep_err.message):find("turn limit", 1, true) ~= nil)
        end)

        test.it("refuses more tool calls per turn than admitted", function()
            local url = get_mock_url()
            local thread_id = new_thread("Many Calls Thread")
            local action_id = "act-many-1"
            local attempt_id = "att-many-1"
            prepare(thread_id, action_id, attempt_id)

            local res = raw_call("bee.driver.wippy:run", {
                operation = "run",
                thread_id = thread_id,
                action_id = action_id,
                attempt_id = attempt_id,
                agent_ref = "bee.driver.wippy.test:test_agent",
                brief = "Please call_tool_many at once",
                host_config = {endpoint = url, stream = false},
            })
            test.is_false(res.ok)
            local val = res.value :: Object
            test.eq(val.outcome, "failed")
            local rep_err = res.error :: Object
            test.is_true(tostring(rep_err.message):find("tool calls", 1, true) ~= nil)
        end)

        test.it("fences run entry on a moved carrier epoch", function()
            local url = get_mock_url()
            local thread_id = new_thread("Fence Thread")
            local action_id = "act-fence-1"
            local attempt_id = "att-fence-1"
            prepare(thread_id, action_id, attempt_id)

            local res = raw_call("bee.driver.wippy:run", {
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
            local val = res.value :: Object
            test.eq(val.outcome, "failed")
            test.is_true(tostring((res.error :: Object).message):find("carrier epoch moved", 1, true) ~= nil)
        end)

        test.it("refuses invalid host configuration with typed errors", function()
            local url = get_mock_url()
            local thread_id = new_thread("Host Config Thread")
            local action_id = "act-hc-1"
            local attempt_id = "att-hc-1"
            prepare(thread_id, action_id, attempt_id)

            local plain = raw_call("bee.driver.wippy:run", {
                operation = "run",
                thread_id = thread_id,
                action_id = action_id,
                attempt_id = attempt_id,
                agent_ref = "bee.driver.wippy.test:test_agent",
                brief = "First turn greeting",
                host_config = {endpoint = "http://example.com/v1", stream = false},
            })
            test.is_false(plain.ok)
            test.is_true(tostring((plain.error :: Object).message):find("plain http", 1, true) ~= nil)

            local cred = raw_call("bee.driver.wippy:run", {
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
            test.is_true(tostring((cred.error :: Object).message):find("resolve credential", 1, true) ~= nil)

            local unknown = raw_call("bee.driver.wippy:run", {
                operation = "run",
                thread_id = thread_id,
                action_id = action_id,
                attempt_id = attempt_id,
                agent_ref = "bee.driver.wippy.test:test_agent",
                brief = "First turn greeting",
                host_config = {endpoint = url, stream = false, bogus_field = 1},
            })
            test.is_false(unknown.ok)
            test.is_true(tostring((unknown.error :: Object).message):find("unknown field", 1, true) ~= nil)
        end)

        test.it("validates run, status, wait and cancel requests", function()
            local url = get_mock_url()
            test.eq((raw_call("bee.driver.wippy:run", {operation = "run", thread_id = "t"}).error :: Object).code, "INVALID")
            test.eq((raw_call("bee.driver.wippy:run", {operation = "bogus"}).error :: Object).code, "INVALID")
            test.eq((raw_call("bee.driver.wippy:run", {operation = "wait", thread_id = "t", attempt_id = "a", wait_ms = -1}).error :: Object).code, "INVALID")

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
            local val = res.value :: Object
            test.eq(val.answer, "Standard answer: Just checking status flow")

            local st = driver_call("status", {thread_id = thread_id, attempt_id = attempt_id})
            local st_val = st.value :: Object
            test.eq(st_val.state, "ended")
            test.eq(st_val.answer, "Standard answer: Just checking status flow")

            local waited = driver_call("wait", {thread_id = thread_id, attempt_id = attempt_id, wait_ms = 50})
            test.eq((waited.value :: Object).state, "ended")
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
            test.eq((res.value :: Object).outcome, "succeeded")
        end)

        test.it("denies tool execution when a declared scope is not admitted", function()
            local ok_exec, denied = runner.execute_tool(
                {ref = "bee.driver.wippy.test:test_tool", scopes = {"bee.driver.wippy.test:missing_policy"}},
                {}, "att-scope-1", "default")
            test.is_false(ok_exec)
            test.eq((denied :: Object).code, "DENIED")
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
            test.eq(#(normalized.observations :: {Object}), 1)

            local finished = raw_call("bee.driver.wippy.binding:normalize", {index = 1, eof = true})
            test.is_true(finished.ok)

            local bad_envelope = raw_call("bee.driver.wippy.binding:normalize", {index = 0, envelope = {observations = {{source = "stream"}}}})
            test.is_false(bad_envelope.ok)

            local configured = raw_call("bee.driver.wippy.binding:configure", {fixture = false})
            test.is_true(configured.ok)
            local delivery = configured.delivery :: Object
            test.eq(#(delivery.arguments :: {unknown}), 0)
            test.eq(#(delivery.files :: {unknown}), 0)

            local provided = raw_call("bee.driver.wippy.binding:configure", {fixture = false, provider_ref = "bee:gateway_endpoint"})
            test.is_false(provided.ok)
        end)
    end)
end

return test.run_cases(define_tests)
