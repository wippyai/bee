-- MIT. The Hub service supplies a measured registry snapshot, its migration
-- ledger reader, and the public migration runner.  This adapter never discovers
-- arbitrary entries or lets a request name a database: it runs only the
-- snapshot-owned migration IDs admitted by the install plan.
local M = {}

M.MAX_MIGRATIONS = 128

type Entry = {id: string, meta: {[string]: unknown}, registry: {[string]: unknown}}
type RunnerResult = {migrations: {unknown}?}
type DatabaseRunner = {
    run_next: (DatabaseRunner, {[string]: unknown}) -> RunnerResult,
    rollback: (DatabaseRunner, {[string]: unknown}) -> RunnerResult,
}
type Runner = {setup: (string) -> (DatabaseRunner?, string?)}
type Source = {
    entries: {Entry},
    -- Captured from the target database before execution.  An empty runner
    -- result proves nothing; only this ledger evidence makes an up/down a
    -- harmless idempotent skip.
    is_applied: (string, string) -> (boolean?, string?),
    runner: Runner,
}
type Request = {operation: string, entry_ids: {string}, components: {string}}
type Row = {id: string, target_db: string, module: string, status: string, reason: string?}
type Result = {operation: string, rows: {Row}}

local function dense_strings(raw: unknown, label: string, maximum: integer): ({string}?, string?)
    if type(raw) ~= "table" then return nil, label .. " must be a dense list" end
    local count = 0
    for key in pairs(raw) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then return nil, label .. " must be a dense list" end
        count = count + 1
    end
    if count > maximum or count ~= #raw then return nil, label .. " exceeds its bound or is sparse" end
    local result: {string} = {}
    local seen: {[string]: boolean} = {}
    for index = 1, count do
        local value = raw[index]
        if type(value) ~= "string" or value == "" or #value > 256 then return nil, label .. " contains an invalid identifier" end
        if seen[value] then return nil, label .. " contains a duplicate identifier" end
        seen[value] = true
        result[index] = value
    end
    return result, nil
end

local function component(value: string): boolean
    local org, name = value:match("^([%w_%-%.]+)/([%w_%-%.]+)$")
    return org ~= nil and name ~= nil and org ~= "." and org ~= ".." and name ~= "." and name ~= ".."
end

function M.decode(raw: unknown): (Request?, string?)
    if type(raw) ~= "table" then return nil, "migration request must be an object" end
    local value = raw :: {[string]: unknown}
    for key in pairs(value) do
        if key ~= "operation" and key ~= "entry_ids" and key ~= "components" then return nil, "migration request contains an unknown field" end
    end
    local operation = value.operation
    if operation ~= "up" and operation ~= "down" then return nil, "migration operation must be up or down" end
    local entry_ids, entry_error = dense_strings(value.entry_ids, "migration entry_ids", M.MAX_MIGRATIONS)
    if not entry_ids or #entry_ids == 0 then return nil, entry_error or "migration entry_ids must not be empty" end
    local components, component_error = dense_strings(value.components, "migration components", M.MAX_MIGRATIONS)
    if not components or #components == 0 then return nil, component_error or "migration components must not be empty" end
    for _, name in ipairs(components) do
        if not component(name) then return nil, "migration components must be org/module names" end
    end
    return {operation = operation, entry_ids = entry_ids, components = components}, nil
end

local function entry_map(entries: unknown): ({[string]: Entry}?, string?)
    if type(entries) ~= "table" then return nil, "captured registry entries are invalid" end
    local supplied = entries :: {[number]: unknown}
    local count = 0
    for key in pairs(supplied) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then return nil, "captured registry entries are invalid" end
        count = count + 1
    end
    if count > M.MAX_MIGRATIONS * 16 or count ~= #supplied then return nil, "captured registry entries are invalid" end
    local out: {[string]: Entry} = {}
    for index = 1, count do
        local raw = supplied[index]
        if type(raw) ~= "table" then return nil, "captured registry entry " .. tostring(index) .. " is invalid" end
        local value = raw :: {[string]: unknown}
        local id = value.id
        if type(id) ~= "string" or id == "" or #id > 256 or not id:match("^[^:%s]+:[^:%s]+$") then
            return nil, "captured registry entry " .. tostring(index) .. " is invalid"
        end
        if type(value.meta) ~= "table" or type(value.registry) ~= "table" then
            return nil, "captured registry entry " .. tostring(index) .. " has no typed metadata or ownership"
        end
        local entry_id = id :: string
        local entry: Entry = {id = entry_id, meta = value.meta :: {[string]: unknown}, registry = value.registry :: {[string]: unknown}}
        if out[entry_id] then return nil, "captured registry contains a duplicate entry" end
        out[entry_id] = entry
    end
    return out, nil
end

local function timestamp(entry: Entry): string
    if type(entry.meta) == "table" and type(entry.meta.timestamp) == "string" then return entry.meta.timestamp end
    return ""
end

local function result_row(part: unknown, id: string): {[string]: unknown}?
    if type(part) ~= "table" or type(part.migrations) ~= "table" then return nil end
    for _, raw in ipairs(part.migrations) do
        if type(raw) == "table" then
            local row = raw :: {[string]: unknown}
            if row.id == id and type(row.status) == "string" then return row end
        end
    end
    return nil
end

