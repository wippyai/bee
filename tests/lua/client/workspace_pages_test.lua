-- MIT. The display's workspace pages accept only a bounded presenter query
-- and a well-formed catalog page.
local test = require("test")
local workspace_pages = require("workspace_pages")
local ID = string.rep("c", 32)
local function define_tests()
    test.describe("Display workspace pages", function()
        test.it("decodes presenter queries strictly", function()
            local query = workspace_pages.query({version = 1, op = "workspaces", request_id = "r1", label = "pro", after = "cursor"})
            test.eq(query and query.label, "pro")
            test.eq(query and query.after, "cursor")
            test.is_nil(workspace_pages.query({version = 1, op = "workspaces", request_id = ""}))
            test.is_nil(workspace_pages.query({version = 1, op = "workspaces", request_id = "r1", label = ""}))
            test.is_nil(workspace_pages.query({version = 1, op = "workspaces", request_id = "r1", root_ref = "bee:workspace_root"}))
        end)
        test.it("decodes a catalog page and keeps the folder's unnamed row", function()
            local page = workspace_pages.decode({ok = true, value = {items = {{workspace_id = ID, label = "", root_ref = "bee:workspace_root"}},
                next_after = "cursor-2"}})
            test.eq(page and #page.items, 1)
            test.eq(page and page.items[1].label, "")
            test.eq(page and page.next_after, "cursor-2")
            test.is_nil(workspace_pages.decode({ok = false, error = {code = "DENIED"}}))
            test.is_nil(workspace_pages.decode({ok = true, value = {items = {{workspace_id = "short", label = "x"}}}}))
            test.is_nil(workspace_pages.decode({ok = true, value = {items = {}, next_after = ""}}))
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}
