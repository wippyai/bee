-- MIT. Transaction-local storage of an admitted MCP surface and its selection.
-- The caller owns authorization, decoding and transaction commit/rollback.
local bounds = require("bounds")
local json = require("json")
local capability_model = require("capability_model")
local authority = require("authority")
local clock = require("clock")
local canonical = require("canonical")
local mcp = require("mcp")
local profile_grants = require("profile_grants")
local agent_trait = require("agent_trait")
local session_traits = require("session_traits")
local trait_access = require("trait_access")
local M = {}
type State = {surface_json: string, active_json: string, context_json: string, revision: integer}
type Fault = {code: string, message: string}
type Grant = {approval_id: string, proposal_digest: string, traits: {string}}
local function fault(code: string, message: string): Fault return {code = code, message = message} end
local function text(value: string, limit: integer): boolean return #value > 0 and #value <= limit end
function M.profile_authority(tx: sql.Transaction, binding_id: string, workspace: string?, declaration: {[string]: unknown}, now: integer?): (authority.Grant?, Fault?)
    local id = bounds.id(declaration.authority_grant_id)
    if not id then return nil,fault("DENIED","surface consent identity is missing") end
    local grant, err = authority.read(tx,id)
    if not grant or err or grant.workspace_id ~= (workspace or "legacy:unscoped") or authority.state(grant,now or clock.milliseconds()) ~= "active" then return nil,fault("DENIED",err or "surface consent is no longer active") end
    if grant.domain == "profile_choices" then
        local invalid = profile_grants.live(tx, grant)
        if invalid then return nil, fault("DENIED", invalid) end
        local parameters = bounds.object(grant.scope.parameters)
        local saved = parameters and bounds.object(parameters.configuration)
        local bee = saved and bounds.object(saved.bee)
        if not saved or canonical.encode(bee) ~= canonical.encode(declaration.profile) then return nil,fault("DENIED","surface differs from saved profile consent") end
        local chosen: {[string]: boolean} = {}
        for _, raw in ipairs(bee and bounds.array(bee.mcp,64) or {}) do
            local item = bounds.object(raw)
            local tool = item and bounds.id(item.tool)
            if tool then chosen[tool] = true end
        end
        local base = bounds.ids(declaration.base_tools,true)
        if not base then return nil,fault("DENIED","surface base tools are invalid") end
        for _, trait in ipairs(mcp.CONSENT_TRAITS) do
            for _, name in ipairs(trait.tools) do
                for _, tool in ipairs(base) do if tool == name and not chosen[tool] then return nil,fault("DENIED","surface exceeds saved profile consent") end end
            end
        end
        return grant,nil
    end
    if grant.domain ~= "gateway_access" or (grant.metadata.legacy_surface ~= true and grant.metadata.surface_projection ~= true) or grant.metadata.binding_id ~= binding_id or grant.subject.audience ~= binding_id then return nil,fault("DENIED","surface consent belongs to another context") end
    local parameters = bounds.object(grant.scope.parameters)
    local expected = parameters and bounds.object(parameters.configuration)
    local configuration: {[string]: unknown} = {}
    for key, value in pairs(declaration) do if key ~= "authority_grant_id" then configuration[key] = value end end
    if not expected or canonical.encode(expected) ~= canonical.encode(configuration) then return nil,fault("DENIED","surface exceeds legacy consent") end
    return grant,nil
end
function M.call_authority(tx: sql.Transaction, binding_id: string, workspace: string?, declaration: {[string]: unknown}, name: string, now: integer): (string?, Fault?)
    local id = bounds.id(declaration.authority_grant_id)
    if id then
        local record, err = M.profile_authority(tx,binding_id,workspace,declaration,now)
        if not record then return nil,err end
    end
    local access = bounds.object(declaration.access)
    local requested = access and bounds.ids(access.traits,true) or {}
    local traits: {[string]: {string}} = {[mcp.APPLICATION_RUNTIME_TRAIT.id] = mcp.APPLICATION_RUNTIME_TRAIT.tools}
    for _, trait in ipairs(mcp.CONSENT_TRAITS) do traits[trait.id] = trait.tools end
    local extensions: {[string]: boolean} = {}
    for _, raw in ipairs(bounds.array(declaration.traits,64) or {}) do
        local trait = bounds.object(raw)
        local trait_id = trait and bounds.id(trait.id)
        local tools = trait and bounds.ids(trait.tools,true)
        if trait_id and tools then
            traits[trait_id] = tools
            local decoded = agent_trait.declaration(raw)
            if decoded and agent_trait.extension(decoded) then
                extensions[trait_id] = true
                local current = trait_access.load(trait_id)
                if current then traits[trait_id] = current.tools end
            end
        end
    end
    for _, trait in ipairs(requested or {}) do
        for _, tool in ipairs(traits[trait] or {}) do
            if tool == name then
                if extensions[trait] then
                    local rows, err = tx:query("SELECT action_id,thread_id FROM bee_gateway_bindings WHERE binding_id=?", {binding_id})
                    if not rows or err or #rows ~= 1 then return nil, fault("STORAGE", "read extension call scope") end
                    local session, thread = bounds.id(rows[1].action_id), bounds.id(rows[1].thread_id)
                    if not session or not thread then return nil, fault("STORAGE", "invalid extension call scope") end
                    local selected, invalid = session_traits.read(tx, session, trait)
                    if not selected or invalid or not selected.selected or selected.workspace_id ~= workspace or selected.thread_id ~= thread then
                        return nil, fault("DENIED", invalid or "trait is not active in this session")
                    end
                    local consent_error = session_traits.consent(tx, selected)
                    if consent_error then return nil, fault("DENIED", consent_error) end
                    local contains = false
                    for _, offered in ipairs(selected.declaration.tools) do if offered == name then contains = true end end
                    if not contains then return nil, fault("DENIED", "tool is outside the person's trait consent") end
                    return selected.grant_id, nil
                end
                local receipt, err = M.runtime_grant(tx,binding_id,trait,now)
                if not receipt then return nil,err or fault("DENIED","access grant no longer admits calls") end
                return receipt.approval_id .. ":grant",nil
            end
        end
    end
    return id,nil
