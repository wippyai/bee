-- MIT. The inbox frame fits every terminal size, keeps hits inside it,
-- leads with the proposed effect, and lets no control sequence from a
-- request through.
local test = require("test")
local tty = require("tty")
local model = require("model")
local view = require("view")
local appearance = require("appearance")
type Object = {[string]: unknown}
local function request(id: string, state: string, prompt: string): Object
    return {approval_id = id, workspace_id = "ws-1", requester_id = "bee.test.requester", request_kind = "permission", policy = "inbox-test",
        proposal = {kind = "attempt", ref = "attempt-" .. id, revision = "r1", action_id = "action-" .. id, payload = {tool_name = "Bash", correlation_id = "c-1"}},
        proposal_digest = string.rep("b", 64), prompt = {text = prompt}, revision = 1, state = state, owner_node = "node-1", owner_incarnation = 2,
        expires_at = "2026-09-09T10:00:00.000Z", created_at = "2026-09-09T09:00:00.000Z"}
end
local function define_tests()
    test.describe("Inbox frame", function()
        test.it("keeps rows, detail and hits inside every terminal size and strips hostile text", function()
            local state = model.new({"ws-1"})
            local changes: {Object} = {}
            for index = 1, 12 do
                changes[#changes + 1] = {seq = index, approval_id = "r" .. tostring(index), revision = 1, request = request("r" .. tostring(index), index % 3 == 0 and "expired" or "pending", "touch proof.txt \27[31mred\27[0m\r\7 line")}
            end
            model.apply_inbox(state, "ws-1", {ok = true, error = nil, value = {changes = changes, next_seq = 12, more = false}, replayed = false})
            model.select(state, "r5")
            model.apply_read(state, "r5", {ok = true, error = nil, value = request("r5", "pending", "touch proof.txt \27[2J"), replayed = false})
            model.toggle_technical(state)
            for _, width in ipairs({1, 12, 40, 80, 140}) do
                for _, height in ipairs({1, 3, 8, 14, 30}) do
                    local frame = view.draw(width, height, appearance.defaults(), state, model.rows(state), 0, "")
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
                        test.not_nil(view.hit(frame.hits, hit.x, hit.y))
                    end
                end
            end
            local frame = view.draw(100, 30, appearance.defaults(), state, model.rows(state), 0, "")
            local text = table.concat(frame.rows, "\n")
            test.is_true(text:find("Effect: Bash", 1, true) ~= nil)
            test.is_true(text:find("Digest", 1, true) ~= nil)
            test.is_true(text:find("Approve", 1, true) ~= nil)
            local approve = false
            for _, hit in ipairs(frame.hits) do if hit.kind == "approve" then approve = true end end
            test.is_true(approve)
        end)
        test.it("offers no decision without an opened pending request or while one awaits the owner", function()
            local state = model.new({"ws-1"})
            model.apply_inbox(state, "ws-1", {ok = true, error = nil, value = {changes = {{seq = 1, approval_id = "r1", revision = 1, request = request("r1", "pending", "x")}}, next_seq = 1, more = false}, replayed = false})
            model.select(state, "r1")
            local function offers(kind: string): boolean
                local frame = view.draw(100, 30, appearance.defaults(), state, model.rows(state), 0, "")
                for _, hit in ipairs(frame.hits) do if hit.kind == kind then return true end end
                return false
            end
            test.is_false(offers("approve"))
            model.apply_read(state, "r1", {ok = true, error = nil, value = request("r1", "pending", "x"), replayed = false})
            test.is_true(offers("approve"))
            test.not_nil(model.decision_intent(state, "q1", "approved"))
            test.is_false(offers("approve"))
            test.is_false(offers("refresh"))
        end)
        test.it("shows keyboard guidance when no operation needs attention", function()
            local state = model.new({"ws-1"})
            local frame = view.draw(100, 20, appearance.defaults(), state, model.rows(state), 0, "")
            test.is_true(table.concat(frame.rows, "\n"):find("↑↓ select · Enter open", 1, true) ~= nil)
        end)
    end)
end
return test.run_cases(define_tests)
