-- SPDX-License-Identifier: MIT
local registry = require("registry")
local sql = require("sql")
local hash = require("hash")
local canonical = require("canonical")
local bounds = require("bounds")
local sync = require("sync")
local transaction = require("transaction")
local protocol = require("protocol")
local migration = require("migration")
local driver_profile = require("driver_profile")

local M = {}
type Result = transaction.Result
type Request = protocol.Request
type Profile = protocol.Profile
type Stored = {profile_id: string, revision: integer, profile: Profile?, tombstone: boolean, migration_diagnostic: {[string]: unknown}?}

local FEED_PREFIX = "harness.profiles:"
local EVENT_TYPE = "harness.profile.changed"

local function failure(code: string, message: string, value: unknown?): Result
    return transaction.failure(code, message, value)
end

local function clean(result: Result): Result
    -- The generic sync envelope contains owner/feed authority. Never pass it
    -- through this public, profile-shaped boundary on an error path.
    if result.ok then return result end
    return failure(result.code or "INTERNAL", result.message or "profile operation failed")
end

local function identity(node: string, actor: string, workspace: string, key: string): (string?, string?)
    local encoded, encode_error = canonical.encode({node = node, actor = actor, workspace_id = workspace, idempotency_key = key})
    if not encoded then return nil, tostring(encode_error or "profile identity is not measurable") end
    local value, hash_error = hash.sha256(encoded)
    if not value or hash_error then return nil, tostring(hash_error or "profile identity cannot be measured") end
    return value, nil
end

local function feed(workspace: string): (string?, string?)
    local digest, hash_error = hash.sha256(workspace)
    if not digest or hash_error then return nil, tostring(hash_error or "workspace feed cannot be measured") end
    return FEED_PREFIX .. digest, nil
end

local function open(node: string): (sync.Store?, string?)
    return sync.open({owner = node, event_capacity = 128, receipt_capacity = 1024})
end

local function projection(value: unknown): (Stored?, Result?)
    local object = bounds.object(value)
    if not object then return nil, failure("INTERNAL", "profile projection is malformed") end
    local profile_id = bounds.id(object.key)
    local revision = bounds.count(object.revision)
    if not profile_id or not revision then return nil, failure("INTERNAL", "profile projection identity is malformed") end
    if type(object.tombstone) ~= "boolean" then return nil, failure("INTERNAL", "profile projection tombstone is malformed") end
    if object.tombstone then
        if object.value ~= nil then return nil, failure("INTERNAL", "profile tombstone contains a value") end
        return {profile_id = profile_id, revision = revision, profile = nil, tombstone = true}, nil
    end
    local stored = bounds.object(object.value)
    if stored and stored.schema_revision == migration.DIAGNOSTIC then
        return {profile_id = profile_id, revision = revision, profile = nil, tombstone = false, migration_diagnostic = stored}, nil
    end
    local profile, profile_error = protocol.profile(object.value)
    if not profile then return nil, failure("INTERNAL", profile_error or "stored profile is malformed") end
    return {profile_id = profile_id, revision = revision, profile = profile, tombstone = false}, nil
end

local function reply(input: Request, profile_id: string, revision: integer, profile: Profile?, tombstone: boolean, diagnostic: {[string]: unknown}?): {[string]: unknown}
    local value: {[string]: unknown} = {workspace_id = input.workspace_id, profile_id = profile_id, revision = revision, tombstone = tombstone, migration_diagnostic = diagnostic}
    if not tombstone then value.profile = profile end
    return value
end

local function append(store: sync.Store, tx: sql.Transaction, input: Request, node: string, actor: string, feed_name: string,
    profile_id: string, profile: Profile?, tombstone: boolean): Result
    local event_id, identity_error = identity(node, actor, input.workspace_id, input.idempotency_key)
    if not event_id then return failure("INTERNAL", identity_error or "profile event identity failed") end
    return store:append_in(tx, {
        feed = feed_name, event_id = event_id, idempotency_key = event_id, event_type = EVENT_TYPE,
        projection_key = profile_id, projection_value = profile,
        payload = {schema_revision = protocol.SCHEMA, workspace_id = input.workspace_id,
            profile_id = profile_id, actor_id = actor, operation = input.operation, profile = profile,
            tombstone = tombstone}, tombstone = tombstone, expected_revision = input.expected_revision,
    })
