-- SPDX-License-Identifier: MIT
local test = require("test")
local external = require("external")
local gateway = require("gateway")
local funcs = require("funcs")
local security = require("security")
local json = require("json")
local bounds = require("bounds")
local catalog = require("catalog")
local http_client = require("http_client")
local events = require("events")
local logger = require("logger")
local channel = require("channel")
local time = require("time")
local WORKSPACE = "mcp-external-tests"
type Object = {[string]: unknown}
local function value(reply: unknown): Object
    local object = assert(bounds.object(reply))
    if object.ok ~= true then error(json.encode(object) or "invalid reply") end
    return assert(bounds.object(object.value))
end
local function request(): Object
    return value(external.request({name = "Terminal Claude", workspace_id = WORKSPACE, caller = "fixture-cli"}))
end
local function decide(paired: Object, decision: string)
    local executor = funcs.new():with_actor(security.new_actor("bee.application:" .. WORKSPACE .. ":needs-you",
        {workspace_id = WORKSPACE, definition_id = "bee.approvals.inbox.app:app"}))
    local approval = value(executor:call("bee.approvals.binding:read", {approval_id = paired.approval_id}))
    value(executor:call("bee.approvals.binding:decide", {approval_id = paired.approval_id, decision = decision,
        expected_revision = approval.revision, proposal_digest = approval.proposal_digest}))
end
local function rpc(endpoint: string, action: string, token: string, method: string, params: Object): (Object, integer)
    local response, err = http_client.post("http://" .. endpoint .. "/mcp/" .. action, {headers = {["Content-Type"] = "application/json",
        Authorization = "Bearer " .. token}, body = assert(json.encode({jsonrpc = "2.0", id = 1, method = method, params = params})), timeout = 30})
    if not response or err then error("MCP HTTP call fails") end
    return assert(bounds.object(json.decode(tostring(response.body)))), math.floor(tonumber(response.status_code) or 0)
end
local function names(reply: Object): {[string]: boolean}
    local result = assert(bounds.object(reply.result))
    local rows = assert(bounds.array(result.tools, 64))
    local found: {[string]: boolean} = {}
    for _, raw in ipairs(rows) do local tool = assert(bounds.object(raw)); found[assert(bounds.id(tool.name))] = true end
    return found
