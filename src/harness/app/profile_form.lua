-- MIT. Load and save Agent form values through the existing profile authority.
-- Saving preferences never starts a harness or creates a thread.
local funcs = require("funcs")
local uuid = require("uuid")
local bounds = require("bounds")
local catalog = require("catalog")
local definition = require("definition")
local protocol = require("protocol")
local editor = require("editor")
local descriptors = require("descriptors")
local preferences = require("preferences")
local validation = require("validation")
local json = require("json")
local canonical = require("canonical")
local readiness = require("readiness")
local mcp_catalog = require("mcp")
local M = {}
-- What a profile form opens: a definition for a new profile, or a saved
-- profile, whose own definition applies.
type Subject = {definition_ref: string?, title: string, saved_profile_id: string?, saved_profile_revision: integer?}
type TraitRow = {id: string, title: string, gated: boolean}
type Form = {traits: {TraitRow}?,permission_transport: boolean?, driver_name: string?, placement_names: {[string]: string}?, leases: {string}?, readiness: string?, credentials: {string}?,conflict: boolean?, workspace_id: string, profile_id: string, revision: integer, draft: editor.Draft,
    credential_keys: {[string]: boolean}?, definition_digest: string?, credential_definition: definition.Definition?, default_private_home: boolean?,
    save_key: string, remove_key: string, pending: string?, submitted: protocol.Profile?,
    fields: {[string]: {label: string, section: string, order: integer, group: string?, default: unknown, default_source: string?, value_schema: {[string]: unknown}?}}?, unsupported: {string}?,
    migration_diagnostic: {[string]: unknown}?, repair_json: string?}

