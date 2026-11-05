-- MIT. The approvals inbox review lines: a request's proposal payload as
-- bounded key and value lines, the permission lines of an install or lease
-- approval, and the install card the person reads.
local json = require("json")
local bounds = require("bounds")
local glyphs = require("glyphs")
local wire = require("wire")
local M = {}
M.MAX_PAYLOAD_LINES = 24
type Object = wire.Object
type ApprovalView = wire.ApprovalView
-- payload_lines: a proposal payload as bounded key and value lines, in
-- key order; never interpreted.
function M.payload_lines(value: unknown): {string}
    local view = wire.decode_view(value)
    if not view then return {} end
    local lines: {string} = {}
    local payload = view.proposal.payload
    local keys: {string} = {}
    for key in pairs(payload) do keys[#keys + 1] = tostring(key) end
    table.sort(keys)
    for _, key in ipairs(keys) do
        if #lines >= M.MAX_PAYLOAD_LINES then break end
        local item = payload[key]
        local shown: string
        if type(item) == "table" then
            local encoded = json.encode(item)
            shown = encoded and tostring(encoded) or "{…}"
        else
            shown = tostring(item)
        end
        lines[#lines + 1] = wire.text(key, 40) .. ": " .. wire.text(shown, wire.LINE_LIMIT)
    end
    return lines
end
local MAX_REVIEW_ITEMS = 128
type Review = {capabilities: {string}, changes: {string}, migrations: {Object}, replaces: {string}}

local function review_strings(raw: unknown, label: string): ({string}?, string?)
    local result: {string} = {}
    if raw == nil then return result, nil end
    local rows, rows_error = bounds.array(raw, MAX_REVIEW_ITEMS, label)
    if not rows then return nil, rows_error end
    for index, row in ipairs(rows) do
        if type(row) ~= "string" then return nil, label .. " item " .. tostring(index) .. " must be text" end
        result[index] = row
    end
    return result, nil
end

local function review_migrations(raw: unknown): ({Object}?, string?)
    local result: {Object} = {}
    if raw == nil then return result, nil end
    local rows, rows_error = bounds.array(raw, MAX_REVIEW_ITEMS, "migrations")
    if not rows then return nil, rows_error end
    for index, row in ipairs(rows) do
        local migration = bounds.object(row)
        if not migration then return nil, "migrations item " .. tostring(index) .. " must be an object" end
        result[index] = migration
    end
    return result, nil
end

-- The lists an install proposal shows the person, decoded once for the
-- summary and the card; a malformed list is an error the renderers show.
local function review(payload: Object): (Review?, string?)
    local capabilities, capabilities_error = review_strings(payload.resolved_capabilities, "resolved_capabilities")
    if not capabilities then return nil, capabilities_error end
    local changes, changes_error = review_strings(payload.permission_changes, "permission_changes")
    if not changes then return nil, changes_error end
    local migrations, migrations_error = review_migrations(payload.migrations)
    if not migrations then return nil, migrations_error end
    local replaces, replaces_error = review_strings(payload.replaces, "replaces")
    if not replaces then return nil, replaces_error end
    return {capabilities = capabilities, changes = changes, migrations = migrations, replaces = replaces}, nil
end

function M.permission_lines(value: unknown): {string}
    local view = wire.decode_view(value)
    if not view then return {} end
    local payload = view.proposal.payload
    local lines: {string} = {}
    -- A lease approval states its terms from the typed values the lease is
    -- stored with, ahead of the ceiling: what it covers, how long it lasts and
    -- when that starts, and how many applies it allows. The request's own
    -- expiry is a different deadline and is shown apart.
    if view.proposal.ref == "bee.gov:grant-lease" then
        local ttl, max = bounds.count(payload.ttl_seconds), bounds.count(payload.max_applies)
        local target = wire.text(payload.title or payload.target, wire.LINE_LIMIT)
        lines[#lines + 1] = "App updates: " .. (target:match("([^:]+)$") or target)
        if ttl and ttl > 0 then
            local function count(amount: integer, unit: string): string return tostring(amount) .. " " .. unit .. (amount == 1 and "" or "s") end
            local words = ttl % 86400 == 0 and count(ttl // 86400, "day") or (ttl % 3600 == 0 and count(ttl // 3600, "hour")
                or (ttl % 60 == 0 and count(ttl // 60, "minute") or count(ttl, "second")))
            lines[#lines + 1] = "Lasts: " .. words .. " from the moment it is granted (not this request's expiry)"
        else
            lines[#lines + 1] = "Lasts: no expiry"
        end
        lines[#lines + 1] = max and max > 0 and ("Maximum updates: " .. tostring(max)) or "Maximum updates: unlimited"
    end
    -- A lease review renders complete text; the proposal itself is bounded to 8 KiB.
    local limit = view.proposal.ref == "bee.gov:grant-lease" and 8192 or wire.LINE_LIMIT
    local function append(rows: {string}, prefix: string)
        for _, value in ipairs(rows) do
            if #lines >= M.MAX_PAYLOAD_LINES then break end
            lines[#lines + 1] = prefix .. wire.text(value, limit)
        end
    end
    local shown, review_error = review(payload)
    if not shown then
        lines[#lines + 1] = "Review unavailable: " .. wire.text(review_error, wire.LINE_LIMIT)
        return lines
    end
    if view.proposal.ref ~= "bee.gov:grant-lease" then append(shown.changes, "Change: ") end
    append(shown.capabilities, "Allows: ")
    -- A migration changes the application's database for good; the person
    -- sees each one the installation runs before approving it.
    for _, row in ipairs(shown.migrations) do
        if #lines >= M.MAX_PAYLOAD_LINES then break end
        lines[#lines + 1] = "Migration: " .. wire.text(row.id, 160) .. " on " .. wire.text(row.target_db, 160)
            .. ", changes the database for good"
    end
    return lines
end
-- One section of the install card: its heading and its statements.
type CardSection = {heading: string, lines: {string}}
-- The install question as the person reads it: what is installed, who made it
-- and where it came from, then each fact once, then its scope.
type Card = {glyph: string, title: string, maker: string?, sections: {CardSection}, scope: string}

-- The word after the last colon of a registry id: a migration's short name.
local function short(id: string): string
    return id:match("([^:]+)$") or id
end

-- card reads an install question into the lines it shows, or nil for any
-- other request. Each statement appears once; "Now also" appears only for an
-- upgrade, where it is what the new version adds to the grant already held.
function M.card(value: unknown): Card?
    local view = wire.decode_view(value)
    if not view or view.proposal.ref ~= "bee.gov:establish-overlay" then return nil end
    local payload = view.proposal.payload
    if payload.title == nil and payload.source_workspace == nil then return nil end
    local name = wire.text(payload.title or payload.source_workspace, 80)
    local kind = payload.subject == "driver"
    local self_edit = payload.subject == "self_edit"
    local title = (self_edit and "Change Bee's " or ("Install " .. (kind and "driver " or ""))) .. name .. " " .. wire.text(payload.version, 40)
    local maker = type(payload.maker) == "string" and wire.text(payload.maker, 160) or nil
    local sections: {CardSection} = {}
    local can: {string} = {}
    local shown, review_error = review(payload)
    if not shown then
        return {glyph = kind and glyphs.driver or glyphs.app, title = title, maker = maker,
            sections = {{heading = "Review unavailable", lines = {wire.text(review_error, wire.LINE_LIMIT)}}},
            scope = "For this version in this workspace."}
    end
    for _, raw in ipairs(shown.capabilities) do can[#can + 1] = glyphs.capability .. " " .. wire.text(raw, wire.LINE_LIMIT) end
    if self_edit then
        local replaced: {string} = {}
        for _, id in ipairs(shown.replaces) do replaced[#replaced + 1] = glyphs.capability .. " " .. wire.text(id, wire.LINE_LIMIT) end
        local more = bounds.count(payload.replaces_more)
        if more and more > 0 then replaced[#replaced + 1] = glyphs.capability .. " and " .. tostring(more) .. " more" end
        sections[#sections + 1] = {heading = "It replaces part of Bee", lines = replaced}
        if #can > 0 then sections[#sections + 1] = {heading = "It can", lines = can} end
    else
        if #can == 0 then can[1] = glyphs.capability .. " nothing beyond its own screen" end
        sections[#sections + 1] = {heading = "It can", lines = can}
    end
    local data: {string} = {}
    local databases: {string} = {}
    local named: {[string]: {string}} = {}
    for _, row in ipairs(shown.migrations) do
        local target = wire.text(row.target_db, 80)
        if not named[target] then named[target] = {}; databases[#databases + 1] = target end
        named[target][#named[target] + 1] = short(wire.text(row.id, 160))
    end
    for _, target in ipairs(databases) do
        data[#data + 1] = glyphs.capability .. " changes the \"" .. target .. "\" database ("
            .. table.concat(named[target], ", ") .. ") — this stays after removal"
    end
    if #data > 0 then sections[#sections + 1] = {heading = "It changes your data", lines = data} end
    if payload.grant_predecessor_digest ~= nil then
        local now: {string} = {}
        for _, raw in ipairs(shown.changes) do
            local line = wire.text(raw, wire.LINE_LIMIT)
            now[#now + 1] = glyphs.capability .. " " .. (line:gsub("^added: ", ""))
        end
        if #now > 0 then sections[#sections + 1] = {heading = "Now also", lines = now} end
    end
    return {glyph = kind and glyphs.driver or glyphs.app, title = title, maker = maker, sections = sections,
        scope = "For this version in this workspace."}
end

return M
