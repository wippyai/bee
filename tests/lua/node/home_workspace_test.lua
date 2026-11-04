-- MIT. The folder's own workspace follows the folder: a moved folder keeps
-- the workspace its sessions, profiles and applications are kept in.
local test = require("test")
local sql = require("sql")
local workspaces = require("workspaces")

local DATABASE = "bee.tests.node:home_workspace_db"

local function reset(rows: {{string}})
    local db = assert(sql.get(DATABASE))
    for _, statement in ipairs({
        "DROP TABLE IF EXISTS bee_node_workspaces",
        "DROP TABLE IF EXISTS bee_node_settings",
        "CREATE TABLE bee_node_workspaces (id TEXT PRIMARY KEY, path TEXT NOT NULL UNIQUE, label TEXT NOT NULL, created_at TEXT NOT NULL)",
        "CREATE TABLE bee_node_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
    }) do assert(db:execute(statement)) end
    for _, row in ipairs(rows) do
        assert(db:execute("INSERT INTO bee_node_workspaces (id, path, label, created_at) VALUES (?, ?, ?, ?)", row))
    end
    db:release()
end

local function paths(): {[string]: string}
    local db = assert(sql.get(DATABASE))
    local rows = assert(db:query("SELECT id, path FROM bee_node_workspaces"))
    db:release()
    local result: {[string]: string} = {}
    for _, row in ipairs(rows) do result[tostring(row.id)] = tostring(row.path) end
    return result
end

local function define_tests()
    test.describe("home workspace", function()
        test.before_each(function() workspaces.DB = DATABASE end)

        test.it("is the folder's workspace while the folder stays", function()
            reset({{"home", "/work/app", "app", "2026-10-01T00:00:00Z"}, {"other", "/work/other", "other", "2026-09-01T00:00:00Z"}})
            local home = assert(workspaces.follow("/work/app"))
            test.eq(home.id, "home")
            test.eq(paths().other, "/work/other")
        end)

        test.it("moves with the folder and keeps its identity and label", function()
            reset({{"home", "/work/app", "app", "2026-10-01T00:00:00Z"}})
            test.eq(assert(workspaces.follow("/work/app")).id, "home")
            local moved = assert(workspaces.follow("/elsewhere/renamed"))
            test.eq(moved.id, "home")
            test.eq(moved.path, "/elsewhere/renamed")
            test.eq(moved.label, "app")
            test.eq(assert(workspaces.follow("/again/there")).id, "home", "the recorded home moves every time")
        end)

        test.it("is the folder's first workspace when state arrives from a folder moved earlier", function()
            reset({{"later", "/work/added", "added", "2026-10-05T00:00:00Z"}, {"first", "/old/app", "app", "2026-10-01T00:00:00Z"}})
            local home = assert(workspaces.follow("/new/app"))
            test.eq(home.id, "first")
            test.eq(paths().first, "/new/app")
            test.eq(paths().later, "/work/added")
        end)

        test.it("is created for a folder without workspaces", function()
            reset({})
            local home = assert(workspaces.follow("/work/fresh/"))
            test.eq(home.path, "/work/fresh")
            test.eq(home.label, "fresh")
            test.eq(assert(workspaces.follow("/work/fresh")).id, home.id)
        end)

        test.it("refuses a move onto a folder another workspace holds", function()
            reset({{"home", "/work/app", "app", "2026-10-01T00:00:00Z"}, {"other", "/work/other", "other", "2026-10-02T00:00:00Z"}})
            assert(workspaces.follow("/work/app"))
            local home, err = workspaces.follow("/work/other")
            test.is_nil(home)
            test.contains(tostring(err), "/work/other")
            test.eq(paths().home, "/work/app")
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}
