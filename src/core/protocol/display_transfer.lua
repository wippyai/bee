-- MIT. Display-transfer projections carry choices, never source authority.
local contract = require("contract")

type Target = string
type Item = {tab_id: string, instance_id: string, assignment_revision: integer, targets: {Target}}
type Snapshot = {version: integer, revision: integer, items: {Item}}
type Action = {version: integer, op: "transfer", request_id: string, id: string, instance_id: string,
    target_display_id: string, expected_revision: integer}
type Result = {version: integer, request_id: string, id: string, instance_id: string,
    target_display_id: string, error_code: string, error: string}

local M = {}
local MAX_SAFE_INTEGER = 9007199254740990

local function text(value: unknown, maximum: integer): string?
    local checked = contract.text(value, maximum)
    if not checked or checked == "" then return nil end
    return checked
end
local function revision(value: unknown, minimum: integer): integer?
    if type(value) ~= "number" or value ~= math.floor(value) or value < minimum or value > MAX_SAFE_INTEGER then return nil end
    return math.floor(value)
end
local function array(value: unknown, maximum: integer): integer?
    if type(value) ~= "table" then return nil end
    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key ~= math.floor(key) or key < 1 or key > maximum then return nil end
        count = count + 1
    end
    return count
end
local function exact(value: table, allowed: {[string]: boolean}): boolean
    for key in pairs(value) do if type(key) ~= "string" or not allowed[key] then return false end end
    return true
end
local function target(value: unknown): string?
    return contract.workspace_id(value)
end

local function item(value: unknown): Item?
    if type(value) ~= "table" or not exact(value, {tab_id = true, instance_id = true, assignment_revision = true, targets = true}) then return nil end
    local tab_id, instance_id = text(value.tab_id, 80), text(value.instance_id, 80)
    local assignment_revision = revision(value.assignment_revision, 1)
    local count = array(value.targets, 7)
    if not tab_id or not instance_id or not assignment_revision or not count then return nil end
    local targets: {Target} = {}
    local known: {[string]: boolean} = {}
    for index = 1, count do
        local display_id = target(value.targets[index])
        if not display_id or known[display_id] then return nil end
        known[display_id] = true
        targets[#targets + 1] = display_id
    end
    return {tab_id = tab_id, instance_id = instance_id, assignment_revision = assignment_revision, targets = targets}
end

function M.snapshot(value: unknown): Snapshot?
    if type(value) ~= "table" or value.version ~= 1 or not exact(value, {version = true, revision = true, items = true}) then return nil end
    local current, count = revision(value.revision, 0), array(value.items, 16)
    if not current or not count then return nil end
    local items: {Item} = {}
    local known: {[string]: boolean} = {}
    for index = 1, count do
        local checked = item(value.items[index])
        local key = checked and checked.tab_id or ""
        if not checked or known[key] then return nil end
        known[key] = true
        items[#items + 1] = checked
    end
    return {version = 1, revision = current, items = items}
end

function M.action(value: unknown): Action?
    if type(value) ~= "table" or value.version ~= 1 or value.op ~= "transfer"
        or not exact(value, {version = true, op = true, request_id = true, id = true, instance_id = true,
            target_display_id = true, expected_revision = true}) then return nil end
    local request_id, id, instance_id = text(value.request_id, 80), text(value.id, 80), text(value.instance_id, 80)
    local target_display_id = target(value.target_display_id)
    local expected_revision = revision(value.expected_revision, 1)
    if not request_id or not id or not instance_id or not target_display_id or not expected_revision then return nil end
    return {version = 1, op = "transfer", request_id = request_id, id = id, instance_id = instance_id,
        target_display_id = target_display_id, expected_revision = expected_revision}
end

function M.result(value: unknown): Result?
    if type(value) ~= "table" or value.version ~= 1
        or not exact(value, {version = true, request_id = true, id = true, instance_id = true,
            target_display_id = true, error_code = true, error = true}) then return nil end
    local request_id, id, instance_id = text(value.request_id, 80), text(value.id, 80), text(value.instance_id, 80)
    local target_display_id = target(value.target_display_id)
    local error_code = contract.text(value.error_code, 80)
    local error_text = contract.text(value.error, 4096)
    if not request_id or not id or not instance_id or not target_display_id or not error_code
        or not error_text then return nil end
    if error_code == "" and error_text ~= "" then return nil end
    return {version = 1, request_id = request_id, id = id, instance_id = instance_id,
        target_display_id = target_display_id, error_code = error_code, error = error_text}
end

return M