end
function M.bind_authority(tx: sql.Transaction, owner: string, workspace: string?, subject: string, binding_id: string, configuration: {[string]: unknown}, policy_ref: string?): (string?, Fault?)
    if configuration.authority_grant_id ~= nil then return canonical.encode(configuration),nil end
    local base = bounds.ids(configuration.base_tools,true) or {}
    local consent = configuration.profile ~= nil
    for _, trait in ipairs(mcp.CONSENT_TRAITS) do for _, name in ipairs(trait.tools) do for _, tool in ipairs(base) do if tool == name then consent = true end end end end
    if not consent then return canonical.encode(configuration),nil end
    local scope: {[string]: unknown} = {}
    for key, value in pairs(configuration) do scope[key] = value end
    local issuer, definition = authority.principal(owner)
    local record: authority.Grant = {grant_id = authority.identity("gateway_access",owner,workspace or "legacy:unscoped",binding_id .. ":surface"),domain = "gateway_access",owner_node = owner,workspace_id = workspace or "legacy:unscoped",requester_id = subject,granted_by = issuer,granted_definition = definition,
        subject = {principal_id = subject,audience = binding_id},scope = {type = "exact",parameters = {configuration = scope}},terms = {kind = "binding",time_basis = "absolute"},provenance = {kind = "host_policy",policy_ref = policy_ref,configuration_digest = authority.identity("surface",owner,binding_id,assert(canonical.encode(scope)))},metadata = {binding_id = binding_id,surface_projection = true},state = "active",revision = 1,used = 0,reserved = 0,created_at = clock.now()}
    local err = authority.create(tx,record)
    if err then return nil,fault("STORAGE",err) end
    configuration.authority_grant_id = record.grant_id
    return canonical.encode(configuration),nil
end
local function decode_traits(binding_id: string, encoded: string, code: string,
    message: string): ({string}?, Fault?)
    local decoded, decode_error = json.decode(encoded)
    local traits, traits_error = bounds.ids(decoded, true)
    if decode_error or not traits or not capability_model.traits(binding_id, traits) then
        return nil, fault(code, traits_error or message)
    end
    return traits, nil
end
function M.read(tx: sql.Transaction, binding_id: string): (State?, Fault?)
    local rows, err = tx:query("SELECT surface_json, active_json, context_json, revision FROM bee_gateway_surfaces WHERE binding_id = ?", {binding_id})
    if err or not rows then return nil, fault("STORAGE", "read binding surface") end
    if #rows == 0 then return nil, fault("NOT_FOUND", "binding surface is absent") end
    local row = bounds.object(rows[1])
    if not row then return nil, fault("STORAGE", "invalid binding surface row") end
    local revision = bounds.count(row.revision)
    local surface, active, context = bounds.text(row.surface_json, 131072), bounds.text(row.active_json, 8192), bounds.text(row.context_json, 16384)
    if surface == nil then return nil, fault("STORAGE", "invalid surface JSON") end
    if active == nil then return nil, fault("STORAGE", "invalid active JSON") end
    if context == nil then return nil, fault("STORAGE", "invalid context JSON") end
    if revision == nil then return nil, fault("STORAGE", "invalid surface revision") end
    if revision < 1 or not text(surface, 131072) or not text(active, 8192) or not text(context, 16384) then
        return nil, fault("STORAGE", "invalid binding surface state")
    end
    return {surface_json = surface, active_json = active, context_json = context, revision = revision}, nil
