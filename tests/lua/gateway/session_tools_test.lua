-- MIT. The ten default session tools: closed schemas, mandatory operation
-- keys, identity refused in payloads, exact projection onto a fake owner
-- binding, and owner replies held to the published output schema.
local test = require("test")
local mcp = require("mcp")
local catalog = require("catalog")
local surface = require("surface")
local session_tools = require("session_tools")
type Object = {[string]: unknown}

local SESSION = "bs:node-a:ws-1:s1"
local WORK = "bw:node-a:ws-1:w1"
local WORK2 = "bw:node-a:ws-1:w2"
local OP = "bo:node-a:ws-1:o1"
local NOW = "2026-09-29T10:00:00Z"

local MUTATIONS = {"session_open", "session_run", "session_send", "session_join", "session_cancel", "session_close"}
local READS = {"session_catalog", "session_await", "session_get", "session_list"}

local function valid(name: string): Object
    local spec = {definition = "def:research"}
    if name == "session_catalog" then return {kind = "definition", include_unavailable = true} end
    if name == "session_open" then return {spec = spec, operation_key = "k1"} end
    if name == "session_run" then return {spec = spec, input = "do it", operation_key = "k1"} end
    if name == "session_send" then return {session = SESSION, input = {schema = "bee:Text@1", value = {text = "go"}}, after = {WORK}, operation_key = "k1"} end
    if name == "session_await" then return {subject = WORK, timeout_ms = 1000} end
    if name == "session_join" then return {works = {WORK, WORK2}, policy = "quorum", quorum = 2, operation_key = "k1"} end
    if name == "session_get" then return {work = WORK} end
    if name == "session_list" then return {filter = {lifecycle = "active"}} end
    if name == "session_cancel" then return {work = WORK, reason = "stop", operation_key = "k1"} end
    return {session = SESSION, mode = "drain", operation_key = "k1"}
end

local function snapshot(): Object
    return {session = SESSION, revision = 1, incarnation = 1, title = "t", lifecycle = "active", mode = "managed",
        activity = "idle", execution = {state = "absent", evidence_at = NOW, stale = false}, queue_count = 0,
        questions = {}, effective_limits = {active_ms = 1, model_steps = 1, tool_calls = 1, recovery_attempts = 0, queue_ms = 1, question_ms = 1},
        continuity = {mode = "fresh"}, actions = {}}
end

local function receipt(): Object
    return {work = WORK, session = SESSION, operation = OP, committed_at = NOW, sequence = 1, kind = "request",
        state = "queued", output_schema = "bee:Text@1"}
end

local function success(name: string): Object
    if name == "session_open" then return {ok = true, value = {session = SESSION, operation = OP, snapshot = snapshot()}} end
    if name == "session_run" or name == "session_send" then return {ok = true, value = receipt()} end
    if name == "session_cancel" then return {ok = true, value = {operation = OP, subject = WORK, state = "requested", effect = "cancel"}} end
    if name == "session_close" then return {ok = true, value = {operation = OP, subject = SESSION, state = "requested", effect = "close"}} end
    if name == "session_await" then return {ok = true, value = {subject_kind = "work", subject = WORK, cursor = "c1", tag = "pending", reason = "timeout"}} end
    if name == "session_get" then return {ok = true, value = {kind = "session", value = snapshot()}} end
    if name == "session_list" then return {ok = true, value = {items = {snapshot()}, feed = "f1", snapshot = "s1"}} end
    if name == "session_catalog" then return {ok = true, value = {items = {}, complete = true, unavailable_count = 0, diagnostics = {}}} end
    return {ok = true, value = {subject_kind = "join", subject = "bj:node-a:ws-1:j1", cursor = "c1", tag = "pending", reason = "timeout",
        children = {{subject_kind = "work", subject = WORK, cursor = "c1", tag = "pending", reason = "timeout"}}}}
end

