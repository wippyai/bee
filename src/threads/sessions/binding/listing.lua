local bounds = require("bounds")
local journal = require("journal")
local json = require("json")
local security = require("security")
local remote = require("remote")
local system = require("system")
local snapshot = require("snapshot").decode
local M = {}
type Object = {[string]: unknown}
type Reply = {ok: boolean, value?: unknown, error?: Object}

local function object(value: unknown): Object?
    return bounds.object(value)
end

local function fail(code: string, message: string, operation_key: string?): Reply
    local error: Object = {code = code, message = message, retry = "never"}
    if operation_key then error.operation_key = operation_key end
    return {ok = false, error = error}
end

local function unavailable(message: string, operation_key: string?): Reply
    local reply = fail("UNAVAILABLE", message, operation_key)
    local failure = reply.error
    if failure then failure.retry = "refresh" end
    return reply
end

local function succeed(value: unknown): Reply
    return {ok = true, value = value}
end

local function request_input(request: unknown): (Object?, Reply?)
    local input = object(request)
    if not input then return nil, fail("INVALID", "request must be an object", nil) end
    return input, nil
end

local function identity(): (string?, string?)
    local caller = security.actor()
    if not caller then return nil, nil end
    local id = bounds.id(caller:id())
    local meta = object(caller:meta())
    local workspace = meta and bounds.id(meta.workspace_id)
    if not id or not workspace then return nil, nil end
    return id, workspace
end

local function key(value: unknown): string?
    if type(value) ~= "string" or #value < 1 or #value > 128 or value:find("%c") then return nil end
    return value
end

local function ref(value: unknown): string?
    if type(value) ~= "string" or #value < 1 or #value > 256 or value:find("%c") then return nil end
    return value
end


local function describe(session: string): (Object?, string?)
    local value, err = journal.invoke("session_describe", {session = session})
    if err or not value then return nil, err or "Threads returned no session" end
    return snapshot(value)
end
-- LIST_PAGE_BYTES is the published bound of one reply value; a page carries
-- as many sessions as fit under it with its cursor.
M.LIST_PAGE_BYTES = 65536
local LIST_PAGE_OVERHEAD_BYTES = 512
function M.list(raw_request: unknown): Reply
    local request, refused = request_input(raw_request)
    if not request then return assert(refused) end
    if bounds.fields(request, {"filter", "cursor"}) then return fail("INVALID", "list accepts only filter and cursor") end
    local filter = object(request.filter)
    if request.filter ~= nil and (not filter or bounds.fields(filter, {"lifecycle", "activity", "workspace", "definition"})) then
        return fail("INVALID", "session filter is malformed")
    end
    local lifecycle = filter and filter.lifecycle or nil
    if lifecycle ~= nil and lifecycle ~= "opening" and lifecycle ~= "active" and lifecycle ~= "suspended"
        and lifecycle ~= "closing" and lifecycle ~= "closed" then return fail("INVALID", "lifecycle filter is invalid") end
    local activity = filter and filter.activity or nil
    if activity ~= nil and activity ~= "idle" and activity ~= "working" and activity ~= "blocked" and activity ~= "stalled" then
        return fail("INVALID", "activity filter is invalid")
    end
    local workspace = filter and filter.workspace or nil
    local definition = filter and filter.definition or nil
    if (workspace ~= nil and not bounds.id(workspace)) or (definition ~= nil and not ref(definition)) then return fail("INVALID", "workspace or definition filter is invalid") end
    local cursor = request.cursor == nil and nil or ref(request.cursor)
    if request.cursor ~= nil and not cursor then return fail("INVALID", "cursor is invalid") end
    local page, scan_error = journal.invoke("session_scan", {cursor = cursor, limit = 64, workspace = workspace})
    if scan_error or not page then return unavailable(scan_error or "Threads returned no session page", nil) end
    local scan = object(page)
    local refs = scan and scan.items
    if type(refs) ~= "table" then return unavailable("Threads returned a malformed session page", nil) end
    local items: {Object} = {}
    -- The page stays within one published reply value: once the next session
    -- would not fit, the page ends after the last session scanned.
    local size = LIST_PAGE_OVERHEAD_BYTES
    local scanned: string? = nil
    for _, raw_ref in ipairs(refs) do
        local session = ref(raw_ref)
        if not session then return unavailable("Threads returned a malformed session ref", nil) end
        local current, read_error = describe(session)
        if not current then return unavailable(read_error or "cannot read a listed session", nil) end
        if (lifecycle == nil or current.lifecycle == lifecycle) and (activity == nil or current.activity == activity)
            and (definition == nil or current.definition == definition) then
            local encoded = json.encode(current)
            if not encoded then return unavailable("a listed session is not encodable", nil) end
            if size + #encoded + 1 > M.LIST_PAGE_BYTES then
                if not scanned then return unavailable("one session exceeds the list page bound", nil) end
                return succeed({items = items, next = scanned})
            end
            size = size + #encoded + 1
            items[#items + 1] = current
        end
        scanned = session
    end
    return succeed({items = items, next = scan and ref(scan.next) or nil})
end

-- Read-only display summary for the caller's workspace. No control actions.
function M.attention_count(raw_request: unknown): Reply
    local request, refused = request_input(raw_request)
    if not request then return assert(refused) end
    local actor, workspace = identity()
    if not actor or not workspace or request.workspace_id ~= workspace
        or bounds.fields(request, {"workspace_id"}) then return fail("DENIED", "attention summary requires the caller's workspace") end
    local count = 0
    local cursor: string? = nil
    for _ = 1, 16 do
        local page = M.list({filter = {workspace = workspace}, cursor = cursor})
        if not page.ok then return page end
        local value = object(page.value)
        local items = value and value.items
        if type(items) ~= "table" then return unavailable("session summary unavailable", nil) end
        for _, raw in ipairs(items) do
            local row = object(raw)
            if row and row.lifecycle ~= "closed" and (row.activity == "blocked" or row.activity == "stalled") then count = count + 1 end
        end
        cursor = value and ref(value.next) or nil
        if not cursor then return succeed({count = count}) end
    end
    return unavailable("session summary exceeds the display page limit", nil)
end

for _, name in ipairs({"list"}) do
    local local_method = M[name]
    M[name] = function(raw: unknown): Reply
        local input = object(raw)
        if not input or input.node == nil then return local_method(raw) end
        local node = bounds.id(input.node)
        if not node or node:find("[^A-Za-z0-9_.-]") then return fail("INVALID", "node is malformed", key(input.operation_key)) end
        local request: Object = {}
        for field, value in pairs(input) do if field ~= "node" then request[field] = value end end
        if node == system.node.id() then return local_method(request) end
        local reply = remote.call(node, name, request)
        return {ok = reply.ok == true, value = reply.value, error = object(reply.error)}
    end
end
return M
