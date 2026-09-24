-- MIT. The node workspace catalog pages and searches thousands of rows along
-- its indexes, in a stable order, without reading rows it does not return.
local test = require("test")
local sql = require("sql")
local store = require("store")
local catalog = require("catalog")

local NODE = "bee.workspace.db:catalog_test"
local SCALE = 3000

type Row = {[string]: unknown}

local function transaction(work: (sql.Transaction) -> ())
    local db, open_error = store.database(NODE)
    if not db then error("open node database: " .. tostring(open_error)) end
    local tx, begin_error = db:begin()
    if not tx then db:release(); error("begin: " .. tostring(begin_error)) end
    local ok, failure = pcall(work, tx)
    if not ok then
        tx:rollback(); db:release()
        error(failure)
    end
    local _, commit_error = tx:commit()
    db:release()
    if commit_error then error("commit: " .. tostring(commit_error)) end
end

local function page(query: catalog.Query): catalog.Page
    local result: catalog.Page? = nil
    transaction(function(tx: sql.Transaction)
        local value, failure = catalog.page(tx, query)
        if not value then error(tostring(failure and failure.message)) end
        result = value
    end)
    if not result then error("no page") end
    return result
end

local function query(order: string, prefix: string, root_ref: string?, after: string?, limit: integer, state: string?): catalog.Query
    local cursor: catalog.Cursor? = nil
    if after then
        cursor = catalog.decode_cursor(after)
        if not cursor then error("invalid cursor " .. after) end
    end
    return {state = state or "active", order = order, prefix = prefix, root_ref = root_ref, after = cursor, limit = limit}
end

