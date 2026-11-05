-- MIT. Stored id rewrites that component migrations share: the retired ids
-- a stored record can still name, the rewrite of ids held in JSON arrays,
-- and the fence that makes replicas reread a rewritten sync feed.
local M = {}

local RETIRED_TOOLS: {[string]: string} = {
    ["bee.gov.binding:overlay_call"] = "bee.gov.traits:overlay_call",
    ["bee.gov.binding:delivery_call"] = "bee.gov.traits:delivery_call",
    ["bee.node.binding:tests_call"] = "bee.gov.traits:tests_call",
    ["bee.hub.binding:call"] = "bee.hub.traits:call",
    ["bee.docs.binding:call"] = "bee.docs.traits:call",
}
M.RETIRED_TOOLS = RETIRED_TOOLS

local DRIVERS = {"agy", "claude", "codex", "grok", "muse", "opencode"}

type Target = {table: string, column: string, where: string?, columns: {string}?}
-- arrays: nested JSON array paths, each relative to an element of the one before.
-- field: the object field that holds the id; absent, the element is the id.
type Path = {arrays: {string}, field: string?}
type Row = {[string]: unknown}
type Feed = {owner: string, feed: string}

-- The bee.driver.<provider> entry a built-in driver moved to bee.drivers.<provider>.
function M.driver_entry(provider: string, name: string): (string, string)
    return "bee.driver." .. provider .. "." .. name, "bee.drivers." .. provider .. "." .. name
end

function M.driver_bindings(): {[string]: string}
    local moves: {[string]: string} = {}
    for _, provider in ipairs(DRIVERS) do
        local old, new = M.driver_entry(provider, "binding:binding")
        moves[old] = new
    end
    return moves
end

-- The tool selections a saved profile holds under prefix.
function M.selection_paths(prefix: string): {Path}
    return {
        {arrays = {prefix .. ".bee.mcp"}, field = "tool"},
        {arrays = {prefix .. ".mcp_tools"}},
        {arrays = {prefix .. ".draft.bee.mcp"}, field = "tool"},
        {arrays = {prefix .. ".draft.mcp_tools"}},
    }
end

local function select_statement(target: Target, path: Path): string
    local sources = {"t." .. target.column}
    local joins: {string} = {}
    local conditions: {string} = {target.where or "1"}
    local location = "'" .. path.arrays[1] .. "['"
    for index, array in ipairs(path.arrays) do
        local alias = "j" .. index
        local source = index == 1 and sources[1] or ("CASE WHEN j" .. (index - 1) .. ".type = 'object' THEN j" .. (index - 1) .. ".value ELSE '{}' END")
        joins[#joins + 1] = "json_each(" .. source .. ", '" .. array .. "') " .. alias
        conditions[#conditions + 1] = "typeof(" .. alias .. ".key) = 'integer'"
        if index > 1 then location = location .. " || '" .. array:sub(2) .. "['" end
        location = location .. " || " .. alias .. ".key || ']'"
    end
    local last = "j" .. #path.arrays
    if path.field then
        location = location:sub(1, -2) .. "." .. path.field .. "'"
        conditions[#conditions + 1] = last .. ".type = 'object' AND CASE WHEN " .. last .. ".type = 'object' THEN json_extract(" .. last .. ".value, '$." .. path.field .. "') END = ?1"
    else
        conditions[#conditions + 1] = last .. ".type = 'text' AND " .. last .. ".value = ?1"
    end
    local selected = {"t.rowid AS row_id", location .. " AS path"}
    for _, column in ipairs(target.columns or {}) do selected[#selected + 1] = "t." .. column end
    return "SELECT " .. table.concat(selected, ", ") .. " FROM " .. target.table .. " t, " .. table.concat(joins, ", ") .. " WHERE " .. table.concat(conditions, " AND ")
end

-- Rewrites every id that moves names at paths in target's column and returns
-- each rewritten row once, carrying its row_id and target's columns.
function M.ids(db: sql.DB, target: Target, paths: {Path}, moves: {[string]: string}): ({Row}?, string?)
    local rewritten: {Row} = {}
    local seen: {[unknown]: boolean} = {}
    local update = "UPDATE " .. target.table .. " SET " .. target.column .. " = json_set(" .. target.column .. ", ?, ?) WHERE rowid = ?"
    for _, path in ipairs(paths) do
        local statement = select_statement(target, path)
        for old, new in pairs(moves) do
            local rows, query_error = db:query(statement, {old})
            if not rows then return nil, tostring(query_error) end
            for _, row in ipairs(rows) do
                local _, update_error = db:execute(update, {row.path, new, row.row_id})
                if update_error then return nil, tostring(update_error) end
                if not seen[row.row_id] then
                    seen[row.row_id] = true
                    rewritten[#rewritten + 1] = row
                end
            end
        end
    end
    return rewritten, nil
end

-- Advances each rewritten sync feed past the entries its replicas hold, so
-- they reread it from the start.
function M.fence_feeds(db: sql.DB, feeds: {[string]: Feed}): string?
    for _, item in pairs(feeds) do
        local _, err = db:execute("UPDATE bee_sync_feeds SET head_sequence = head_sequence + 1, earliest_sequence = head_sequence + 2 WHERE owner_id = ? AND feed = ?", {item.owner, item.feed})
        if err then return tostring(err) end
    end
    return nil
end

return M
