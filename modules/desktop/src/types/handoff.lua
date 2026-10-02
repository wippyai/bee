-- MIT. Versioned values that can cross a session process code upgrade.
local contract = require("contract")
local decode = require("decode")
local commands = require("commands")
local bindings = require("bindings")
local M = {}

type Queued = {kind: "command" | "bindings", payload: unknown}
type Saved = {version: integer, workspace_id: string, desktop: unknown,
    status_revision: integer, bindings: unknown, queued: {Queued}}
type Restored = {desktop: decode.Desktop, status_revision: integer,
    bindings: bindings.Snapshot?, queued: {Queued}}

function M.pack(workspace_id: string, desktop: unknown, status_revision: integer,
    binding_snapshot: unknown, queued: {Queued}): Saved
    return {version = 1, workspace_id = workspace_id, desktop = desktop,
        status_revision = status_revision, bindings = binding_snapshot, queued = queued}
end

local function exact(value: {[unknown]: unknown}, names: {[string]: boolean}): boolean
    for key in pairs(value) do
        if type(key) ~= "string" or not names[key] then return false end
    end
    return true
end

function M.decode(value: unknown, workspace_id: string): Restored?
    if type(value) ~= "table" or value.version ~= 1 or value.workspace_id ~= workspace_id
        or not contract.workspace_id(workspace_id) or not exact(value,
            {version = true, workspace_id = true, desktop = true, status_revision = true,
                bindings = true, queued = true}) then return nil end
    local desktop = decode.desktop(value.desktop)
    if not desktop then return nil end
    for _, window in ipairs(desktop.scene.windows) do
        if window.workspace_id ~= workspace_id then return nil end
    end
    local revision = value.status_revision
    if type(revision) ~= "number" or revision < 0 or revision > 9007199254740990
        or revision ~= math.floor(revision) then return nil end
    local binding_snapshot: bindings.Snapshot? = nil
    if value.bindings ~= nil then
        binding_snapshot = bindings.decode(value.bindings)
        if not binding_snapshot or binding_snapshot.workspace_id ~= workspace_id then return nil end
    end
    if type(value.queued) ~= "table" then return nil end
    local count = 0
    for key in pairs(value.queued) do
        if type(key) ~= "number" or key ~= math.floor(key) or key < 1 or key > 128 then return nil end
        count = count + 1
    end
    local queued: {Queued} = {}
    for index = 1, count do
        local item = value.queued[index]
        if type(item) ~= "table" or not exact(item, {kind = true, payload = true}) then return nil end
        if item.kind == "command" then
            if not commands.decode(item.payload) then return nil end
        elseif item.kind == "bindings" then
            local snapshot = bindings.decode(item.payload)
            if not snapshot or snapshot.workspace_id ~= workspace_id then return nil end
        else return nil end
        queued[#queued + 1] = {kind = item.kind, payload = item.payload}
    end
    return {desktop = desktop, status_revision = math.floor(revision),
        bindings = binding_snapshot, queued = queued}
end

return M
