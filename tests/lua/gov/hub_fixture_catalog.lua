-- MIT. Immutable fixture catalog with application metadata and capabilities.
local artifact = require("artifact")
local requirements = require("requirements")
local graph = require("graph")
local inspection = require("inspection")
local M = {}
type Object = {[string]: unknown}
local NS = "app.progress"
local ACCESS = [[
local funcs = require("funcs")
local sql = require("sql")
local M = {}
function M.open(): sql.DB
    local result, problem = funcs.call("bee.gov.binding:granted_resources", {})
    assert(not problem, tostring(problem))
    assert(result.ok, "database grant is absent")
    return assert(sql.get(result.value.databases.progress))
end
return M
]]
local TOOL = [[
local access = require("access")
local function run(_arguments: unknown): {[string]: unknown}
    local db = access.open()
    local rows, problem = db:query("SELECT version FROM evidence ORDER BY version")
    db:release()
    assert(not problem, tostring(problem))
    return {ok = true, value = {migrations = rows}, error = nil}
end
return {run = run}
]]
local TEST = [[
local test = require("test")
local access = require("access")
local function define_tests()
    test.describe("progress database", function()
        test.it("sees both migrations under the application grant", function()
            local db = access.open()
            local rows, problem = db:query("SELECT version FROM evidence ORDER BY version")
            db:release()
            assert(not problem, tostring(problem))
            test.eq(#assert(rows), 2)
            test.eq(tonumber(rows[1].version), 1)
            test.eq(tonumber(rows[2].version), 2)
        end)
    end)
end
return test.run_cases(define_tests)
]]
local function migration(sql: string): string
    return [[return require("migration").define(function()
        migration("Progress schema", function()
            database("sqlite", function()
                up(function(db)
                    local _, problem = db:execute(]] .. string.format("%q", sql) .. [[)
                    assert(not problem, tostring(problem))
                end)
            end)
        end)
    end)]]
end
function M.entries(): {inspection.Entry}
    local entries: {inspection.Entry} = {
        {id = NS .. ":definition", kind = "ns.definition", meta = {title = "Progress"}, data = {}},
        {id = NS .. ":app", kind = "process.lua", meta = {type = "bee.app", application = {
            api_version = 1, title = "Progress", lifetime = "view", revision = "1", instance_policy = "singleton",
            restart_policy = "never", menus = {"bee.shell:apps_menu"}}},
            data = {source = 'local process = require("process")\nlocal function main() process.events():receive() end\nreturn {main = main}',
                method = "main", modules = {"process"}}},
        {id = NS .. ":access", kind = "library.lua", meta = {}, data = {source = ACCESS, modules = {"funcs", "sql"}}},
        {id = NS .. ":database", kind = "ns.requirement", meta = {value_kind = "security.policy", capability = "app.database",
            parameters = {name = "progress"}, reason = "Keep tasks"},
            data = {targets = {{entry = NS .. ":app", path = ".security.policies +="}}}},
    }
    local tools: {string} = {}
    for _, name in ipairs({"allocate", "assign", "create", "get", "report", "state", "tree", "updates"}) do
        local id = NS .. ":tool_" .. name
        tools[#tools + 1] = id
        entries[#entries + 1] = {id = id, kind = "function.lua", meta = {type = "tool", llm_alias = "progress_" .. name,
            llm_description = "Read progress migration evidence", input_schema = '{"type":"object","additionalProperties":false}'},
            data = {source = TOOL, method = "run", imports = {access = NS .. ":access"}}}
    end
    entries[#entries + 1] = {id = NS .. ":agent_tools", kind = "ns.requirement", meta = {value_kind = "security.policy",
        capability = "agent.tools", parameters = {tools = tools}, reason = "Offer progress tools"},
        data = {targets = {{entry = NS .. ":app", path = ".security.policies +="}}}}
    for ordinal, sql in ipairs({"CREATE TABLE evidence (version INTEGER NOT NULL)", "INSERT INTO evidence VALUES (1), (2)"}) do
        entries[#entries + 1] = {id = NS .. (ordinal == 1 and ":schema_migration" or ":evidence_migration"), kind = "function.lua",
            meta = {type = "migration", target_db = "progress", ordinal = ordinal,
                timestamp = "2026-10-0" .. tostring(ordinal) .. "T00:00:00Z"},
            data = {source = migration(sql), method = "run", imports = {migration = "wippy.migration:migration"}}}
    end
    for _, name in ipairs({"commands", "projection", "migration", "view"}) do
        entries[#entries + 1] = {id = NS .. ":" .. name .. "_test", kind = "function.lua",
            meta = {type = "app_test", suite = "progress"}, data = {source = TEST, method = "run",
                imports = {test = "wippy.test:test", access = NS .. ":access"}}}
    end
    return entries
end
function M.source(): graph.Source
    return {versions = function(component: string, _page: integer): ({string}?, boolean?, string?)
        if component ~= "bee/progress" then return nil, nil, "fixture catalog has no module " .. component end
        return {"1.0.0"}, false, nil
    end, artifact = function(component: string, version: string): (inspection.Inspection?, string?)
        if component ~= "bee/progress" or version ~= "1.0.0" then return nil, "fixture catalog has no version" end
        local entries = M.entries()
        local measured = assert(artifact.create(entries))
        return {component = component, version = version, digest = measured.digest, entries = entries,
            requirements = assert(requirements.read(entries, {})), next_offset = nil, eof = true,
            metadata = {type = "application"}}, nil
    end}
end
return M