local function ledger(source: Source, target_db: string, id: string): (boolean?, string?)
    local applied, problem = source.is_applied(target_db, id)
    if type(applied) ~= "boolean" then return nil, problem or "migration ledger did not return a boolean" end
    return applied, nil
end

local function partial(operation: string, rows: {Row}, problem: string): (Result, string)
    return {operation = operation, rows = rows}, problem
end

type Planned = {id: string, target_db: string, module: string, entry: Entry}

local function plan(source: Source, request: Request): ({Planned}?, string?)
    if type(source) ~= "table" or type(source.runner) ~= "table" or type(source.runner.setup) ~= "function"
        or type(source.is_applied) ~= "function" then return nil, "migration execution source is incomplete" end
    local entries, entries_error = entry_map(source.entries)
    if not entries then return nil, entries_error end
    local admitted: {[string]: boolean} = {}
    for _, name in ipairs(request.components) do admitted[name] = true end
    local planned: {Planned} = {}
    for _, id in ipairs(request.entry_ids) do
        local entry = entries[id]
        if not entry then return nil, "captured registry does not contain migration " .. id end
        if type(entry.meta) ~= "table" or entry.meta.type ~= "migration" or type(entry.meta.target_db) ~= "string"
            or entry.meta.target_db == "" or #entry.meta.target_db > 256 then
            return nil, "entry is not a complete migration: " .. id
        end
        -- This is registry ownership, never package-authored metadata.
        local owner = type(entry.registry) == "table" and entry.registry.owner or nil
        if type(owner) ~= "string" or not admitted[owner] then
            return nil, "migration owner is outside the approved components: " .. id
        end
        planned[#planned + 1] = {id = id, target_db = entry.meta.target_db, module = owner, entry = entry}
    end
    table.sort(planned, function(a: Planned, b: Planned): boolean
        if a.target_db ~= b.target_db then return a.target_db < b.target_db end
        local at, bt = timestamp(a.entry), timestamp(b.entry)
        if at ~= bt then return at < bt end
        return a.id < b.id
    end)
    return planned, nil
end

function M.execute(source: Source, raw: unknown): (Result?, string?)
    local request, request_error = M.decode(raw)
    if not request then return nil, request_error end
    local planned, plan_error = plan(source, request)
    if not planned then return nil, plan_error end
    local rows: {Row} = {}
    local index = 1
    while index <= #planned do
        local target_db = planned[index].target_db
        local group: {Planned} = {}
        while index <= #planned and planned[index].target_db == target_db do
            group[#group + 1] = planned[index]
            index = index + 1
        end
        local setup_ok, runner, setup_error = pcall(function() return source.runner.setup(target_db) end)
        if not setup_ok then return partial(request.operation, rows, "create migration runner for " .. target_db .. ": " .. tostring(runner)) end
        if type(runner) ~= "table" or setup_error then
            return partial(request.operation, rows, "create migration runner for " .. target_db .. ": " .. tostring(setup_error or "invalid runner"))
        end
        local database = runner :: DatabaseRunner
        if type(database.run_next) ~= "function" or type(database.rollback) ~= "function" then
            return partial(request.operation, rows, "create migration runner for " .. target_db .. ": invalid runner")
        end
        if request.operation == "up" then
            for _, item in ipairs(group) do
                local applied, ledger_error = ledger(source, target_db, item.id)
                if applied == nil then return partial(request.operation, rows, ledger_error or "read migration ledger") end
                if applied then
                    rows[#rows + 1] = {id = item.id, target_db = target_db, module = item.module,
                        status = "skipped", reason = "already_applied"}
                else
                    local ok, part = pcall(function() return database:run_next({allowed_ids = {item.id}}) end)
                    if not ok then return partial(request.operation, rows, "run migration " .. item.id .. ": " .. tostring(part)) end
                    local row = result_row(part, item.id)
                    if not row then return partial(request.operation, rows, "migration not discovered by runner: " .. item.id) end
                    if row.status ~= "applied" then return partial(request.operation, rows, "migration did not apply: " .. item.id) end
                    rows[#rows + 1] = {id = item.id, target_db = target_db, module = item.module, status = "applied"}
                end
            end
        else
            local wanted: {string} = {}
            local by_id: {[string]: Planned} = {}
            for _, item in ipairs(group) do
                local applied, ledger_error = ledger(source, target_db, item.id)
                if applied == nil then return partial(request.operation, rows, ledger_error or "read migration ledger") end
                if applied then wanted[#wanted + 1] = item.id; by_id[item.id] = item
                else rows[#rows + 1] = {id = item.id, target_db = target_db, module = item.module, status = "skipped", reason = "not_applied"} end
            end
            if #wanted > 0 then
                local ok, part = pcall(function() return database:rollback({count = #wanted, allowed_ids = wanted}) end)
                if not ok then return partial(request.operation, rows, "rollback migrations for " .. target_db .. ": " .. tostring(part)) end
                for _, id in ipairs(wanted) do
                    local row = result_row(part, id)
                    if not row then return partial(request.operation, rows, "migration not discovered by runner: " .. id) end
                    if row.status ~= "reverted" then return partial(request.operation, rows, "migration did not revert: " .. id) end
                    local item = by_id[id]
                    rows[#rows + 1] = {id = id, target_db = target_db, module = item.module, status = "reverted"}
                end
            end
        end
    end
    return {operation = request.operation, rows = rows}, nil
end

return M
