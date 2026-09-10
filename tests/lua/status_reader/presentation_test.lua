-- MIT. Render projection carries bounded values and explicit uncertainty.
local test = require("test")
local reader = require("reader")
local surface = require("surface")
local function define_tests()
    test.describe("Status presentation", function()
        test.it("requires an owner receipt before showing action success", function()
            local value: reader.Reader = reader.new()
            reader.bind(value, "thread")
            value.availability = "ready"
            value.status = {activity = "idle", waiting_on_you = false, waiting_message_ids = {}, open_requests = 0,
                pending_approvals = 0, running_actions = 0, uncertain_actions = 0, open_actions = 0,
                last_outcome = {kind = "turn", outcome = "succeeded", at_sequence = 1}}
            local envelope = {status_revision = 1, statuses = {{tab_id = "tab", instance_id = "instance", value = reader.value(value)}}}
            test.eq(assert(surface.decode(envelope)).items[1].badge.glyph, "○")
            value.status.last_outcome = {kind = "receipt", outcome = "succeeded", at_sequence = 2}
            envelope.statuses[1].value = reader.value(value)
            test.eq(assert(surface.decode(envelope)).items[1].badge.glyph, "✓")
            value.status.open_actions = 1
            envelope.statuses[1].value = reader.value(value)
            test.eq(assert(surface.decode(envelope)).items[1].badge.glyph, "○")
        end)
        test.it("keeps unavailable distinct from idle and rejects malformed ready data", function()
            local value: reader.Reader = reader.new()
            reader.bind(value, "thread")
            local envelope = {status_revision = 1, statuses = {{tab_id = "tab", instance_id = "instance", value = reader.value(value)}}}
            test.eq(assert(surface.decode(envelope)).items[1].badge.text, "Loading")
            reader.lost(value)
            envelope.statuses[1].value = reader.value(value)
            test.eq(assert(surface.decode(envelope)).items[1].badge.text, "Unavailable")
            value.availability = "ready"
            envelope.statuses[1].value = reader.value(value)
            test.is_nil(surface.decode(envelope))
            value.availability = "loading"
            value.generation = -1
            envelope.statuses[1].value = reader.value(value)
            test.is_nil(surface.decode(envelope))
        end)
        test.it("projects viewer waiting and copies presenter values", function()
            local value: reader.Reader = reader.new()
            reader.bind(value, "thread")
            value.availability = "ready"
            value.status = {activity = "waiting", waiting_on_you = true, waiting_message_ids = {}, open_requests = 1,
                pending_approvals = 0, running_actions = 0, uncertain_actions = 0, open_actions = 0, last_outcome = nil}
            local projected = assert(surface.decode({status_revision = 2, statuses = {{tab_id = "tab", instance_id = "instance", value = reader.value(value)}}}))
            test.eq(projected.items[1].badge.glyph, "◐")
            test.eq(projected.items[1].badge.tone, "warning")
            local decoded = assert(surface.presentation(projected))
            projected.items[1].badge.text = "changed"
            test.eq(decoded.items[1].badge.text, "Waiting on you")
            projected.items[1].badge.text = "bad\27[0m"
            test.is_nil(surface.presentation(projected))
            projected.items[1].badge.text = "Waiting"
            projected.items[2] = projected.items[1]
            test.is_nil(surface.presentation(projected))
        end)
    end)
end
return require("test").run_cases(define_tests)
