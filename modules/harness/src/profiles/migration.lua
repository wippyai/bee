-- SPDX-License-Identifier: MIT
local bounds = require("bounds")
local protocol = require("protocol")
local M = {}
M.ID = "bee.agent-profile@2"
M.DIAGNOSTIC = "bee.agent-profile-migration@1"
type Object = {[string]: unknown}
type Binding = (string) -> string?
type NativeHome = "private" | "machine"
type Home = (string, string?) -> NativeHome?
function M.convert(value: unknown, binding: Binding, validate: ((protocol.Profile) -> string?)?, home: Home?): Object
    local source = bounds.object(value)
    local reasons: {string} = {}
    local draft: Object = {schema_revision = protocol.SCHEMA, provider = {}, bee = {}}
    local function diagnostic(reason: string): Object
        reasons[#reasons + 1] = reason
        return {schema_revision = M.DIAGNOSTIC, source = value, draft = draft, reasons = reasons}
    end
    if not source then return diagnostic("Stored profile is not an object") end
    if source.schema_revision == M.DIAGNOSTIC then return source end
    if source.schema_revision == protocol.SCHEMA then
        local profile, err = protocol.profile(source)
        if not profile then return diagnostic(err or "Invalid v2 profile") end
        draft = source
        local validation_error = validate and validate(profile) or nil
        if validation_error then return diagnostic(validation_error) end
        return source
    end
    local extra = bounds.fields(source, {"schema_revision", "title", "definition_ref", "options", "config_profile", "mcp_tools", "instructions", "placement_profile_ref", "workdir", "thread", "agent_ref", "owner_component_revision", "spec_digest", "bee", "budget", "progress_quiet_ms", "presentation"})
    if extra then reasons[#reasons + 1] = extra end
    if source.schema_revision ~= nil and source.schema_revision ~= "bee.agent-profile@1" then reasons[#reasons + 1] = "Unknown source schema" end
    draft.name = source.title
    draft.definition_ref = source.definition_ref
    local definition = bounds.id(source.definition_ref)
    draft.driver_binding_ref = definition and binding(definition) or nil
    if not draft.driver_binding_ref then reasons[#reasons + 1] = "Definition has no admitted driver binding" end
    for _, key in ipairs({"workdir", "thread", "agent_ref", "owner_component_revision", "spec_digest", "presentation"}) do draft[key] = source[key] end
    local provider: Object = {}
    local options: Object = {}
    local raw_options = bounds.object(source.options or {})
    if not raw_options then reasons[#reasons + 1] = "Options are not an object" end
    for key, item in pairs(raw_options or {}) do
        if bounds.member(key, {"model", "effort", "permission_mode", "tool_allow", "tool_deny", "env"}) then provider[key] = item
        else options[key] = item end
    end
    if source.config_profile ~= nil then
        if options.config_profile ~= nil and options.config_profile ~= source.config_profile then reasons[#reasons + 1] = "Conflicting config_profile values"
        else options.config_profile = source.config_profile end
    end
    if next(options) then provider.options = options end
    if source.instructions ~= nil then provider.system_prompt_append = source.instructions end
    draft.provider = provider
    local bee: Object = {}
    local source_bee = bounds.object(source.bee or {})
    if not source_bee then reasons[#reasons + 1] = "Bee settings are not an object" end
    for key, item in pairs(source_bee or {}) do bee[key] = item end
    local tools, tools_error = bounds.ids(source.mcp_tools or {}, true)
    if not tools then reasons[#reasons + 1] = tools_error or "Invalid MCP tools" end
    local mcp: {Object} = {}
    for _, tool in ipairs(tools or {}) do mcp[#mcp + 1] = {tool = tool, scope = {}} end
    if bee.mcp ~= nil then reasons[#reasons + 1] = "Legacy Bee settings contain an unmapped MCP selection" end
    bee.mcp = mcp
    draft.bee = bee
    if source.placement_profile_ref ~= nil then
        if source.placement_profile_ref == "bee.placement:native" then
            local prior_home = definition and home and home(definition, bounds.id(source.presentation)) or nil
            if not prior_home then reasons[#reasons + 1] = "Former native home cannot be established" end
            draft.placement = {kind = "native", home = prior_home}
        else draft.placement = {kind = "docker", profile_ref = source.placement_profile_ref} end
    end
    if source.budget ~= nil then
        local budget = bounds.object(source.budget)
        if budget then
            local renamed: Object = {}
            for key, item in pairs(budget) do
                local field = key == "max_turns" and "provider_steps" or key == "max_tokens" and "tokens" or key
                if renamed[field] ~= nil and renamed[field] ~= item then reasons[#reasons + 1] = "Conflicting budget alias " .. field end
                renamed[field] = item
            end
            draft.budgets = {turn = renamed}
        else reasons[#reasons + 1] = "Invalid budget" end
    end
    if source.progress_quiet_ms ~= nil then draft.supervision = {quiet_period_ms = source.progress_quiet_ms, on_stall = "report"} end
    local checked, err = protocol.profile(draft)
    if not checked then reasons[#reasons + 1] = err or "Profile cannot be mapped" end
    if checked and validate then
        local invalid = validate(checked)
        if invalid then reasons[#reasons + 1] = invalid end
    end
    if #reasons > 0 then return {schema_revision = M.DIAGNOSTIC, source = value, draft = draft, reasons = reasons} end
    return draft
end
return M
