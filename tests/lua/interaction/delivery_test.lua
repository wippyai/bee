-- MIT. Selection and question identity remain separate from actor admission.
local test = require("test")
local questions = require("questions")
local protocol = require("protocol")
local workspace = "0123456789abcdef0123456789abcdef"
local function select_view(state: questions.State, connection: string, sequence: integer, id: string, instance: string)
    return questions.select(state, connection, {version = 1, workspace_id = workspace, connection_id = connection,
        revision = sequence, targets = {{id = id, instance_id = instance}}})
end
local function question(id: string, instance: string, request: string)
    return {version = 1, request_id = request, id = id, instance_id = instance,
        kind = "confirm", title = "Close?", message = "Work is running", accept = "Close", initial = ""}
end
local function answer(connection: string, sequence: integer, id: string, instance: string, request: string)
    return {version = 1, workspace_id = workspace, connection_id = connection, selection_revision = sequence,
        request_id = request, id = id, instance_id = instance, action = "accept", value = ""}
end
local function define_tests()
    test.describe("Client question ownership", function()
        test.it("publishes only selected exact targets and replays pending questions on rejoin", function()
            local state = questions.new(workspace)
            test.is_true(questions.update(state, {version = 1, items = {question("left", "a", "q1"), question("right", "b", "q2")}}))
            test.is_true(select_view(state, "first", 1, "left", "a"))
            test.is_true(select_view(state, "second", 1, "right", "b"))
            local left = assert(questions.snapshot(state, "first"))
            test.eq(#left.items, 1)
            test.eq(left.items[1].request_id, "q1")
            test.eq(assert(questions.snapshot(state, "second")).items[1].request_id, "q2")
            left.items[1].title = "Changed"
            test.eq(assert(questions.snapshot(state, "first")).items[1].title, "Close?")
            questions.forget(state, "first")
            test.is_nil(questions.snapshot(state, "first"))
            test.is_true(select_view(state, "new-execution", 1, "left", "a"))
            test.eq(assert(questions.snapshot(state, "new-execution")).items[1].request_id, "q1")
            test.is_true(select_view(state, "new-execution", 2, "left", "replacement"))
            test.eq(#assert(questions.snapshot(state, "new-execution")).items, 0)
        end)
        test.it("refuses foreign, stale, unselected and retired answers", function()
            local state = questions.new(workspace)
            assert(select_view(state, "client", 2, "view", "instance"))
            assert(questions.update(state, {version = 1, items = {question("view", "instance", "q")}}))
            test.is_nil(questions.answer(state, "client", answer("other", 2, "view", "instance", "q")))
            test.is_nil(questions.answer(state, "client", answer("client", 1, "view", "instance", "q")))
            test.is_nil(questions.answer(state, "client", answer("client", 2, "other", "instance", "q")))
            test.is_nil(questions.answer(state, "client", answer("client", 2, "view", "replacement", "q")))
            local foreign = answer("client", 2, "view", "instance", "q")
            foreign.workspace_id = "ffffffffffffffffffffffffffffffff"
            test.is_nil(questions.answer(state, "client", foreign))
            local malformed = answer("client", 2, "view", "instance", "q")
            malformed.value = "unexpected"
            test.is_nil(questions.answer(state, "client", malformed))
            test.not_nil(questions.answer(state, "client", answer("client", 2, "view", "instance", "q")))
            assert(questions.update(state, {version = 1, items = {}}))
            test.is_nil(questions.answer(state, "client", answer("client", 2, "view", "instance", "q")))
        end)
        test.it("dispatches at most one answer while the broker owns retirement", function()
            local state = questions.new(workspace)
            assert(select_view(state, "first", 1, "view", "instance"))
            assert(select_view(state, "second", 1, "view", "instance"))
            assert(questions.update(state, {version = 1, items = {question("view", "instance", "q")}}))
            local accepted = questions.answer(state, "first", answer("first", 1, "view", "instance", "q"))
            if not accepted then error("Expected admitted answer") end
            -- A failed send does not claim the answer and permits an explicit retry.
            test.not_nil(questions.answer(state, "second", answer("second", 1, "view", "instance", "q")))
            questions.dispatched(state, accepted)
            test.is_nil(questions.answer(state, "second", answer("second", 1, "view", "instance", "q")))
            questions.forget(state, "first")
            assert(questions.update(state, {version = 1, items = {question("view", "instance", "q")}}))
            test.is_nil(questions.answer(state, "second", answer("second", 1, "view", "instance", "q")))
            test.eq(#assert(questions.snapshot(state, "second")).items, 1)
            assert(questions.update(state, {version = 1, items = {}}))
            test.eq(#assert(questions.snapshot(state, "second")).items, 0)
        end)
        test.it("bounds selections and rejects duplicate or out-of-order targets", function()
            local state = questions.new(workspace)
            assert(select_view(state, "client", 2, "view", "instance"))
            test.is_false(select_view(state, "client", 1, "other", "instance"))
            test.eq(assert(questions.snapshot(state, "client")).selection_revision, 2)
            local duplicate = {version = 1, workspace_id = workspace, connection_id = "client", revision = 3,
                targets = {{id = "view", instance_id = "a"}, {id = "view", instance_id = "b"}}}
            test.is_nil(protocol.selection(duplicate))
            for index = 2, 8 do assert(select_view(state, tostring(index), 1, "view", "instance")) end
            test.is_false(select_view(state, "ninth", 1, "view", "instance"))
            local snapshot = assert(questions.snapshot(state, "client"))
            test.not_nil(protocol.snapshot(snapshot))
            snapshot.selection_revision = -1
            test.is_nil(protocol.snapshot(snapshot))
        end)
    end)
end
local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
