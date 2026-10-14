-- MIT. The tools a workspace's applications offer agents. An application
-- offers a tool only while it is admitted in the workspace and holds a live
-- grant for agent.tools naming that tool function; the function itself must
-- still decode as an application tool. Discovery reads registry metadata and
-- grant records, never namespaces. Two applications offering one alias offer
-- neither, and the collision is reported.
local registry = require("registry")
local bounds = require("bounds")
local agent_tool = require("agent_tool")
local application = require("application")
local capability_access = require("capability_access")

local M = {}
M.MAX_TOOLS = 64

type Object = {[string]: unknown}
type Tool = {alias: string, ref: string, definition_id: string, description: string,
    input_schema: Object, output_schema: Object?, annotations: {[string]: boolean}}
type Diagnostic = {code: string, tool: string, message: string}
type Discovery = {tools: {Tool}, diagnostics: {Diagnostic}}

-- discover lists the tools the applications admitted in workspace_id offer.
function M.discover(workspace_id: string): (Discovery?, string?)
    local definitions, definitions_error = application.definitions(workspace_id)
    if not definitions then return nil, definitions_error end
    local offered: {Tool} = {}
    local diagnostics: {Diagnostic} = {}
    for _, definition_id in ipairs(definitions) do
        local record, refusal = capability_access.record(workspace_id, definition_id)
        if refusal then
            local fault = refusal.error
            diagnostics[#diagnostics + 1] = {code = "GRANT_UNREADABLE", tool = definition_id,
                message = fault and fault.message or "the application's grants cannot be read"}
        elseif record then
            for _, raw_grant in ipairs(record.capabilities) do
                local grant = bounds.object(raw_grant)
                local scope = grant and bounds.object(grant.scope) or nil
                local refs = scope and grant and grant.capability == "agent.tools" and bounds.ids(scope.tools, true) or nil
                for _, ref in ipairs(refs or {}) do
                    local entry = registry.get(ref)
                    local tool, tool_error = nil, "agent tool " .. ref .. " is not installed"
                    if entry then tool, tool_error = agent_tool.application(ref, entry) end
                    if tool then
                        offered[#offered + 1] = {alias = tool.alias, ref = ref, definition_id = definition_id,
                            description = tool.description, input_schema = tool.input_schema,
                            output_schema = tool.output_schema, annotations = tool.annotations}
                    else
                        diagnostics[#diagnostics + 1] = {code = "TOOL_INVALID", tool = ref, message = tostring(tool_error)}
                    end
                end
            end
        end
    end
    local holders: {[string]: {string}} = {}
    for _, tool in ipairs(offered) do
        local refs = holders[tool.alias] or {}
        refs[#refs + 1] = tool.ref
        holders[tool.alias] = refs
    end
    local tools: {Tool} = {}
    for _, tool in ipairs(offered) do
        local refs = holders[tool.alias]
        if #refs == 1 then
            tools[#tools + 1] = tool
        elseif refs[1] == tool.ref then
            table.sort(refs)
            diagnostics[#diagnostics + 1] = {code = "ALIAS_COLLISION", tool = tool.alias,
                message = "applications offer " .. tool.alias .. " from " .. table.concat(refs, ", ") .. "; none of them is offered"}
        end
    end
    table.sort(tools, function(left: Tool, right: Tool): boolean return left.alias < right.alias end)
    if #tools > M.MAX_TOOLS then
        diagnostics[#diagnostics + 1] = {code = "TOO_MANY_TOOLS", tool = "",
            message = "applications offer " .. tostring(#tools) .. " tools; the first " .. tostring(M.MAX_TOOLS) .. " by name are offered"}
        local kept: {Tool} = {}
        for index = 1, M.MAX_TOOLS do kept[index] = tools[index] end
        tools = kept
    end
    return {tools = tools, diagnostics = diagnostics}, nil
end

-- find is the tool alias names in workspace_id's current discovery.
function M.find(workspace_id: string, alias: string): (Tool?, string?)
    local found, discovery_error = M.discover(workspace_id)
    if not found then return nil, discovery_error end
    for _, tool in ipairs(found.tools) do
        if tool.alias == alias then return tool, nil end
    end
    return nil, nil
end

return M
