-- MIT. Window plans cannot acquire a headless carrier or its durable effects.
local test = require("test")
local machine = require("machine")
local driver_types = require("driver_types")
local policy = require("policy")
local placement_types = require("placement_types")
local classify = require("classify")
local checkpoint = require("checkpoint")
local stream_json = require("stream_json")
local function plan(mode: string, protocol: string): machine.Plan
    local launch: driver_types.Launch = {executable = "codex", argv = {}, environment = {}, readiness = "terminal:attached"}
    local policy_value: policy.Policy = {ref = "policy", digest = "policy-digest", prepare_options = {}, required_cleanup = "direct_process", required_exit_observation = "eof_gated",
            start_ms = 1000, stop_grace_ms = 100, drain_ms = 100, runner_drain_ms = 100, retain_ms = 100,
            executables = {}, environment = {}, host_environment = {}, allow_host_home = false, gateway_tools = {}, agent_launch = {}, agent_launch_unconfined = {}, agent_model_map = {}, agent_delegates = {}, gateway_ttl_ms = 1000, gateway_hooks = {}, fixture = true, allowed_overrides = {}}
    local placement_request_value: placement_types.LaunchRequest = {idempotency_key = "key", owner_id = "actor", owner_incarnation = 1, action_id = "action", attempt_id = "attempt",
            binding_ref = "binding", policy_ref = "policy", profile_id = "window", binding_digest = "binding-digest", profile_digest = "profile-digest",
            placement_binding_ref = "bee.placement.native.binding:binding", placement_binding_digest = string.rep("a", 64),
            launch = launch, resources = {}, environment = {}, environment_refs = {}, projections = {}, required_cleanup = "direct_process",
            required_exit_observation = "eof_gated", timeouts = {start_ms = 1000, stop_grace_ms = 100, drain_ms = 100, retain_ms = 100}}
    local profile_value: classify.Profile = {id = "window", mode = mode, protocol = protocol, protocol_revision = "1", supported = true, private_home = true,
            permission = {mode = "none", eligible = false}}
    local request_value: machine.Request = {thread_id = "thread", action_id = "action", attempt_id = "attempt", owner_id = "actor", owner_incarnation = 1,
            binding_ref = "binding", profile_id = "window", brief = "", policy_ref = "policy", resources = {}, environment = {}}
    return {
        request = request_value,
        binding = {binding_id = "binding", driver_id = "codex", title = "Codex", implementation_version = "1", profiles_ref = "profiles",
            binding_digest = {entry = "binding-digest", scope = "entry"}, profile_digest = {entry = "profile-digest", scope = "entry"},
            default_profile = "window", profiles = {}, methods = {}, state = "compatible", activated = true, diagnostics = {}},
        profile = profile_value,
        launch = launch,
        policy = policy_value,
        placement_binding = {binding_id = "bee.placement.native.binding:binding", binding_digest = string.rep("a", 64), placement_kind = "native", methods = {
            prepare = "bee.placement.native.binding:prepare", start = "bee.placement.native.binding:start", status = "bee.placement.native.binding:status",
            stop = "bee.placement.native.binding:stop", reconcile = "bee.placement.native.binding:reconcile", cleanup = "bee.placement.native.binding:cleanup",
            evidence = "bee.placement.native.binding:evidence", attach = "bee.placement.native.binding:attach",
            capabilities = "bee.placement.native.binding:capabilities", measure_executable = "bee.placement.native.binding:measure_executable",
            close_stdin = "bee.placement.native.binding:close_stdin"}},
        plan_digest = "plan-digest",
        placement_request = placement_request_value,
        exit_codes_trustworthy = false, prepare_target = "prepare", normalize_target = "normalize",
    }
