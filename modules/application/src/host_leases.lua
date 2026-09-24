-- MIT. Leases on node-managed workspace hosts: the messages a holder and the
-- node host manager exchange, and the holder's side of them. A lease is a
-- process-registry name its holder registers; the manager accepts a request
-- only from the process that holds the name it carries, and every lease ends
-- when its holder releases it or exits.
local process = require("process")
local channel = require("channel")
local time = require("time")
local uuid = require("uuid")

type Acquire = {request_id: string, workspace_id: string, lease: string}
type Result = {request_id: string, workspace_id: string, host: string, managed: boolean, error_code: string, error: string}
type Lease = {name: string, workspace_id: string, host: string, managed: boolean}
type Attach = {request_id: string, lease: string}
type Attached = {request_id: string, workspace_id: string, error_code: string, error: string, ready: unknown}

local M = {}
M.MANAGER = "bee.workspace.hosts"
M.PREFIX = "bee.workspace.lease/"
M.ACQUIRE = "bee.workspace.hosts.acquire"
M.RELEASE = "bee.workspace.hosts.release"
M.RESULT = "bee.workspace.hosts.result"
-- A holder that admits desktops attaches to its leased host: the manager, the
-- host's owner, then relays that holder's desktop admission requests and the
-- host's answers, and answers the attach with the host's readiness.
M.ATTACH = "bee.workspace.hosts.attach"
M.ATTACHED = "bee.workspace.hosts.attached"

local function identity(value: unknown): string?
    if type(value) ~= "string" or #value ~= 32 or value:find("[^0-9a-f]") then return nil end
    return value
end

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
    local request_id, workspace_id, lease = text(value.request_id, 80), identity(value.workspace_id), M.lease_name(value.lease)
    if not request_id or request_id == "" or not workspace_id or not lease then return nil end
    return {request_id = request_id, workspace_id = workspace_id, lease = lease}
end

function M.release_request(value: unknown): string?
    if type(value) ~= "table" or value.version ~= 1 then return nil end
    return M.lease_name(value.lease)
end

function M.attach_request(value: unknown): Attach?
    if type(value) ~= "table" or value.version ~= 1 then return nil end
    local request_id, lease = text(value.request_id, 80), M.lease_name(value.lease)
    if not request_id or request_id == "" or not lease then return nil end
    return {request_id = request_id, lease = lease}
end

function M.attached(value: unknown): Attached?
    if type(value) ~= "table" or value.version ~= 1 then return nil end
    local request_id, workspace_id = text(value.request_id, 80), identity(value.workspace_id)
    local code, message = text(value.error_code, 64), text(value.error, 2000)
    if not request_id or not workspace_id or not code or not message then return nil end
    if (code == "") == (value.ready == nil) then return nil end
    return {request_id = request_id, workspace_id = workspace_id, error_code = code, error = message, ready = value.ready}
end

function M.result(value: unknown): Result?
    if type(value) ~= "table" or value.version ~= 1 then return nil end
    local request_id, workspace_id = text(value.request_id, 80), identity(value.workspace_id)
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
function M.acquire(selected: string, timeout: string): (Lease?, string?)
    local id = identity(selected)
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

-- Attach to a managed lease's host to admit desktops through the manager. The
-- value is the host's readiness announcement, for the caller to decode. A
-- timeout leaves the attachment unknown; the caller releases the lease.
function M.attach(lease: Lease, timeout: string): (unknown, string?)
    if not lease.managed then return nil, "the workspace is served by its own composition" end
    local manager = process.registry.lookup(M.MANAGER)
    if not manager then return nil, "the node host manager is not running" end
    local answers, listen_error = process.listen(M.ATTACHED, {message = true})
    if not answers then return nil, tostring(listen_error) end
    local request_id = "attach-" .. tostring(uuid.v7())
    local sent, send_error = process.send(manager, M.ATTACH, {version = 1, request_id = request_id, lease = lease.name})
    if not sent then process.unlisten(answers); return nil, "send attach request: " .. tostring(send_error) end
    local timer, timer_error = time.timer(timeout)
    if not timer then process.unlisten(answers); return nil, tostring(timer_error) end
    local deadline = timer:channel()
    local answer: Attached? = nil
    while true do
        local selected = channel.select({answers:case_receive(), deadline:case_receive()})
        if not selected.ok or selected.channel == deadline then break end
        if tostring(selected.value:from()) == tostring(manager) then
            local candidate = M.attached(selected.value:payload():data())
            if candidate and candidate.request_id == request_id then answer = candidate; break end
        end
    end
    timer:stop()
    process.unlisten(answers)
    if not answer then return nil, "the host manager did not answer the attach" end
    if answer.workspace_id ~= lease.workspace_id then return nil, "the host manager attached another workspace" end
    if answer.error_code ~= "" then return nil, answer.error_code .. ": " .. answer.error end
    return answer.ready, nil
end

function M.release(lease: Lease)
    local manager = process.registry.lookup(M.MANAGER)
    if manager then process.send(manager, M.RELEASE, {version = 1, lease = lease.name}) end
    release_name(lease.name)
end

return M