-- Every page of one query, following next_after until the catalog says done.
local function walk(order: string, prefix: string, root_ref: string?, limit: integer, state: string?): {catalog.Summary}
    local rows: {catalog.Summary} = {}
    local after: string? = nil
    local pages = 0
    repeat
        local current = page(query(order, prefix, root_ref, after, limit, state))
        for _, item in ipairs(current.items) do rows[#rows + 1] = item end
        after = current.next_after
        pages = pages + 1
        if pages > SCALE then error("paging did not end") end
    until not after
    return rows
end

local function plans(statement: catalog.Statement): {string}
    local details: {string} = {}
    transaction(function(tx: sql.Transaction)
        local rows, err = tx:query("EXPLAIN QUERY PLAN " .. statement.sql, statement.params)
        if err or not rows then error("explain: " .. tostring(err)) end
        for _, row in ipairs(rows) do details[#details + 1] = tostring((row :: Row).detail) end
    end)
    return details
end

local seeded = false
local function seed()
    if seeded then return end
    seeded = true
    transaction(function(tx: sql.Transaction)
        local _, err = tx:execute([[
WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n WHERE x < ?)
INSERT INTO workspaces (workspace_id, label, root_ref, subpath, state, created_at, last_used_at)
SELECT lower(hex(randomblob(16))), printf('Project %04d', x), 'bee.catalog.test:scale', printf('legacy/%04d', x),
    CASE WHEN x % 10 = 0 THEN 'archived' ELSE 'active' END,
    strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
FROM n]], {SCALE})
        if err then error("seed: " .. tostring(err)) end
        for _, definition in ipairs({
            {label = "legacy", root_ref = "bee.catalog.test:scale", subpath = "legacy"},
            {label = "legacy sibling", root_ref = "bee.catalog.test:scale", subpath = "legacy-old"},
            {label = "legacy backup", root_ref = "bee.catalog.test:scale", subpath = "legacy.bak"},
            {label = "Beehive", root_ref = "bee.catalog.test:scale", subpath = "hive"},
            {label = "beeline", root_ref = "bee.catalog.test:scale", subpath = "line"},
        }) do
            local row, failure = catalog.insert(tx, definition)
            if not row then error("insert: " .. tostring(failure and failure.message)) end
        end
    end)
end

local function define_tests()
    test.describe("Workspace catalog rows", function()
        test.it("lists every active workspace once, in label order, across pages", function()
            seed()
            local rows = walk("label", "", nil, 100)
            -- The seeded rows and the five named ones; a node database holds
            -- no folder row until the classic launch path opens the folder.
            local active = SCALE - SCALE / 10 + 5
            test.eq(#rows, active)
            local seen: {[string]: boolean} = {}
            for index, row in ipairs(rows) do
                test.is_nil(seen[row.workspace_id])
                seen[row.workspace_id] = true
                test.eq(row.state, "active")
                if index > 1 then
                    local previous = rows[index - 1]
                    local before, current = catalog.fold(previous.label), catalog.fold(row.label)
                    test.is_true(before < current or (before == current and previous.workspace_id < row.workspace_id))
                end
            end
            test.eq(#walk("label", "", nil, 100, "archived"), SCALE / 10)
        end)

        test.it("keeps its place when rows are added before the cursor", function()
            seed()
            local first = page(query("label", "project 1", nil, nil, 5))
            test.eq(#first.items, 5)
            test.eq(first.items[1].label, "Project 1001")
            transaction(function(tx: sql.Transaction)
                local row = catalog.insert(tx, {label = "Project 1000a", root_ref = "bee.catalog.test:scale", subpath = "late"})
                test.not_nil(row)
            end)
            local second = page(query("label", "project 1", nil, first.next_after, 2))
            test.eq(second.items[1].label, "Project 1006")
            test.eq(second.items[2].label, "Project 1007")
        end)

        test.it("finds labels by case-folded prefix", function()
            seed()
            local bees = walk("label", "BEE", nil, 1)
            test.eq(#bees, 2)
            test.eq(bees[1].label, "Beehive")
            test.eq(bees[2].label, "beeline")
            test.eq(#walk("label", "Project 00", nil, 7), 90)
            test.eq(#walk("label", "no such workspace", nil, 10), 0)
        end)

        test.it("finds folders by path prefix, segment by segment", function()
            seed()
            local legacy = walk("path", "legacy", "bee.catalog.test:scale", 250)
            test.eq(#legacy, 1 + SCALE - SCALE / 10)
            test.eq(legacy[1].subpath, "legacy")
            for index = 2, #legacy do
                test.eq(legacy[index].subpath:sub(1, 7), "legacy/")
                if index > 2 then test.is_true(legacy[index - 1].subpath < legacy[index].subpath) end
            end
            local one = walk("path", "legacy/0042", "bee.catalog.test:scale", 10)
            test.eq(#one, 1)
            test.eq(one[1].subpath, "legacy/0042")
            test.eq(#walk("path", "", "bee.catalog.test:scale", 500), SCALE - SCALE / 10 + 6)
            test.eq(#walk("path", "", "bee.catalog.test:elsewhere", 10), 0)
            test.eq(#walk("path", "legacy", "bee.catalog.test:scale", 1, "archived"), SCALE / 10)
        end)

        test.it("reads each page through an index without sorting or scanning", function()
            local cursor = catalog.encode_cursor({key = "project 0100", workspace_id = string.rep("a", 32)})
            local queries = {
                query("label", "", nil, nil, 50),
                query("label", "", nil, cursor, 50),
                query("label", "Proj", nil, cursor, 50),
                query("path", "legacy", "bee.catalog.test:scale", nil, 50),
                query("path", "legacy", "bee.catalog.test:scale", catalog.encode_cursor({key = "legacy/0100", workspace_id = string.rep("b", 32)}), 50),
                query("path", "", "bee.catalog.test:scale", nil, 50),
            }
            for _, value in ipairs(queries) do
                for _, statement in ipairs(catalog.statements(value)) do
                    local details = plans(statement)
                    local plan = table.concat(details, " | ")
                    if #details ~= 1 or not plan:find("SEARCH workspaces USING INDEX ", 1, true) or plan:find("TEMP B-TREE", 1, true) then
                        error("unindexed plan for " .. statement.sql .. ": " .. plan)
                    end
                end
            end
        end)

        test.it("walks one path under several roots in root order with a root-qualified cursor", function()
            transaction(function(tx: sql.Transaction)
                for _, definition in ipairs({
                    {label = "north", root_ref = "bee.catalog.test:north", subpath = "shared"},
                    {label = "north child", root_ref = "bee.catalog.test:north", subpath = "shared/one"},
                    {label = "south", root_ref = "bee.catalog.test:south", subpath = "shared"},
                    {label = "south sibling", root_ref = "bee.catalog.test:south", subpath = "shared-old"},
                }) do
                    local row, failure = catalog.insert(tx, definition)
                    if not row then error("insert: " .. tostring(failure and failure.message)) end
                end
            end)
            local rows: {catalog.Summary} = {}
            local after: string? = nil
            repeat
                local cursor: catalog.Cursor? = nil
                if after then cursor = catalog.decode_cursor(after) end
                local current = page({state = "active", order = "roots", prefix = "shared", root_ref = nil, after = cursor, limit = 1,
                    roots = {"bee.catalog.test:north", "bee.catalog.test:south", "bee.catalog.test:west"}})
                for _, item in ipairs(current.items) do rows[#rows + 1] = item end
                after = current.next_after
            until not after
            test.eq(#rows, 3)
            test.eq(rows[1].root_ref .. "/" .. rows[1].subpath, "bee.catalog.test:north/shared")
            test.eq(rows[2].root_ref .. "/" .. rows[2].subpath, "bee.catalog.test:north/shared/one")
            test.eq(rows[3].root_ref .. "/" .. rows[3].subpath, "bee.catalog.test:south/shared")
            local cursor = catalog.encode_cursor({key = "shared", workspace_id = string.rep("a", 32), root_ref = "bee.catalog.test:north"})
            for _, statement in ipairs(catalog.statements({state = "active", order = "roots", prefix = "shared", root_ref = nil,
                after = catalog.decode_cursor(cursor), limit = 5, roots = {"bee.catalog.test:north", "bee.catalog.test:south"}})) do
                local plan = table.concat(plans(statement), " | ")
                if not plan:find("SEARCH workspaces USING INDEX ", 1, true) or plan:find("TEMP B-TREE", 1, true) then
                    error("unindexed plan for " .. statement.sql .. ": " .. plan)
                end
            end
        end)

        test.it("refuses cursors it did not issue", function()
            test.is_nil(catalog.decode_cursor("not a cursor"))
            test.is_nil(catalog.decode_cursor(string.rep("a", 32) .. ":abc"))
            test.is_nil(catalog.decode_cursor(string.rep("g", 32) .. ":"))
            test.is_nil(catalog.decode_cursor(string.rep("a", 32) .. ":" .. string.rep("00", 1025)))
            local cursor = catalog.decode_cursor(catalog.encode_cursor({key = "näme/Ω", workspace_id = string.rep("c", 32)}))
            if not cursor then error("round trip") end
            test.eq(cursor.key, "näme/Ω")
            test.is_nil(cursor.root_ref)
            local rooted = catalog.decode_cursor(catalog.encode_cursor({key = "a", workspace_id = string.rep("c", 32), root_ref = "bee:root"}))
            test.eq(rooted and rooted.root_ref, "bee:root")
            test.is_nil(catalog.decode_cursor(string.rep("a", 32) .. ":61:" .. string.rep("62", 161)))
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}
