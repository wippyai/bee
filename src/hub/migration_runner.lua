-- MIT. Execute the standard migration function contract under host-selected
-- permissions. Package functions own their DSL and ledger transactions.
local sql = require("sql")
local funcs = require("funcs")
local security = require("security")
local migrations = require("migrations")
local M = {}
type Applied = {id: string, group: integer}
type Binding = {database_id: string, table_prefix: string?}
type Bindings = {[string]: Binding}
type PolicyIds = {string}

local HUB_PRIVATE_POLICIES: {string} = {
    "bee.hub:execution_policy", "bee.hub:publisher_policy", "bee.hub:dependency_policy",
    "bee.hub:receipt_policy", "bee.hub:worker_policy", "bee.hub:worker_name_policy",
    "bee.hub:worker_reply_policy", "bee.hub:migration_context_policy",
}

local function registry_id(value: unknown): string?
    if type(value) ~= "string" or #value == 0 or #value > 160 or value:find("%c")
        or not value:match("^[A-Za-z0-9][A-Za-z0-9_.-]*:[A-Za-z0-9][A-Za-z0-9_.-]*$") then return nil end
    return value
end

local function prefix(value: unknown): string?
    if type(value) ~= "string" or #value == 0 or #value > 64
        or not value:match("^[A-Za-z][A-Za-z0-9_]*$") then return nil end
    return value
end

local function binding_for(target: string, bindings: Bindings?): (Binding?, string?)
    if bindings == nil then return {database_id = target}, nil end
    local raw: unknown = bindings[target]
    if type(raw) ~= "table" then return nil, "migration database binding is missing for " .. target end
    local value = raw :: {[string]: unknown}
    for key in pairs(value) do
        if key ~= "database_id" and key ~= "table_prefix" then
            return nil, "migration database binding has unknown field " .. tostring(key)
        end
    end
    local database_id = registry_id(value.database_id)
    local table_prefix = value.table_prefix == nil and nil or prefix(value.table_prefix)
    if not database_id or (value.table_prefix ~= nil and not table_prefix) then
        return nil, "migration database binding is invalid for " .. target
    end
    return {database_id = database_id, table_prefix = table_prefix}, nil
end

local function capture_bindings(entries: {migrations.Entry}, bindings: Bindings?): (Bindings?, string?)
    if bindings == nil then return nil, nil end
    local captured: Bindings = {}
    for _, entry in ipairs(entries) do
        local target = entry.meta.target_db
        if type(target) ~= "string" then return nil, "migration target database is invalid for " .. entry.id end
        if not captured[target] then
            local selected, binding_error = binding_for(target, bindings)
            if not selected then return nil, binding_error end
            captured[target] = selected
        end
    end
    return captured, nil
end

local function capture_policy_ids(raw: PolicyIds?): (PolicyIds?, string?)
    if raw == nil then return nil, nil end
    if #raw > 64 then return nil, "migration execution policies exceed their bound" end
    local result: PolicyIds = {}
    local seen: {[string]: boolean} = {}
    for index, value in ipairs(raw) do
        local id = registry_id(value)
        if not id or seen[id] then return nil, "migration execution policy is invalid or duplicated" end
        seen[id] = true
        result[index] = id
    end
    return result, nil
end

function M.allowed(entries: {migrations.Entry}, bindings: Bindings?): (boolean, string?)
    for _, entry in ipairs(entries) do
        local target = entry.meta.target_db
        if type(target) ~= "string" then return false, "migration target database is invalid for " .. entry.id end
        local selected, binding_error = binding_for(target, bindings)
        if not selected then return false, binding_error end
        if not security.can("db.get", selected.database_id) then
            return false, "host database grant required for migration " .. entry.id
        end
        if not security.can("funcs.call", entry.id) then
            return false, "host function grant required for migration " .. entry.id
        end
    end
    return true, nil
end