end
local function define_tests()
    test.describe("Carrier transport ownership", function()
        test.it("queues an inbox offer during a turn and writes its identified line only after the turn ends", function()
            local selected = plan("session", "stream-json")
            selected.binding.driver_id = "claude"
            selected.policy.inbox_push = true
            selected.launch.session_end = "stdin_close"
            local point = checkpoint.new({binding_ref = "binding", binding_digest = "binding-digest", profile_id = "session", profile_digest = "profile-digest"}, 1)
            local terminal: driver_types.Terminal = {outcome = "succeeded", answer = "first", resume_ref = "provider-session"}
            local session: machine.Session = {plan = selected, turn_id = "turn:attempt:1", turn_open = true, epoch = 1, revision = 0,
                checkpoint = point, decoder = stream_json.new(machine.MAX_FRAME_BYTES), normalizer = {terminal = terminal}, terminal = terminal,
                stream_ended = false, exit = nil, eof = {stdout = false, stderr = false}, runner = "runner", settled = nil, recovered = false,
                output = "open", pending_hint = nil, placement_evidence = 0, stderr_sequence = 0, last_sequence = {stdout = 0, stderr = 0}, held_from = nil,
                dropping_stdout = false}
            local offer: machine.Offer = {thread_id = "thread", action_id = "action", record_id = "record-1", inbox_sequence = 1,
                payload_digest = string.rep("a", 64), message_id = "message-1", message_kind = "request", sender_action_id = "sender",
                sender_thread_id = "sender-thread", sender_node_id = "local-node", content = {text = "hello"}, state = "offered", dispatch = true, offer_count = 1}
            local calls: {string} = {}
            local writes: {string} = {}
            local inbox_state = "offered"
            local io: machine.IO = {call = function(target: string, request: unknown): (unknown, string?)
                    calls[#calls + 1] = target
                    if target == "bee.threads.carrier:commit" then return {ok = true, value = {checkpoint_revision = session.revision + 1}}, nil end
                    if target == "bee.threads.service:inbox_offer" then return {ok = true, value = offer}, nil end
                    if target == "bee.threads.service:inbox_list" then return {ok = true, value = {items = {{record_id = offer.record_id, inbox_sequence = offer.inbox_sequence, state = inbox_state}}}}, nil end
                    return {ok = true, value = {}}, nil
                end,
                send = function(target: string, topic: string, value: unknown)
                    test.eq(target, "runner")
                    test.eq(topic, "bee.placement.input")
                    writes[#writes + 1] = (value :: {[string]: unknown}).data :: string
                end,
                self_pid = function(): string return "carrier" end,
                now_ms = function(): integer return 1 end,
                key = function(): string return "key" end}
            local offered, offer_error = machine.offer_inbox(io, session)
            test.is_nil(offer_error)
            test.eq((offered :: machine.Offer).record_id, "record-1")
            local busy, busy_error = machine.begin_push_turn(io, session, offer)
            test.is_nil(busy)
            test.eq(busy_error, "a different turn is still open")
            test.eq(#writes, 0)
            local ended, end_error = machine.finish_push_turn(io, session)
            test.is_nil(end_error)
            test.is_true(ended)
            local write_id, write_error = machine.begin_push_turn(io, session, offer)
            test.is_nil(write_error)
            test.eq(write_id, "inbox:record-1:1:1")
            test.eq(#writes, 1)
            test.is_true(writes[1]:find("record-1", 1, true) ~= nil)
            test.is_true(writes[1]:find(offer.payload_digest, 1, true) ~= nil)
            test.eq(session.turn_id, "turn:attempt:inbox:1:1")
            test.is_true(session.turn_open)
            test.eq(calls[#calls - 1], "bee.threads.service:request_turn")
            test.eq(calls[#calls], "bee.threads.carrier:commit")
            local before_stale = #calls
            local stale, stale_error = machine.on_write_ack(io, session, "runner", {attempt_id = "attempt", write_id = write_id :: string, generation = 0, accepted = true})
            test.is_true(stale)
            test.is_nil(stale_error)
            test.eq(#calls, before_stale)
            local accepted, accepted_error = machine.on_write_ack(io, session, "runner", {attempt_id = "attempt", write_id = write_id :: string, generation = 1, accepted = true})
            test.is_true(accepted)
            test.is_nil(accepted_error)
            test.eq(calls[#calls - 2], "bee.threads.service:inbox_list")
            test.eq(calls[#calls - 1], "bee.threads.service:inbox_transport")
            test.eq(calls[#calls], "bee.threads.carrier:commit")
            test.eq(#session.checkpoint.pending_writes, 0)
            inbox_state = "acknowledged"
            table.insert(session.checkpoint.pending_writes, {write_id = write_id :: string, input_digest = string.rep("b", 64), data = writes[1], dispatched = true})
            local after_agent_ack = #calls
            local late, late_error = machine.on_write_ack(io, session, "runner", {attempt_id = "attempt", write_id = write_id :: string, generation = 1, accepted = true})
            test.is_true(late)
            test.is_nil(late_error)
            test.eq(#calls, after_agent_ack + 2)
            test.eq(calls[#calls - 1], "bee.threads.service:inbox_list")
            test.eq(calls[#calls], "bee.threads.carrier:commit")
            inbox_state = "offered"
            -- The recovered runner answers a status query for the old write
            -- under its new attachment generation. Its original record ID
            -- is transported before the accepted journal entry is retired.
            session.epoch = 2
            session.checkpoint.attachment_generation = 2
            table.insert(session.checkpoint.pending_writes, {write_id = write_id :: string, input_digest = string.rep("b", 64), data = writes[1], dispatched = true})
            local recovered, recovered_error = machine.on_write_status(io, session, "runner", {attempt_id = "attempt", write_id = write_id :: string, generation = 2, status = "accepted"})
            test.is_true(recovered)
            test.is_nil(recovered_error)
            test.eq(calls[#calls - 2], "bee.threads.service:inbox_list")
            test.eq(calls[#calls - 1], "bee.threads.service:inbox_transport")
            test.eq(calls[#calls], "bee.threads.carrier:commit")
            test.eq(#session.checkpoint.pending_writes, 0)
            session.terminal = terminal
            session.checkpoint.terminal = terminal
            local completed, complete_error = machine.finish_push_turn(io, session)
            test.is_true(completed)
            test.is_nil(complete_error)
            session.epoch = 3
            offer.offer_count = 2
            offer.dispatch = true
            local redelivered, redelivery_error = machine.begin_push_turn(io, session, offer)
            test.is_nil(redelivery_error)
            test.eq(redelivered, "inbox:record-1:1:3")
            test.eq(session.turn_id, "turn:attempt:inbox:1:2")
            test.eq(#writes, 2)
            test.is_true(writes[2]:find("record-1", 1, true) ~= nil)
        end)
        test.it("refuses a required host file in a private home but allows it in the inherited home", function()
            local launch: driver_types.Launch = {executable = "codex", argv = {}, environment = {}, readiness = "terminal:attached",
                required_files = {{variable = "CODEX_HOME", path = "ds-flash.config.toml", default_directory = ".codex"}}}
            local refusal = machine.required_file_refusal(launch, true)
            test.not_nil(refusal)
            test.is_true(refusal:find("ds-flash", 1, true) ~= nil)
            test.is_true(refusal:find("only available where Bee inherits the user's home", 1, true) ~= nil)
            test.is_nil(machine.required_file_refusal(launch, false))
            local plain: driver_types.Launch = {executable = "codex", argv = {}, environment = {}, readiness = "terminal:attached"}
            test.is_nil(machine.required_file_refusal(plain, true))
        end)

        test.it("refuses malformed driver replies before executable measurement or admission", function()
            local request = plan("window", "pty").request
            request.binding_ref = "bee.driver.claude:binding"
            request.profile_id = "batch"
            request.policy_ref = "bee.harness.catalog:fixture_policy"
            request.brief = "test"
            local replies: {unknown} = {
                {ok = true, launch = {executable = 42, argv = {}, readiness = "ready"}},
                {ok = true, launch = {executable = "claude", argv = {false}, readiness = "ready"}},
                {ok = "yes", launch = {executable = "claude", argv = {}, readiness = "ready"}},
                {ok = true, launch = {executable = "claude", argv = {}, readiness = "ready"}, extra = true},
            }
            for _, response in ipairs(replies) do
                local calls = 0
                local io: machine.IO = {
                    call = function(target: string, value: unknown): (unknown, string?)
                        calls = calls + 1
                        test.eq(target, "bee.driver.claude.binding:prepare")
                        return response, nil
                    end,
                    send = function(target: string, topic: string, value: unknown) error("unexpected send") end,
                    self_pid = function(): string return "test" end,
                    now_ms = function(): integer return 0 end,
                    key = function(): string return "key" end,
                }
                local prepared, err = machine.plan(io, request)
                test.is_nil(prepared)
                test.eq(calls, 1)
                test.is_true(err ~= nil and err:find("driver prepare:", 1, true) ~= nil)
            end
        end)
        test.it("prepares a window attempt without requesting a turn or starting a transport", function()
            local calls: {string} = {}
            local io: machine.IO = {
                call = function(target: string, value: unknown): (unknown, string?)
                    calls[#calls + 1] = target
                    if target == "bee.threads.service:admit_action" then
                        if type(value) ~= "table" then error("missing action request") end
                        local admitted = value.admitted
                        if type(admitted) ~= "table" then error("missing admitted action") end
                        local input = admitted.input
                        if type(input) ~= "table" then error("missing action content") end
                        test.eq(input.text, "Open Codex window")
                    end
                    if target == "bee.threads.carrier:claim" then return {ok = true, value = {carrier_epoch = 7}}, nil end
                    if target == "bee.placement.native.binding:prepare" then
                        return {ok = true, value = {notice = {code = "LOGIN_REQUIRED", provider = "codex", command = "codex login"}}}, nil
                    end
                    return {ok = true, value = {}}, nil
                end,
                send = function(target: string, topic: string, value: unknown) error("unexpected transport send") end,
                self_pid = function(): string return "test" end,
                now_ms = function(): integer return 0 end,
                key = function(): string return "key" end,
            }
            local prepared, err = machine.prepare_attempt(io, plan("window", "pty"))
            if not prepared then error(tostring(err)) end
            test.eq(prepared.epoch, 7)
            test.is_nil(prepared.gateway_binding)
            test.eq(prepared.notice and prepared.notice.code, "LOGIN_REQUIRED")
            test.eq(prepared.notice and prepared.notice.command, "codex login")
            test.eq(table.concat(calls, ","), "bee.threads.service:admit_action,bee.threads.service:prepare_attempt,bee.threads.carrier:claim,bee.placement.native.binding:prepare")
        end)
        test.it("rejects a malformed placement login notice", function()
            local io: machine.IO = {
                call = function(target: string, value: unknown): (unknown, string?)
                    if target == "bee.threads.carrier:claim" then return {ok = true, value = {carrier_epoch = 7}}, nil end
                    if target == "bee.placement.native.binding:prepare" then
                        return {ok = true, value = {notice = {code = "LOGIN_REQUIRED", provider = "codex", command = "codex login\nextra"}}}, nil
                    end
                    return {ok = true, value = {}}, nil
                end,
                send = function(target: string, topic: string, value: unknown) error("unexpected transport send") end,
                self_pid = function(): string return "test" end,
                now_ms = function(): integer return 0 end,
                key = function(): string return "key" end,
            }
            local prepared, err = machine.prepare_attempt(io, plan("window", "pty"))
            test.is_nil(prepared)
            test.eq(err, "placement prepare returned an invalid notice")
        end)
        test.it("dispatches preparation through the selected placement binding", function()
            local selected: machine.Plan = plan("window", "pty")
            selected.placement_binding = {binding_id = "example.placement:binding", binding_digest = string.rep("b", 64), placement_kind = "native", methods = {
                prepare = "example.placement:prepare", start = "example.placement:start", status = "example.placement:status",
                stop = "example.placement:stop", reconcile = "example.placement:reconcile", cleanup = "example.placement:cleanup",
                evidence = "example.placement:evidence", attach = "example.placement:attach",
                capabilities = "example.placement:capabilities", measure_executable = "example.placement:measure_executable",
                close_stdin = "example.placement:close_stdin"}}
            selected.placement_request.placement_binding_ref = "example.placement:binding"
            selected.placement_request.placement_binding_digest = string.rep("b", 64)
            local calls: {string} = {}
            local io: machine.IO = {
                call = function(target: string, value: unknown): (unknown, string?)
                    calls[#calls + 1] = target
                    if target == "example.placement:prepare" then test.eq(value, selected.placement_request) end
                    if target == "bee.threads.carrier:claim" then return {ok = true, value = {carrier_epoch = 7}}, nil end
                    return {ok = true, value = {}}, nil
                end,
                send = function(target: string, topic: string, value: unknown) error("unexpected send") end,
                self_pid = function(): string return "test" end,
                now_ms = function(): integer return 0 end,
                key = function(): string return "key" end,
            }
            local prepared, err = machine.prepare_attempt(io, selected)
            if not prepared then error(tostring(err)) end
            test.eq(calls[#calls], "example.placement:prepare")
            test.is_nil(table.concat(calls, ","):find("bee.placement.native.binding:prepare", 1, true))
        end)
        test.it("carries the oldest outstanding inbox item in a fresh bounded-driver brief", function()
            local item = {thread_id = "thread", inbox_sequence = 3, record_id = "record-9", thread_sequence = 41,
                payload_digest = string.rep("b", 64), state = "committed", delivery_status = "committed", sender_action_id = "sender",
                sender_node_id = "node", sender_thread_id = "sender-thread", message_id = "message-9",
                content = {text = "hello again"}, message_kind = "request"}
            local listed = 0
            local io: machine.IO = {
                call = function(target: string, value: unknown): (unknown, string?)
                    if target == "bee.threads.service:inbox_list" then
                        listed = listed + 1
                        return {ok = true, value = {items = {item}}}, nil
                    end
                    return nil, "unexpected call " .. target
                end,
                send = function(target: string, topic: string, value: unknown) error("unexpected send") end,
                self_pid = function(): string return "test" end,
                now_ms = function(): integer return 0 end,
                key = function(): string return "key" end,
            }
            local function request(brief: string): machine.Request
                return {thread_id = "thread", action_id = "action", attempt_id = "attempt", owner_id = "actor", owner_incarnation = 1,
                    binding_ref = "binding", profile_id = "batch", brief = brief, policy_ref = "policy",
                    resources = {} :: {placement_types.ResourceGrant}, environment = {} :: {[string]: string}}
            end
            local function profile(mode: string): classify.Profile
                return {id = "batch", mode = mode, protocol = "stream-json", protocol_revision = "1", supported = true, private_home = true,
                    permission = {mode = "none", eligible = false}}
            end
            for _, driver in ipairs({"codex", "agy", "grok", "muse"}) do
                local carried = machine.carry_brief(io, request("follow up"), driver, "session")
                test.is_true(carried:find("record-9", 1, true) ~= nil, driver .. ": " .. carried)
                test.is_true(carried:find("message-9", 1, true) ~= nil, driver .. ": " .. carried)
                test.is_true(carried:find("hello again", 1, true) ~= nil, driver .. ": " .. carried)
                test.is_true(carried:find("session_ack", 1, true) ~= nil, driver .. ": " .. carried)
                test.is_true(carried:sub(-9) == "follow up", driver .. ": " .. carried)
            end
            test.eq(listed, 4)
            local second = machine.carry_brief(io, request("follow up"), "codex", "session")
            test.is_true(second:find("record-9", 1, true) ~= nil)
            local idempotent = machine.carry_brief(io, {thread_id = "thread", action_id = "action", attempt_id = "attempt", owner_id = "actor",
                owner_incarnation = 1, binding_ref = "binding", profile_id = "batch", brief = second, policy_ref = "policy", resources = {}, environment = {}},
                "codex", "session")
            test.eq(idempotent, second)
            local resumed = request("follow up")
            resumed.previous_attempt_id = "attempt-1"
            test.eq(machine.carry_brief(io, resumed, "codex", "session"), "follow up")
            local retained = request("follow up")
            retained.session_ref = "session-1"
            test.eq(machine.carry_brief(io, retained, "codex", "session"), "follow up")
            test.eq(machine.carry_brief(io, request("follow up"), "claude", "session"), "follow up")
            test.eq(machine.carry_brief(io, request("follow up"), "codex", "window"), "follow up")
            local terminal = machine.carry_brief(io, request("follow up"), "codex", "session")
            test.is_true(terminal:find("record-9", 1, true) ~= nil)
        end)
        test.it("leaves the brief alone without outstanding inbox and bounds what it carries", function()
            local function io_for(items: {unknown}?, failure: string?): machine.IO
                return {
                    call = function(target: string, value: unknown): (unknown, string?)
                        if target == "bee.threads.service:inbox_list" then
                            if failure then return nil, failure end
                            return {ok = true, value = {items = items or {}}}, nil
                        end
                        return nil, "unexpected call " .. target
                    end,
                    send = function(target: string, topic: string, value: unknown) error("unexpected send") end,
                    self_pid = function(): string return "test" end,
                    now_ms = function(): integer return 0 end,
                    key = function(): string return "key" end,
                }
            end
            local function request(): machine.Request
                return {thread_id = "thread", action_id = "action", attempt_id = "attempt", owner_id = "actor", owner_incarnation = 1,
                    binding_ref = "binding", profile_id = "batch", brief = "follow up", policy_ref = "policy",
                    resources = {} :: {placement_types.ResourceGrant}, environment = {} :: {[string]: string}}
            end
            test.eq(machine.carry_brief(io_for(nil, nil), request(), "codex", "session"), "follow up")
            test.eq(machine.carry_brief(io_for(nil, "bee.threads.service:inbox_list: STORAGE: down"), request(), "codex", "session"), "follow up")
            local terminal = {{thread_id = "thread", inbox_sequence = 1, record_id = "record-1", thread_sequence = 2,
                payload_digest = string.rep("c", 64), state = "acknowledged", delivery_status = "acknowledged", sender_action_id = "sender",
                sender_node_id = "node", sender_thread_id = "sender-thread", message_id = "message-1", content = {text = "done"}, message_kind = "request"}}
            test.eq(machine.carry_brief(io_for(terminal, nil), request(), "codex", "session"), "follow up")
            local replied = {{thread_id = "thread", inbox_sequence = 2, record_id = "record-2", thread_sequence = 3,
                payload_digest = string.rep("d", 64), state = "replied", delivery_status = "replied", sender_action_id = "sender",
                sender_node_id = "node", sender_thread_id = "sender-thread", message_id = "message-2", content = {text = "done"}, message_kind = "reply"}}
            test.eq(machine.carry_brief(io_for(replied, nil), request(), "codex", "session"), "follow up")
            local huge = {{thread_id = "thread", inbox_sequence = 4, record_id = "record-4", thread_sequence = 5,
                payload_digest = string.rep("e", 64), state = "committed", delivery_status = "committed", sender_action_id = "sender",
                sender_node_id = "node", sender_thread_id = "sender-thread", message_id = "message-4",
                content = {text = string.rep("x", 20000)}, message_kind = "request"}}
            local bounded = machine.carry_brief(io_for(huge, nil), request(), "codex", "session")
            test.is_true(#bounded <= 16383, "brief bound: " .. tostring(#bounded))
            test.is_true(bounded:find("record-4", 1, true) ~= nil)
            test.is_true(bounded:find("session_inbox", 1, true) ~= nil)
            test.is_true(bounded:sub(-9) == "follow up")
        end)
        test.it("attaches a fresh sequential attempt to its own admitted action and chains the settled attempt", function()
            local selected = plan("session", "stream-json")
            selected.binding.driver_id = "codex"
            local prepared_body: {[string]: unknown}? = nil
            local io: machine.IO = {
                call = function(target: string, value: unknown): (unknown, string?)
                    if target == "bee.threads.service:admit_action" then return {ok = false, error = {code = "CONFLICT", message = "action already exists"}}, nil end
                    if target == "bee.threads.service:read_after" then
                        return {ok = true, value = {records = {
                            {kind = "action.admitted", action_id = "action", sequence = 2, body = {principal_id = "actor"}},
                            {kind = "receipt", action_id = "action", attempt_id = "attempt-1", sequence = 9, body = {scope = "attempt", outcome = "succeeded"}},
                        }, has_more = false, scanned_through = 9}}, nil
                    end
                    if target == "bee.threads.service:prepare_attempt" then
                        prepared_body = value :: {[string]: unknown}
                        return {ok = true, value = {}}, nil
                    end
                    if target == "bee.threads.carrier:claim" then return {ok = true, value = {carrier_epoch = 2}}, nil end
                    return {ok = true, value = {}}, nil
                end,
                send = function(target: string, topic: string, value: unknown) error("unexpected send") end,
                self_pid = function(): string return "test" end,
                now_ms = function(): integer return 0 end,
                key = function(): string return "key" end,
            }
            local prepared, err = machine.prepare_attempt(io, selected)
            if not prepared then error(tostring(err)) end
            test.eq(prepared_body and prepared_body.expected_previous_attempt_id, "attempt-1")
            local foreign: machine.IO = {
                call = function(target: string, value: unknown): (unknown, string?)
                    if target == "bee.threads.service:admit_action" then return {ok = false, error = {code = "CONFLICT", message = "action already exists"}}, nil end
                    if target == "bee.threads.service:read_after" then
                        return {ok = true, value = {records = {
                            {kind = "action.admitted", action_id = "action", sequence = 2, body = {principal_id = "someone-else"}},
                        }, has_more = false, scanned_through = 2}}, nil
                    end
                    return {ok = true, value = {}}, nil
                end,
                send = function(target: string, topic: string, value: unknown) error("unexpected send") end,
                self_pid = function(): string return "test" end,
                now_ms = function(): integer return 0 end,
                key = function(): string return "key" end,
            }
            local refused, refuse_error = machine.prepare_attempt(foreign, selected)
            test.is_nil(refused)
            test.eq(refuse_error, "bee.threads.service:admit_action: CONFLICT: action already exists")
        end)
        test.it("refuses window and nonstructured profiles before opening or claiming an attempt", function()
            local calls = 0
            local io: machine.IO = {
                call = function(target: string, value: unknown): (unknown, string?) calls = calls + 1; return nil, "unexpected call" end,
                send = function(target: string, topic: string, value: unknown) calls = calls + 1 end,
                self_pid = function(): string return "test" end,
                now_ms = function(): integer return 0 end,
                key = function(): string return "key" end,
            }
            for _, candidate in ipairs({plan("window", "pty"), plan("window", "stream-json"), plan("session", "pty")}) do
                local opened, open_error = machine.open(io, candidate)
                test.is_nil(opened)
                test.eq(open_error, "structured carrier requires a stream-json session or batch profile")
                local resumed, resume_error = machine.resume(io, candidate)
                test.is_nil(resumed)
                test.eq(resume_error, open_error)
            end
            test.eq(calls, 0)
        end)
    end)
end
return test.run_cases(define_tests)