function M.review(form: Form): (string?, string?)
    local profile, invalid = editor.result(form.draft)
    if not profile then return nil, invalid end
    local pinned, pin_error = catalog.pin()
    if not pinned then return nil, pin_error end
    local binding = catalog.entry(pinned, profile.driver_binding_ref)
    local meta = binding and bounds.object(binding.meta)
    local ref = meta and bounds.id(meta.descriptor_ref)
    if not ref then return nil, "Driver descriptor is missing" end
    local descriptor, schema_error = descriptors.load_from(pinned, ref)
    if not descriptor then return nil, schema_error end
    local selected, selection_error = protocol.preferences(profile)
    if not selected then return nil, selection_error end
    local review, review_error = preferences.review(descriptor, selected.options, editor.placement_ref(profile))
    if not review then return nil, review_error end
    local entry = catalog.entry(pinned, profile.definition_ref)
    if not entry then return nil, "Agent definition is missing" end
    local declared, definition_error = definition.decode(profile.definition_ref, entry)
    if not declared then return nil, definition_error end
    local credentials = profile.bee.credential_refs or definition.credential_names(declared, "docker", true)
    review = review .. "\nSelected credentials: " .. (#credentials == 0 and "none" or table.concat(credentials, ", "))
    if profile.workdir then review = review .. "\nLaunch folder: " .. profile.workdir.root_ref .. "/" .. profile.workdir.path end
    return review, nil
end

function M.credential_names(form: Form): {string}
    if not form.credential_definition then return form.credentials or {} end
    local placement = form.draft.placement
    local private = placement and placement.kind == "native" and placement.home == "private" or placement == nil and form.default_private_home == true
    return definition.credential_names(form.credential_definition, placement and placement.kind or "native", private)
end

local function call(request: unknown): ({[string]: unknown}?, string?)
    local raw, err = funcs.call("bee.harness.binding:call", request)
    if err then return nil, tostring(err) end
    local reply = bounds.object(raw)
    if not reply then return nil, "Profile store returned an invalid reply" end
    if reply.ok ~= true then
        local code = bounds.id(reply.code) or "UNAVAILABLE"
        return nil, code .. ": " .. (bounds.text(reply.message, 512) or "Profile operation refused")
    end
    local value = bounds.object(reply.value)
    if not value then return nil, "Profile store returned no value" end
    return value, nil
end

-- The saved profile at the selected revision, or the reason it cannot be used.
function M.refresh(form: Form): (Form?, string?)
    if form.pending or form.repair_json then return nil, "Finish the pending save or definition repair first" end
    local profile, err = editor.result(form.draft)
    if not profile then return nil, err end
    local refreshed, refresh_error = M.load(form.workspace_id, {definition_ref = profile.definition_ref, title = profile.name}, false, profile)
    if not refreshed then return nil, refresh_error end
    refreshed.profile_id, refreshed.revision = form.profile_id, form.revision
    refreshed.save_key, refreshed.remove_key = form.save_key, form.remove_key
    return refreshed, nil
end

function M.saved(workspace: string, id: string, revision: integer): (protocol.Profile?, string?, {[string]: unknown}?)
    local saved, read_error = call({operation = "get", workspace_id = workspace, profile_id = id})
    if not saved then return nil, read_error end
    if saved.workspace_id ~= workspace or saved.profile_id ~= id or saved.revision ~= revision or saved.tombstone ~= false then
        return nil, "Profile changed. Refresh and select it again."
    end
    local diagnostic = bounds.object(saved.migration_diagnostic)
    if diagnostic then return nil, nil, diagnostic end
    return protocol.profile(saved.profile)
end

function M.load(workspace: string, choice: Subject, duplicate: boolean, initial: protocol.Profile?): (Form?, string?)
    local id, revision = choice.saved_profile_id or "", choice.saved_profile_revision or 0
    local profile: protocol.Profile? = initial
    local diagnostic: {[string]: unknown}? = nil
    if choice.saved_profile_id then
        local value, value_error, repair = M.saved(workspace, id, revision)
        diagnostic = repair
        if not value and not repair then return nil, value_error end
        if value and choice.definition_ref and value.definition_ref ~= choice.definition_ref then return nil, "Profile definition changed" end
        profile = value
    end
    local migration_draft = diagnostic and bounds.object(diagnostic.draft)
    local definition_ref = profile and profile.definition_ref or choice.definition_ref or (migration_draft and bounds.id(migration_draft.definition_ref))
    local function repair_only(reason: string?): (Form?, string?)
        if not migration_draft and profile then
            migration_draft = profile
            diagnostic = {source = profile, reasons = {reason or "Agent definition is missing"}}
        end
        if not diagnostic or not migration_draft then return nil, reason or "Agent definition is missing" end
        local base: protocol.Profile = {schema_revision = protocol.SCHEMA, definition_ref = definition_ref or "migration:repair", driver_binding_ref = "migration:repair", name = bounds.line(migration_draft.name, 80) or "Migration repair", provider = {}, bee = {}}
        local draft, err = editor.new(base, {options = {}, mcp_tools = {}, instructions = false, placements = {}})
        if not draft then return nil, err end
        if duplicate then
            local fresh, fresh_error = uuid.v7()
            if not fresh then return nil, tostring(fresh_error) end
            id, revision = fresh, 0
        end
        local save_key, save_error = uuid.v7()
        local remove_key, remove_error = uuid.v7()
        if not save_key or not remove_key then return nil, tostring(save_error or remove_error) end
        return {workspace_id = workspace, profile_id = id, revision = revision, draft = draft, save_key = save_key, remove_key = remove_key,
            migration_diagnostic = diagnostic, repair_json = canonical.encode(migration_draft), fields = {}, unsupported = {}}, nil
    end
    if not definition_ref then return repair_only() end
    local pinned = catalog.pin()
    if not pinned then return repair_only("Agent definitions could not be read") end
    local entry = catalog.entry(pinned, definition_ref)
    if not entry then
        return repair_only("Agent definition is no longer available")
    end
    local decoded, decode_error = definition.decode(definition_ref, entry)
    if not decoded then return repair_only(decode_error) end
    if profile and profile.driver_binding_ref ~= decoded.binding_ref then return repair_only("Saved driver differs from the current definition") end
    local policy_entry = catalog.entry(pinned, decoded.policy_ref)
    local policy_data = policy_entry and bounds.object(policy_entry.data) or nil
    if not policy_data then return repair_only("Agent policy could not be read") end
    local tools, tools_error = bounds.ids(policy_data.gateway_tools or {}, true)
    if not tools then return repair_only(tools_error) end
    local mcp: {protocol.Mcp} = {}
    for _, tool in ipairs(tools) do mcp[#mcp + 1] = {tool = tool, scope = {}} end
    local base: protocol.Profile = {schema_revision = protocol.SCHEMA, name = choice.title,
        definition_ref = definition_ref, driver_binding_ref = decoded.binding_ref, provider = {}, bee = {mcp = mcp}}
    if profile then base = profile end
    if duplicate or id == "" then
        local fresh, fresh_error = uuid.v7()
        if not fresh then return nil, tostring(fresh_error) end
        id, revision = fresh, 0
    end
    -- A folder or thread choice is offered only where the definition and its
    -- launch policy both allow the override; admission checks it again.
    local admitted = bounds.ids(policy_data.allowed_overrides or {}, true) or {}
    local function allows(name: string): boolean
        return definition.allows(decoded, name) and bounds.member(name, admitted) ~= nil
    end
    local binding_entry = catalog.entry(pinned, decoded.binding_ref)
    local binding_meta = binding_entry and bounds.object(binding_entry.meta)
    local driver_name = binding_meta and bounds.id(binding_meta.driver_id)
    local descriptor_ref = binding_meta and bounds.id(binding_meta.descriptor_ref)
    if not descriptor_ref then return repair_only("Driver descriptor is missing") end
    local descriptor, descriptor_error = descriptors.load_from(pinned, descriptor_ref)
    if not descriptor then return repair_only(descriptor_error) end
    local probed = readiness.probe(decoded.binding_ref, decoded.profile_id, readiness.new_cache(), editor.placement_ref(base))
    local capabilities = probed.result and probed.result.capabilities or {}
    local compiled, compile_error = preferences.compile(descriptor, policy_data, policy_data.fixture ~= true and capabilities or nil, nil, nil, nil, nil, editor.placement_ref(base))
    if not compiled then return repair_only(compile_error) end
    local metadata: {[string]: {label: string, section: string, order: integer, group: string?, default: unknown, default_source: string?, value_schema: {[string]: unknown}?}} = {}
    local unsupported: {string} = {}
    local form_options: {[string]: unknown} = {}
    for name, row in pairs(compiled.fields) do
        local field = row.declaration
        if field.path then
            local label = bounds.line(field.label, 80) or name
            metadata[name] = {label = label, section = bounds.member(field.section, {"basic", "advanced"}) or "advanced", order = bounds.count(field.order) or 0,
                group = bounds.line(field.group, 80), default = row.default, default_source = row.default_source, value_schema = bounds.object(field.value_schema)}
            if row.locked_reason then unsupported[#unsupported + 1] = label .. ": " .. row.locked_reason
            elseif row.allowed and name ~= "system_prompt_append" then
                local spec = descriptors.runtime_spec(field)
                local restriction = row.allowed
                if restriction.kind == "enum" then form_options[name] = restriction.values
                elseif restriction.kind == "text" then form_options[name] = restriction
                elseif spec.type == "boolean" then form_options[name] = {false, true}
                elseif spec.type == "json" or spec.type == "ids" then form_options[name] = {kind = "declared"}
                else form_options[name] = {kind = "text", max_bytes = bounds.count(spec.max) or 512} end
            end
        end
    end
    local prompt = compiled.fields.system_prompt_append
    local prompt_available = prompt ~= nil and prompt.locked_reason == nil
    local draft, draft_error = editor.new(base, {options = form_options,
        host_home = policy_data.allow_host_home == true, placements = policy_data.placement_profiles or {"bee.placement.profiles:native"}, mcp_tools = tools, instructions = prompt_available, workdir = allows("workdir"), thread = allows("thread")})
    if not draft then
        if profile then
            migration_draft = profile
            diagnostic = {source = profile, reasons = {draft_error or "Saved preferences are outside the current host policy"}}
            return repair_only()
        end
        return nil, draft_error
    end
    local save_key, save_error = uuid.v7()
    local remove_key, remove_error = uuid.v7()
    if not save_key or not remove_key then return nil, tostring(save_error or remove_error) end
    local leases: {string} = {}
    local raw_leases, lease_error = funcs.call("bee.approvals.binding:runtime_lease", {operation = "list", workspace_id = workspace})
    local lease_reply = not lease_error and bounds.object(raw_leases)
    local lease_value = lease_reply and lease_reply.ok == true and bounds.object(lease_reply.value)
    for _, raw in ipairs(lease_value and bounds.array(lease_value.leases, 64) or {}) do
        local row = bounds.object(raw)
        local ref = row and bounds.id(row.lease_ref)
        if ref and row and row.revoked_at == nil then leases[#leases + 1] = ref end
    end
    for _, ref in ipairs(base.bee.approval_leases or {}) do if not bounds.member(ref, leases) then leases[#leases + 1] = ref end end
    local placement_names: {[string]: string} = {}
    for _, ref in ipairs(bounds.ids(policy_data.placement_profiles or {"bee.placement.profiles:native"}, true) or {}) do
        local place = catalog.entry(pinned, ref)
        local meta = place and bounds.object(place.meta)
        placement_names[ref] = meta and bounds.line(meta.title, 80) or ref
    end
    local default_private = true
    local listed = catalog.read(pinned)
    for _, binding in ipairs(listed and listed.bindings or {}) do
        if binding.binding_id == decoded.binding_ref then
            for _, profile in ipairs(binding.profiles) do
                if profile.id == decoded.profile_id then default_private = profile.private_home end
            end
        end
    end
    local credential_keys: {[string]: boolean} = {}
    local sources, source_error = pinned:find({["meta.type"] = "bee.credential_source"})
    if source_error or not sources then return nil, "Credential source metadata is unavailable" end
    for _, source in ipairs(sources) do
        local meta = bounds.object(source.meta)
        local name = meta and bounds.id(meta.credential_name)
        if name and source.kind == "env.variable" then credential_keys[name] = true end
    end
    local credential_choices = definition.credential_names(decoded, base.placement and base.placement.kind or "native",
        base.placement and base.placement.kind == "native" and base.placement.home == "private" or base.placement == nil and default_private)
    local traits: {TraitRow} = {}
    local surface = bounds.object(policy_data.gateway_surface) or {}
    local access = bounds.object(surface.access) or {}
    local offered: {[string]: boolean} = {}
    for _, id in ipairs(bounds.ids(access.traits, true) or {}) do offered[id] = true end
    for _, raw in ipairs(bounds.array(surface.traits, 64) or {}) do
        local trait = bounds.object(raw)
        if trait and type(trait.id) == "string" then offered[trait.id] = true end
    end
    local entries, trait_error = pinned:find({["meta.type"] = "agent.trait"})
    if not entries or trait_error then return nil, "Trait catalog is unavailable" end
    local listed_traits: {[string]: boolean} = {}
    for _, entry in ipairs(entries) do
        if offered[entry.id] then
            local meta = bounds.object(entry.meta) or {}
            local data = bounds.object(entry.data) or {}
            traits[#traits + 1] = {id = entry.id, title = bounds.line(meta.title, 80) or entry.id,
                gated = meta.application_ref ~= nil or data.listens ~= nil or data.hooks ~= nil}
            listed_traits[entry.id] = true
        end
    end
    local builtins = {mcp_catalog.APPLICATION_RUNTIME_TRAIT}
    for _, trait in ipairs(mcp_catalog.CONSENT_TRAITS) do builtins[#builtins + 1] = trait end
    for _, trait in ipairs(builtins) do
        if offered[trait.id] and not listed_traits[trait.id] then
            traits[#traits + 1] = {id = trait.id, title = trait.title, gated = true}
        end
    end
    table.sort(traits, function(a: TraitRow, b: TraitRow): boolean return a.title < b.title end)
    return {traits = traits, workspace_id = workspace, profile_id = id, revision = revision, draft = draft,
        permission_transport = policy_data.permission_exchange ~= nil,
        driver_name = driver_name, placement_names = placement_names, leases = leases, readiness = probed.result and (probed.result.reason or ("Runtime " .. (probed.result.executable.version or "version unavailable"))) or probed.error,
        save_key = save_key, remove_key = remove_key, fields = metadata, unsupported = unsupported, credentials = credential_choices,
        credential_keys = credential_keys, credential_definition = decoded, definition_digest = decoded.digest, default_private_home = default_private,
        migration_diagnostic = diagnostic, repair_json = migration_draft and canonical.encode(migration_draft) or nil}, nil
end

function M.change_driver(form: Form, choice: Subject): (Form?, string?)
    if form.pending then return nil, "Finish the pending profile operation first" end
    local selected, err = M.load(form.workspace_id, choice, true)
    if not selected then return nil, err end
    selected.profile_id, selected.revision = form.profile_id, form.revision
    selected.save_key, selected.remove_key = form.save_key, form.remove_key
    local named, name_error = editor.set_title(selected.draft, form.draft.name)
    if not named then return nil, name_error end
    return selected, nil
end

function M.save(form: Form): (boolean, string?)
    if form.pending == "remove" then return false, "Resolve profile removal before saving" end
    local profile, err = editor.result(form.draft)
    if form.repair_json then
        local decoded, decode_error = json.decode(form.repair_json)
        if decode_error then return false, "Migration repair is invalid JSON" end
        profile, err = protocol.profile(decoded)
    end
    if form.submitted then profile = form.submitted end
    if not profile then return false, err end
    if profile.bee.permission_answers and profile.bee.permission_answers ~= "provider" and not form.permission_transport then
        return false, "This host has no accepted permission transport. Use provider answers."
    end
    local stored, invalid = protocol.storage(profile)
    if not stored then return false, invalid end
    local pinned = catalog.pin()
    if not pinned then return false, "Profile schema registry is unavailable" end
    local profile_error = validation.check(pinned, profile) or validation.ceiling(pinned, profile, nil, true)
    if profile_error then return false, profile_error end
    form.pending, form.submitted = "save", profile
    local saved, save_error = call({operation = "put", workspace_id = form.workspace_id,
        profile_id = form.profile_id, expected_revision = form.revision, idempotency_key = form.save_key, profile = profile})
    if not saved then
        if save_error and save_error:match("^CONFLICT:") then form.pending = nil; form.submitted = nil; form.conflict = true end
        return false, save_error
    end
    if saved.workspace_id ~= form.workspace_id or saved.profile_id ~= form.profile_id
        or saved.revision ~= form.revision + 1 or saved.tombstone ~= false then
        return false, "Profile save returned an unexpected identity"
    end
    return true, nil
end

function M.copy(form: Form): (boolean, string?)
    local id, err = uuid.v7()
    local save_key, key_error = uuid.v7()
    if not id or not save_key then return false, tostring(err or key_error) end
    form.profile_id, form.revision, form.save_key = id, 0, save_key
    form.pending, form.submitted, form.conflict = nil, nil, nil
    return true, nil
end
function M.reload(form: Form): (Form?, string?)
    local saved, err = call({operation = "get", workspace_id = form.workspace_id, profile_id = form.profile_id})
    if not saved then return nil, err end
    local revision = bounds.count(saved.revision)
    if not revision or saved.tombstone ~= false then return nil, "Profile is no longer available" end
    return M.load(form.workspace_id, {title = form.draft.name, saved_profile_id = form.profile_id, saved_profile_revision = revision}, false)
end
function M.remove(form: Form): (boolean, string?)
    if form.pending == "save" then return false, "Resolve profile saving before removing" end
    if form.revision < 1 then return false, "This profile has not been saved" end
    form.pending = "remove"
    local saved, err = call({operation = "remove", workspace_id = form.workspace_id,
        profile_id = form.profile_id, expected_revision = form.revision, idempotency_key = form.remove_key})
    if not saved then return false, err end
    if saved.workspace_id ~= form.workspace_id or saved.profile_id ~= form.profile_id
        or saved.revision ~= form.revision + 1 or saved.tombstone ~= true then
        return false, "Profile removal returned an unexpected identity"
    end
    return true, nil
end
return M
