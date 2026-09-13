-- SPDX-License-Identifier: MIT
-- Only fixture credentials cross the private in-memory callback to the host
-- acceptance driver. Nothing is printed or written to a credential file.
local funcs = require("funcs")
local json = require("json")
local http_client = require("http_client")
local time = require("time")
local env = require("env")
local logger = require("logger")
local security = require("security")
type Object = {[string]: unknown}
local function call(target: string, request: Object): Object
    local raw, err = funcs.call(target, request)
    if err or type(raw) ~= "table" then error(target .. ": " .. tostring(err)) end
    local reply = raw :: Object
    if reply.ok ~= true then
        local failure = reply.error
        if type(failure) == "table" then
            error(target .. " refused: " .. tostring((failure :: Object).code) .. ": " .. tostring((failure :: Object).message))
        end
        error(target .. " refused without an error value")
    end
    return reply.value :: Object
end
local function main()
    local callback = env.get("bee.gateway_container:callback")
    if not callback then error("fixture callback missing") end
    local selected: Object? = nil
    for _ = 1, 100 do
        local raw, err = funcs.call("bee.gateway:address", {})
        if not err and type(raw) == "table" then selected = raw :: Object; break end
        time.sleep("20ms")
    end
    if not selected or type(selected.address) ~= "string" then error("listener unavailable") end
    local address = selected.address :: string
    for _, url in ipairs({"http://" .. address .. "/mcp/other", "http://" .. address .. "/ready/extra", "http://" .. address .. "/ready?extra=1", "http://example.invalid/ready"}) do
        if security.can("http_client.request", url) then error("readiness policy grants an unrelated URL") end
    end
    call("bee.threads.service:create", {thread_id = "container-thread", idempotency_key = "create", title = "Container gateway proof"})
    local admitted = call("bee.gateway:admit", {subject = "bee.test.container", action_id = "container-action", attempt_id = "container-attempt",
        thread_id = "container-thread", owner_incarnation = 1, carrier_epoch = 1, tools = {"thread_read", "thread_wait"}, hooks = {"SessionStart"}, ttl_ms = 120000})
    local binding = admitted.binding :: Object
    local authorized = call("bee.gateway:authorize_materialization", {attempt_id = "container-attempt", carrier_epoch = 1, binding_id = binding.binding_id})
    local materialized = call("bee.gateway:materialize", {attempt_id = "container-attempt", carrier_epoch = 1, materialization_key = authorized.materialization_key})
    local ready = call("bee.gateway:ready", {binding_id = binding.binding_id})
    if ready.listening ~= true or ready.binding_valid ~= true then error("gateway readiness refused") end
    local function phase(name: string)
        local payload = json.encode({phase = name, address = address, token = materialized.token, hook_token = materialized.hook_token})
        local response, err = http_client.post(callback, {body = payload, headers = {["Content-Type"] = "application/json"}, timeout = "45s"})
        if not response or err or response.status_code ~= 200 then error("container " .. name .. " proof failed") end
    end
    phase("active")
    call("bee.gateway:revoke", {binding_id = binding.binding_id})
    phase("revoked")
end
local function checked_main()
    local ok, err = pcall(main)
    if not ok then
        logger:error("container fixture failed", {error = tostring(err)})
        error(err)
    end
end
return {main = checked_main}
