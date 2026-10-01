-- SPDX-License-Identifier: MIT
local bounds = require("bounds")
local M = {}
type Scope = {workspace_id: string?, name: string?, access: "read" | "write"?, subpath: string?, path_prefix: string?, scope: string?,
    methods: {string}?, definitions: {string}?, operations: {string}?, traits: {string}?, audiences: {string}?}
type Mcp = {tool: string, scope: Scope}
type File = {workspace_id: string, resource: string, subpath: string, access: "read" | "write"}
type Workspace = {workspace_id: string, operations: {string}}
type Bee = {mcp: {Mcp}?, files: {File}?, workspaces: {Workspace}?, credential_refs: {string}?, approval_leases: {string}?, permission_answers: "provider" | "ask" | "deny"?}
local function strings(value: unknown, label: string): ({string}?, string?)
    local rows, err = bounds.array(value, 64)
    if not rows then return nil, err end
    local result: {string} = {}
    local seen: {[string]: boolean} = {}
    for _, raw in ipairs(rows) do
        local text = bounds.line(raw, 512)
        if not text or text == "" or seen[text] then return nil, label .. " must contain unique bounded strings" end
        seen[text] = true; result[#result + 1] = text
    end
    return result, nil
end
local function scope(value: unknown): (Scope?, string?)
    local raw = bounds.object(value)
    if not raw or bounds.fields(raw, {"workspace_id", "name", "access", "subpath", "path_prefix", "scope", "methods", "definitions", "operations", "traits", "audiences"}) then return nil, "invalid MCP scope" end
    local result: Scope = {}
    for _, field in ipairs({"workspace_id", "name", "scope", "path_prefix"}) do
        if raw[field] ~= nil then
            local text = bounds.line(raw[field], 512)
            if not text or text == "" then return nil, "scope." .. field .. " must be bounded text" end
            if field == "workspace_id" then result.workspace_id = text
            elseif field == "name" then result.name = text
            elseif field == "scope" then result.scope = text else result.path_prefix = text end
        end
    end
    if raw.subpath ~= nil then
        local path, err = bounds.subpath(raw.subpath)
        if not path then return nil, err end
        result.subpath = path
    end
    if raw.access == "read" then result.access = "read"
    elseif raw.access == "write" then result.access = "write"
    elseif raw.access ~= nil then return nil, "scope.access must be read or write" end
    for _, field in ipairs({"methods", "definitions", "operations", "traits", "audiences"}) do
        if raw[field] ~= nil then
            local list, err = strings(raw[field], "scope." .. field)
            if not list then return nil, err end
            if field == "methods" then result.methods = list
            elseif field == "definitions" then result.definitions = list
            elseif field == "operations" then result.operations = list
            elseif field == "traits" then result.traits = list else result.audiences = list end
        end
    end
    return result, nil
end
function M.decode(value: unknown): (Bee?, string?)
    local raw = bounds.object(value)
    if not raw or bounds.fields(raw, {"mcp", "files", "workspaces", "credential_refs", "approval_leases", "permission_answers"}) then return nil, "bee has unknown fields" end
    local result: Bee = {}
    if raw.permission_answers == "provider" then result.permission_answers = "provider"
    elseif raw.permission_answers == "ask" then result.permission_answers = "ask"
    elseif raw.permission_answers == "deny" then result.permission_answers = "deny"
    elseif raw.permission_answers ~= nil then return nil, "bee.permission_answers must be provider, ask or deny" end
    for _, field in ipairs({"credential_refs", "approval_leases"}) do
        if raw[field] ~= nil then
            local list, err = bounds.ids(raw[field], true)
            if not list then return nil, err end
            if field == "credential_refs" then result.credential_refs = list else result.approval_leases = list end
        end
    end
    if raw.mcp ~= nil then
        local list, err = bounds.array(raw.mcp, 64)
        if not list then return nil, err end
        local items: {Mcp} = {}
        local seen: {[string]: boolean} = {}
        for _, value in ipairs(list) do
            local item = bounds.object(value)
            local tool = item and bounds.id(item.tool)
            if not item or not tool or bounds.fields(item, {"tool", "scope"}) then return nil, "bee.mcp must name tool and scope" end
            if seen[tool] then return nil, "Duplicate MCP tool " .. tool end
            seen[tool] = true
            local selected, scope_error = scope(item.scope)
            if not selected then return nil, scope_error end
            items[#items + 1] = {tool = tool, scope = selected}
        end
        result.mcp = items
    end
    if raw.files ~= nil then
        local list, err = bounds.array(raw.files, 64)
        if not list then return nil, err end
        local items: {File} = {}
        for _, value in ipairs(list) do
            local item = bounds.object(value)
            local workspace = item and bounds.id(item.workspace_id)
            local resource = item and bounds.id(item.resource)
            local path = item and bounds.subpath(item.subpath)
            if not item or not workspace or not resource or not path or bounds.fields(item, {"workspace_id", "resource", "subpath", "access"}) then return nil, "invalid bee.files grant" end
            local access: "read" | "write"
            if item.access == "read" then access = "read" elseif item.access == "write" then access = "write" else return nil, "file access must be read or write" end
            items[#items + 1] = {workspace_id = workspace, resource = resource, subpath = path, access = access}
        end
        result.files = items
    end
    if raw.workspaces ~= nil then
        local list, err = bounds.array(raw.workspaces, 64)
        if not list then return nil, err end
        local items: {Workspace} = {}
        for _, value in ipairs(list) do
            local item = bounds.object(value)
            local workspace = item and bounds.id(item.workspace_id)
            local operations = item and strings(item.operations, "workspace.operations")
            if not item or not workspace or not operations or bounds.fields(item, {"workspace_id", "operations"}) then return nil, "invalid bee.workspaces grant" end
            items[#items + 1] = {workspace_id = workspace, operations = operations}
        end
        result.workspaces = items
    end
    return result, nil
end
return M
