-- MIT. Leases on node-managed workspace hosts: the messages a holder and the
-- node host manager exchange, and the holder's side of them. A lease is a
-- process-registry name its holder registers; the manager accepts a request
-- only from the process that holds the name it carries, and every lease ends
-- when its holder releases it or exits.
local process = require("process")
local channel = require("channel")
local time = require("time")
local uuid = require("uuid")
local contract = require("contract")

type Acquire = {request_id: string, workspace_id: string, lease: string}
type Result = {request_id: string, workspace_id: string, host: string, managed: boolean, error_code: string, error: string}
type Lease = {name: string, workspace_id: string, host: string, managed: boolean}

local M = {}
M.MANAGER = "bee.workspace.hosts"
M.PREFIX = "bee.workspace.lease/"
M.ACQUIRE = "bee.workspace.hosts.acquire"
M.RELEASE = "bee.workspace.hosts.release"
M.RESULT = "bee.workspace.hosts.result"

local function text(value: unknown, limit: integer): string?
    if type(value) ~= "string" or #value > limit or value:find("%c") then return nil end
    return value
end

function M.lease_name(value: unknown): string?
    local name = text(value, 120)
    if not name or name:sub(1, #M.PREFIX) ~= M.PREFIX or #name == #M.PREFIX then return nil end
    if name:sub(#M.PREFIX + 1):find("[^%w%-]") then return nil end
    return name
end

function M.acquire_request(value: unknown): Acquire?
    if type(value) ~= "table" or value.version ~= 1 then return nil end
    local request_id, workspace_id, lease = text(value.request_id, 80), contract.workspace_id(value.workspace_id), M.lease_name(value.lease)
    if not request_id or request_id == "" or not workspace_id or not lease then return nil end
    return {request_id = request_id, workspace_id = workspace_id, lease = lease}
end

function M.release_request(value: unknown): string?
    if type(value) ~= "table" or value.version ~= 1 then return nil end
    return M.lease_name(value.lease)
end

function M.result(value: unknown): Result?
    if type(value) ~= "table" or value.version ~= 1 then return nil end
    local request_id, workspace_id = text(value.request_id, 80), contract.workspace_id(value.workspace_id)
    local host, code, message = text(value.host, 200), text(value.error_code, 64), text(value.error, 2000)
    if not request_id or not workspace_id or not host or not code or not message or type(value.managed) ~= "boolean" then return nil end
    if (code == "") == (host == "") then return nil end
    return {request_id = request_id, workspace_id = workspace_id, host = host, managed = value.managed, error_code = code, error = message}
end

local function release_name(name: string)
    process.registry.unregister(name, process.registry.LOCAL)
end

-- Take a lease on a workspace; the manager starts its host when none is live.
-- A timeout leaves the outcome unknown, so the lease is released, never retried.
function M.acquire(workspace_id: string, timeout: string): (Lease?, string?)
    local id = contract.workspace_id(workspace_id)
    if not id then return nil, "invalid workspace identity" end
    local manager = process.registry.lookup(M.MANAGER)
    if not manager then return nil, "the node host manager is not running" end
    local nonce, nonce_error = uuid.v7()
    if not nonce then return nil, tostring(nonce_error) end
    local name = M.PREFIX .. nonce
    local registered, register_error = process.registry.register(name)
    if not registered then return nil, "register lease: " .. tostring(register_error) end
    local results, listen_error = process.listen(M.RESULT, {message = true})
    if not results then release_name(name); return nil, tostring(listen_error) end
    local request_id = "acquire-" .. nonce
    local sent, send_error = process.send(manager, M.ACQUIRE, {version = 1, request_id = request_id, workspace_id = id, lease = name})
    if not sent then
        process.unlisten(results); release_name(name)
        return nil, "send lease request: " .. tostring(send_error)
    end
    local timer, timer_error = time.timer(timeout)
    if not timer then
        process.unlisten(results); release_name(name)
        return nil, tostring(timer_error)
    end
    local deadline = timer:channel()
    local result: Result? = nil
    while true do
        local selected = channel.select({results:case_receive(), deadline:case_receive()})
        if not selected.ok or selected.channel == deadline then break end
        if tostring(selected.value:from()) == tostring(manager) then
            local candidate = M.result(selected.value:payload():data())
            if candidate and candidate.request_id == request_id then result = candidate; break end
        end
    end
    timer:stop()
    process.unlisten(results)
    if not result then
        process.send(manager, M.RELEASE, {version = 1, lease = name})
        release_name(name)
        return nil, "the host manager did not answer; the lease was released"
    end
    if result.error_code ~= "" then
        release_name(name)
        return nil, result.error_code .. ": " .. result.error
    end
    return {name = name, workspace_id = id, host = result.host, managed = result.managed}, nil
end

function M.release(lease: Lease)
    local manager = process.registry.lookup(M.MANAGER)
    if manager then process.send(manager, M.RELEASE, {version = 1, lease = lease.name}) end
    release_name(lease.name)
end

return M
