-- MIT. Interactive acceptance of the real Claude permission exchange: the
-- version-recorded executable runs with the driver's exchange launch
-- shape against a scripted loopback endpoint that answers one Bash
-- tool_use, with an isolated home, a sentinel key and no provider. The
-- proof is behavioral: a typed request appears and the harness waits; a
-- correlated allow executes the action once; a deny prevents it and is
-- acknowledged by a correlated failed tool result; a wrong correlation and
-- silence authorize nothing and leave the harness waiting. Without the
-- executable the gate is reported open.
local test = require("test")
local exec = require("exec")
local env = require("env")
local registry = require("registry")
local time = require("time")
local channel = require("channel")
local json = require("json")
local stream_json = require("stream_json")
local protocol = require("protocol")
local adapter = require("adapter")
local launch = require("launch")
local ADAPTER = "bee.driver.claude:permission_adapter"
local SENTINEL = "sk-ant-sentinel-bee-000"
type Object = {[string]: unknown}
type Run = {observations: {Object}, request: adapter.Request?, boundary: integer}
local counter = 0
local function fresh(prefix: string): string
    counter = counter + 1
    return prefix .. "-" .. tostring(math.floor(time.now():unix_nano() / 1000)) .. "-" .. tostring(counter)
end
local function claude_bin(): string?
    local bin, err = env.get("bee.harness.catalog:claude_bin")
    if err or type(bin) ~= "string" or bin == "" then return nil end
    return bin
end
local function fixture_bin(): string
    local bin, err = env.get("bee.harness.catalog:fixture_bin")
    if err or type(bin) ~= "string" or bin == "" then error("BEE_FIXTURE_BIN is not set for the test runtime") end
    return bin
end
local function read_all(stream): string
    local content = ""
    while true do
        local chunk: unknown = stream:read(65536)
        if type(chunk) ~= "string" or chunk == "" then break end
        content = content .. (chunk :: string)
    end
    return content
end
local function shell(command: string): string
    local executor = assert(exec.get("bee.placement.native:executor"))
    local proc, exec_error = executor:exec("sh -c '" .. command .. "'")
    if not proc then error("exec " .. command .. ": " .. tostring(exec_error)) end
    local stdout = proc:stdout_stream()
    assert(proc:start())
    local output = read_all(stdout)
    proc:wait()
    stdout:close()
    executor:release()
    return output
end
local function encoded(line: string?, err: string?): string
    if not line then error("encode response: " .. tostring(err)) end
    return line
end
local function real_adapter(): adapter.Adapter
    local entry = registry.get(ADAPTER)
    if not entry then error("adapter entry") end
    local decoded, err = adapter.decode(ADAPTER, (entry.data :: Object).adapter)
    if not decoded then error(tostring(err)) end
    return decoded
end
-- The endpoint answers one Bash tool_use of the given command, then text.
local function start_endpoint(record: string, command: string): (string, any, any)
    local executor = assert(exec.get("bee.placement.native:executor"))
    local proc, err = executor:exec(fixture_bin() .. "/gateway-client endpoint " .. record, {env = {BEE_ENDPOINT_TOOL = command}})
    if not proc then error("endpoint: " .. tostring(err)) end
    assert(proc:start())
    for _ = 1, 100 do
        local port = shell("cat " .. record .. ".port 2>/dev/null"):match("%d+")
        if port then return port, proc, executor end
        time.sleep("50ms")
    end
    error("the endpoint did not report its port")
