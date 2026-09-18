-- MIT. The frame fits every terminal size in both modes, keeps hits inside
-- it, shows the session and recap as stored, marks what is not shown, and
-- lets no control sequence through.
local test = require("test")
local tty = require("tty")
local model = require("model")
local view = require("view")
local appearance = require("appearance")
type Object = {[string]: unknown}
local function ok(value: unknown): model.Reply
    return {ok = true, error = nil, value = value, replayed = false}
end
local function message(sequence: integer, text: string): Object
    return {schema_revision = "bee.thread-record@1", record_id = "r" .. tostring(sequence), thread_id = "t-1", sequence = sequence, recorded_at = "2026-09-09T00:00:00.000Z",
        kind = "message", producer_id = "bee.test.alice", source = "bee", body = {message_id = "m" .. tostring(sequence), message_kind = "request", sender_id = "bee.test.alice", recipient_ids = {}, content = {text = text}}}
end
local function attached(): model.State
    local state = model.new("bee.timeline.i1")
    model.open(state, "t-1", nil)
    model.apply_get(state, ok({summary = {thread_id = "t-1", title = "Review \27[2Jrun", state = "open", head_sequence = 30, owner_id = "bee.test.alice"}, membership = {}}))
    model.apply_attach(state, ok({subscription_id = "s-1", after_sequence = 0, lease_generation = 1, owner_incarnation = 2, owner_authority = "auth", closed = false}))
    model.apply_recap(state, ok({through_sequence = 20, revision = 3, checkpoint = {summary_lines = {"first line \7bell"}, last_turn = {turn_id = "turn-1", outcome = "uncertain"}}, head_sequence = 30}))
    local records: {Object} = {}
    for sequence = 1, 30 do records[#records + 1] = message(sequence, "text " .. tostring(sequence) .. " \27[31mred\r") end
    model.apply_page(state, ok({subscription_id = "s-1", page_id = "p-1", lease_generation = 1, from_sequence = 0, scanned_through = 30, records = records, has_more = false}))
    model.apply_ack(state, ok({after_sequence = 30}))
    return state
end
local function define_tests()
    test.describe("Timeline frame", function()
        test.it("keeps rows and hits inside every terminal size in both modes and strips hostile text", function()
            local state = attached()
            model.select(state, 12)
            model.toggle_technical(state)
            local picking = model.new("bee.timeline.i2")
            model.apply_list(picking, ok({threads = {{thread_id = "t-1", title = "One \27[31m", state = "open", head_sequence = 3, owner_id = "bee.test.alice"}}}))
            for _, subject in ipairs({state, picking}) do
                for _, width in ipairs({1, 12, 40, 80, 140}) do
                    for _, height in ipairs({1, 3, 8, 14, 30}) do
                        local frame = view.draw(width, height, appearance.defaults(), subject, 0, "")
                        test.eq(#frame.rows, height)
                        for _, row in ipairs(frame.rows) do
                            test.eq(tty.text.width(row), width)
                            test.is_nil(row:find("\27[31m", 1, true))
                            test.is_nil(row:find("\27[2J", 1, true))
                            test.is_nil(row:find("\r", 1, true))
                            test.is_nil(row:find("\7", 1, true))
                        end
                        for _, hit in ipairs(frame.hits) do
                            test.is_true(hit.x >= 1 and hit.y >= 1)
                            test.is_true(hit.x + hit.width - 1 <= width)
                            test.is_true(hit.y + hit.height - 1 <= height)
                        end
                    end
                end
            end
            local frame = view.draw(140, 30, appearance.defaults(), state, 0, "")
            local text = table.concat(frame.rows, "\n")
            test.is_true(text:find("TIMELINE  Review  [2Jrun  open", 1, true) ~= nil)
            test.is_true(text:find("Recap through 20  last turn uncertain: first line", 1, true) ~= nil)
            test.is_true(text:find("Cursor 30 of 30  lease 1  owner incarnation 2", 1, true) ~= nil)
            test.is_true(text:find("record r12  recorded", 1, true) ~= nil)
            local kinds: {[string]: boolean} = {}
            for _, hit in ipairs(frame.hits) do kinds[hit.kind] = true end
            test.is_true(kinds["row"] and kinds["follow"] and kinds["threads"] and kinds["refresh"] and kinds["technical"])
            local picker = table.concat(view.draw(120, 20, appearance.defaults(), picking, 0, "").rows, "\n")
            test.is_true(picker:find("TIMELINE  choose a thread", 1, true) ~= nil)
            test.is_true(picker:find("One  [31m", 1, true) ~= nil)
            test.is_true(picker:find("↑↓ select · Enter open", 1, true) ~= nil)
        end)
        test.it("shows an unavailable owner, a required resume and unshown records without inventing rows", function()
            local state = model.new("bee.timeline.i1")
            model.open(state, "t-1", nil)
            model.apply_attach(state, {ok = false, error = {code = "DENIED", message = "caller is not a member of the thread"}, value = nil, replayed = false})
            local text = table.concat(view.draw(120, 20, appearance.defaults(), state, 0, "").rows, "\n")
            test.is_true(text:find("Owner unavailable: DENIED: caller is not a member of the thread", 1, true) ~= nil)
            test.is_nil(text:find("No records yet", 1, true))
            local resumed = attached()
            model.apply_ack(resumed, {ok = false, error = {code = "CONFLICT", message = "earlier owner incarnation"}, value = nil, replayed = false})
            local again = table.concat(view.draw(120, 20, appearance.defaults(), resumed, 0, "").rows, "\n")
            test.is_true(again:find("Resume required: CONFLICT: earlier owner incarnation", 1, true) ~= nil)
            local gapped = attached()
            model.apply_page(gapped, ok({subscription_id = "s-1", page_id = "p-2", lease_generation = 1, from_sequence = 40, scanned_through = 41, records = {message(41, "late")}, has_more = false}))
            gapped.dropped_through = 5
            local marked = table.concat(view.draw(160, 40, appearance.defaults(), gapped, 0, "").rows, "\n")
            test.is_true(marked:find("(records between 30 and 41 not shown)", 1, true) ~= nil)
            test.is_true(marked:find("earlier records through 5 not shown", 1, true) ~= nil)
        end)
        test.it("disables stale picker actions while the thread list is unavailable", function()
            local state = model.new("bee.timeline.i3")
            model.apply_list(state, ok({threads = {{thread_id = "t-1", title = "One", state = "open", head_sequence = 3, owner_id = "bee.test.alice"}}, next_after = "page-2"}))
            state.picker.unavailable = "the owner cannot be reached"
            local frame = view.draw(100, 20, appearance.defaults(), state, 0, "")
            for _, hit in ipairs(frame.hits) do
                test.is_false(hit.kind == "open" or hit.kind == "more")
            end
        end)
    end)
end
return require("test").run_cases(define_tests)
