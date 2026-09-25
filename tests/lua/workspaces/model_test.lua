-- MIT. The Workspaces viewer model holds one catalog page at a time, pages
-- with the owner's cursors, searches by label or folder, and shows the
-- selected workspace as its owners describe it, bounded.
local test = require("test")
local model = require("model")
local caller = require("caller")

type Object = {[string]: unknown}

local function id(index: integer): string
    return string.format("%032x", index)
end

local function row(index: integer, label: string?): Object
    return {workspace_id = id(index), label = label or ("Project " .. tostring(index)), root_ref = "bee.environment:workspace_root",
        subpath = "legacy/" .. tostring(index), state = "active", created_at = "2026-09-24T00:00:00.000Z", last_used_at = "2026-09-24T01:00:00.000Z"}
end

local function page(first: integer, count: integer, next_after: string?): caller.Reply
    local items: {Object} = {}
    for index = first, first + count - 1 do items[#items + 1] = row(index) end
    return {ok = true, error = nil, value = {items = items, next_after = next_after}, replayed = false}
end

local function ok(value: unknown): caller.Reply
    return {ok = true, error = nil, value = value, replayed = false}
end

local function define_tests()
    test.describe("Workspaces viewer model", function()
        test.it("asks for one page of the list, a label search or a folder search", function()
            local state = model.new()
            local listing = model.listing(state)
            test.eq(listing.target, "bee.workspace.catalog:list")
            test.eq(listing.request.state, "active")
            test.eq(listing.request.limit, model.PAGE)
            test.is_nil(listing.request.after)
            model.type_text(state, "Bee")
            model.submit(state)
            local label = model.listing(state)
            test.eq(label.target, "bee.workspace.catalog:search")
            test.eq(label.request.label, "Bee")
            model.erase(state); model.erase(state); model.erase(state)
            model.type_text(state, "/legacy/")
            model.submit(state)
            local folder = model.listing(state)
            -- A folder search walks every root the host admits.
            test.is_nil(folder.request.root_ref)
            test.eq(folder.request.path, "legacy")
            test.is_nil(folder.request.label)
            model.switch(state, "archived")
            test.eq(model.listing(state).request.state, "archived")
        end)

        test.it("pages forward and back with the owner's cursors and keeps only the current page", function()
            local state = model.new()
            model.apply_page(state, page(1, model.PAGE, "cursor-1"))
            test.eq(#state.items, model.PAGE)
            test.eq(state.selected, id(1))
            for step = 1, model.PAGE - 1 do test.eq(model.move(state, 1), "select") end
            test.eq(state.selected, id(model.PAGE))
            test.eq(model.move(state, 1), "page")
            test.eq(model.listing(state).request.after, "cursor-1")
            model.apply_page(state, page(model.PAGE + 1, model.PAGE, "cursor-2"))
            test.eq(state.page, 2)
            test.eq(#state.items, model.PAGE)
            test.eq(state.selected, id(model.PAGE + 1))
            test.eq(model.move(state, -1), "page")
            test.is_nil(model.listing(state).request.after)
            test.eq(state.page, 1)
            model.apply_page(state, page(1, 3, nil))
            test.is_nil(model.move(state, -1))
            test.eq(model.move(state, 1), "select")
            test.eq(model.move(state, 1), "select")
            test.is_nil(model.move(state, 1))
        end)

        test.it("walks a catalog of thousands without holding more than one page", function()
            local state = model.new()
            local total = 3000
            local seen = 0
            model.apply_page(state, page(1, model.PAGE, "cursor"))
            while true do
                seen = seen + #state.items
                test.is_true(#state.items <= model.PAGE)
                local first = seen + 1
                if first > total then break end
                test.is_true(model.forward(state))
                model.apply_page(state, page(first, model.PAGE, first + model.PAGE <= total and "cursor" or nil))
            end
            test.eq(seen, total)
            test.eq(state.page, total // model.PAGE)
            test.is_false(model.forward(state))
        end)

        test.it("strips hostile text from the catalog and keeps a failing page visible", function()
            local state = model.new()
            model.apply_page(state, ok({items = {row(1, "evil\27[2J\7label"), {workspace_id = "short"}, "junk"}}))
            test.eq(#state.items, 1)
            test.is_nil(state.items[1].label:find("\27", 1, true))
            test.is_nil(state.items[1].label:find("\7", 1, true))
            model.apply_page(state, {ok = false, error = {code = "DENIED", message = "no"}, value = nil, replayed = false})
            test.eq(state.error, "DENIED: no")
            test.eq(#state.items, 1)
        end)

        test.it("shows what the selected workspace holds and ignores answers for another one", function()
            local state = model.new()
            model.apply_page(state, page(1, 2, nil))
            local selected = state.selected
            model.apply_inspect(state, selected, ok({workspace = row(1), live = true,
                applications = {{definition_id = "bee.settings:app", instance_id = "i-1", restart_policy = "automatic"}},
                extensions = {{binding = "bee:resources_workspace_extension", title = "Resources", total = 3, items = {{label = "docs", detail = "bee.environment:workspace_root · read"}}},
                    {binding = "bee:broken", title = "Broken", total = 0, items = {}, error = "refused\27[31m"}}}))
            local detail = state.detail
            if not detail then error("detail") end
            test.eq(detail.live, true)
            test.eq(detail.applications[1].label, "bee.settings:app")
            test.eq(#detail.sections, 2)
            test.eq(detail.sections[1].title, "Resources")
            test.eq(detail.sections[1].total, 3)
            test.is_nil(tostring(detail.sections[2].error):find("\27", 1, true))
            model.apply_threads(state, selected, ok({threads = {{thread_id = "t-1", title = "Plan", state = "open"}}, next_after_thread_id = "t-1"}))
            test.eq(detail.threads[1].label, "Plan")
            test.eq(detail.more_threads, true)
            model.apply_inspect(state, id(2), ok({live = false}))
            test.eq(state.detail and state.detail.workspace_id, selected)
            model.apply_inspect(state, selected, {ok = false, error = {code = "NOT_FOUND", message = "gone"}, value = nil, replayed = false})
            test.eq(state.detail and state.detail.error, "NOT_FOUND: gone")
        end)

        test.it("archives from the active list and restores from the archived one", function()
            local state = model.new()
            model.apply_page(state, page(1, 2, nil))
            local intent = model.change_intent(state)
            test.eq(intent and intent.target, "bee.workspace.catalog:archive")
            local archived = row(1)
            archived.state = "archived"
            model.apply_change(state, ok(archived))
            test.eq(#state.items, 1)
            test.eq(state.selected, id(2))
            test.eq(state.status, "Archived Project 1")
            model.switch(state, "archived")
            model.apply_page(state, ok({items = {archived}}))
            test.eq(model.change_intent(state) and model.change_intent(state).target, "bee.workspace.catalog:restore")
            model.apply_change(state, {ok = false, error = {code = "BUSY", message = "host"}, value = nil, replayed = false})
            test.eq(state.status, "BUSY: host")
            test.eq(#state.items, 1)
        end)

        test.it("returns to the first active page with a created workspace selected", function()
            local state = model.new()
            model.switch(state, "archived")
            model.type_text(state, "old")
            model.submit(state)
            local created = model.summary(row(7, "Fresh"))
            if not created then error("summary") end
            model.created(state, created)
            test.eq(state.tab, "active")
            test.eq(state.query, "")
            test.is_nil(model.listing(state).request.after)
            test.eq(state.status, "Created Fresh")
            model.apply_page(state, page(5, 4, nil))
            test.eq(state.selected, id(7))
        end)

        test.it("edits the search one character at a time and bounds it", function()
            local state = model.new()
            model.type_text(state, "ä")
            model.type_text(state, "b")
            model.erase(state)
            test.eq(state.query, "ä")
            model.erase(state)
            test.eq(state.query, "")
            model.type_text(state, "\27")
            test.eq(state.query, "")
            for _ = 1, 200 do model.type_text(state, "x") end
            test.eq(#state.query, model.QUERY_LIMIT)
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}