end
type Session = {proc: any, executor: any, chunks: any, feed: (string) -> (), run: Run, ended: boolean}
-- open runs the executable exactly as the driver launches it for an
-- exchange: the brief as the first stdin line, stdin kept open.
local function open(pinned: adapter.Adapter, claude: string, port: string, work: string, home: string): Session
    local decoded, decode_error = launch.decode({profile_id = "batch", brief = "leave a marker", permission_mode = "default", max_turns = 3, permission_exchange = true})
    if not decoded then error(tostring(decode_error)) end
    local specification = launch.specification(decoded)
    local executor = assert(exec.get("bee.placement.native:executor"))
    local command = claude
    for _, argument in ipairs(specification.argv) do command = command .. " " .. argument end
    local proc, err = executor:exec(command, {work_dir = work, env = {PATH = "/usr/bin:/bin", HOME = home, ANTHROPIC_API_KEY = SENTINEL, ANTHROPIC_BASE_URL = "http://127.0.0.1:" .. port}})
    if not proc then error("exec claude: " .. tostring(err)) end
    local stdout = proc:stdout_stream()
    assert(proc:start())
    local chunks = channel.new(16)
    coroutine.spawn(function()
        while true do
            local data: unknown = stdout:read(4096)
            if type(data) ~= "string" or data == "" then break end
            chunks:send(data)
        end
        chunks:send("")
    end)
    local written, write_error = proc:write_stdin(specification.stdin or "")
    if not written then error("write the brief: " .. tostring(write_error)) end
    local decoder = stream_json.new(65536)
    local state = protocol.new(false)
    local run: Run = {observations = {}, request = nil, boundary = 0}
    local function feed(data: string)
        for _, envelope in ipairs(stream_json.feed(decoder, data)) do
            local step = protocol.normalize(state, envelope.index, envelope.value)
            for _, observation in ipairs(step.observations) do
                run.observations[#run.observations + 1] = observation :: Object
                if not run.request then
                    local found = adapter.request(pinned, observation)
                    if found then run.request = found end
                end
            end
        end
    end
    return {proc = proc, executor = executor, chunks = chunks, feed = feed, run = run, ended = false}
end
-- observe reads until the predicate holds or the deadline passes; false
-- means the deadline passed with the harness still running quietly.
local function observe(session: Session, deadline: string, done: (Run) -> boolean): boolean
    local timer = time.after(deadline)
    while not done(session.run) do
        if session.ended then return false end
        local selected = channel.select({session.chunks:case_receive(), timer:case_receive()})
        if not selected.ok or selected.channel == timer then return false end
        local data = selected.value :: string
        if data == "" then
            session.ended = true
            return done(session.run)
        end
        session.feed(data)
    end
    return true
end
local function has_request(run: Run): boolean
    return run.request ~= nil
end
local function tool_result_after(run: Run, outcome: string?): Object?
    for index = run.boundary + 1, #run.observations do
        local observation = run.observations[index]
        if observation.type == "tool.result" then
            local data = observation.data :: Object
            if data.call_id == "toolu_bee_1" and (not outcome or data.outcome == outcome) then return observation end
        end
    end
    return nil
end
local function ended(run: Run): boolean
    for _, observation in ipairs(run.observations) do
        local data = observation.data :: Object
        if observation.type == "turn.signal" and data.phase == "ended" then return true end
    end
    return false
end
local function respond(session: Session, line: string)
    session.run.boundary = #session.run.observations
    local written, err = session.proc:write_stdin(line)
    if not written then error("write_stdin: " .. tostring(err)) end
end
local function close(session: Session)
    session.proc:signal(9)
    session.proc:wait()
    session.proc:close(true)
    session.executor:release()
end
local function define_tests()
    test.describe("Claude permission exchange acceptance", function()
        test.it("waits on a typed request, executes once on a correlated allow, refuses on deny, and keeps waiting through a wrong correlation and silence, or reports the gate open", function()
            local claude = claude_bin()
            if not claude then
                test.eq(launch.CLAUDE_AUTHENTICATION, "unproven")
                return
            end
            if not shell(claude .. " --version"):find("Claude Code", 1, true) then error("not the Claude executable") end
            local pinned = real_adapter()
            local root = ".wippy/claude-acceptance-" .. fresh("run")
            local function case(name: string, drive: (Session, string) -> ())
                local work, home = root .. "/" .. name .. "/work", root .. "/" .. name .. "/home"
                shell("mkdir -p " .. work .. " " .. home)
                local record = root .. "/" .. name .. "/endpoint.jsonl"
                local port, endpoint, endpoint_executor = start_endpoint(record, "touch proof.txt")
                local session = open(pinned, claude, port, work, home)
                if not observe(session, "20s", has_request) then error(name .. ": no permission request observed; observations " .. tostring(#session.run.observations)) end
                local request = session.run.request :: adapter.Request
                test.eq(request.tool_name, "Bash")
                test.eq(request.acknowledgment_id, "toolu_bee_1")
                test.is_nil(tool_result_after(session.run, nil))
                drive(session, work)
                close(session)
                endpoint:signal(9)
                endpoint:wait()
                endpoint:close(true)
                endpoint_executor:release()
                local recorded = shell("cat " .. record)
                if not recorded:find('"x_api_key": "' .. SENTINEL .. '"', 1, true) then error(name .. ": the endpoint saw no api key") end
                for _, observation in ipairs(session.run.observations) do
                    test.is_nil(json.encode(observation):find(SENTINEL, 1, true))
                end
            end
            case("allow", function(session: Session, work: string)
                local request = session.run.request :: adapter.Request
                respond(session, encoded(adapter.allow(pinned, request, nil)))
                if not observe(session, "20s", ended) then
                    local seen: {string} = {}
                    for index = session.run.boundary + 1, #session.run.observations do
                        local observation = session.run.observations[index]
                        seen[#seen + 1] = tostring(observation.type) .. ":" .. tostring((observation.data :: Object).code or (observation.data :: Object).event_name or (observation.data :: Object).phase or "")
                    end
                    error("allow: the turn did not end; ended " .. tostring(session.ended) .. "; marker " .. shell("ls " .. work) .. "; after the response: " .. table.concat(seen, ","))
                end
                local echo = tool_result_after(session.run, "succeeded")
                if not echo then error("allow: no correlated tool result") end
                test.is_true(adapter.acknowledged(pinned, request, echo))
                test.eq(shell("ls " .. work):find("proof.txt", 1, true) ~= nil, true)
                local consistent, err = adapter.transcript_consistent(pinned, session.run.observations, session.run.boundary)
                if not consistent then error("allow: " .. tostring(err)) end
            end)
            case("deny", function(session: Session, work: string)
                local request = session.run.request :: adapter.Request
                respond(session, encoded(adapter.deny(pinned, request, "decision denied")))
                if not observe(session, "20s", ended) then error("deny: the turn did not end") end
                local denial = tool_result_after(session.run, "failed")
                if not denial then error("deny: no correlated failed tool result") end
                test.is_true(adapter.deny_acknowledged(pinned, request, denial))
                test.is_nil(tool_result_after(session.run, "succeeded"))
                test.eq(shell("ls " .. work):find("proof.txt", 1, true), nil)
            end)
            case("wrong", function(session: Session, work: string)
                local request = session.run.request :: adapter.Request
                local other: adapter.Request = {permission_request_id = request.permission_request_id, correlation_id = "not-" .. request.correlation_id, acknowledgment_id = request.acknowledgment_id,
                    tool_name = request.tool_name, input_digest = request.input_digest, input = request.input, prompt = request.prompt}
                respond(session, encoded(adapter.allow(pinned, other, nil)))
                test.is_false(observe(session, "3s", function(run: Run): boolean return tool_result_after(run, nil) ~= nil or ended(run) end))
                test.is_false(session.ended)
                test.eq(shell("ls " .. work):find("proof.txt", 1, true), nil)
                -- Still waiting: the correlated allow now executes it.
                respond(session, encoded(adapter.allow(pinned, request, nil)))
                if not observe(session, "20s", ended) then error("wrong: the turn did not end after the correlated allow") end
                test.not_nil(tool_result_after(session.run, "succeeded"))
                test.eq(shell("ls " .. work):find("proof.txt", 1, true) ~= nil, true)
            end)
            case("silence", function(session: Session, work: string)
                local request = session.run.request :: adapter.Request
                test.is_false(observe(session, "3s", function(run: Run): boolean return tool_result_after(run, nil) ~= nil or ended(run) end))
                test.is_false(session.ended)
                test.eq(shell("ls " .. work):find("proof.txt", 1, true), nil)
                -- Still waiting: the deny is acknowledged and nothing ran.
                respond(session, encoded(adapter.deny(pinned, request, "decision denied")))
                if not observe(session, "20s", ended) then error("silence: the turn did not end after the deny") end
                test.not_nil(tool_result_after(session.run, "failed"))
                test.is_nil(tool_result_after(session.run, "succeeded"))
                test.eq(shell("ls " .. work):find("proof.txt", 1, true), nil)
            end)
            shell("rm -rf " .. root)
            test.eq(launch.CLAUDE_AUTHENTICATION, "unproven")
        end)
    end)
end
return test.run_cases(define_tests)