-- Query only the selected IDs. Checking an absent ledger never creates it.
local function read_applied(target: string, ids: {string}): ({Applied}?, string?)
    local db, open_error = sql.get(target)
    if not db then return nil, tostring(open_error) end
    local kind, type_error = db:type()
    if type_error then db:release(); return nil, tostring(type_error) end
    local exists: string
    if kind == sql.type.SQLITE then
        exists = "SELECT COUNT(*) AS count FROM sqlite_master WHERE type = 'table' AND name = '_migrations'"
    elseif kind == sql.type.POSTGRES then
        exists = "SELECT COUNT(*) AS count FROM information_schema.tables WHERE table_schema = current_schema() AND table_name = '_migrations'"
    elseif kind == sql.type.MYSQL then
        exists = "SELECT COUNT(*) AS count FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = '_migrations'"
    else
        db:release(); return nil, "unsupported migration ledger database"
    end
    local tables, tables_error = db:query(exists)
    if not tables then db:release(); return nil, tostring(tables_error) end
    local row = tables[1]
    local count = row and row.count
    if (type(count) ~= "number" and type(count) ~= "string") or tonumber(count) == nil then
        db:release(); return nil, "invalid migration ledger existence result"
    end
    if tonumber(count) == 0 then db:release(); return {}, nil end
    local parameters: {unknown} = {}
    local placeholders: {string} = {}
    for index, id in ipairs(ids) do
        parameters[index] = id
        placeholders[index] = kind == sql.type.POSTGRES and "$" .. tostring(index) or "?"
    end
    if #ids == 0 then db:release(); return {}, nil end
    local rows, query_error = db:query("SELECT id, applied_at FROM _migrations WHERE id IN ("
        .. table.concat(placeholders, ",") .. ") ORDER BY applied_at DESC", parameters)
    db:release()
    if not rows then return nil, tostring(query_error) end
    local result: {Applied} = {}
    local previous: string? = nil
    local group = 0
    for _, item in ipairs(rows) do
        if type(item.id) ~= "string" or item.applied_at == nil then return nil, "invalid migration ledger row" end
        local stamp = tostring(item.applied_at)
        if stamp ~= previous then group = group + 1; previous = stamp end
        result[#result + 1] = {id = item.id, group = group}
    end
    return result, nil
end

function M.is_applied(target: string, id: string, binding: Binding?): (boolean?, string?)
    if type(target) ~= "string" or target == "" or type(id) ~= "string" or id == "" then
        return nil, "migration ledger identity is invalid"
    end
    local selected, binding_error = binding_for(target, binding and {[target] = binding} or nil)
    if not selected then return nil, binding_error end
    local rows, problem = read_applied(selected.database_id, {id})
    if not rows then return nil, problem end
    return #rows == 1, nil
end

function M.source(entries: {migrations.Entry}, private_policies: {string}?, bindings: Bindings?,
    execution_policies: PolicyIds?): migrations.Source
    local by_id: {[string]: migrations.Entry} = {}
    for _, entry in ipairs(entries) do by_id[entry.id] = entry end
    local captured_bindings, bindings_error = capture_bindings(entries, bindings)
    local captured_policies, policies_error = capture_policy_ids(execution_policies)
    local stripped_policies: {string} = {}
    for index, policy in ipairs(private_policies or HUB_PRIVATE_POLICIES) do
        stripped_policies[index] = policy
    end
    local function selected(target: string, raw: unknown): {string}
        if type(raw) ~= "table" or type(raw.allowed_ids) ~= "table" then error("migration IDs required") end
        local ids: {string} = {}
        local seen: {[string]: boolean} = {}
        for _, id in ipairs(raw.allowed_ids :: {unknown}) do
            if type(id) ~= "string" then error("invalid migration ID") end
            local entry = by_id[id]
            if not entry or entry.meta.target_db ~= target or seen[id] then error("migration is outside the captured database selection") end
            seen[id] = true
            ids[#ids + 1] = id
        end
        if #ids == 0 or #ids > migrations.MAX_MIGRATIONS then error("invalid migration selection size") end
        return ids
    end
    local function execute(target: string, id: string, direction: string): unknown
        local entry = by_id[id]
        if not entry or entry.meta.target_db ~= target then error("migration is outside the captured database selection") end
        if bindings_error then error(bindings_error) end
        local selected_binding, binding_error = binding_for(target, captured_bindings)
        if not selected_binding then error(binding_error or "migration database binding is invalid") end
        local allowed, grant_error = M.allowed(entries, captured_bindings)
        if not allowed then error(grant_error or "migration grant denied") end
        -- Retain host policies, including denials, but never pass the
        -- component's private publication/worker authority to package code.
        local scope = security.scope()
        if not scope then error("migration execution scope unavailable") end
        for _, policy in ipairs(stripped_policies) do
            scope = scope:without(policy)
        end
        if policies_error then error(policies_error) end
        for _, policy_id in ipairs(captured_policies or {}) do
            local policy, policy_error = security.policy(policy_id)
            if not policy then error(tostring(policy_error or "migration execution policy is unavailable")) end
            scope = scope:with(policy)
        end
        local executor, scope_error = funcs.new():with_scope(scope)
        if not executor then error(tostring(scope_error)) end
        local options: {[string]: unknown} = {target_db = target, database_id = selected_binding.database_id,
            direction = direction, id = id}
        if selected_binding.table_prefix then options.table_prefix = selected_binding.table_prefix end
        local result, call_error = executor:call(id, options)
        if call_error then error(tostring(call_error)) end
        if type(result) ~= "table" or type(result.status) ~= "string" then error("invalid migration function result") end
        if result.status == "error" then error(type(result.error) == "string" and result.error or "migration function failed") end
        -- The standard DSL wraps its per-migration result; standalone
        -- migration functions may return the same result directly.
        local value: unknown = result
        if type(result.migrations) == "table" and #result.migrations > 0 then value = result.migrations[1] end
        if type(value) ~= "table" or type(value.status) ~= "string" then error("invalid migration result row") end
        if value.status == "error" then error(type(value.error) == "string" and value.error or "migration function failed") end
        return {id = id, status = value.status}
    end
    return {
        entries = entries,
        is_applied = function(target: string, id: string): (boolean?, string?)
            local entry = by_id[id]
            if not entry or entry.meta.target_db ~= target then return nil, "migration is outside the captured database selection" end
            if bindings_error then return nil, bindings_error end
            local selected_binding, binding_error = binding_for(target, captured_bindings)
            if not selected_binding then return nil, binding_error end
            return M.is_applied(target, id, selected_binding)
        end,
        runner = {setup = function(target: string): (migrations.DatabaseRunner?, string?)
            if bindings_error then return nil, bindings_error end
            if policies_error then return nil, policies_error end
            local selected_binding, binding_error = binding_for(target, captured_bindings)
            if not selected_binding then return nil, binding_error end
            local allowed, grant_error = M.allowed(entries, captured_bindings)
            if not allowed then return nil, grant_error end
            return {
                run_next = function(_: migrations.DatabaseRunner, options: {[string]: unknown}): migrations.RunnerResult
                    local ids = selected(target, options)
                    if #ids ~= 1 then error("one migration ID required") end
                    return {migrations = {execute(target, ids[1], "up")}}
                end,
                rollback = function(_: migrations.DatabaseRunner, options: {[string]: unknown}): migrations.RunnerResult
                    local ids = selected(target, options)
                    if options.count ~= #ids then error("rollback count differs from selected IDs") end
                    local applied, problem = read_applied(selected_binding.database_id, ids)
                    if not applied then error(problem or "read migration ledger") end
                    table.sort(applied, function(a: Applied, b: Applied): boolean
                        if a.group ~= b.group then return a.group < b.group end
                        local left, right = by_id[a.id], by_id[b.id]
                        local at = left and left.meta.timestamp or ""
                        local bt = right and right.meta.timestamp or ""
                        if type(at) ~= "string" or type(bt) ~= "string" then error("invalid migration timestamp") end
                        if at ~= bt then return at > bt end
                        return a.id > b.id
                    end)
                    local results: {unknown} = {}
                    for _, item in ipairs(applied) do
                        local ok, value = pcall(function() return execute(target, item.id, "down") end)
                        if not ok then return {migrations = results, error = "rollback migration " .. item.id .. ": " .. tostring(value)} end
                        results[#results + 1] = value
                    end
                    return {migrations = results}
                end,
            }, nil
        end},
    }
end

return M
