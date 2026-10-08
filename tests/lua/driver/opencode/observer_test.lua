-- SPDX-License-Identifier: MIT
local test = require("test")
local fs = require("fs")
local json = require("json")
local bounds = require("bounds")
local mapper = require("mapper")
local function fixture(name: string): string
    local files = assert(fs.get("bee.tests.driver:fixtures"))
    local content = assert(files:readfile("opencode/http-events-1/" .. name))
    return content
end
local function define_tests()
    test.describe("OpenCode captured HTTP events", function()
        test.it("deduplicates running tools and settles only the completed stop message at idle", function()
            local state = mapper.new()
            local rows: {{[string]: unknown}} = {}
            for line in fixture("events.jsonl"):gmatch("[^\n]+") do
                for _, row in ipairs(mapper.event(state, assert(bounds.object(json.decode(line))))) do rows[#rows + 1] = row end
            end
            local names: {string} = {}
            for i, row in ipairs(rows) do names[i] = tostring(row.hook_event_name) end
            test.eq(table.concat(names, ","), "SessionStart,UserPromptSubmit,PreToolUse,PermissionRequest,PostToolUse,Stop")
            test.eq(assert(bounds.object(rows[3].tool_input)).command, "printf fixture-tool")
            test.eq(rows[6].last_assistant_message, "Acknowledged fixture peer request")
            test.eq(rows[2].prompt, "Fixture peer request: run the fixture command and acknowledge.")
        end)
        test.it("recovers a completed reply from messages after a stream gap without repeating settled hooks", function()
            local state = mapper.new()
            local messages = assert(bounds.array(json.decode(fixture("messages.json")), 256))
            local session = assert(bounds.object(assert(bounds.object(messages[1])).info)).sessionID
            mapper.event(state, {type = "session.created", properties = {info = {id = session}}})
            local rows = mapper.snapshot(state, tostring(session), messages)
            test.eq(rows[#rows].hook_event_name, "PostToolUse")
            local idle = {type = "session.idle", properties = {sessionID = session}}
            local stopped = mapper.statuses(state, {})
            test.eq(stopped[1].last_assistant_message, "Acknowledged fixture peer request")
            test.eq(#mapper.snapshot(state, tostring(session), messages), 0)
            test.eq(#mapper.event(state, idle), 0)
        end)
        test.it("keeps a reconciled terminal tool state when an older running event is queued", function()
            local state = mapper.new()
            local messages = assert(bounds.array(json.decode(fixture("messages.json")), 256))
            local session = tostring(assert(bounds.object(assert(bounds.object(messages[1])).info)).sessionID)
            mapper.event(state, {type = "session.created", properties = {info = {id = session}}})
            mapper.snapshot(state, session, messages)
            local checked = false
            for line in fixture("events.jsonl"):gmatch("[^\n]+") do
                local event = assert(bounds.object(json.decode(line)))
                local properties = bounds.object(event.properties) or {}
                local part = bounds.object(properties.part) or {}
                if part.type == "tool" and (bounds.object(part.state) or {}).status == "running" then
                    test.eq(#mapper.event(state, event), 0)
                    checked = true
                    break
                end
            end
            test.is_true(checked)
        end)
        test.it("uses the running tool input for a permission request with partial metadata", function()
            local state = mapper.new()
            mapper.event(state, {type = "session.created", properties = {info = {id = "s"}}})
            mapper.snapshot(state, "s", {{info = {id = "a", role = "assistant"}, parts = {{id = "part", messageID = "a", type = "tool", tool = "bash", callID = "call", state = {status = "running", input = {command = "printf fixture", description = "Fixture command"}}}}}})
            local event = {type = "permission.asked", properties = {sessionID = "s", id = "permission", permission = "bash", tool = {callID = "call"}, metadata = {}}}
            local rows = mapper.event(state, event)
            test.eq(assert(bounds.object(rows[1].tool_input)).command, "printf fixture")
            test.eq(rows[1].permission_id, "permission")
            test.eq(#mapper.event(state, event), 0)
        end)
        test.it("does not settle an intermediate or incomplete assistant", function()
            for _, info in ipairs({{finish = "tool-calls", time = {completed = 1}}, {finish = "stop", time = {}}}) do
                local state = mapper.new()
                mapper.event(state, {type = "session.created", properties = {info = {id = "s"}}})
                mapper.snapshot(state, "s", {{info = {id = "u", role = "user"}, parts = {{id = "pu", messageID = "u", type = "text", text = "prompt"}}},
                    {info = {id = "a", role = "assistant", parentID = "u", finish = info.finish, time = info.time}, parts = {{id = "pa", messageID = "a", type = "text", text = "partial"}}}})
                test.eq(#mapper.event(state, {type = "session.idle", properties = {sessionID = "s"}}), 0)
                test.eq(state.failure, "OpenCode idle omitted a completed reply")
            end
        end)
    end)
end
return test.run_cases(define_tests)
