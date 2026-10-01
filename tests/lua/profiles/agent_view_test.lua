-- MIT. Agent picker and session screens: unavailable reasons, activity and transcript.
local test = require("test")
local picker_view = require("picker_view")
local session_view = require("session_view")
local appearance = require("appearance")
local agents = require("agents")
local directory_view = require("directory_view")
local protocol = require("protocol")
local tty = require("tty")
type Object = {[string]: unknown}
local function listing_of(value: unknown): agents.Listing return value :: agents.Listing end
local function conversation_of(value: unknown): agents.Conversation return value :: agents.Conversation end
local function screen(rows: {string}): string return table.concat(rows, "\n") end
local function conversation(activity: string, turns: {Object}, ref: string?): agents.Conversation
    local session_ref = ref or "bs:n:w:worker"
    return conversation_of({session = {ref = function(): string return session_ref end, snapshot = {provider = "claude"}}, title = "Worker", lifecycle = "active", activity = activity, queued = 1, turns = turns, notice = ""})
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
            test.is_true(text:find("Refresh", 1, true) ~= nil)
        end)
        test.it("strips terminal controls and offers no launch where nothing can be chosen", function()
            local hostile: any = {items = {{ref = "f:p", kind = "definition", title = "Profile\27]52;injected", status = "ready",
                ready = true, reason = ""}}, unavailable = 0, notes = {}}
            local shown = picker_view.draw(40, 10, appearance.defaults(), listing_of(hostile), 1, "", false, false)
            test.eq(#shown.rows, 10)
            test.is_nil((table.concat(shown.rows):find("\27]52", 1, true)))
            for _, size in ipairs({{20, 3}, {2, 10}}) do
                local small = picker_view.draw(size[1], size[2], appearance.defaults(), listing_of(hostile), 1, "", false, false)
                test.eq(small.capacity, 0)
                for _, hit in ipairs(small.hits) do
                    test.is_true(hit.kind ~= "open" and hit.kind ~= "setup" and hit.kind ~= "edit")
                end
            end
            local empty: any = {items = {}, unavailable = 0, notes = {}}
            for _, hit in ipairs(picker_view.draw(80, 12, appearance.defaults(), listing_of(empty), 0, "", false, false).hits) do
                test.is_true(hit.kind ~= "open" and hit.kind ~= "setup" and hit.kind ~= "edit")
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
            test.is_true(rows[1]:find("NEW SESSION", 1, true) ~= nil and rows[1]:find("2 agents", 1, true) ~= nil)
            test.eq(rows[3]:sub(1, 7), " Alpha ")
            test.eq(rows[4]:sub(1, #"›"), "›")
            test.is_true(rows[24]:find("Enter open · U unavailable", 1, true) ~= nil)
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
    test.describe("Sessions list", function()
        test.it("renders addressable stopped sessions and stable help at 120 and 80", function()
            for _, size in ipairs({{120, 36}, {80, 24}}) do
                local rows: any = {{session = "bs:n:w:s", title = "Fix API", lifecycle = "closed", activity = "idle", queue_count = 0}}
                local shown = directory_view.draw(size[1], size[2], appearance.defaults(), rows :: {protocol.SessionSnapshot}, 1, "Refreshed", false)
                test.eq(#shown.rows, size[2])
                for _, row in ipairs(shown.rows) do test.eq(tty.text.width(row), size[1]) end
                local plain = screen(shown.rows):gsub("\27%[[0-9;]*m", "")
                test.is_true(plain:find("Fix API", 1, true) ~= nil)
                test.is_true(plain:find("closed", 1, true) ~= nil)
                test.is_nil((plain:find("bs:n:w:s", 1, true)))
                test.is_true(shown.rows[size[2]]:find("Enter open", 1, true) ~= nil)
            end
        end)
    end)
    test.describe("Agent session screen", function()
        test.it("wraps prose at spaces and preserves paragraphs", function()
            local conv = conversation("idle", {{input = "hello", state = "ready", text = "alpha beta gamma delta\nnext paragraph"}})
            local lines = session_view.lines(conv, 18)
            test.eq(lines[2].text, "  alpha beta gamma")
            test.eq(lines[3].text, "  delta")
            test.eq(lines[4].text, "  next paragraph")
        end)
        test.it("offers a new session from closed history instead of a composer", function()
            local conv = conversation("idle", {{input = "hello", state = "ready", text = "done"}})
            conv.lifecycle = "closed"
            for _, size in ipairs({{120, 36}, {80, 24}}) do
                local shown = session_view.draw(size[1], size[2], appearance.defaults(), conv, "", "")
                test.is_true(screen(shown.rows):find("Start new session from this", 1, true) ~= nil)
                test.is_true(screen(shown.rows):find("Closed · history remains available", 1, true) ~= nil)
                test.is_true(screen(shown.rows):find("done", 1, true) ~= nil)
            end
        end)
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
        test.it("keeps conversation identity, stop control and help in rendered frames", function()
            for _, size in ipairs({{120, 36}, {80, 24}}) do
                local shown = session_view.draw(size[1], size[2], appearance.defaults(), conversation("working", {
                    {input = "Fix API", state = "working", text = ""}}), "next", "Working")
                test.eq(#shown.rows, size[2])
                for _, row in ipairs(shown.rows) do test.eq(tty.text.width(row), size[1]) end
                test.is_true(screen(shown.rows):find("Conversation", 1, true) ~= nil)
                test.is_nil((screen(shown.rows):find("bs:", 1, true)))
                test.is_true(screen(shown.rows):find("Stop current work", 1, true) ~= nil)
                test.is_true(shown.rows[size[2]]:find("Ctrl+K stop work", 1, true) ~= nil)
            end
        end)
        test.it("updates the sidebar marker from the session snapshot", function()
            local rows: {protocol.SessionSnapshot} = {}
            local conv = conversation("working", {})
            local decoded = protocol.decode_snapshot({session = "bs:n:w:worker", revision = 1, incarnation = 1, title = "Fix API", lifecycle = "active", activity = "blocked", queue_count = 0,
                execution = {state = "absent", evidence_at = "2026-09-30T12:00:00.000Z", stale = false}, effective_limits = {}, continuity = {mode = "fresh"}, actions = {}})
            rows[1] = assert(decoded)
            local shown = session_view.draw(120, 36, appearance.defaults(), conv, "", "", rows)
            test.is_true(screen(shown.rows):find("blocked", 1, true) ~= nil)
        end)
        test.it("shows the session rail on a wide conversation and preserves mouse coordinates", function()
            local conv = conversation("working", {{input = "fix", state = "working", text = ""}}, "bs:n:w:s")
            local rows: any = {{session = "bs:n:w:s", title = "Fix API"}, {session = "bs:n:w:other", title = "Review docs"}}
            local shown = session_view.draw(120, 36, appearance.defaults(), conv, "draft", "", rows :: {protocol.SessionSnapshot})
            test.eq(#shown.rows, 36)
            for _, row in ipairs(shown.rows) do test.eq(tty.text.width(row), 120) end
            test.is_true(screen(shown.rows):find("Review docs", 1, true) ~= nil)
            local sidebar, send = false, false
            for _, hit in ipairs(shown.hits) do
                test.is_true(hit.x + hit.width - 1 <= 120 and hit.y <= 36)
                if hit.kind == "sidebar_session" and hit.index == 2 then sidebar = true end
                if hit.kind == "send" and hit.x > 26 then send = true end
            end
            test.is_true(sidebar and send)
        end)
        test.it("declares shared frame controls with shortcuts on every agent screen", function()
            local listing: any = {items = {{ref = "f:a", kind = "definition", title = "Alpha", status = "ready", ready = true, reason = ""}}, unavailable = 0, notes = {}}
            local sessions: any = {{session = "bs:n:w:s", title = "Fix API", lifecycle = "active", activity = "idle", queue_count = 0}}
            local conv = conversation("working", {{input = "fix", state = "working", text = ""}}, "bs:n:w:s")
            local screens = {
                picker_view.draw(80, 24, appearance.defaults(), listing_of(listing), 1, "", false, false),
                directory_view.draw(80, 24, appearance.defaults(), sessions :: {protocol.SessionSnapshot}, 1, "", false),
                session_view.draw(80, 24, appearance.defaults(), conv, "draft", ""),
                session_view.draw(120, 24, appearance.defaults(), conv, "draft", "", sessions :: {protocol.SessionSnapshot}),
            }
            for _, shown in ipairs(screens) do
                local controls = assert(shown.controls)
                test.is_true(#controls.buttons > 0)
                for _, button in ipairs(controls.buttons) do test.not_nil(button.key) end
                local footer = shown.rows[#shown.rows]:gsub("\27%[[0-9;]*m", "")
                local _, helps = footer:gsub("%? help", "")
                test.eq(helps, 1)
            end
            local hinted: {[string]: boolean} = {}
            for _, hint in ipairs(assert(screens[1].controls).hints) do hinted[hint.key] = true end
            test.is_true(hinted.M and hinted.E and hinted.N and hinted.S)
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
