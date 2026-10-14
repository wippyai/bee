local test = require("test")
local sql = require("sql")
local funcs = require("funcs")
local bounds = require("bounds")
local client = require("client")
local system = require("system")
local DATABASE = "bee.tests.node:app_namespace_db"
local APPS = {"help","library","processes","settings","terminal"}
local function migrate(name: string)
    local id = "bee.node.migrations:" .. name
    local result, err = funcs.call(id,{target_db = "bee:db",database_id = DATABASE,direction = "up",id = id})
    assert(not err,tostring(err))
    local reply = assert(bounds.object(result))
    assert(reply.status ~= "error",tostring(reply.error))
end
local function unit()
    test.describe("Application namespace migration",function()
        test.it("preserves saved instance data and unrelated definitions",function()
            for _, name in ipairs({"workspaces","settings","desktops","identities","instance_workspaces","test_runs"}) do migrate(name) end
            local db = assert(sql.get(DATABASE))
            local workspace = string.rep("a",32)
            assert(db:execute("INSERT INTO bee_node_workspaces VALUES (?, '/fixture', 'Fixture', '2026-10-01T00:00:00Z')",{workspace}))
            assert(db:execute("INSERT INTO bee_node_desktops VALUES ('desktop', ?, 'Desktop', '2026-10-01T00:00:00Z')",{workspace}))
            for _, name in ipairs(APPS) do
                assert(db:execute("INSERT INTO bee_node_instances(id,desktop_id,app,args,created_at,workspace_id) VALUES (?, 'desktop', ?, ?, '2026-10-01T00:00:00Z', ?)",{name,"bee.apps." .. name .. ":app",'{"retained":true}',workspace}))
            end
            assert(db:execute("INSERT INTO bee_node_instances(id,desktop_id,app,args,created_at,workspace_id) VALUES ('other', 'desktop', 'external:app', '{}', '2026-10-01T00:00:00Z', ?)",{workspace}))
            db:release()
            migrate("app_namespaces")
            migrate("app_namespaces")
            db = assert(sql.get(DATABASE))
            local rows = assert(db:query("SELECT * FROM bee_node_instances ORDER BY id"))
            test.eq(#rows,6)
            for _, row in ipairs(rows) do
                test.eq(row.app,row.id == "other" and "external:app" or "bee.apps." .. tostring(row.id) .. ".app:app")
                test.eq(row.args,row.id == "other" and "{}" or '{"retained":true}')
                test.eq(row.desktop_id,"desktop")
                test.eq(row.workspace_id,workspace)
                test.eq(row.created_at,"2026-10-01T00:00:00Z")
            end
            db:release()
        end)
    end)
end
local function restart()
    test.describe("Saved applications after a full restart",function()
        test.it("reopens each migrated definition with its saved identity",function()
            local state = assert(client.state(assert(client.call(assert(system.node.id()),"watch",{}))))
            for _, name in ipairs(APPS) do
                local found = false
                for _, item in ipairs(state.running) do
                    if item.id == "namespace-" .. name then
                        test.eq(item.app,"bee.apps." .. name .. ".app:app")
                        found = true
                    end
                end
                test.is_true(found,"saved " .. name .. " instance does not reopen")
            end
            assert(client.call(assert(system.node.id()),"leave",{}))
        end)
    end)
end
return {run = test.run_cases(unit),restart = test.run_cases(restart)}