end
function M.initialize(tx: sql.Transaction, binding_id: string, surface: string, active: string, context: string): (State?, Fault?)
    if not bounds.id(binding_id) or not text(surface, 131072) or not text(active, 8192) or not text(context, 16384) then
        return nil, fault("INVALID", "binding surface exceeds storage bounds")
    end
    local inserted, err = tx:execute("INSERT INTO bee_gateway_surfaces (binding_id, surface_json, active_json, context_json, revision) VALUES (?, ?, ?, ?, 1) ON CONFLICT(binding_id) DO NOTHING",
        {binding_id, surface, active, context})
    if err or not inserted then return nil, fault("STORAGE", "initialize binding surface") end
    if inserted.rows_affected ~= 1 then return nil, fault("CONFLICT", "binding surface already exists") end
    return {surface_json = surface, active_json = active, context_json = context, revision = 1}, nil
end
function M.replace(tx: sql.Transaction, binding_id: string, expected_revision: integer, active: string, context: string): (State?, Fault?)
    if not bounds.id(binding_id) or expected_revision < 1 or expected_revision >= 9007199254740991
        or not text(active, 8192) or not text(context, 16384) then return nil, fault("INVALID", "invalid surface replacement") end
    local updated, err = tx:execute("UPDATE bee_gateway_surfaces SET active_json = ?, context_json = ?, revision = revision + 1 WHERE binding_id = ? AND revision = ?",
        {active, context, binding_id, expected_revision})
    if err or not updated then return nil, fault("STORAGE", "update binding surface") end
    if updated.rows_affected ~= 1 then return nil, fault("CONFLICT", "binding surface changed or is absent") end
    return M.read(tx, binding_id)
