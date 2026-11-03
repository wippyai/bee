-- MIT. Stored native deliveries carry the writable roots declaration of the
-- built-in descriptor that a saved Git roots adapter name stood for.
local test = require("test")
local sql = require("sql")
local funcs = require("funcs")
local json = require("json")
local canonical = require("canonical")
local descriptor = require("descriptor")
local DATABASE = "bee.tests.placement.native:writable_roots_migration_db"

local function migrate(id: string)
    local reply, err = funcs.call(id, {target_db = "bee:db", database_id = DATABASE, direction = "up", id = id})
    assert(not err, tostring(err))
    assert(type(reply) == "table" and reply.status ~= "error", tostring(type(reply) == "table" and reply.error))
end

local function stored(db: sql.DB, attempt_id: string): {[string]: unknown}
    local rows = assert(db:query("SELECT request_json FROM bee_placement_attempts WHERE attempt_id = ?", {attempt_id}))
    local decoded: unknown = json.decode(rows[1].request_json)
    return assert((decoded :: {[string]: unknown}).delivery :: {[string]: unknown})
end

local function define_tests()
    test.describe("Stored Git writable roots", function()
        test.it("replaces each adapter name with its descriptor's declaration and leaves other deliveries", function()
            local db = assert(sql.get(DATABASE))
            assert(db:execute("CREATE TABLE bee_placement_attempts (attempt_id TEXT PRIMARY KEY, request_json TEXT)"))
            for _, row in ipairs({{"codex", "codex_workspace_write"}, {"claude", "claude_add_dir"}, {"agy", "agy_add_dir"}}) do
                assert(db:execute("INSERT INTO bee_placement_attempts VALUES (?, ?)", {row[1], json.encode({attempt_id = row[1],
                    delivery = {arguments = {"--x"}, files = {}, git_writable_roots_adapter = row[2]}})}))
            end
            assert(db:execute("INSERT INTO bee_placement_attempts VALUES ('plain', ?)", {json.encode({attempt_id = "plain", delivery = {arguments = {}, files = {}}})}))
            migrate("bee.placement.native.migrations:writable_roots")
            for _, provider in ipairs({"codex", "claude", "agy"}) do
                local delivery = stored(db, provider)
                test.is_nil(delivery.git_writable_roots_adapter)
                test.eq((delivery.arguments :: {string})[1], "--x")
                local expected = assert(assert(descriptor.load("bee.drivers." .. provider .. ".descriptor:cli")).writable_roots)
                test.eq(assert(canonical.encode(delivery.git_writable_roots)), assert(canonical.encode(expected)), provider)
            end
            local plain = stored(db, "plain")
            test.is_nil(plain.git_writable_roots)
            db:release()
        end)
    end)
end
return test.run_cases(define_tests)
