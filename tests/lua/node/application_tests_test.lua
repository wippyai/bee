-- MIT. Application tests follow registry ownership and explicit associations.
local test = require("test")
local application_tests = require("application_tests")
type Object = {[string]: unknown}
local APP = "app.progress:app"
local function app(id: string, owner: string): Object
    return {id = id, kind = "process.lua", meta = {type = "bee.app"}, registry = {owner = owner}}
end
local function entry(id: string, owner: string, association: string?): Object
    return {id = id, kind = "function.lua", meta = {type = "app_test", application = association}, registry = {owner = owner}}
end
local function define_tests()
    test.describe("application test discovery", function()
        test.it("finds Hub package tests across namespaces and excludes unrelated same-namespace entries", function()
            local found = assert(application_tests.select({app(APP, "bee/progress"),
                entry("progress.checks:database", "bee/progress", nil),
                entry("app.progress:foreign", "other/package", nil)}, APP, {}))
            test.eq(#found, 1)
            test.eq(found[1].id, "progress.checks:database")
        end)
        test.it("requires explicit association when a package carries multiple applications", function()
            local found = assert(application_tests.select({app(APP, "bee/progress"),
                app("progress.admin:app", "bee/progress"), entry("checks:mine", "bee/progress", APP),
                entry("checks:ambiguous", "bee/progress", nil),
                entry("checks:other", "bee/progress", "progress.admin:app")}, APP, {}))
            test.eq(#found, 1)
            test.eq(found[1].id, "checks:mine")
        end)
        test.it("refuses an association declared by another package", function()
            local found = assert(application_tests.select({app(APP, "bee/progress"),
                entry("checks:forged", "other/package", APP)}, APP, {}))
            test.eq(#found, 0)
        end)
        test.it("uses the admitted overlay membership when registry ownership is empty", function()
            local found = assert(application_tests.select({app(APP, ""),
                entry("checks:owned", "", nil), entry("app.progress:foreign", "", APP)}, APP,
                {[APP] = true, ["checks:owned"] = true}))
            test.eq(#found, 1)
            test.eq(found[1].id, "checks:owned")
        end)
        test.it("never infers association from a namespace without registry provenance", function()
            local found = assert(application_tests.select({app(APP, ""), entry("app.progress:test", "", nil)}, APP, {}))
            test.eq(#found, 0)
        end)
    end)
end
return test.run_cases(define_tests)
