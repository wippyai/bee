-- MIT. Verified workspace subroots and private-path exclusion for file grants.
local test = require("test")
local files = require("capability_files")

local OWNER = "bee.gov.apps:workspace-1.notes"
local APP = "app.notes:app"
-- The classic folder workspace and a workspace nested under the same root.
local CLASSIC = {root_ref = "bee.env:workspace_root", directory = ".", base = "project", subpath = ""}
local NESTED = {root_ref = "bee.env:workspace_root", directory = ".", base = "project", subpath = "projects/alpha"}

local function define_tests()
    test.describe("verified workspace file grants", function()
        test.it("accepts a narrow workspace subroot", function()
            local subpath = assert(files.verify_subpath("notes"))
            test.eq(subpath, "notes")
        end)
        test.it("refuses private paths and their ancestors", function()
            test.is_nil(files.verify_subpath(".wippy"))
            test.is_nil(files.verify_subpath(".wippy/app-db/main.db"))
            test.is_nil(files.verify_subpath("."))
            test.is_nil(files.verify_subpath(".."))
            test.is_nil(files.verify_subpath("notes/../.wippy"))
            test.is_nil(files.verify_subpath("/absolute"))
        end)
        test.it("derives a host-created read-only volume for reads", function()
            local volume = assert(files.volume(OWNER, CLASSIC, "notes", false))
            test.eq(volume.kind, "fs.directory")
            local config = volume.data :: {[string]: unknown}
            test.eq(config.directory, "notes")
            test.eq(config.base, "project")
            test.is_true(config.readonly)
            test.is_false(config.auto_init)
            test.is_true(volume.id:find("^bee%.gov%.grants:volume%.", 1) ~= nil)
            local writable = assert(files.volume(OWNER, CLASSIC, "notes", true))
            test.is_false((writable.data :: {[string]: unknown}).readonly)
            test.is_true((writable.data :: {[string]: unknown}).auto_init)
            test.eq(writable.id, volume.id)
        end)
        test.it("roots the volume at the workspace folder, not the node folder", function()
            local nested = assert(files.volume(OWNER, NESTED, "notes", false))
            test.eq((nested.data :: {[string]: unknown}).directory, "projects/alpha/notes")
            test.eq((nested.data :: {[string]: unknown}).base, "project")
            test.is_true(nested.id ~= (assert(files.volume(OWNER, CLASSIC, "notes", false))).id)
            local absolute = assert(files.volume(OWNER, {root_ref = "bee.env:shared_root", directory = "/srv/work",
                subpath = "alpha"}, "notes", false))
            test.eq((absolute.data :: {[string]: unknown}).directory, "/srv/work/alpha/notes")
            test.is_nil((absolute.data :: {[string]: unknown}).base)
            test.is_nil(files.volume(OWNER, {root_ref = "bee.env:workspace_root", directory = ".", base = "project",
                subpath = ".wippy/placement"}, "notes", false))
            test.is_nil(files.volume(OWNER, {root_ref = "bee.env:workspace_root", directory = "${env:bee:root}",
                base = "project", subpath = ""}, "notes", false))
            test.is_nil(files.volume(OWNER, {root_ref = "bee.env:workspace_root", directory = "../outside",
                base = "project", subpath = ""}, "notes", false))
            test.is_nil(files.volume(OWNER, {directory = ".", base = "project", subpath = ""}, "notes", false))
        end)
        test.it("derives an isolated database outside the readable tree", function()
            local database = assert(files.database(OWNER, "notes"))
            test.eq(database.kind, "db.sql.sqlite")
            test.is_true(((database.data :: {[string]: unknown}).file :: string):find("^%.wippy/app%-db/", 1) ~= nil)
            test.is_true(database.id:find("^bee%.gov%.grants:database%.", 1) ~= nil)
            test.is_nil(files.database(OWNER, "../escape"))
        end)
        test.it("names the exact policy actions for each grant", function()
            local read_policy = assert(files.file_policy(OWNER, CLASSIC, "notes", false, "bee.gov.grants:policy.read"))
            test.eq(read_policy.kind, "security.policy")
            local read_inner = (read_policy.data :: {[string]: unknown}).policy :: {[string]: unknown}
            local read_actions = read_inner.actions :: {string}
            local read_resources = read_inner.resources :: {string}
            test.eq(#read_actions, 2)
            test.eq(read_actions[1], "fs.get")
            test.eq(read_actions[2], "funcs.call")
            test.eq(#read_resources, 2)
            test.eq(read_resources[1], (assert(files.volume(OWNER, CLASSIC, "notes", false))).id)
            test.eq(read_resources[2], files.GRANTED_RESOURCES)
            local db_policy = assert(files.database_policy(OWNER, "notes", "bee.gov.grants:policy.db"))
            local db_inner = (db_policy.data :: {[string]: unknown}).policy :: {[string]: unknown}
            local db_actions = db_inner.actions :: {string}
            local db_resources = db_inner.resources :: {string}
            test.eq(#db_actions, 2)
            test.eq(db_actions[1], "db.get")
            test.eq(#db_resources, 2)
            test.eq(db_resources[1], (assert(files.database(OWNER, "notes"))).id)
            test.eq(db_resources[2], files.GRANTED_RESOURCES)
            test.is_nil(files.file_policy(OWNER, CLASSIC, ".wippy", false, "bee.gov.grants:policy.read"))
        end)
        test.it("keeps the volume identity stable for one owner and subpath", function()
            local first = assert(files.volume(OWNER, CLASSIC, "notes", false))
            local second = assert(files.volume(OWNER, CLASSIC, "shared", false))
            test.is_true(first.id ~= second.id)
            test.is_true((assert(files.database(OWNER, "notes"))).id ~= (assert(files.database(OWNER, "other"))).id)
        end)
    end)
end
return test.run_cases(define_tests)
