-- MIT. Agent picker and session screens: unavailable reasons, activity and transcript.
local test = require("test")
local picker_view = require("picker_view")
local session_view = require("session_view")
local appearance = require("appearance")
local agents = require("agents")
type Object = {[string]: unknown}
local function listing_of(value: unknown): agents.Listing return value :: agents.Listing end
local function conversation_of(value: unknown): agents.Conversation return value :: agents.Conversation end
local function screen(rows: {string}): string return table.concat(rows, "\n") end
local function conversation(activity: string, turns: {Object}): agents.Conversation
    return conversation_of({title = "Worker", lifecycle = "active", activity = activity, queued = 1, turns = turns, notice = ""})
end
local function define_tests()
    test.describe("Agent picker screen", function()
        local listing: any = {items = {
            {ref = "a:claude", kind = "definition", title = "Claude", status = "ready", ready = true, reason = ""},
            {ref = "c:codex", kind = "definition", title = "Codex", status = "missing", ready = false, reason = "codex is not installed"},
        }, unavailable = 1, notes = {}}
        test.it("marks unavailable agents and states their reason when selected", function()
            local text = screen(picker_view.draw(120, 20, appearance.defaults(), listing_of(listing), 2, "", false, true).rows)
            test.is_true(text:find("Codex · missing", 1, true) ~= nil)
            test.is_true(text:find("codex is not installed", 1, true) ~= nil)
            test.is_true(text:find("Hide unavailable", 1, true) ~= nil)
        end)
        test.it("offers the toggle and the unavailable count while they are hidden", function()
            local ready: any = {items = {listing.items[1]}, unavailable = 1, notes = {}}
            local text = screen(picker_view.draw(120, 20, appearance.defaults(), listing_of(ready), 1, "", false, false).rows)
            test.is_true(text:find("Show unavailable", 1, true) ~= nil)
            test.is_true(text:find("1 unavailable", 1, true) ~= nil)
            test.is_true(text:find("Re-probe", 1, true) ~= nil)
        end)
        test.it("strips terminal controls and offers no launch where nothing can be chosen", function()
            local hostile: any = {items = {{ref = "f:p", kind = "definition", title = "Profile\27]52;injected", status = "ready",
                ready = true, reason = ""}}, unavailable = 0, notes = {}}
            local shown = picker_view.draw(40, 10, appearance.defaults(), listing_of(hostile), 1, "", false, false)
            test.eq(#shown.rows, 10)
            test.is_nil(table.concat(shown.rows):find("\27]52", 1, true))
            for _, size in ipairs({{20, 3}, {2, 10}}) do
                local small = picker_view.draw(size[1], size[2], appearance.defaults(), listing_of(hostile), 1, "", false, false)
                test.eq(small.capacity, 0)
                for _, hit in ipairs(small.hits) do
                    test.is_true(hit.kind ~= "open" and hit.kind ~= "attach" and hit.kind ~= "new" and hit.kind ~= "edit")
                end
            end
            local empty: any = {items = {}, unavailable = 0, notes = {}}
            for _, hit in ipairs(picker_view.draw(80, 12, appearance.defaults(), listing_of(empty), 0, "", false, false).hits) do
                test.is_true(hit.kind ~= "open" and hit.kind ~= "attach" and hit.kind ~= "new" and hit.kind ~= "edit")
            end
            local loading = table.concat(picker_view.draw(80, 12, appearance.defaults(), listing_of(empty), 0, "Loading agents…", false, false).rows)
            test.is_true(loading:find("Loading agents", 1, true) ~= nil)
            test.is_true(loading:find("No agents are ready", 1, true) == nil)
            local busy = picker_view.draw(80, 12, appearance.defaults(), listing_of(hostile), 1, "Opening session…", true, false)
            test.is_true(table.concat(busy.rows):find("Opening session", 1, true) ~= nil)
            for _, hit in ipairs(busy.hits) do
                test.is_true(hit.kind ~= "open" and hit.kind ~= "attach" and hit.kind ~= "new" and hit.kind ~= "edit" and hit.kind ~= "refresh")
            end
        end)
        test.it("keeps key hints in the footer and marks the chosen agent without color", function()
            local two: any = {items = {
                {ref = "f:a", kind = "definition", title = "Alpha", status = "ready", ready = true, reason = ""},
                {ref = "f:b", kind = "definition", title = "Beta", status = "ready", ready = true, reason = ""}}, unavailable = 0, notes = {}}
            local drawn = picker_view.draw(120, 24, appearance.defaults(), listing_of(two), 2, "", false, false)
            local rows: {string} = {}
            for index, row in ipairs(drawn.rows) do rows[index] = row:gsub("\27%[[0-9;]*m", "") end
            test.is_true(rows[1]:find("AGENT", 1, true) ~= nil and rows[1]:find("2 agents", 1, true) ~= nil)
            test.eq(rows[3]:sub(1, 7), " Alpha ")
            test.eq(rows[4]:sub(1, #"›"), "›")
            test.is_true(rows[24]:find("Enter open · M attach", 1, true) ~= nil)
            local chosen = 0
            for _, hit in ipairs(drawn.hits) do if hit.kind == "choice" and hit.y == 4 then chosen = hit.index end end
            test.eq(chosen, 2)
        end)
        test.it("explains an empty catalog", function()
            local empty: any = {items = {}, unavailable = 0, notes = {}}
            local text = screen(picker_view.draw(120, 20, appearance.defaults(), listing_of(empty), 0, "", false, false).rows)
            test.is_true(text:find("No agents are ready on this node", 1, true) ~= nil)
        end)
    end)
    test.describe("Agent session screen", function()
        test.it("shows activity, the transcript and the draft", function()
            local conv = conversation("working", {
                {input = "hello", state = "ready", text = "line one\nline two"},
                {input = "next", state = "queued", text = ""},
            })
            local shown = session_view.draw(80, 16, appearance.defaults(), conv, "draft", "")
            local text = screen(shown.rows)
            test.is_true(text:find("working · 1 queued", 1, true) ~= nil)
            test.is_true(text:find("> hello", 1, true) ~= nil)
            test.is_true(text:find("  line two", 1, true) ~= nil)
            test.is_true(text:find("  queued", 1, true) ~= nil)
            test.is_true(text:find("> draft", 1, true) ~= nil)
        end)
        test.it("labels blocked results", function()
            local lines = session_view.lines(conversation("blocked", {{input = "b", state = "blocked", text = "budget spent"}}), 40)
            test.eq(lines[2].text, "  blocked: budget spent")
        end)
        test.it("wraps long lines to the display width", function()
            local lines = session_view.lines(conversation("idle", {{input = "c", state = "ready", text = string.rep("x", 25)}}), 12)
            test.eq(#lines, 4)
            test.eq(lines[2].text, "  " .. string.rep("x", 10))
            test.eq(lines[4].text, "  " .. string.rep("x", 5))
        end)
        test.it("edits the draft by character and clears it", function()
            local draft = ""
            draft = session_view.edit(draft, {type = "key", action = "press", key = "h", key_type = "rune"})
            draft = session_view.edit(draft, {type = "key", action = "press", key = "é", key_type = "rune"})
            test.eq(draft, "hé")
            draft = session_view.edit(draft, {type = "key", action = "press", key = "", key_type = "backspace"})
            test.eq(draft, "h")
            draft = session_view.edit(draft, {type = "paste", text = "ello"})
            test.eq(draft, "hello")
            draft = session_view.edit(draft, {type = "key", action = "press", key = "u", key_type = "rune", ctrl = true})
            test.eq(draft, "")
        end)
    end)
end
return test.run_cases(define_tests)
