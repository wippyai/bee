-- SPDX-License-Identifier: MIT
local bounds = require("bounds")
local access = require("profile_access")
local surface = require("surface")
local M = {}
type Object = {[string]: unknown}
local function inside(parent: string, child: unknown): boolean
    return type(child) == "string" and (parent == "" or child == parent or child:sub(1, #parent + 1) == parent .. "/")
end
function M.check(profile: access.Bee?, tool: string, operation: string, workspace: string?, arguments: Object): string?
    if not profile then return nil end
    local spec = bounds.object(arguments.spec) or arguments
    local supplied = spec.workspace_id or spec.workspace or arguments.workspace_id
    local requested = supplied or workspace
    local destinations: {unknown} = {}
    local function destination(raw: unknown)
        if type(raw) ~= "string" or #raw > 256 then return end
        local prefix, _node, home, _id = raw:match("^([a-z]+):([^:]+):([^:]+):([^:]+)$")
        if prefix == "bs" or prefix == "bw" or prefix == "bo" then destinations[#destinations + 1] = home end
    end
    for _, name in ipairs({"session", "work", "operation"}) do destination(arguments[name]) end
    for _, item in ipairs(bounds.array(arguments.works, 64) or {}) do destination(item) end
    if supplied ~= nil or #destinations == 0 then destinations[#destinations + 1] = requested
    else requested = destinations[1] end
    for _, destination in ipairs(destinations) do
        if destination ~= workspace then
            local granted = false
            for _, grant in ipairs(profile.workspaces or {}) do
                if grant.workspace_id == destination and bounds.member(operation, grant.operations) then granted = true end
            end
            if not granted then return "profile does not grant this workspace operation" end
        end
    end
    local selected: access.Scope? = nil
    if profile.mcp ~= nil then
        for _, item in ipairs(profile.mcp) do if item.tool == tool then selected = item.scope end end
        if not selected then return "tool is outside the saved MCP selection" end
    end
    if selected then
        for key, ceiling in pairs(selected) do
            local actual: unknown = arguments[key]
            if key == "workspace_id" then
                for _, destination in ipairs(destinations) do if destination ~= ceiling then return "tool call exceeds profile workspace_id" end end
                actual = requested
            end
            if key == "subpath" or key == "path_prefix" then
                if type(ceiling) ~= "string" or not inside(ceiling, arguments.subpath or arguments.path) then return "tool call exceeds profile " .. key end
            elseif type(ceiling) == "table" then
                local choices = bounds.ids(ceiling, true)
                local members = {methods = "method", definitions = "definition", operations = "operation", traits = "trait", audiences = "audience"}
                local field = members[key]
                local member = key == "methods" and operation or (field and (spec[field] or arguments[field]))
                if not choices or not bounds.member(member, choices) then return "tool call exceeds profile " .. key end
            elseif ceiling == "write" and key == "access" then
                if actual ~= "read" and actual ~= "write" then return "tool call has no bounded file access" end
            elseif actual ~= ceiling then return "tool call exceeds profile " .. key end
        end
    end
    if arguments.resource ~= nil and profile.files ~= nil then
        local granted = false
        for _, file in ipairs(profile.files or {}) do
            if file.workspace_id == requested and file.resource == arguments.resource
                and inside(file.subpath, arguments.subpath)
                and (arguments.access == "read" or (arguments.access == "write" and file.access == "write")) then granted = true end
        end
        if not granted then return "tool call exceeds profile file grants" end
    end
    return nil
end
type Call = (string, unknown) -> (unknown, unknown)
function M.revalidate(grants: {surface.Grant}?, attempt: string, call: Call): string?
    for _, grant in ipairs(grants or {}) do
        local raw, err = call("bee.resources.binding:resolve", {grant_id = grant.grant_ref, subject = grant.subject, audience = grant.subject, attempt_id = attempt})
        local reply = not err and bounds.object(raw)
        local value = reply and reply.ok == true and bounds.object(reply.value)
        if not value or value.grant_id ~= grant.grant_ref or value.workspace_id ~= grant.workspace_id or value.name ~= grant.name
            or value.subpath ~= grant.subpath or (grant.access == "write" and value.access ~= "write") then return "profile resource grant is revoked, expired or changed: " .. grant.name end
    end
    return nil
end

return M
