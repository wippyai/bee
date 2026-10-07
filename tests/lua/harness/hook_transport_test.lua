-- MIT. Hook payloads at the size harnesses send them: a PostToolUse carries
-- the complete tool output, so a large Read reaches /hook/{action} as a body
-- far past the record the gateway keeps. The gateway accepts it up to its
-- transport ceiling and queues the bounded normalized fact: sizes and digests
-- of the content, never the content.
local test = require("test")
local bounds = require("bounds")
local funcs = require("funcs")
local security = require("security")
local registry = require("registry")
local time = require("time")
local json = require("json")
local http_client = require("http_client")
local hooks = require("hooks")
local principals = require("principals")
local ACTOR = "bee.test.hook_transport"
type Object = {[string]: unknown}
local counter = 0
local function fresh(prefix: string): string
    counter = counter + 1
    return prefix .. "-" .. tostring(math.floor(time.now():unix_nano() / 1000)) .. "-" .. tostring(counter)
end
local scope_names = {"bee.harness.catalog:carrier_client_policy", "bee.harness.catalog:gateway_client_policy", "bee.harness.security:carrier_policy", "bee.threads.security:create", "bee.threads.security:observe",
    "bee.tests.support:gateway_manage_policy", "bee.tests.support:gateway_admit_policy", "bee.security.gateway:gateway_materialize_policy"}
local function scope(): security.Scope
    local policies: {security.Policy} = {}
    for index, name in ipairs(scope_names) do
        local found, err = security.policy(name)
        if err or not found then error("policy " .. name .. ": " .. tostring(err)) end
        policies[index] = found
    end
    return security.new_scope(policies)
end
local function call(target: string, request: unknown): Object
    local result, err = funcs.new():with_actor(principals.actor(ACTOR, principals.workspace(request))):with_scope(scope()):call(target, request)
    if err then error(target .. ": " .. tostring(err)) end
    local reply = assert(bounds.object(result))
    if reply.ok ~= true then
        local fault = bounds.object(reply.error) or {}
        error(target .. ": " .. tostring(fault.code) .. ": " .. tostring(fault.message))
    end
    return assert(bounds.object(reply.value))
end
local function address(): string
    local entry = registry.get("bee.gateway.api:gateway_endpoint")
    if not entry then error("gateway endpoint entry") end
    return tostring((assert(bounds.object(entry.data))).address)
end
-- A PostToolUse for a Read as Claude Code sends it: the tool input and the
-- complete file content the tool returned.
local function read_event(tool_use_id: string, content_bytes: integer): string
    local line = string.rep("x", 79) .. "\n"
    local content = string.rep(line, content_bytes // #line) .. string.rep("y", content_bytes % #line)
    return assert(json.encode({session_id = "hook-transport-session", hook_event_name = "PostToolUse", tool_name = "Read",
        tool_use_id = tool_use_id, tool_input = {file_path = "/work/large.txt"},
        tool_response = {type = "text", file = {filePath = "/work/large.txt", content = content, numLines = content_bytes // #line,
            startLine = 1, totalLines = content_bytes // #line}}}))
end
local function define_tests()
    test.describe("hook transport", function()
        test.it("queues a PostToolUse carrying a large tool output as its bounded fact, up to the transport ceiling", function()
            call("bee.gateway.binding:open", {address = address()})
            local thread = call("bee.threads.binding:create", {thread_id = fresh("thread"), idempotency_key = fresh("key"), title = "Hook transport"})
            local attempt_id = fresh("attempt")
            local action_id = "action-" .. attempt_id
            local admitted = call("bee.gateway.binding:admit", {subject = ACTOR, action_id = action_id, attempt_id = attempt_id,
                thread_id = thread.thread_id, owner_incarnation = 1, carrier_epoch = 1, tools = {"thread_read"}, hooks = {"PostToolUse"}})
            local binding_id = tostring((assert(bounds.object(admitted.binding))).binding_id)
            local authorized = call("bee.gateway.binding:authorize_materialization", {attempt_id = attempt_id, carrier_epoch = 1, binding_id = binding_id})
            local minted = call("bee.gateway.binding:materialize", {attempt_id = attempt_id, carrier_epoch = 1, binding_id = binding_id,
                materialization_key = authorized.materialization_key})
            local url = "http://" .. address() .. "/hook/" .. action_id
            local function post(body: string): integer
                local response, err = http_client.post(url, {headers = {["Content-Type"] = "application/json",
                    Authorization = "Bearer " .. tostring(minted.hook_token)}, body = body, timeout = 30})
                if err or not response then error("hook post: " .. tostring(err)) end
                return math.floor(tonumber(response.status_code) or 0)
            end
            -- A new occurrence is queued (202) or, once committed, answered 200.
            local function accepted(status: integer)
                test.is_true(status == 200 or status == 202, "hook answered " .. tostring(status))
            end
            local large = read_event("tool-large", 40 * 1024)
            test.is_true(#large > 32768)
            accepted(post(large))
            -- Each 80-byte line gains one byte when its newline is escaped.
            local near = read_event("tool-near", (hooks.MAX_PAYLOAD_BYTES - 4096) * 80 // 81)
            test.is_true(#near <= hooks.MAX_PAYLOAD_BYTES and #near > hooks.MAX_PAYLOAD_BYTES - 8192, "near-ceiling body is " .. tostring(#near))
            accepted(post(near))
            test.eq(post(read_event("tool-over", hooks.MAX_PAYLOAD_BYTES + 1024)), 413)
            local queue = call("bee.gateway.binding:hook_queue", {binding_id = binding_id})
            local seen: {[string]: Object} = {}
            for _, raw in ipairs(principals.objects(queue.hooks)) do
                local fields = assert(bounds.object(raw.fields))
                seen[tostring(fields.tool_use_id)] = fields
            end
            test.is_nil(seen["tool-over"])
            for id, body in pairs({["tool-large"] = large, ["tool-near"] = near}) do
                local fields = assert(seen[id], id)
                test.eq(fields.event, "PostToolUse")
                test.eq(fields.tool_name, "Read")
                test.is_nil(fields.tool_response)
                local sizes = assert(bounds.object(fields.content_sizes))
                test.is_true((tonumber(sizes.tool_response) or 0) > #body - 1024, id)
                test.eq(#tostring((assert(bounds.object(fields.content_digests))).tool_response), 64)
            end
            local stored = json.encode(queue.hooks) or ""
            test.is_true(#stored < 8192)
            test.is_nil((stored:find("xxxxxxxx", 1, true)))
            call("bee.gateway.binding:revoke", {binding_id = binding_id})
        end)
    end)
end
return test.run_cases(define_tests)
