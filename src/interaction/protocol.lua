-- MIT. Bounded host/client interaction envelopes carry no authority.
local contract = require("contract")
local interaction = require("interaction")
type Target = {id: string, instance_id: string}
type Selection = {workspace_id: string, connection_id: string, revision: integer, targets: {Target}}
type Snapshot = {version: integer, workspace_id: string, connection_id: string,
    selection_revision: integer, revision: integer, items: {interaction.Wire}}
local M = {}
local function revision(value: unknown): integer?
    if type(value) ~= "number" or value < 0 or value > 9007199254740990 or value ~= math.floor(value) then return nil end
    return math.floor(value)
end
function M.selection(value: unknown): Selection?
    if type(value) ~= "table" or value.version ~= 1 or type(value.targets) ~= "table" then return nil end
    local workspace_id, connection_id = contract.workspace_id(value.workspace_id), contract.text(value.connection_id, 80)
    local sequence = revision(value.revision)
    if not workspace_id or not connection_id or connection_id == "" or not sequence then return nil end
    local count = 0
    for key in pairs(value.targets) do
        if type(key) ~= "number" or key ~= math.floor(key) or key < 1 or key > 16 then return nil end
        count = count + 1
    end
    local targets: {Target} = {}
    local seen: {[string]: boolean} = {}
    for index = 1, count do
        local raw: unknown = value.targets[index]
        if type(raw) ~= "table" then return nil end
        local id, instance_id = contract.text(raw.id, 80), contract.text(raw.instance_id, 80)
        if not id or id == "" or not instance_id or instance_id == "" or seen[id] then return nil end
        seen[id] = true
        targets[#targets + 1] = {id = id, instance_id = instance_id}
    end
    return {workspace_id = workspace_id, connection_id = connection_id, revision = sequence, targets = targets}
end
function M.snapshot(value: unknown): Snapshot?
    if type(value) ~= "table" or value.version ~= 1 then return nil end
    local workspace_id, connection_id = contract.workspace_id(value.workspace_id), contract.text(value.connection_id, 80)
    local selected, sequence = revision(value.selection_revision), revision(value.revision)
    local specs = interaction.snapshot(value)
    if not workspace_id or not connection_id or connection_id == "" or not selected or not sequence or not specs then return nil end
    local items: {interaction.Wire} = {}
    for _, spec in ipairs(specs) do items[#items + 1] = interaction.wire(spec) end
    return {version = 1, workspace_id = workspace_id, connection_id = connection_id,
        selection_revision = selected, revision = sequence, items = items}
end
return M
