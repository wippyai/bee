-- MIT. Folder pages update the picker only after every row and cursor validate.
local test = require("test")
local picker = require("picker")
local caller = require("caller")
type Object = {[string]: unknown}

local function success(value: unknown): caller.Reply
    return {ok = true, error = nil, value = value, replayed = false}
end

local function define_tests()
    test.describe("Application folder picker reply boundary", function()
        test.it("rejects malformed roots without replacing the last complete list", function()
            local state = picker.new()
            picker.apply_roots(state, success({roots = {{root_ref = "bee.env:workspace_root", access = "write"}}}))
            test.eq(#state.roots, 1)

            picker.apply_roots(state, success({roots = {{root_ref = "bee.env:other_root", access = "read"},
                {root_ref = "bee.env:broken_root", access = "admin"}}}))
            test.eq(#state.roots, 1)
            test.eq(state.roots[1].root_ref, "bee.env:workspace_root")
            test.not_nil(state.error)
        end)

        test.it("rejects a malformed folder page as a whole and preserves its cursor", function()
            local state = picker.new()
            picker.apply_roots(state, success({roots = {{root_ref = "bee.env:workspace_root", access = "write"}}}))
            test.is_true(picker.open(state))
            picker.apply_folders(state, success({root_ref = "bee.env:workspace_root", path = "", access = "write",
                folders = {{name = "alpha"}}, next_after = "alpha"}))
            test.eq(#state.folders, 1)
            test.is_true(picker.forward(state))
            test.eq(state.cursor, "alpha")

            picker.apply_folders(state, success({root_ref = "bee.env:workspace_root", path = "", access = "write",
                folders = {{name = "beta"}, {name = "bad/name"}}, next_after = "beta"}))
            test.eq(#state.folders, 1)
            test.eq(state.folders[1].name, "alpha")
            test.eq(state.cursor, "alpha")
            test.eq(state.next_after, "alpha")
            test.not_nil(state.error)
        end)

        test.it("rejects non-list pages, extra row keys, and mismatched cursors", function()
            local state = picker.new()
            picker.apply_roots(state, success({roots = {{root_ref = "bee.env:workspace_root", access = "read"}}}))
            test.is_true(picker.open(state))
            local initial: Object = {root_ref = "bee.env:workspace_root", path = "", access = "read", folders = {}}
            local non_list: Object = {}
            for key, value in pairs(initial) do non_list[key] = value end
            non_list.folders = {first = {name = "hidden"}}
            picker.apply_folders(state, success(non_list))
            test.eq(#state.folders, 0)
            test.not_nil(state.error)

            local extra_row: Object = {}
            for key, value in pairs(initial) do extra_row[key] = value end
            extra_row.folders = {{name = "visible", unexpected = true}}
            picker.apply_folders(state, success(extra_row))
            test.eq(#state.folders, 0)

            local bad_cursor: Object = {}
            for key, value in pairs(initial) do bad_cursor[key] = value end
            bad_cursor.folders = {{name = "visible"}}
            bad_cursor.next_after = "another-folder"
            picker.apply_folders(state, success(bad_cursor))
            test.eq(#state.folders, 0)
            test.not_nil(state.error)
        end)
    end)
end

return test.run_cases(define_tests)
