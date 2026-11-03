-- MIT. Agy's hook stdin as the Bee hook payload: tool gates map to tool
-- fields, and a turn's prompt and answer come from the conversation
-- transcript, read from its end back to the latest prompt.
local test = require("test")
local fs = require("fs")
local env = require("env")
local funcs = require("funcs")
local json = require("json")
local time = require("time")
local bounds = require("bounds")
local READER = "bee.driver.agy.hooks:input"
local TRANSCRIPT = ".system_generated/logs/transcript_full.jsonl"
type Object = {[string]: unknown}
local counter = 0

local function read(event: string, hook: Object): Object
    local reply, err = funcs.call(READER, {event = event, body = assert(json.encode(hook))})
    if err then error(tostring(err)) end
    return assert(bounds.object(reply))
end

local function fixture(path: string): string
    local volume = assert(fs.get("bee.tests.driver:fixtures"))
    return assert(volume:readfile(path))
end

-- conversation writes a transcript under a fresh artifact directory named for
-- the conversation and returns the hook fields that locate it.
local function conversation(id: string, content: string): Object
    counter = counter + 1
    local volume = assert(fs.get("bee.tests.driver:agy_artifacts"))
    local relative = tostring(time.now():unix_nano()) .. "-" .. tostring(counter) .. "/brain/" .. id
    local path = ""
    for part in (relative .. "/.system_generated/logs"):gmatch("[^/]+") do
        path = path == "" and part or path .. "/" .. part
        if not volume:exists(path) then assert(volume:mkdir(path)) end
    end
    assert(volume:writefile(relative .. "/" .. TRANSCRIPT, content))
    local artifact = assert(env.get("bee.tests.driver:agy_artifact_root")) .. "/" .. relative
    return {conversationId = id, artifactDirectoryPath = artifact, transcriptPath = artifact .. "/" .. TRANSCRIPT}
end

local function with(fields: Object, extra: Object): Object
    local result: Object = {}
    for key, value in pairs(fields) do result[key] = value end
    for key, value in pairs(extra) do result[key] = value end
    return result
end

local function captured(path: string, located: Object): Object
    return with(assert(bounds.object(json.decode(fixture(path)))), located)
end

