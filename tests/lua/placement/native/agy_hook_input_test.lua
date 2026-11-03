-- MIT. Agy's hook stdin as the Bee hook payload. Tool gates map to tool
-- fields; a turn's prompt and answer come from the conversation transcript,
-- which the session's placement reads only under the hook_files directory
-- the Agy descriptor declares in that session's own HOME.
local test = require("test")
local fs = require("fs")
local funcs = require("funcs")
local security = require("security")
local json = require("json")
local bounds = require("bounds")
local store = require("store")
local request_codec = require("request_codec")
local placement_types = require("placement_types")
local homes = require("homes")
local native_fixture = require("native_fixture")
local READER = "bee.driver.agy.hooks:input"
local BRAIN = ".gemini/antigravity-cli/brain"
local TRANSCRIPT = ".system_generated/logs/transcript_full.jsonl"
type Object = {[string]: unknown}
type Session = {attempt_id: string, home: string, base: string}

local function fixture(path: string): string
    local volume = assert(fs.get("bee.tests.driver:fixtures"))
    return assert(volume:readfile(path))
end

-- session records an Agy attempt with a retained private HOME.
local function session(binding_ref: string?): Session
    local session_ref = native_fixture.fresh("agy-session")
    local request = native_fixture.launch({"sh", "-c", "true"}, "direct_process")
    request.binding_ref = binding_ref or "bee.drivers.agy.binding:binding"
    request.session_ref = session_ref
    local declared = assert(bounds.object(request.launch))
    declared.home_ref = "session"
    local resources = assert(bounds.array(request.resources))
    resources[#resources + 1] = {name = "session", grant_ref = "session-grant", root_ref = native_fixture.ROOT, subpath = "", access = "write", purpose = "session"}
    request.resources = resources
    local db = assert(store.open())
    local decoded, decode_error = request_codec.decode(request)
    if not decoded then error(tostring(decode_error)) end
    local delivery: placement_types.ConfigurationDelivery = {arguments = {}, files = {}}
    decoded.delivery = delivery
    native_fixture.intend_materialization(db, decoded)
    db:release()
    local base = assert(homes.ensure_session(assert(homes.session_key(native_fixture.OWNER, session_ref)))) .. "/home"
    return {attempt_id = tostring(request.attempt_id), home = assert(homes.os_path(base)), base = base}
end

-- write puts content at a path relative to the session's HOME.
local function write(owner: Session, relative: string, content: string)
    local volume = assert(homes.private_volume())
    local path = owner.base
    for part in relative:match("^(.*)/[^/]+$"):gmatch("[^/]+") do
        path = path .. "/" .. part
        if not volume:exists(path) then assert(volume:mkdir(path)) end
    end
    assert(volume:writefile(owner.base .. "/" .. relative, content))
end

-- conversation writes a transcript where Agy keeps it and returns the hook
-- fields that locate it.
local function conversation(owner: Session, id: string, content: string): Object
    local relative = BRAIN .. "/" .. id
    write(owner, relative .. "/" .. TRANSCRIPT, content)
    local artifact = owner.home .. "/" .. relative
    return {conversationId = id, artifactDirectoryPath = artifact, transcriptPath = artifact .. "/" .. TRANSCRIPT}
end

local function read(owner: Session, event: string, hook: Object): Object
    local isolated = assert(funcs.new():with_scope(security.new_scope({})))
    local reply, err = isolated:call(READER, {event = event, body = assert(json.encode(hook)), attempt_id = owner.attempt_id})
    if err then error(tostring(err)) end
    return assert(bounds.object(reply))
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

local function payload_of(reply: Object): Object
    return assert(bounds.object(reply.payload), tostring(reply.error))
end

local function refused(reply: Object): string
    return tostring(reply.error)
end

local function define_tests()
    test.describe("Agy hook input", function()
        test.it("maps permission and tool gates to tool fields and refuses an unidentified call", function()
            local owner = session()
            local gate = {conversationId = "fixture-session", stepIdx = 19, toolCall = {name = "run_command", args = {CommandLine = "printf x"}}}
            local permission = payload_of(read(owner, "PermissionRequest", gate))
            test.eq(permission.session_id, "fixture-session")
            test.eq(permission.tool_name, "run_command")
            test.eq(permission.hook_event_name, "PermissionRequest")
            test.is_nil(permission.tool_call_id)
            test.eq(payload_of(read(owner, "PreToolUse", gate)).tool_call_id, "19")
            test.not_nil(read(owner, "PreToolUse", with(gate, {stepIdx = -1})).error)
            test.not_nil(read(owner, "PreToolUse", {conversationId = "fixture-session", stepIdx = 1, toolCall = {name = "../x", args = {}}}).error)
            test.not_nil(read(owner, "PreToolUse", {conversationId = ".hidden", stepIdx = 1, toolCall = {name = "x", args = {}}}).error)
        end)

        test.it("reads the captured prompt and answer and refuses an unrelated file", function()
            local owner = session()
            local located = conversation(owner, "ef06ab43-51b5-4911-8a6f-f4700e9a3193", fixture("agy/hooks-1/transcript.jsonl"))
            local prompt = payload_of(read(owner, "UserPromptSubmit", captured("agy/hooks-1/PreInvocation.json", located)))
            test.eq(prompt.prompt, "Fixture prompt.")
            test.eq(prompt.session_id, located.conversationId)
            local stop = payload_of(read(owner, "Stop", captured("agy/hooks-1/Stop.json", located)))
            test.eq(stop.last_assistant_message, "Fixture answer.")
            test.is_true(read(owner, "UserPromptSubmit", with(captured("agy/hooks-1/PreInvocation.json", located), {invocationNum = 1})).skip == true)
            local unrelated = with(captured("agy/hooks-1/Stop.json", located), {transcriptPath = tostring(located.artifactDirectoryPath) .. "/auth.json"})
            test.not_nil(read(owner, "Stop", unrelated).error)
        end)

        test.it("refuses a transcript outside the session's own declared directory", function()
            local owner, other = session(), session()
            local prompt = '{"step_index":0,"type":"USER_INPUT","source":"USER_EXPLICIT","status":"DONE","content":"p"}\n'
                .. '{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","content":"a"}\n'
            local foreign = conversation(other, "conversation-1", prompt)
            local answer = read(owner, "Stop", with(foreign, {fullyIdle = true, error = ""}))
            test.is_true(refused(answer):find("outside the attempt's HOME", 1, true) ~= nil, refused(answer))
            write(owner, "notes/conversation-1/" .. TRANSCRIPT, prompt)
            local artifact = owner.home .. "/notes/conversation-1"
            local undeclared = read(owner, "Stop", {conversationId = "conversation-1", artifactDirectoryPath = artifact,
                transcriptPath = artifact .. "/" .. TRANSCRIPT, fullyIdle = true, error = ""})
            test.is_true(refused(undeclared):find("outside the hook files", 1, true) ~= nil, refused(undeclared))
            local linked = conversation(owner, "linked", prompt)
            native_fixture.shell("ln -sf /etc/hostname '" .. tostring(linked.transcriptPath) .. "'")
            test.not_nil(read(owner, "Stop", with(linked, {fullyIdle = true, error = ""})).error, "a link out of the placement root is not followed")
            local own = conversation(owner, "conversation-1", prompt)
            test.eq(payload_of(read(owner, "Stop", with(own, {fullyIdle = true, error = ""}))).last_assistant_message, "a")
        end)

        test.it("refuses an incomplete transcript and an active provider", function()
            local owner = session()
            local prompt = '{"step_index":0,"type":"USER_INPUT","source":"USER_EXPLICIT","status":"DONE","content":"Fixture prompt."}\n'
            for index, content in ipairs({prompt, prompt .. '{"step_index":1,"type":"PLANNER_RESPONSE","status":"ACTIVE","content":"unfinished"}\n', "{broken"}) do
                local located = conversation(owner, "incomplete-" .. tostring(index), content)
                test.not_nil(read(owner, "Stop", with(located, {fullyIdle = true, error = ""})).error)
            end
            local located = conversation(owner, "complete", prompt .. '{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","content":"done"}\n')
            test.eq(payload_of(read(owner, "Stop", with(located, {fullyIdle = true, error = ""}))).last_assistant_message, "done")
            test.not_nil(read(owner, "Stop", with(located, {fullyIdle = false})).error)
            test.not_nil(read(owner, "Stop", with(located, {fullyIdle = true, error = "quota"})).error)
        end)

        test.it("reads the current turn from the end of a long resumed conversation", function()
            local owner = session()
            local filler = '{"step_index":%d,"source":"MODEL","type":"GENERIC","status":"DONE","content":"' .. string.rep("x", 50000) .. '"}\n'
            local lines: {string} = {}
            for index = 0, 799 do lines[#lines + 1] = string.format(filler, index) end
            lines[#lines + 1] = '{"step_index":800,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","content":"<USER_REQUEST>\\nwe back\\n</USER_REQUEST>\\n<ADDITIONAL_METADATA>\\nlocal time\\n</ADDITIONAL_METADATA>"}\n'
            lines[#lines + 1] = '{"step_index":801,"source":"SYSTEM","type":"SYSTEM_MESSAGE","status":"DONE","content":"ephemeral"}\n'
            local content = table.concat(lines)
            test.is_true(#content > 33554432, "the transcript exceeds one turn's bound")
            local located = conversation(owner, "conversation-1", content)
            local prompt = payload_of(read(owner, "UserPromptSubmit", with(located, {invocationNum = 0, initialNumSteps = 802})))
            test.eq(prompt.prompt, "we back")
            test.eq(prompt.prompt_id, "800")
            local answered = conversation(owner, "conversation-1", content .. '{"step_index":802,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","content":"Welcome back."}\n')
            local stop = payload_of(read(owner, "Stop", with(answered, {fullyIdle = true, error = ""})))
            test.eq(stop.last_assistant_message, "Welcome back.")
            test.eq(stop.prompt_id, "800")
        end)

        test.it("reads a prompt up to the 64 KiB a session hook prompt carries and refuses a larger one", function()
            local owner = session()
            local function transcript(prompt: string): string
                return assert(json.encode({step_index = 0, source = "USER_EXPLICIT", type = "USER_INPUT", status = "DONE",
                    content = "<USER_REQUEST>\n" .. prompt .. "\n</USER_REQUEST>"})) .. "\n"
            end
            local row = '\t{"level":"info","msg":"a \\"quoted\\" log line"}\n'
            local large = string.rep(row, 65536 // #row)
            large = large .. string.rep("x", 65536 - #large)
            local located = conversation(owner, "conversation-large", transcript(large))
            test.eq(payload_of(read(owner, "UserPromptSubmit", with(located, {invocationNum = 0, initialNumSteps = 1}))).prompt, large)
            local oversized = conversation(owner, "conversation-oversized", transcript(large .. "x"))
            test.contains(refused(read(owner, "UserPromptSubmit", with(oversized, {invocationNum = 0, initialNumSteps = 1}))), "exceeds its bound")
        end)
        test.it("holds no prompt for an invocation after the model answered the latest prompt", function()
            local owner = session()
            local located = conversation(owner, "conversation-1", table.concat({
                '{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","content":"Fixture prompt."}\n',
                '{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","content":"Started."}\n',
                '{"step_index":2,"source":"SYSTEM","type":"SYSTEM_MESSAGE","status":"DONE","content":"background command finished"}\n'}))
            test.is_true(read(owner, "UserPromptSubmit", with(located, {invocationNum = 0, initialNumSteps = 3})).skip == true)
        end)

        test.it("reads a hook file under a third-party driver's declared directory", function()
            local owner = session("bee.tests.placement.native:third_party_cli")
            write(owner, ".outside/logs/turn.json", "{}")
            write(owner, ".outside/private.json", "{}")
            local reader = assert(funcs.new():with_scope(security.new_scope({})))
            local function hook_file(relative: string): Object
                local reply, err = reader:call("bee.placement.native.binding:hook_file",
                    {attempt_id = owner.attempt_id, path = owner.home .. "/" .. relative, offset = 0, length = 16})
                if err then error(tostring(err)) end
                return assert(bounds.object(reply))
            end
            local declared = hook_file(".outside/logs/turn.json")
            test.is_true(declared.ok == true, tostring(declared.error and bounds.object(declared.error) and (bounds.object(declared.error) or {}).message))
            test.eq((bounds.object(declared.value) or {}).data, "{}")
            test.is_false(hook_file(".outside/private.json").ok == true)
        end)

        test.it("reads a captured resumed turn of Antigravity 1.4.12", function()
            local owner = session()
            local located = conversation(owner, "ee6a08a2-71ef-462b-99a2-81fa84aa835e", fixture("agy/hooks-1.4.12/transcript_full.jsonl"))
            local prompt = payload_of(read(owner, "UserPromptSubmit", captured("agy/hooks-1.4.12/10-PreInvocation.json", located)))
            test.eq(prompt.prompt, "Read a.txt, then reply with its content.")
            test.eq(prompt.prompt_id, "6")
            local stop = payload_of(read(owner, "Stop", captured("agy/hooks-1.4.12/16-Stop.json", located)))
            test.eq(stop.last_assistant_message, "alpha")
            test.eq(stop.prompt_id, "6")
        end)
    end)
end
return {run = native_fixture.suite(define_tests)}
