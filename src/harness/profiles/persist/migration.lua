-- SPDX-License-Identifier: MIT
local bounds = require("bounds")
local protocol = require("protocol")
local driver_profile = require("driver_profile")
local M = {}
M.ID = "bee.agent-profile@3"
M.DIAGNOSTIC = "bee.agent-profile-migration@1"
type Object = {[string]: unknown}
type Binding = (string) -> string?
type NativeHome = "private" | "machine"
type Home = (string) -> NativeHome?
M.BUDGETS_RETIRED = "Budgets no longer apply: every session runs in an interactive window. Saving this profile drops them."
M.SUPERVISION_RETIRED = "Stall supervision no longer applies: every session runs in an interactive window. Saving this profile drops it."
-- A v2 profile in the current schema, with the reasons a configured budget or
-- supervision gives the owner.
local function retire(source: Object): (Object, {string})
    local draft = bounds.object(protocol.upgrade(source)) or {}
    local reasons: {string} = {}
    if source.budgets ~= nil then reasons[#reasons + 1] = M.BUDGETS_RETIRED end
    local supervision = bounds.object(source.supervision)
    if source.supervision ~= nil and (not supervision or supervision.quiet_period_ms ~= nil or (supervision.on_stall ~= nil and supervision.on_stall ~= "report")) then
        reasons[#reasons + 1] = M.SUPERVISION_RETIRED
    end
    return draft, reasons
end
function M.convert(value: unknown, binding: Binding, validate: ((protocol.Profile) -> string?)?, home: Home?): Object
    local source = bounds.object(value)
    local reasons: {string} = {}
    local draft: Object = {schema_revision = protocol.SCHEMA, provider = {}, bee = {}}
    local function diagnostic(reason: string): Object
        reasons[#reasons + 1] = reason
        return {schema_revision = M.DIAGNOSTIC, source = value, draft = draft, reasons = reasons}
    end
    if not source then return diagnostic("Stored profile is not an object") end
    if source.schema_revision == M.DIAGNOSTIC then
        local prior = bounds.object(source.draft)
        if not prior or prior.schema_revision ~= protocol.PRIOR then return source end
        local upgraded, retired = retire(prior)
        local kept: {string} = {}
        for _, reason in ipairs(bounds.array(source.reasons, 64) or {}) do
            if type(reason) == "string" then kept[#kept + 1] = reason end
        end
        for _, reason in ipairs(retired) do kept[#kept + 1] = reason end
        return {schema_revision = M.DIAGNOSTIC, source = source.source, draft = upgraded, reasons = kept}
    end
    if source.schema_revision == protocol.SCHEMA or source.schema_revision == protocol.PRIOR then
        local current: Object = source
        if source.schema_revision == protocol.PRIOR then
            local upgraded, retired = retire(source)
            current = upgraded
            for _, reason in ipairs(retired) do reasons[#reasons + 1] = reason end
        end
        draft = current
        local profile, err = protocol.profile(current)
        if not profile then return diagnostic(err or "Invalid profile") end
        local validation_error = validate and validate(profile) or nil
        if validation_error then return diagnostic(validation_error) end
        if #reasons > 0 then return {schema_revision = M.DIAGNOSTIC, source = value, draft = draft, reasons = reasons} end
        local stored, storage_error = protocol.storage(profile)
        if not stored then return diagnostic(storage_error or "Driver option schema unavailable") end
        return stored
    end
    local extra = bounds.fields(source, {"schema_revision", "title", "definition_ref", "options", "config_profile", "mcp_tools", "instructions", "placement_profile_ref", "workdir", "thread", "agent_ref", "owner_component_revision", "spec_digest", "bee", "budget", "progress_quiet_ms", "presentation"})
    if extra then reasons[#reasons + 1] = extra end
    if source.schema_revision ~= nil and source.schema_revision ~= "bee.agent-profile@1" then reasons[#reasons + 1] = "Unknown source schema" end
    draft.name = source.title
    draft.definition_ref = source.definition_ref
    local definition = bounds.id(source.definition_ref)
    draft.driver_binding_ref = definition and binding(definition) or nil
    if not draft.driver_binding_ref then reasons[#reasons + 1] = "Definition has no admitted driver binding" end
    for _, key in ipairs({"workdir", "thread", "agent_ref", "owner_component_revision", "spec_digest"}) do draft[key] = source[key] end
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
        if source.placement_profile_ref == "bee.placement.profiles:native" then
            local prior_home = definition and home and home(definition) or nil
            if not prior_home then reasons[#reasons + 1] = "Former native home cannot be established" end
            draft.placement = {kind = "native", home = prior_home}
        else draft.placement = {kind = "docker", profile_ref = source.placement_profile_ref} end
    end
    if source.budget ~= nil then reasons[#reasons + 1] = M.BUDGETS_RETIRED end
    if source.progress_quiet_ms ~= nil then reasons[#reasons + 1] = M.SUPERVISION_RETIRED end
    local checked, err = protocol.profile(draft)
    if not checked then reasons[#reasons + 1] = err or "Profile cannot be mapped" end
    if checked and validate then
        local invalid = validate(checked)
        if invalid then reasons[#reasons + 1] = invalid end
    end
    if #reasons > 0 then return {schema_revision = M.DIAGNOSTIC, source = value, draft = draft, reasons = reasons} end
    if not checked then return diagnostic("Profile cannot be mapped") end
    local stored, storage_error = protocol.storage(checked)
    if not stored then return diagnostic(storage_error or "Driver option schema unavailable") end
    return stored
end
function M.registered(value: unknown, pinned: registry.Snapshot, validate: ((protocol.Profile) -> string?)?): Object
    return M.convert(value, function(ref: string): string?
            local entry = pinned:get(ref)
            local data = entry and bounds.object(entry.data)
            return data and bounds.id(data.binding_ref) or nil
        end, validate,
        function(ref: string): NativeHome?
            local entry = pinned:get(ref)
            local definition = entry and bounds.object(entry.data)
            local binding_ref = definition and bounds.id(definition.binding_ref)
            local binding = binding_ref and pinned:get(binding_ref)
            local meta = binding and bounds.object(binding.meta)
            local profiles_ref = meta and bounds.id(meta.profiles_ref)
            local declaration = profiles_ref and pinned:get(profiles_ref)
            local data = declaration and bounds.object(declaration.data)
            local driver = data and driver_profile.decode(data.driver)
            local profile_id = definition and bounds.id(definition.profile_id)
            local selected = driver and profile_id and driver_profile.find(driver, profile_id)
            if not selected then return nil end
            return selected.isolation_env.private_home and "private" or "machine"
        end)
end
return M
