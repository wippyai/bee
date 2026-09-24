-- MIT. The Workspaces frame at 80x24, 120x36 and beyond: exact rows and
-- widths, every target inside the canvas, the identity, current state and
-- primary action at each size, the detail beside the list from 120x36 and
-- as its own page below it, and no terminal control from owner text.
local test = require("test")
local tty = require("tty")
local model = require("model")
local creation = require("creation")
local view = require("view")
local frame = require("frame")
local appearance = require("appearance")
local caller = require("caller")

type Object = {[string]: unknown}

local function ok(value: unknown): caller.Reply
    return {ok = true, error = nil, value = value, replayed = false}
end

local function plain(rows: {string}): {string}
    local result: {string} = {}
    for index, row in ipairs(rows) do result[index] = (row:gsub("\27%[[0-9;]*m", "")) end
    return result
end

local function find(rows: {string}, needle: string): integer?
    for index, row in ipairs(rows) do if row:find(needle, 1, true) then return index end end
    return nil
end

local function populated(): model.State
    local state = model.new()
    local items: {Object} = {}
    for index = 1, 30 do
        items[index] = {workspace_id = string.format("%032x", index), label = index == 2 and "Legacy billing\27[2J" or ("Project " .. tostring(index)),
            root_ref = "bee:workspace_root", subpath = "legacy/" .. tostring(index), state = "active",
            created_at = "2026-09-20T08:00:00.000Z", last_used_at = "2026-09-24T09:30:00.000Z"}
    end
    model.apply_page(state, ok({items = items, next_after = "cursor"}))
    model.move(state, 1)
    model.apply_inspect(state, state.selected, ok({live = true,
        applications = {{definition_id = "bee.settings:app", instance_id = "i-1", restart_policy = "automatic"}},
        extensions = {{binding = "bee:resources_workspace_extension", title = "Resources", total = 1, items = {{label = "project", detail = "bee:workspace_root · write"}}},
            {binding = "bee:gateway_workspace_extension", title = "Agent sessions", total = 0, items = {}}}}))
    model.apply_threads(state, state.selected, ok({threads = {{thread_id = "t-1", title = "Migrate billing", state = "open"}}}))
    return state
end