end

local function get(store: sync.Store, tx: sql.Transaction, input: Request, feed_name: string): Result
    local result = store:projection_in(tx, feed_name, input.profile_id)
    if not result.ok then return clean(result) end
    if result.value == nil then return failure("NOT_FOUND", "profile does not exist") end
    local item, item_error = projection(result.value)
    if not item then return item_error or failure("INTERNAL", "decode profile") end
    return transaction.success(reply(input, item.profile_id, item.revision, item.profile, item.tombstone, item.migration_diagnostic), false)
end

local function list(store: sync.Store, tx: sql.Transaction, input: Request, feed_name: string): Result
    local collected: {Stored} = {}
    local cursor: integer? = nil
    local after: string? = nil
    repeat
        local result = store:snapshot_in(tx, feed_name, 64, after, cursor or input.expected_cursor)
        if not result.ok then
            if result.code == "RESET_REQUIRED" then
                local raw = bounds.object(result.value)
                return failure("RESET_REQUIRED", "profile cursor changed", {workspace_id = input.workspace_id,
                    cursor = raw and bounds.count(raw.cursor), reset_required = true})
            end
            return clean(result)
        end
        local page = bounds.object(result.value)
        local rows = page and bounds.array(page.items, 64)
        if not page or not rows then return failure("INTERNAL", "profile snapshot is malformed") end
        cursor = bounds.count(page.cursor)
        if not cursor then return failure("INTERNAL", "profile cursor is malformed") end
        for _, row in ipairs(rows) do
            local item, err = projection(row)
            if not item then return err or failure("INTERNAL", "profile row is invalid") end
            local profile = item.profile
            local diagnostic = item.migration_diagnostic
            local draft = diagnostic and bounds.object(diagnostic.draft)
            local definition_ref = profile and profile.definition_ref or (draft and bounds.id(draft.definition_ref))
            local name = profile and profile.name or (draft and bounds.line(draft.name, 80)) or item.profile_id
            if (not input.definition_ref or input.definition_ref == definition_ref)
                and (not input.query or name:lower():find(input.query:lower(), 1, true)) then collected[#collected + 1] = item end
        end
        if page.complete == true then after = nil
        else
            local next_key = bounds.id(page.next_key)
            if not next_key or (after and next_key <= after) then return failure("INTERNAL", "profile continuation does not advance") end
            after = next_key
        end
    until not after
    table.sort(collected, function(left: Stored, right: Stored): boolean
        local a, b = left.profile, right.profile
        local x, y = a and a.name:lower() or left.profile_id, b and b.name:lower() or right.profile_id
        if input.sort == "driver" then
            local first, second = a and a.driver_binding_ref or "", b and b.driver_binding_ref or ""
            if first ~= second then return first < second end
        end
        if x ~= y then return x < y end
        return left.profile_id < right.profile_id
    end)
    local start = 1
    if input.after_key ~= "" then
        local found = false
        for index, item in ipairs(collected) do
            if item.profile_id == input.after_key then start = index + 1; found = true; break end
        end
        if not found then return failure("INVALID_ARGUMENT", "profile continuation is outside this selection") end
    end
    local items: {{[string]: unknown}} = {}
    local last = math.floor(math.min(#collected, start + input.limit - 1))
    for index = start, last do
        local item = collected[index]
        items[#items + 1] = reply(input, item.profile_id, item.revision, item.profile, item.tombstone, item.migration_diagnostic)
    end
    local complete = last >= #collected
    return transaction.success({workspace_id = input.workspace_id, items = items, cursor = cursor,
        next_key = not complete and collected[last].profile_id or nil, complete = complete}, false)
end

local function put(store: sync.Store, tx: sql.Transaction, input: Request, node: string, actor: string, feed_name: string): Result
    local profile = input.profile
    if not profile then return failure("INVALID_ARGUMENT", "put profile is required") end
    local result = append(store, tx, input, node, actor, feed_name, input.profile_id, profile, false)
    if not result.ok then return clean(result) end
    local value = bounds.object(result.value)
    local revision = value and bounds.count(value.revision) or nil
    if not revision then return failure("INTERNAL", "profile append omitted revision") end
    return transaction.success(reply(input, input.profile_id, revision, profile, false), result.replayed)
end

local function remove(store: sync.Store, tx: sql.Transaction, input: Request, node: string, actor: string, feed_name: string): Result
    -- Keep this read and append in the same transaction. For an existing row,
    -- append_in checks receipts before CAS, allowing an old remove to replay
    -- after a later edit. A fresh remove of a tombstone is refused before it
    -- could append another tombstone.
    local current_result = store:projection_in(tx, feed_name, input.profile_id)
    if not current_result.ok then return clean(current_result) end
    if current_result.value == nil then return failure("NOT_FOUND", "profile does not exist") end
    local current, current_error = projection(current_result.value)
    if not current then return current_error or failure("INTERNAL", "decode profile") end
    if current.tombstone and input.expected_revision == current.revision then
        return failure("CONFLICT", "profile is already removed")
    end
    local result = append(store, tx, input, node, actor, feed_name, input.profile_id, nil, true)
    if not result.ok then return clean(result) end
    local value = bounds.object(result.value)
    local revision = value and bounds.count(value.revision) or nil
    if not revision then return failure("INTERNAL", "profile removal omitted revision") end
    return transaction.success(reply(input, input.profile_id, revision, nil, true), result.replayed)
end

function M.call(input: Request, node: string, actor: string, pinned: registry.Snapshot, validate: (registry.Snapshot, Profile) -> string?): Result
    local feed_name, feed_error = feed(input.workspace_id)
    if not feed_name then return failure("INTERNAL", feed_error or "profile feed failed") end
    local owner: string = node
    local caller: string = actor
    local selected_feed: string = feed_name
    local store, open_error = open(owner)
    if not store then return failure("UNAVAILABLE", open_error or "profile store unavailable") end
    local migrated = store:migrate(FEED_PREFIX, migration.ID, function(source: unknown): (unknown?, string?)
        return migration.convert(source, function(ref: string): string?
            local entry = pinned:get(ref)
            local data = entry and bounds.object(entry.data)
            return data and bounds.id(data.binding_ref) or nil
        end, function(profile: Profile): string? return validate(pinned, profile) end,
        function(ref: string, presentation: string?): migration.NativeHome?
            local entry = pinned:get(ref)
            local definition = entry and bounds.object(entry.data)
            local binding_ref = definition and bounds.id(definition.binding_ref)
            local binding = binding_ref and pinned:get(binding_ref)
            local meta = binding and bounds.object(binding.meta)
            local profiles_ref = meta and bounds.id(meta.profiles_ref)
            local declaration = profiles_ref and pinned:get(profiles_ref)
            local data = declaration and bounds.object(declaration.data)
            local driver = data and driver_profile.decode(data.driver)
            local profile_id = definition and bounds.id(presentation == "window" and definition.profile_id or definition.session_profile_id or definition.profile_id)
            local selected = driver and profile_id and driver_profile.find(driver, profile_id)
            if not selected then return nil end
            return selected.isolation_env.private_home and "private" or "machine"
        end), nil
    end)
    if not migrated.ok then store:close(); return clean(migrated) end
    local request: Request = {operation = input.operation, workspace_id = input.workspace_id,
        profile_id = input.profile_id, profile = input.profile, expected_revision = input.expected_revision,
        idempotency_key = input.idempotency_key, after_key = input.after_key,
        expected_cursor = input.expected_cursor, limit = input.limit, definition_ref = input.definition_ref,
        query = input.query, sort = input.sort}
    local result: Result
    if input.operation == "get" then
        result = transaction.read(store.db, "profiles", function(tx: sql.Transaction): Result return get(store, tx, request, selected_feed) end)
    elseif input.operation == "list" then
        result = transaction.read(store.db, "profiles", function(tx: sql.Transaction): Result return list(store, tx, request, selected_feed) end)
    elseif input.operation == "put" then
        result = transaction.write(store.db, "profiles", function(tx: sql.Transaction): Result return put(store, tx, request, owner, caller, selected_feed) end)
    else
        result = transaction.write(store.db, "profiles", function(tx: sql.Transaction): Result return remove(store, tx, request, owner, caller, selected_feed) end)
    end
    store:close()
    return result
end

return M