end
local function define_tests()
    value(gateway.open({address = assert(gateway.endpoint())}))
    test.describe("External MCP pairing", function()
        test.it("files a named trait request with no credential before approval", function()
            local paired = request()
            test.eq(paired.status, "pending")
            test.is_nil(paired.token)
            local pending = value(external.complete(assert(bounds.id(paired.client_id)), "fixture-cli"))
            test.eq(pending.status, "pending")
            local approval = value(funcs.call("bee.approvals.binding:read", {approval_id = paired.approval_id}))
            test.is_true(json.encode(approval):find("Terminal Claude", 1, true) ~= nil)
            test.is_true(json.encode(approval):find("bee.mcp:read", 1, true) ~= nil)
            value(external.revoke(assert(bounds.id(paired.client_id)), WORKSPACE))
        end)
        test.it("denial yields no credential", function()
            local paired = request()
            decide(paired, "denied")
            local denied = value(external.complete(assert(bounds.id(paired.client_id)), "fixture-cli"))
            test.eq(denied.status, "denied")
            test.is_nil(denied.token)
        end)
        test.it("approves once, scopes the token, records calls and revokes immediately", function()
            local logs = assert(events.subscribe("logs", "logs.entry"))
            local paired = request()
            local id = assert(bounds.id(paired.client_id))
            decide(paired, "approved")
            local issued = value(external.complete(id, "fixture-cli"))
            local token = assert(bounds.text(issued.token, 128))
            local action = assert(bounds.id(issued.action_id))
            local binding = assert((gateway.authenticate(token, action, "tool")))
            test.eq(binding.subject, paired.subject)
            test.eq(binding.thread_id, paired.thread_id)
            test.is_nil((gateway.authenticate(token, "other-action", "tool")))
            local surface = assert((gateway.surface(binding)))
            local tools = assert(catalog.select(surface.configuration.catalog, surface.configuration.ceiling,
                surface.configuration.base_tools, surface.configuration.allowed_traits, surface.selection.active))
            local admitted_names: {[string]: boolean} = {}
            for _, tool in ipairs(tools) do admitted_names[tool.name] = true end
            test.is_true(admitted_names.docs == true)
            test.is_false(admitted_names.app_tools == true)
            test.is_false(admitted_names.thread_message == true)
            local endpoint = assert(bounds.text(issued.endpoint, 256))
            local offered = names((rpc(endpoint, action, token, "tools/list", {})))
            test.is_true(offered.docs == true)
            test.is_false(offered.thread_message == true)
            local called, status = rpc(endpoint, action, token, "tools/call", {name = "capabilities", arguments = {}})
            test.eq(status, 200)
            test.is_nil(called.error)
            test.is_false(assert(bounds.object(called.result)).isError == true)
            local denied_call = rpc(endpoint, action, token, "tools/call", {name = "thread_message", arguments = {}})
            test.not_nil(denied_call.error)
            value(gateway.record_external_call(binding, "docs"))
            local executor = funcs.new():with_actor(security.new_actor(binding.subject, {workspace_id = WORKSPACE}))
            local records = value(executor:call("bee.threads.binding:read_after", {thread_id = binding.thread_id, cursor = 0, limit = 64}))
            local encoded = assert(json.encode(records))
            test.is_true(encoded:find("MCP tool: docs", 1, true) ~= nil)
            test.is_true(encoded:find("MCP tool: capabilities", 1, true) ~= nil)
            test.is_nil((encoded:find(token, 1, true)))
            local directory = value(external.list(WORKSPACE))
            test.is_nil((assert(json.encode(directory)):find(token, 1, true)))
            local replay = value(external.complete(id, "fixture-cli"))
            test.eq(replay.status, "connected")
            test.is_nil(replay.token)
            local requested = rpc(endpoint, action, token, "tools/call", {name = "session", arguments = {operation = "request_access",
                idempotency_key = "notes", traits = {"bee.mcp:notes"}, reason = "Post progress notes"}})
            local result = assert(bounds.object(requested.result))
            local approved_request = value(result.structuredContent)
            test.is_false(names((rpc(endpoint, action, token, "tools/list", {}))).thread_message == true)
            decide(approved_request, "approved")
            local widened = rpc(endpoint, action, token, "tools/call", {name = "session", arguments = {operation = "access_status", approval_id = approved_request.approval_id}})
            test.eq(value(assert(bounds.object(widened.result)).structuredContent).status, "granted")
            test.is_true(names((rpc(endpoint, action, token, "tools/list", {}))).thread_message == true)
            local noted = rpc(endpoint, action, token, "tools/call", {name = "thread_message", arguments = {
                idempotency_key = id .. ".note", message_id = id .. ".note", message_kind = "progress", content = {text = "External progress note"}}})
            test.is_false(assert(bounds.object(noted.result)).isError == true)
            local transcript = assert(json.encode(value(external.records(id, WORKSPACE))))
            test.is_true(transcript:find("External progress note", 1, true) ~= nil)
            test.is_nil((transcript:find(token, 1, true)))
            value(external.revoke(id, WORKSPACE))
            test.is_nil((gateway.authenticate(token, action, "tool")))
            local _, refused_status = rpc(endpoint, action, token, "tools/list", {})
            test.eq(refused_status, 401)
            local marker = "MCP log barrier " .. id
            logger:info(marker)
            local deadline = time.after("5s")
            local reached = false
            while not reached do
                local selected = channel.select({logs:channel():case_receive(), deadline:case_receive()})
                if not selected.ok or selected.channel == deadline then logs:close(); error("MCP log capture has no barrier") end
                local event = assert(bounds.object(selected.value))
                local data = assert(bounds.object(event.data))
                local captured = assert(json.encode(data))
                test.is_nil((captured:find(token, 1, true)))
                local entry = bounds.object(data.entry)
                reached = entry ~= nil and entry.message == marker
            end
            logs:close()
        end)
        test.it("refuses configuration retrieval by another terminal or workspace", function()
            local paired = request()
            local id = assert(bounds.id(paired.client_id))
            test.is_false(external.complete(id, "other-cli").ok)
            test.is_false(external.revoke(id, "other-workspace").ok)
            value(external.revoke(id, WORKSPACE))
        end)
    end)
end
return test.run_cases(define_tests)