local function check(width: integer, height: integer, state: model.State, form: creation.Form?): {string}
    local drawn = view.draw(width, height, appearance.defaults(), state, 0, form)
    test.eq(#drawn.rows, height)
    for _, row in ipairs(drawn.rows) do
        test.eq(tty.text.width(row), width)
        local visible = row:gsub("\27%[[0-9;]*m", "")
        test.is_nil(visible:find("\27", 1, true))
    end
    for _, hit in ipairs(drawn.hits) do
        test.is_true(hit.x >= 1 and hit.y >= 1 and hit.x + hit.width - 1 <= width and hit.y + hit.height - 1 <= height)
    end
    return plain(drawn.rows)
end

local function define_tests()
    test.describe("Workspaces frame", function()
        test.it("fits every size class and strips owner text", function()
            local state = populated()
            for _, size in ipairs({{40, 12}, {80, 24}, {120, 36}, {160, 48}}) do
                local rows = check(size[1], size[2], state)
                test.contains(rows[1], "WORKSPACES")
            end
        end)

        test.it("shows the list, search and actions at 80x24 and the detail on its own page", function()
            local state = populated()
            local rows = check(80, 24, state)
            test.contains(rows[1], "Active · page 1 · 30 workspaces")
            test.contains(rows[2], "Active")
            test.contains(rows[2], "Archived")
            test.contains(rows[4], "Search")
            test.contains(rows[4], "label prefix, or /folder")
            test.not_nil(find(rows, "WORKSPACE"))
            local selected = find(rows, "›Legacy billing")
            test.not_nil(selected)
            test.contains(rows[23], "Enter Open")
            test.contains(rows[23], "A Archive")
            test.contains(rows[23], "N New")
            test.contains(rows[24], "↑↓ move · Enter open · N new · / search · S serve · A archive · Esc close")
            test.is_nil(find(rows, "APPLICATIONS"))
            model.show(state, true)
            local detail = check(80, 24, state)
            test.contains(detail[6], "LEGACY BILLING")
            test.contains(detail[6], "Served")
            test.not_nil(find(detail, "Folder   bee:workspace_root/legacy/2"))
            test.not_nil(find(detail, "APPLICATIONS"))
            test.not_nil(find(detail, "bee.settings:app"))
            test.contains(detail[23], "Esc Back")
        end)

        test.it("puts the detail beside the list at 120x36", function()
            local state = populated()
            local rows = check(120, 36, state)
            local listed = find(rows, "›Legacy billing")
            if not listed then error("selected row missing") end
            test.not_nil(find(rows, "LEGACY BILLING"))
            test.not_nil(find(rows, "THREADS"))
            test.not_nil(find(rows, "Migrate billing"))
            test.not_nil(find(rows, "RESOURCES"))
            test.not_nil(find(rows, "project · bee:workspace_root · write"))
            test.not_nil(find(rows, "AGENT SESSIONS"))
            local title = find(rows, "LEGACY BILLING") or 0
            test.is_true(rows[title]:find("LEGACY BILLING", 1, true) > 42)
            test.contains(rows[35], "Enter Open")
            test.contains(rows[36], "Tab switch")
            test.contains(rows[36], "Esc close")
        end)

        test.it("asks before archiving and names the workspace", function()
            local state = populated()
            model.confirm(state, true)
            local rows = check(80, 24, state)
            test.contains(rows[24], "Archive Legacy billing")
            test.contains(rows[24], "Enter confirms · Esc cancels")
        end)

        test.it("states an empty search, an unreadable catalog and a failing extension", function()
            local state = model.new()
            model.type_text(state, "nothing")
            model.submit(state)
            model.apply_page(state, ok({items = {}}))
            test.not_nil(find(check(80, 24, state), "No workspace matches nothing"))
            local failed = model.new()
            model.apply_page(failed, {ok = false, error = {code = "DENIED", message = "catalog"}, value = nil, replayed = false})
            test.not_nil(find(check(80, 24, failed), "Could not read the workspace catalog"))
            local broken = populated()
            model.apply_inspect(broken, broken.selected, ok({live = false, applications = {},
                extensions = {{binding = "bee:broken", title = "Broken", total = 0, items = {}, error = "refused"}}}))
            local rows = check(120, 36, broken)
            test.not_nil(find(rows, "Not served"))
            test.not_nil(find(rows, "refused"))
        end)

        test.it("draws the create flow's folder step at every size class", function()
            local form = creation.new()
            creation.apply_roots(form, ok({roots = {{root_ref = "bee:workspace_root", access = "write"}, {root_ref = "bee:archive", access = "read"}}}))
            for _, size in ipairs({{40, 12}, {80, 24}, {120, 36}, {160, 48}}) do
                local rows = check(size[1], size[2], model.new(), form)
                test.contains(rows[1], "NEW WORKSPACE")
                test.not_nil(find(rows, "bee:workspace_root"))
            end
            local roots = check(80, 24, model.new(), form)
            test.contains(roots[1], "Choose a root")
            test.contains(roots[2], "1 Folder")
            test.not_nil(find(roots, "›bee:workspace_root"))
            test.contains(roots[23], "Enter Open")
            test.contains(roots[24], "U use folder")
            creation.open(form)
            creation.apply_folders(form, ok({root_ref = "bee:workspace_root", path = "", access = "write",
                folders = {{name = "alpha"}, {name = "beta", workspace_id = string.rep("b", 32)}}}))
            local rows = check(80, 24, model.new(), form)
            test.contains(rows[1], "bee:workspace_root")
            local beta = find(rows, "beta")
            if not beta then error("beta row missing") end
            test.contains(rows[beta], "workspace")
            local drawn = view.draw(80, 24, appearance.defaults(), model.new(), 0, form)
            local kinds: {[string]: boolean} = {}
            for _, hit in ipairs(drawn.hits) do kinds[hit.kind] = true end
            for _, kind in ipairs({"folder", "create_open", "create_use", "create_up", "create_cancel"}) do test.is_true(kinds[kind] == true) end
        end)

        test.it("draws the details step with the new folder only under a writable root", function()
            local form = creation.new()
            creation.apply_roots(form, ok({roots = {{root_ref = "bee:workspace_root", access = "write"}}}))
            creation.open(form)
            creation.apply_folders(form, ok({root_ref = "bee:workspace_root", path = "", access = "write", folders = {{name = "alpha"}}}))
            creation.open(form)
            creation.apply_folders(form, ok({root_ref = "bee:workspace_root", path = "alpha", access = "write", folders = {}}))
            creation.use(form)
            for _, size in ipairs({{40, 12}, {80, 24}, {120, 36}, {160, 48}}) do check(size[1], size[2], model.new(), form) end
            local rows = check(80, 24, model.new(), form)
            test.contains(rows[2], "✓ Folder")
            test.contains(rows[2], "2 Details")
            test.not_nil(find(rows, "›Label       alpha"))
            test.not_nil(find(rows, "New folder"))
            test.not_nil(find(rows, "Holds       bee:workspace_root/alpha"))
            test.contains(rows[23], "Enter Create")
            creation.field(form, 1)
            creation.type_text(form, "api")
            test.not_nil(find(check(80, 24, model.new(), form), "Holds       bee:workspace_root/alpha/api"))
            local fixed = creation.new()
            creation.apply_roots(fixed, ok({roots = {{root_ref = "bee:archive", access = "read"}}}))
            creation.open(fixed)
            creation.apply_folders(fixed, ok({root_ref = "bee:archive", path = "", access = "read", folders = {}}))
            creation.use(fixed)
            test.is_nil(find(check(80, 24, model.new(), fixed), "New folder"))
        end)

        test.it("records a target for every row, tab, field and enabled action", function()
            local state = populated()
            local drawn = view.draw(120, 36, appearance.defaults(), state, 0)
            local kinds: {[string]: boolean} = {}
            for _, hit in ipairs(drawn.hits) do kinds[hit.kind] = true end
            for _, kind in ipairs({"workspace", "active", "archived", "field", "open", "new", "search", "refresh", "serve", "change"}) do
                test.is_true(kinds[kind] == true)
            end
            local row = frame.hit(drawn.hits, 10, 8)
            test.eq(row and row.kind, "workspace")
            test.is_nil(frame.hit(drawn.hits, 80, 8) and frame.hit(drawn.hits, 80, 8).kind == "workspace" or nil)
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}