local function fake_owner(log: {Object}): Object
    local owner: Object = {}
    for _, method in ipairs({"open", "run", "send", "await", "join", "get", "list", "cancel", "close"}) do
        owner[method] = function(_self: Object, request: Object): (unknown, unknown)
            log[#log + 1] = {method = method, request = request}
            return {ok = true, value = {}}, nil
        end
    end
    return owner
end

local function define_tests()
    test.describe("Default session MCP tools", function()
        test.it("publishes exactly the ten tools as owner contract projections", function()
            test.eq(#session_tools.NAMES, 10)
            local seen: {[string]: mcp.Tool} = {}
            for _, tool in ipairs(mcp.TOOLS) do
                test.is_nil(seen[tool.name])
                seen[tool.name] = tool
            end
            for _, name in ipairs(session_tools.NAMES) do
                local tool = seen[name]
                if not tool then error("missing " .. name) end
                local contract, method = session_tools.target(name)
                test.eq(tool.operation, tostring(contract) .. "." .. tostring(method))
                test.eq(tool.policies[1], mcp.TOOL_POLICY_REFS.session)
                local outputs = mcp.OUTPUT_SCHEMAS :: {[string]: Object}
                test.not_nil(outputs[name])
                test.eq((outputs[name] :: Object).type, "object")
                test.eq(tool.schema.additionalProperties, false)
                test.eq(tool.schema.type, "object")
            end
            test.eq((seen.session_catalog :: mcp.Tool).operation, "bee.sessions:catalog.list")
            test.eq((seen.session_send :: mcp.Tool).operation, "bee.sessions:contract.send")
            test.not_nil(seen.session_inbox_send)
            test.eq((seen.session_inbox_send :: mcp.Tool).operation, "bee.threads.service:inbox_send")
        end)
        test.it("advertises operation_key as required on every mutation and annotations that match", function()
            for _, name in ipairs(MUTATIONS) do
                local tool = mcp.tool(name) :: mcp.Tool
                local required = tool.schema.required :: {string}
                local found = false
                for _, item in ipairs(required) do if item == "operation_key" then found = true end end
                test.is_true(found)
                test.eq(tool.annotations.readOnlyHint, false)
                test.eq(tool.annotations.idempotentHint, true)
            end
            for _, name in ipairs(READS) do test.eq((mcp.tool(name) :: mcp.Tool).annotations.readOnlyHint, true) end
            for _, name in ipairs({"session_join", "session_cancel", "session_close"}) do
                test.eq((mcp.tool(name) :: mcp.Tool).annotations.destructiveHint, true)
            end
            test.eq((mcp.tool("session_send") :: mcp.Tool).annotations.destructiveHint, false)
        end)
        test.it("steers use in the descriptions", function()
            local send = (mcp.tool("session_send") :: mcp.Tool).description
            test.is_true(send:find("Submit work", 1, true) ~= nil)
            test.is_true((mcp.tool("session_open") :: mcp.Tool).description:find("session_send", 1, true) ~= nil)
            test.is_true((mcp.tool("session_run") :: mcp.Tool).description:find("not the answer", 1, true) ~= nil)
            local await = (mcp.tool("session_await") :: mcp.Tool).description
            test.is_true(await:find("work, operation or question", 1, true) ~= nil)
            test.is_true(await:find("timeout never cancels", 1, true) ~= nil)
        end)
        test.it("admits every tool through the strict catalog and keeps the no-shadow rule", function()
            local list: {Object} = {}
            for _, tool in ipairs(mcp.TOOLS) do
                list[#list + 1] = {name = tool.name, operation = tool.operation, description = tool.description,
                    policies = {"bee.gateway:tool_session_policy_ref"}, schema = tool.schema, annotations = tool.annotations}
            end
            test.not_nil(catalog.decode({tools = list, traits = {}}))
            local raw = {tools = {}, traits = {}, base_tools = {"session_send"}, active_traits = {}, fixed_context = {}, dynamic_keys = {}}
            test.not_nil(surface.prepare(raw, mcp.TOOLS, {"session_send"}))
            test.is_nil(surface.prepare(raw, mcp.TOOLS, {"session_missing"}))
            raw.tools = {{name = "session_send", operation = "research:send", description = "Shadow", policies = {"research:policy"},
                schema = {type = "object"}, annotations = {readOnlyHint = true}}}
            test.is_nil(surface.prepare(raw, mcp.TOOLS, {"session_send"}))
        end)
        test.it("decodes a valid call for every tool", function()
            for _, name in ipairs(session_tools.NAMES) do
                local request, failure = session_tools.decode(name, {arguments = valid(name)})
                test.is_nil(failure)
                test.not_nil(request)
            end
        end)
        test.it("refuses a mutation without its operation_key", function()
            for _, name in ipairs(MUTATIONS) do
                local arguments = valid(name)
                arguments.operation_key = nil
                local request, failure = session_tools.decode(name, {arguments = arguments})
                test.is_nil(request)
                test.eq(failure, "arguments.operation_key is required")
            end
        end)
        test.it("refuses caller identity and unknown fields in every payload", function()
            for _, name in ipairs(session_tools.NAMES) do
                for _, field in ipairs({"subject_id", "workspace_id", "thread_id", "caller", "sender_action_id", "incarnation_epoch"}) do
                    if not (name == "session_await" and field == "subject_id") then
                        local arguments = valid(name)
                        arguments[field] = "forged"
                        local request, failure = session_tools.decode(name, {arguments = arguments})
                        test.is_nil(request)
                        test.eq(failure, "unknown field " .. field)
                    end
                end
            end
        end)
        test.it("enforces reference, time, timeout and exclusivity bounds", function()
            local function refused(name: string, mutate: (Object) -> ()): string?
                local arguments = valid(name)
                mutate(arguments)
                local request, failure = session_tools.decode(name, {arguments = arguments})
                test.is_nil(request)
                return failure
            end
            refused("session_send", function(a) a.session = "session-1" end)
            refused("session_send", function(a) a.session = WORK end)
            refused("session_send", function(a) a.after = {WORK, WORK} end)
            refused("session_send", function(a) a.after = {} end)
            refused("session_send", function(a) a.expires_at = "tomorrow" end)
            refused("session_send", function(a) a.input = 5 end)
            refused("session_send", function(a) a.operation_key = string.rep("k", 129) end)
            refused("session_send", function(a) a.input = string.rep("x", 16385) end)
            refused("session_await", function(a) a.timeout_ms = 60001 end)
            refused("session_await", function(a) a.subject = SESSION end)
            refused("session_get", function(a) a.session = SESSION end)
            refused("session_get", function(a) a.work = nil end)
            refused("session_join", function(a) a.quorum = nil end)
            refused("session_join", function(a) a.quorum = 3 end)
            refused("session_join", function(a) a.policy = "all_success" end)
            refused("session_join", function(a) a.works = {} end)
            refused("session_close", function(a) a.mode = "kill" end)
            refused("session_open", function(a) a.spec = {} end)
            refused("session_open", function(a) a.spec = {definition = "d", limits = {active_ms = 0}} end)
            for _, subject in ipairs({WORK, OP, "bq:node-a:ws-1:q1"}) do
                test.not_nil(session_tools.decode("session_await", {arguments = {subject = subject, deadline_at = "2026-09-29T10:00:00.5+02:00"}}))
            end
            test.not_nil(session_tools.decode("session_get", {arguments = {operation_key = "k"}}))
            test.is_nil(session_tools.decode("session_get", {arguments = "text"}))
            test.is_nil(session_tools.decode("session_get", {}))
        end)
        test.it("bounds inline JSON payloads by depth", function()
            local deep: Object = {}
            local cursor = deep
            for _ = 1, 17 do
                local child: Object = {}
                cursor.next = child
                cursor = child
            end
            local request = session_tools.decode("session_run", {arguments = {spec = {definition = "d"},
                input = {schema = "s", value = deep}, operation_key = "k"}})
            test.is_nil(request)
        end)
        test.it("projects each tool onto exactly one owner method with the validated request", function()
            local expected = {session_catalog = "list", session_open = "open", session_run = "run", session_send = "send",
                session_await = "await", session_join = "join", session_get = "get", session_list = "list",
                session_cancel = "cancel", session_close = "close"}
            for _, name in ipairs(session_tools.NAMES) do
                local log: {Object} = {}
                local owner = fake_owner(log)
                local request = session_tools.decode(name, {arguments = valid(name)}) :: Object
                local reply, failure = session_tools.call(owner, name, request)
                test.is_nil(failure)
                test.not_nil(reply)
                test.eq(#log, 1)
                local call = log[1] :: Object
                test.eq(call.method, expected[name])
                test.eq(call.request, request)
            end
            test.is_nil(select(1, session_tools.call({}, "session_open", {})))
            local _, missing = session_tools.call({}, "session_open", {})
            test.eq(missing, "owner binding has no method open")
        end)
        test.it("accepts owner replies that satisfy the published output schema", function()
            for _, name in ipairs(session_tools.NAMES) do
                local checked, failure = session_tools.result(name, success(name))
                if not checked then error(name .. ": " .. tostring(failure)) end
            end
            local fault = {ok = false, error = {code = "CONFLICT", message = "key reused", retry = "never", operation_key = "k1"}}
            for _, name in ipairs(MUTATIONS) do test.not_nil(session_tools.result(name, fault)) end
            local read_fault = {ok = false, error = {code = "NOT_FOUND", message = "gone", retry = "never"}}
            for _, name in ipairs(READS) do test.not_nil(session_tools.result(name, read_fault)) end
        end)
        test.it("refuses owner replies that break the published schema", function()
            local no_key = {ok = false, error = {code = "CONFLICT", message = "key reused", retry = "never"}}
            for _, name in ipairs(MUTATIONS) do
                local checked = session_tools.result(name, no_key)
                test.is_nil(checked)
            end
            local extra = success("session_send")
            extra.extra = true
            test.is_nil(session_tools.result("session_send", extra))
            local wrong = success("session_send")
            wrong.value = snapshot()
            test.is_nil(session_tools.result("session_send", wrong))
            local settled_pending = success("session_await")
            settled_pending.value = {subject_kind = "work", subject = WORK, cursor = "c", tag = "ready", reason = "timeout"}
            test.is_nil(session_tools.result("session_await", settled_pending))
            test.is_nil(session_tools.result("session_get", "text"))
            local bad_cancel = success("session_cancel")
            ;(bad_cancel.value :: Object).effect = "close"
            test.is_nil(session_tools.result("session_cancel", bad_cancel))
        end)
    end)
end
return require("test").run_cases(define_tests)