end
-- The approval owner has consumed the exact effect before this transaction.
-- Recording the receipt and revision together makes a lost commit reply replayable.
function M.grants(tx: sql.Transaction, binding_id: string, now: integer?): ({string}?, Fault?)
    local rows, err = tx:query("SELECT a.traits_json FROM bee_gateway_access_receipts a JOIN bee_approval_grants g ON g.grant_id = a.grant_id JOIN bee_gateway_bindings b ON b.binding_id = a.binding_id WHERE a.binding_id = ? AND g.state = 'active' AND (g.until_ms IS NULL OR g.until_ms > ?) AND (g.max_uses IS NULL OR g.used + g.reserved < g.max_uses) AND b.revoked_at IS NULL AND b.sealed_at IS NULL AND b.expires_at > ?", {binding_id,now or clock.milliseconds(),clock.stamp(now or clock.milliseconds())})
    if not rows or err then return nil, fault("STORAGE", "read MCP access grants") end
    if #rows > 64 then return nil, fault("STORAGE", "MCP access receipt capacity exceeded") end
    local result: {string} = {}
    local seen: {[string]: boolean} = {}
    for _, raw in ipairs(rows) do
        local row = bounds.object(raw)
        local encoded = row and bounds.text(row.traits_json, 8192)
        if not encoded then return nil, fault("STORAGE", "invalid grant receipt") end
        local traits, invalid = decode_traits(binding_id, encoded, "STORAGE", "invalid grant traits")
        if not traits then return nil, invalid end
        for _, id in ipairs(traits) do
            if not seen[id] then seen[id] = true; result[#result + 1] = id end
        end
    end
    if #result > 64 then return nil, fault("STORAGE", "too many granted traits") end
    table.sort(result)
    return result, nil
end
function M.receipt(db: sql.DB, binding_id: string, approval_id: string)
    return db:query("SELECT traits_json FROM bee_gateway_access_receipts WHERE binding_id = ? AND approval_id = ?", {binding_id, approval_id})
end
-- A receipt is durable evidence, not a new authorization mechanism.  When
-- several approved effects carry one trait, the explicit approval-ID order
-- makes the provenance selected for a retried runtime call stable.
function M.runtime_grant(tx: sql.Transaction, binding_id: string, trait_id: string, now: integer?): (Grant?, Fault?)
    if not bounds.id(binding_id) or not bounds.id(trait_id) then return nil, fault("INVALID", "invalid runtime receipt lookup") end
    local rows, err = tx:query("SELECT a.approval_id,a.proposal_digest,a.traits_json FROM bee_gateway_access_receipts a JOIN bee_approval_grants g ON g.grant_id = a.grant_id JOIN bee_gateway_bindings b ON b.binding_id = a.binding_id WHERE a.binding_id = ? AND g.state = 'active' AND (g.until_ms IS NULL OR g.until_ms > ?) AND (g.max_uses IS NULL OR g.used + g.reserved < g.max_uses) AND b.revoked_at IS NULL AND b.sealed_at IS NULL AND b.expires_at > ? ORDER BY a.approval_id ASC", {binding_id,now or clock.milliseconds(),clock.stamp(now or clock.milliseconds())})
    if not rows or err then return nil, fault("STORAGE", "read application runtime access receipt") end
    if #rows > 64 then return nil, fault("STORAGE", "MCP access receipt capacity exceeded") end
    for _, raw in ipairs(rows) do
        local row = bounds.object(raw)
        local approval_id = row and bounds.id(row.approval_id)
        local proposal_digest = row and bounds.text(row.proposal_digest, 64)
        local encoded = row and bounds.text(row.traits_json, 8192)
        if not approval_id or not proposal_digest or #proposal_digest ~= 64
            or not proposal_digest:match("^[0-9a-f]+$") or not encoded then
            return nil, fault("STORAGE", "invalid application runtime access receipt")
        end
        local traits, invalid = decode_traits(binding_id, encoded, "STORAGE", "invalid application runtime access receipt")
        if not traits then return nil, invalid end
        for _, id in ipairs(traits) do
            if id == trait_id then return {approval_id = approval_id, proposal_digest = proposal_digest, traits = traits}, nil end
        end
    end
    return nil, nil
end
function M.grant(tx: sql.Transaction, binding_id: string, approval_id: string, digest: string, traits_json: string, now: integer?): (State?, Fault?)
    if not bounds.id(binding_id) or not bounds.id(approval_id) or #digest ~= 64 or not digest:match("^%x+$")
        or not text(traits_json, 8192) then return nil, fault("INVALID", "invalid grant receipt") end
    local added, traits_fault = decode_traits(binding_id, traits_json, "INVALID", "invalid grant receipt")
    if not added then return nil, traits_fault end
    local rows, err = tx:query("SELECT proposal_digest, traits_json FROM bee_gateway_access_receipts WHERE binding_id = ? AND approval_id = ?", {binding_id, approval_id})
    if not rows or err then return nil, fault("STORAGE", "read grant receipt") end
    if #rows > 0 then
        local row = bounds.object(rows[1])
        if not row or row.proposal_digest ~= digest or row.traits_json ~= traits_json then return nil, fault("CONFLICT", "grant receipt differs") end
        return M.read(tx, binding_id)
    end
    local record, record_error = authority.read(tx,approval_id .. ":grant")
    if not record then return nil,fault("DENIED",record_error or "gateway access grant is missing") end
    if record.domain ~= "gateway_access" or record.metadata.binding_id ~= binding_id or authority.state(record,now or clock.milliseconds()) ~= "active" then return nil,fault("DENIED","gateway access grant is not active for this binding") end
    if canonical.encode(record.metadata.traits) ~= canonical.encode(added) then return nil,fault("CONFLICT","gateway access grant traits differ") end
    local count, count_error = tx:query("SELECT COUNT(*) AS n FROM bee_gateway_access_receipts WHERE binding_id = ?", {binding_id})
    if not count or count_error then return nil, fault("STORAGE", "count grant receipts") end
    local first = bounds.object(count[1])
    local n = first and bounds.count(first.n)
    if not n then return nil, fault("STORAGE", "invalid grant count") end
    if n >= 64 then return nil, fault("LIMIT_EXCEEDED", "MCP grant receipt capacity reached") end
    local current, current_error = M.read(tx, binding_id)
    if not current then return nil, current_error end
    local old_raw, old_error = json.decode(current.active_json)
    local active = bounds.ids(old_raw, true)
    if old_error or not active then return nil, fault("STORAGE", "invalid active traits") end
    local seen: {[string]: boolean} = {}
    for _, id in ipairs(active) do seen[id] = true end
    for _, id in ipairs(added) do if not seen[id] then active[#active + 1] = id; seen[id] = true end end
    if #active > 64 then return nil, fault("LIMIT_EXCEEDED", "too many active traits") end
    table.sort(active)
    local active_json, encode_error = json.encode(active)
    if not active_json or encode_error then return nil, fault("STORAGE", "encode active traits") end
    local inserted, insert_error = tx:execute("INSERT INTO bee_gateway_access_receipts (binding_id, approval_id, proposal_digest, traits_json, grant_id) VALUES (?, ?, ?, ?, ?)", {binding_id, approval_id, digest, traits_json,approval_id .. ":grant"})
    if not inserted or insert_error then return nil, fault("STORAGE", "record MCP grant receipt") end
    local updated, update_error = tx:execute("UPDATE bee_gateway_surfaces SET active_json = ?, revision = revision + 1 WHERE binding_id = ? AND revision < 9007199254740991", {active_json, binding_id})
    if not updated or update_error or updated.rows_affected ~= 1 then return nil, fault("STORAGE", "advance MCP grant revision") end
    return M.read(tx, binding_id)
end
return M