local function define_tests()
    test.describe("Agy hook input", function()
        test.it("maps permission and tool gates to tool fields and refuses an unidentified call", function()
            local gate = {conversationId = "fixture-session", stepIdx = 19, toolCall = {name = "run_command", args = {CommandLine = "printf x"}}}
            local permission = assert(bounds.object(read("PermissionRequest", gate).payload))
            test.eq(permission.session_id, "fixture-session")
            test.eq(permission.tool_name, "run_command")
            test.eq(permission.hook_event_name, "PermissionRequest")
            test.is_nil(permission.tool_call_id)
            test.eq(assert(bounds.object(read("PreToolUse", gate).payload)).tool_call_id, "19")
            test.not_nil(read("PreToolUse", with(gate, {stepIdx = -1})).error)
            test.not_nil(read("PreToolUse", {conversationId = "fixture-session", stepIdx = 1, toolCall = {name = "../x", args = {}}}).error)
            test.not_nil(read("PreToolUse", {conversationId = ".hidden", stepIdx = 1, toolCall = {name = "x", args = {}}}).error)
        end)

        test.it("reads the captured prompt and answer and refuses an unrelated file", function()
            local located = conversation("ef06ab43-51b5-4911-8a6f-f4700e9a3193", fixture("agy/hooks-1/transcript.jsonl"))
            local prompt = read("UserPromptSubmit", captured("agy/hooks-1/PreInvocation.json", located))
            test.eq(assert(bounds.object(prompt.payload)).prompt, "Fixture prompt.")
            test.eq(assert(bounds.object(prompt.payload)).session_id, located.conversationId)
            local stop = read("Stop", captured("agy/hooks-1/Stop.json", located))
            test.eq(assert(bounds.object(stop.payload)).last_assistant_message, "Fixture answer.")
            test.is_true(read("UserPromptSubmit", with(captured("agy/hooks-1/PreInvocation.json", located), {invocationNum = 1})).skip == true)
            local unrelated = with(captured("agy/hooks-1/Stop.json", located), {transcriptPath = tostring(located.artifactDirectoryPath) .. "/auth.json"})
            test.not_nil(read("Stop", unrelated).error)
        end)

        test.it("refuses an incomplete transcript and an active provider", function()
            local prompt = '{"step_index":0,"type":"USER_INPUT","source":"USER_EXPLICIT","status":"DONE","content":"Fixture prompt."}\n'
            for _, content in ipairs({prompt, prompt .. '{"step_index":1,"type":"PLANNER_RESPONSE","status":"ACTIVE","content":"unfinished"}\n', "{broken"}) do
                local located = conversation("fixture-session", content)
                test.not_nil(read("Stop", with(located, {fullyIdle = true, error = ""})).error)
            end
            local located = conversation("fixture-session", prompt .. '{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","content":"done"}\n')
            test.eq(assert(bounds.object(read("Stop", with(located, {fullyIdle = true, error = ""})).payload)).last_assistant_message, "done")
            test.not_nil(read("Stop", with(located, {fullyIdle = false})).error)
            test.not_nil(read("Stop", with(located, {fullyIdle = true, error = "quota"})).error)
        end)

        test.it("reads the current turn from the end of a long resumed conversation", function()
            local filler = '{"step_index":%d,"source":"MODEL","type":"GENERIC","status":"DONE","content":"' .. string.rep("x", 50000) .. '"}\n'
            local lines: {string} = {}
            for index = 0, 799 do lines[#lines + 1] = string.format(filler, index) end
            lines[#lines + 1] = '{"step_index":800,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","content":"<USER_REQUEST>\\nwe back\\n</USER_REQUEST>\\n<ADDITIONAL_METADATA>\\nlocal time\\n</ADDITIONAL_METADATA>"}\n'
            lines[#lines + 1] = '{"step_index":801,"source":"SYSTEM","type":"SYSTEM_MESSAGE","status":"DONE","content":"ephemeral"}\n'
            local content = table.concat(lines)
            test.is_true(#content > 33554432, "the transcript exceeds one turn's bound")
            local located = conversation("conversation-1", content)
            local prompt = assert(bounds.object(read("UserPromptSubmit", with(located, {invocationNum = 0, initialNumSteps = 802})).payload))
            test.eq(prompt.prompt, "we back")
            test.eq(prompt.prompt_id, "800")
            local answered = conversation("conversation-1", content .. '{"step_index":802,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","content":"Welcome back."}\n')
            local stop = assert(bounds.object(read("Stop", with(answered, {fullyIdle = true, error = ""})).payload))
            test.eq(stop.last_assistant_message, "Welcome back.")
            test.eq(stop.prompt_id, "800")
        end)

        test.it("holds no prompt for an invocation after the model answered the latest prompt", function()
            local located = conversation("conversation-1", table.concat({
                '{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","content":"Fixture prompt."}\n',
                '{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","content":"Started."}\n',
                '{"step_index":2,"source":"SYSTEM","type":"SYSTEM_MESSAGE","status":"DONE","content":"background command finished"}\n'}))
            test.is_true(read("UserPromptSubmit", with(located, {invocationNum = 0, initialNumSteps = 3})).skip == true)
        end)

        test.it("reads a captured resumed turn of Antigravity 1.4.12", function()
            local located = conversation("ee6a08a2-71ef-462b-99a2-81fa84aa835e", fixture("agy/hooks-1.4.12/transcript_full.jsonl"))
            local prompt = assert(bounds.object(read("UserPromptSubmit", captured("agy/hooks-1.4.12/10-PreInvocation.json", located)).payload))
            test.eq(prompt.prompt, "Read a.txt, then reply with its content.")
            test.eq(prompt.prompt_id, "6")
            local stop = assert(bounds.object(read("Stop", captured("agy/hooks-1.4.12/16-Stop.json", located)).payload))
            test.eq(stop.last_assistant_message, "alpha")
            test.eq(stop.prompt_id, "6")
        end)
    end)
end
return test.run_cases(define_tests)
