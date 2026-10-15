-- MIT. Calls for the gateway authority.
local sql = require("sql")
local hash = require("hash")
local uuid = require("uuid")
local json = require("json")
local bounds = require("bounds")
local canonical = require("canonical")
local configuration = require("configuration")
local mcp = require("mcp")
local surface = require("surface")
local catalog = require("catalog")
local surface_store = require("surface_store")
local grant_store = require("grant_store")
local binding_store = require("binding_store")
local external_store = require("external_store")
local subject_call = require("subject_call")
local access = require("access")
local part_model = require("part_model")
local part_surfaces = require("part_surfaces")
local part_values = require("part_values")
local M = {}
type Reply = part_model.Reply
type Binding = part_model.Binding
local fail = part_values.fail
local succeed = part_values.succeed
local now_ms = part_values.now_ms
local stamp = part_values.stamp
local open = part_values.open
function M.admit_call(binding: Binding, name: string): Reply
    local current, failure = part_surfaces.surface(binding)
    if not current then return failure or fail("DENIED", "call surface unavailable") end
    local selected = catalog.select(current.configuration.catalog, current.configuration.ceiling,
        current.configuration.base_tools, current.configuration.allowed_traits, current.selection.active)
    local active = false
    for _, tool in ipairs(selected or {}) do if tool.name == name then active = true end end
    if not active then return fail("DENIED", "tool is not active in this binding") end
    local db, failure = open()
    if not db then return failure or fail("STORAGE","open call authority") end
    local tx, err = db:begin({isolation = sql.isolation.SERIALIZABLE})
    if not tx then db:release(); return fail("STORAGE","begin call admission") end
    local rows = binding_store.surface_authority(tx,binding.binding_id)
    local row = rows and #rows == 1 and bounds.object(rows[1]) or nil
    local now = now_ms()
    if not row or row.revoked_at ~= nil or row.sealed_at ~= nil or row.credential_generation ~= binding.credential_generation or type(row.expires_at) ~= "string" or row.expires_at <= stamp(now) then tx:rollback(); db:release(); return fail("DENIED","binding no longer admits calls") end
    local stored, stored_error = surface_store.read(tx,binding.binding_id)
    local declaration = stored and bounds.object(json.decode(stored.surface_json))
    if not declaration then tx:rollback(); db:release(); return fail("STORAGE",stored_error and stored_error.message or "invalid call surface") end
    local id, authority_error = surface_store.call_authority(tx,binding.binding_id,binding.workspace_id,declaration,name,now,
        current.configuration.catalog.traits, current.configuration.access)
    if authority_error then tx:rollback(); db:release(); return fail("DENIED",authority_error.message) end
    if id then
        local grant, read_error = grant_store.read(tx,id)
        if not grant or read_error or grant.workspace_id ~= (binding.workspace_id or "legacy:unscoped") or grant_store.state(grant,now) ~= "active" then tx:rollback(); db:release(); return fail("DENIED","consent grant no longer admits calls") end
        local effect = assert(uuid.v7())
        local digest = assert(hash.sha256(assert(canonical.encode({binding_id = binding.binding_id,tool = name}))))
        local reserved, reserve_error = grant_store.use(tx,grant,"reserve",effect,digest,grant.revision,binding.subject,now)
        if reserved == nil then tx:rollback(); db:release(); return fail("DENIED",reserve_error or "call reservation denied") end
        local admitted, admission_error = grant_store.use(tx,grant,"admit",effect,digest,grant.revision,binding.subject,now)
        if admitted == nil then tx:rollback(); db:release(); return fail("DENIED",admission_error or "call admission denied") end
    end
    local _, commit_error = tx:commit()
    db:release()
    if commit_error then return fail("STORAGE","commit call admission") end
    return succeed({grant_id = id})
end
function M.record_external_call(binding: Binding, name: string): Reply
    local db, failure = open()
    if not db then return failure or fail("STORAGE", "open external clients") end
    local rows, err = external_store.by_binding(db, binding.binding_id)
    db:release()
    if not rows or err then return fail("STORAGE", "read external client") end
    if #rows == 0 then return succeed({}) end
    local reference_id = mcp.TOOL_POLICY_REFS.message
    local policy, policy_error = subject_call.linked(reference_id, "thread record policy")
    if not policy then return policy_error or fail("UNAVAILABLE", "thread record policy is unavailable") end
    local id, id_error = uuid.v7()
    if not id then return fail("STORAGE", tostring(id_error)) end
    return subject_call.call(binding, {policy}, "bee.threads.binding:record", {thread_id = binding.thread_id,
        idempotency_key = id, kind = "message", body = {message_id = id, message_kind = "progress", recipient_ids = {}, content = {text = "MCP tool: " .. name}}})
end
return M
