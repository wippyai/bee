-- MIT. Native placement execution regressions.
local test = require("test")
local bounds = require("bounds")
local principals = require("principals")
local funcs = require("funcs")
local sql = require("sql")
local security = require("security")
local process = require("process")
local runner_fixture = require("runner_fixture")
local channel = require("channel")
local time = require("time")
local registry = require("registry")
local exec = require("exec")
local fs = require("fs")
local service = require("service")
local identity = require("identity")
local configuration = require("configuration")
local grok_configuration = require("grok_configuration")
local grok_launch = require("grok_launch")
local claude_launch = require("claude_launch")
local codex_launch = require("codex_launch")
local agy_launch = require("agy_launch")
local muse_launch = require("muse_launch")
local opencode_launch = require("opencode_launch")
local configuration_protocol = require("configuration_protocol")
local preferences = require("preferences")
local hash = require("hash")
local json = require("json")
local store = require("store")
local materialization = require("materialization")
local resources = require("resources")
local request_codec = require("request_codec")
local protocol = require("protocol")
local output_buffer = require("output_buffer")
local homes = require("homes")
local quote = require("quote")
local types = require("types")
local placement_decode = require("placement_decode")
local executable_stream = require("executable_stream")
local exits = require("exits")
local native_fixture = require("native_fixture")
type PreparedConfiguration = {environment: {[string]: string}, working_directory: string, arguments: {string}}

local function execution_tests()
    test.describe("Native placement execution", function()
        local measured = native_fixture.value(service.capabilities())
        local capability = tostring(measured.capability)
        local observation = tostring(measured.exit_observation)
        test.it("refuses a duplicate runner before it can materialize the claimed attempt", function()
            local prepared = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", native_fixture.launch({"sh", "-c", "true"}, "direct_process")))
            local db, open_error = store.open()
            if not db then error(open_error or "store") end
            local winner = process.pid()
            local claimed = store.transition(db, prepared.attempt_id, {expected_execution = "intended", execution = "starting",
                fields = {runner_pid = winner}, evidence = {kind = "test.claimed", detail = "first runner already owns materialization"}})
            if not claimed.ok then db:release(); error(claimed.message or "claim") end
            local topic = "bee.test.duplicate-runner." .. native_fixture.fresh("reply")
            local replies = assert(process.listen(topic, {message = true}))
            local duplicate, spawn_error = process.spawn("bee.placement.native.service:runner", "bee:workers", prepared.attempt_id, process.pid(), topic)
            if not duplicate then process.unlisten(replies); db:release(); error(tostring(spawn_error)) end
            local selected = channel.select({replies:case_receive(), time.after("5s"):case_receive()})
            process.unlisten(replies)
            if not selected.ok or selected.channel ~= replies then db:release(); error("duplicate runner did not answer") end
            test.eq(tostring(selected.value:from()), tostring(duplicate))
            local reply = selected.value:payload():data()
            test.is_false(reply.started)
            test.is_true((reply.reason or ""):find("attempt belongs to another runner", 1, true) ~= nil)
            local row = store.row(db, prepared.attempt_id)
            if not row then db:release(); error("attempt disappeared") end
            test.eq(row.runner_pid, winner)
            test.eq(row.execution_state, "starting")
            test.eq(row.evidence_count, 2)
            local home_key = assert(homes.attempt_key(native_fixture.OWNER, prepared.attempt_id))
            test.is_false(homes.attempt_exists(home_key))
            db:release()
        end)
        test.it("rejects runner control messages from an unauthenticated sender", function()
            local request = native_fixture.launch({"sh", "-c", "sleep 5"}, "direct_process")
            local prepared = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", request))
            local fences = assert(process.listen(protocol.TOPIC_FENCED, {message = true}))
            local statuses = assert(process.listen(protocol.TOPIC_STATUS, {message = true}))
            local exits = assert(process.listen(protocol.TOPIC_EXIT, {message = true}))
            local outputs = assert(process.listen(protocol.TOPIC_OUTPUT, {message = true}))
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "attach", {attempt_id = prepared.attempt_id, recipient = process.pid(), generation = 1}))
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "start", {attempt_id = prepared.attempt_id}))
            local db = assert(store.open())
            local row = store.row(db, prepared.attempt_id)
            db:release()
            local runner = tostring(row and row.runner_pid)

            process.send(runner, protocol.TOPIC_CONTROL, {command = "attach", recipient = process.pid(), generation = 2})
            local attach_deadline = time.after("200ms")
            local forged_attach_accepted = false
            while true do
                local attach_reply = channel.select({fences:case_receive(), attach_deadline:case_receive()})
                if not attach_reply.ok or attach_reply.channel == attach_deadline then break end
                local data: unknown = attach_reply.value:payload():data()
                if tostring(attach_reply.value:from()) == runner and type(data) == "table"
                    and data.attempt_id == prepared.attempt_id and data.generation == 2 then
                    forged_attach_accepted = data.fenced == true
                    break
                end
            end

            process.send(runner, protocol.TOPIC_CONTROL, {command = "status", attempt_id = prepared.attempt_id, probe = "forged-probe"})
            local status_deadline = time.after("200ms")
            local forged_status_accepted = false
            while true do
                local status_reply = channel.select({statuses:case_receive(), status_deadline:case_receive()})
                if not status_reply.ok or status_reply.channel == status_deadline then break end
                local data: unknown = status_reply.value:payload():data()
                if tostring(status_reply.value:from()) == runner and type(data) == "table"
                    and data.attempt_id == prepared.attempt_id and data.probe == "forged-probe" then
                    forged_status_accepted = true
                    break
                end
            end

            process.send(runner, protocol.TOPIC_CONTROL, {command = "stop", mode = "forced", grace_ms = 1})
            local stop_deadline = time.after("200ms")
            local forged_stop_accepted = false
            while true do
                local stop_reply = channel.select({exits:case_receive(), stop_deadline:case_receive()})
                if not stop_reply.ok or stop_reply.channel == stop_deadline then break end
                local data: unknown = stop_reply.value:payload():data()
                if tostring(stop_reply.value:from()) == runner and type(data) == "table"
                    and data.attempt_id == prepared.attempt_id then
                    forged_stop_accepted = true
                    break
                end
            end

            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "stop", {attempt_id = prepared.attempt_id, mode = "forced"}))
            local exit_seen = forged_stop_accepted
            if not exit_seen then
                local exit_deadline = time.after("5s")
                while true do
                    local stopped = channel.select({exits:case_receive(), exit_deadline:case_receive()})
                    if not stopped.ok or stopped.channel == exit_deadline then break end
                    local data: unknown = stopped.value:payload():data()
                    if type(data) == "table" and data.attempt_id == prepared.attempt_id then exit_seen = true; break end
                end
            end
            test.is_true(exit_seen, "authorized stop did not deliver the fixture child exit")
            test.is_true(native_fixture.wait_for(function()
                return (native_fixture.value(native_fixture.call(native_fixture.OWNER, "status", {attempt_id = prepared.attempt_id})).attempt).execution_state == "exited"
            end, 5000), "authorized stop did not finish the fixture child")
            local eof_count = 0
            local output_deadline = time.after("5s")
            while eof_count < 2 do
                local output = channel.select({outputs:case_receive(), output_deadline:case_receive()})
                assert(output.ok and output.channel == outputs, "runner did not close both output streams")
                local data: unknown = output.value:payload():data()
                if type(data) == "table" and data.attempt_id == prepared.attempt_id then
                    if type(data.sequence) == "number" then
                        process.send(runner, protocol.TOPIC_ACK, {generation = data.generation, consumed_through = data.sequence})
                    end
                    if data.eof == true then eof_count = eof_count + 1 end
                end
            end
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "cleanup", {attempt_id = prepared.attempt_id}))
            process.unlisten(fences)
            process.unlisten(statuses)
            process.unlisten(exits)
            process.unlisten(outputs)

            test.is_false(forged_attach_accepted, "unauthenticated attach received a fence reply")
            test.is_false(forged_status_accepted, "unauthenticated status received runner state")
            test.is_false(forged_stop_accepted, "unauthenticated stop ended the child")
        end)
        test.it("restores the prior attachment when the runner refuses a replacement recipient", function()
            local request = native_fixture.launch({"sh", "-c", "exec tail -f /dev/null"}, "direct_process")
            local prepared = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", request))
            local outputs = assert(process.listen(protocol.TOPIC_OUTPUT, {message = true}))
            local attached = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "attach", {attempt_id = prepared.attempt_id, recipient = process.pid(), generation = 1}))
            test.eq(attached.attachment_generation, 1)
            local started = native_fixture.call(native_fixture.OWNER, "start", {attempt_id = prepared.attempt_id})
            local refused = started.ok and native_fixture.call(native_fixture.OWNER, "attach", {attempt_id = prepared.attempt_id,
                recipient = "00000000-0000-0000-0000-000000000001", generation = 2}) or started
            local after_refusal = (native_fixture.value(native_fixture.call(native_fixture.OWNER, "status", {attempt_id = prepared.attempt_id})).attempt)
            local db = assert(store.open())
            local after_row = store.row(db, prepared.attempt_id)
            db:release()
            local stopped = native_fixture.call(native_fixture.OWNER, "stop", {attempt_id = prepared.attempt_id, mode = "forced"})
            test.is_true(stopped.ok, "refusal fixture child did not accept stop")
            local eof_count = 0
            local deadline = time.after("5s")
            while eof_count < 2 do
                local output = channel.select({outputs:case_receive(), deadline:case_receive()})
                assert(output.ok and output.channel == outputs, "refusal fixture runner did not close its output streams")
                local data: unknown = output.value:payload():data()
                if type(data) == "table" and data.attempt_id == prepared.attempt_id then
                    local db = assert(store.open())
                    local row = store.row(db, prepared.attempt_id)
                    db:release()
                    if type(data.sequence) == "number" then
                        process.send(tostring(row and row.runner_pid), protocol.TOPIC_ACK,
                            {generation = data.generation, consumed_through = data.sequence})
                    end
                    if data.eof == true then eof_count = eof_count + 1 end
                end
            end
            local finished = native_fixture.wait_for(function()
                return (native_fixture.value(native_fixture.call(native_fixture.OWNER, "status", {attempt_id = prepared.attempt_id})).attempt).execution_state == "exited"
            end, 3000)
            local final = (native_fixture.value(native_fixture.call(native_fixture.OWNER, "status", {attempt_id = prepared.attempt_id})).attempt)
            local cleaned = native_fixture.call(native_fixture.OWNER, "cleanup", {attempt_id = prepared.attempt_id})
            process.unlisten(outputs)

            test.is_true(started.ok, "refusal fixture runner did not start")
            test.eq(refused.error and refused.error.code, "CONFLICT", "runner did not report a definite recipient refusal")
            test.eq(after_refusal.execution_state, "running", "definite attachment refusal made a live attempt uncertain")
            test.eq(after_refusal.attachment_generation, 1, "refused recipient replaced the committed generation")
            test.eq(after_row and after_row.recipient, process.pid(), "refused recipient replaced the committed carrier")
            test.is_true(finished, "refusal fixture child did not exit")
            test.eq(final.execution_state, "exited")
            test.is_true(cleaned.ok, "refusal fixture cleanup did not complete")
        end)
        test.it("runs a child through the runner with acknowledged streams and a proven exit", function()
            local request = native_fixture.launch({"sh", "-c", "echo start:$PROBE_VALUE; pwd; read line; echo got:$line; echo warn 1>&2"}, "direct_process")
            local prepared = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", request))
            local outputs = assert(process.listen(protocol.TOPIC_OUTPUT, {message = true}))
            local acks = assert(process.listen(protocol.TOPIC_ACK, {message = true}))
            local exits = assert(process.listen(protocol.TOPIC_EXIT, {message = true}))
            local stale = native_fixture.call(native_fixture.OWNER, "attach", {attempt_id = prepared.attempt_id, recipient = process.pid(), generation = 0})
            test.eq(stale.error and stale.error.code, "INVALID")
            local attached = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "attach", {attempt_id = prepared.attempt_id, recipient = process.pid(), generation = 1}))
            test.eq(attached.attachment_generation, 1)
            local replaced = native_fixture.call(native_fixture.OWNER, "attach", {attempt_id = prepared.attempt_id, recipient = process.pid(), generation = 1})
            test.eq(replaced.error and replaced.error.code, "CONFLICT")
            local started = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "start", {attempt_id = prepared.attempt_id}))
            test.eq(started.execution_state, "running")
            test.not_nil(started.home_ref)
            test.eq(native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "start", {attempt_id = prepared.attempt_id})).execution_state, "running")
            local text = ""
            local highest = 0
            local function collect(until_text: string): boolean
                local deadline = time.after("10s")
                while not text:find(until_text, 1, true) do
                    local selected = channel.select({outputs:case_receive(), deadline:case_receive()})
                    if not selected.ok or selected.channel == deadline then return false end
                    local data = assert(bounds.object(selected.value:payload():data()))
                    test.eq(data.attempt_id, prepared.attempt_id)
                    test.eq(data.generation, 1)
                    if data.data then text = text .. tostring(data.data) end
                    if type(data.sequence) ~= "number" then error("invalid fixture data.sequence") end
                    local sequence = math.floor(data.sequence)
                    if sequence <= highest then error("sequence " .. tostring(sequence) .. " after " .. tostring(highest)) end
                    highest = sequence
                    process.send(tostring(selected.value:from()), protocol.TOPIC_ACK, {generation = 1, consumed_through = sequence})
                end
                return true
            end
            if not collect("start:probe-42") then error("no start output; received: " .. text) end
            if not text:find("placement%-project") then error("pwd is not the project root; received: " .. text) end
            local runner = ""
            do
                local db = store.open()
                if not db then error("store") end
                local row = store.row(db, prepared.attempt_id)
                db:release()
                runner = tostring(row and row.runner_pid)
            end
            process.send(runner, protocol.TOPIC_INPUT, {write_id = "w-1", generation = 1, data = "ping\n"})
            local ack = acks:receive()
            local accepted = assert(bounds.object(ack:payload():data()))
            test.eq(accepted.write_id, "w-1")
            if accepted.accepted ~= true then error("write refused: " .. tostring(accepted.reason)) end
            process.send(runner, protocol.TOPIC_INPUT, {write_id = "w-1", generation = 1, data = "ping\n"})
            local repeated = assert(bounds.object(acks:receive():payload():data()))
            if repeated.accepted ~= true then error("repeated write refused: " .. tostring(repeated.reason)) end
            if not collect("got:ping") then error("no echo of the input; received: " .. text) end
            local exit_deadline = time.after("10s")
            local exit: {[string]: unknown}? = nil
            while not exit do
                local selected = channel.select({exits:case_receive(), exit_deadline:case_receive()})
                assert(selected.ok and selected.channel == exits, "runner did not report this attempt's exit")
                local data: unknown = selected.value:payload():data()
                if type(data) == "table" and data.attempt_id == prepared.attempt_id then exit = assert(bounds.object(data)) end
            end
            test.eq(exit.code, 0)
            if exit.uncertain == true then error("exit reported uncertain") end
            if not collect("warn") then error("no stderr; received: " .. text) end
            if not native_fixture.wait_for(function()
                return (native_fixture.value(native_fixture.call(native_fixture.OWNER, "status", {attempt_id = prepared.attempt_id})).attempt).execution_state == "exited"
            end, 5000) then error("exit not recorded: " .. tostring((native_fixture.value(native_fixture.call(native_fixture.OWNER, "status", {attempt_id = prepared.attempt_id})).attempt).execution_state)) end
            local status = native_fixture.value(native_fixture.call(native_fixture.OWNER, "status", {attempt_id = prepared.attempt_id}))
            local attempt = status.attempt
            test.eq(attempt.execution_state, "exited")
            test.eq((attempt.exit).code, 0)
            local liveness = status.liveness
            if capability == "process_group" then
                if not liveness.observed or liveness.alive == true then error("exited child still reads alive: " .. liveness.detail) end
            else
                test.is_false(liveness.observed)
            end
            local recorded = native_fixture.kinds(prepared.attempt_id)
            for _, expected in ipairs({"intent.recorded", "attach", "runner.start_accepted", "runner.started", "home.created", "runner.materialized",
                "child.start_returned", "child.streams_ready", "child.identity_requested", "child.identity_returned",
                "child.started", "runner.ack_sending", "runner.ack_sent", "runner.ack_received", "child.exited"}) do
                test.is_true(native_fixture.has(recorded, expected))
            end
            test.eq(attempt.cleanup_state, "pending")
            test.eq(attempt.exit_source, "runner")
            test.eq(attempt.exit_observation, observation)
            local cleaned = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "cleanup", {attempt_id = prepared.attempt_id}))
            test.eq(cleaned.cleanup_state, "complete")
            test.eq(cleaned.execution_state, "exited")
            local key = homes.attempt_key(native_fixture.OWNER, prepared.attempt_id)
            if homes.attempt_exists(key) then error("attempt home remains after cleanup: " .. table.concat(native_fixture.kinds(prepared.attempt_id), ",")) end
            process.unlisten(outputs)
            process.unlisten(acks)
            process.unlisten(exits)
        end)
        test.it("escalates a cooperative stop and refuses cleanup before the exit is proven", function()
            local request = native_fixture.launch({"sh", "-c", "trap '' TERM; echo ready; sleep 8"}, "direct_process")
            local prepared = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", request))
            local early = native_fixture.call(native_fixture.OWNER, "cleanup", {attempt_id = prepared.attempt_id})
            test.eq(early.error and early.error.code, "CONFLICT")
            local started = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "start", {attempt_id = prepared.attempt_id}))
            test.eq(started.execution_state, "running")
            local blocked = native_fixture.call(native_fixture.OWNER, "cleanup", {attempt_id = prepared.attempt_id})
            test.eq(blocked.error and blocked.error.code, "CONFLICT")
            local stopping = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "stop", {attempt_id = prepared.attempt_id, mode = "cooperative"}))
            test.eq(stopping.execution_state, "stopping")
            if not native_fixture.wait_for(function()
                return (native_fixture.value(native_fixture.call(native_fixture.OWNER, "status", {attempt_id = prepared.attempt_id})).attempt).execution_state == "exited"
            end, 8000) then error("escalation did not end the child: " .. table.concat(native_fixture.kinds(prepared.attempt_id), ",")) end
            test.eq(native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "reconcile", {attempt_id = prepared.attempt_id})).execution_state, "exited")
            local recorded = native_fixture.kinds(prepared.attempt_id)
            for _, wanted in ipairs({"stop.requested", "signal.term", "signal.kill", "child.exited"}) do
                if not native_fixture.has(recorded, wanted) then error("evidence lacks " .. wanted .. ": " .. table.concat(recorded, ",")) end
            end
            local cleaned = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "cleanup", {attempt_id = prepared.attempt_id}))
            test.eq(cleaned.cleanup_state, "complete")
        end)
        test.it("measures an executable read-only and refuses a start whose executable no longer measures as planned", function()
            local cwd = native_fixture.shell("pwd"):gsub("%s+$", "")
            local script = cwd .. "/.wippy/measured-" .. native_fixture.fresh("script") .. ".sh"
            native_fixture.shell('printf "#!/bin/sh\\necho measured\\n" > ' .. script .. " && chmod +x " .. script)
            local measured = native_fixture.value(native_fixture.call(native_fixture.OWNER, "measure_executable", {path = script}))
            test.eq(measured.revision, "bee.executable-measurement@1")
            test.eq(measured.kind, "script")
            test.eq(measured.interpreter, "/bin/sh")
            test.eq(tostring(measured.digest):len(), 64)
            test.eq(measured.digest, (hash.sha256("#!/bin/sh\necho measured\n")))
            local image = native_fixture.value(native_fixture.call(native_fixture.OWNER, "measure_executable", {path = "/bin/sh"}))
            test.eq(image.kind, "elf")
            test.eq(tostring(image.digest):len(), 64)
            local reported = assert(bounds.object(native_fixture.value(service.capabilities()).executable_measurement))
            test.eq(type(reported.streaming), "boolean")
            test.eq(type(reported.read_only_volume), "boolean")
            test.is_true(#tostring(reported.detail) > 0)
            if reported.read_only_volume == true then test.is_true(tostring(reported.detail):find("refused as read-only", 1, true) ~= nil) end
            test.eq(native_fixture.shell("ls " .. cwd .. "/.wippy/placement 2>/dev/null | grep -c measurement-probe || true"):match("%d+"), "0")
            local missing = native_fixture.call(native_fixture.OWNER, "measure_executable", {path = cwd .. "/.wippy/absent-" .. native_fixture.fresh("x")})
            test.eq(missing.error and missing.error.code, "UNAVAILABLE")
            local relative = native_fixture.call(native_fixture.OWNER, "measure_executable", {path = "bin/sh"})
            test.eq(relative.error and relative.error.code, "UNAVAILABLE")
            local request = native_fixture.launch({script}, "direct_process")
            request.executable = {revision = "bee.executable-measurement@1", kind = "script", digest = string.rep("0", 64)}
            local stale = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", request))
            local refused = native_fixture.call(native_fixture.OWNER, "start", {attempt_id = stale.attempt_id})
            test.is_true(refused.ok)
            test.eq(native_fixture.attempt_of(refused).execution_state, "start_failed")
            test.is_true(native_fixture.has(native_fixture.kinds(stale.attempt_id), "executable.changed"))
            local fresh_request = native_fixture.launch({script}, "direct_process")
            fresh_request.executable = {revision = "bee.executable-measurement@1", kind = "script", digest = measured.digest}
            local prepared = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", fresh_request))
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "start", {attempt_id = prepared.attempt_id}))
            test.is_true(native_fixture.wait_for(function()
                return (native_fixture.value(native_fixture.call(native_fixture.OWNER, "status", {attempt_id = prepared.attempt_id})).attempt).execution_state == "exited"
            end, 8000))
            test.is_true(native_fixture.has(native_fixture.kinds(prepared.attempt_id), "executable.measured"))
            native_fixture.shell("rm -f " .. script)
        end)
        test.it("refuses executable read errors and streams shorter than the stat size", function()
            local function reader(chunks: {string}, failure: string?): ((integer) -> (unknown, unknown), () -> (boolean?, unknown?), () -> boolean)
                local reads = 0
                local closed = false
                local function read(_: integer): (unknown, unknown)
                    reads = reads + 1
                    if reads <= #chunks then return chunks[reads], nil end
                    if reads == #chunks + 1 then return nil, failure or "EOF" end
                    return nil, "EOF"
                end
                local function close(): (boolean?, unknown?)
                    closed = true
                    return true, nil
                end
                return read, close, function(): boolean return closed end
            end
            local failed_read, failed_close, failed_closed = reader({"prefix"}, "device read failed")
            local failed, read_error = executable_stream.digest(failed_read, failed_close, 16)
            test.is_nil(failed)
            test.is_true(tostring(read_error):find("device read failed", 1, true) ~= nil)
            test.is_true(failed_closed())
            local short_read, short_close, short_closed = reader({"abc"}, nil)
            local short, short_error = executable_stream.digest(short_read, short_close, 4)
            test.is_nil(short)
            test.is_true(tostring(short_error):find("measured 3 of 4 bytes", 1, true) ~= nil)
            test.is_true(short_closed())
        end)
        test.it("closes a live child's stdin at the owner's request and records it, or answers why it cannot", function()
            -- The shell reads stdin itself, so no descendant outlives a kill
            -- holding the pipes on a runtime without process groups.
            local request = native_fixture.launch({"sh", "-c", "while IFS= read -r line; do :; done; echo closed"}, "direct_process")
            local prepared = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", request))
            local outputs = assert(process.listen(protocol.TOPIC_OUTPUT, {message = true}))
            native_fixture.call(native_fixture.OWNER, "attach", {attempt_id = prepared.attempt_id, recipient = process.pid(), generation = 1})
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "start", {attempt_id = prepared.attempt_id}))
            local unknown = native_fixture.call(native_fixture.OWNER, "close_stdin", {attempt_id = native_fixture.fresh("attempt")})
            test.is_false(unknown.ok)
            local closed = native_fixture.value(native_fixture.call(native_fixture.OWNER, "close_stdin", {attempt_id = prepared.attempt_id}))
            local supported = native_fixture.value(service.capabilities()).stdin_close == true
            local recorded = native_fixture.kinds(prepared.attempt_id)
            if supported then
                test.eq(closed.closed, true)
                test.is_true(native_fixture.has(recorded, "stdin.closed"))
                local text = ""
                local deadline = time.after("10s")
                while not text:find("closed", 1, true) do
                    local selected = channel.select({outputs:case_receive(), deadline:case_receive()})
                    if not selected.ok or selected.channel == deadline then error("the child did not see end of input; output: " .. text) end
                    local data = assert(bounds.object(selected.value:payload():data()))
                    if data.data then text = text .. tostring(data.data) end
                    process.send(tostring(selected.value:from()), protocol.TOPIC_ACK, {generation = 1, consumed_through = math.floor(data.sequence)})
                end
                if not native_fixture.wait_for(function()
                    return (native_fixture.value(native_fixture.call(native_fixture.OWNER, "status", {attempt_id = prepared.attempt_id})).attempt).execution_state == "exited"
                end, 8000) then error("the child did not exit after end of input") end
                local again = native_fixture.call(native_fixture.OWNER, "close_stdin", {attempt_id = prepared.attempt_id})
                local ended = native_fixture.value(again)
                test.eq(ended.closed, false)
                test.eq(ended.reason, "the child has exited")
                test.eq((assert(bounds.object(ended.attempt))).execution_state, "exited")
            else
                test.eq(closed.closed, false)
                test.eq(closed.reason, "executor cannot close stdin")
                test.is_true(native_fixture.has(recorded, "stdin.uncertain"))
                native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "stop", {attempt_id = prepared.attempt_id, mode = "forced"}))
            end
            process.unlisten(outputs)
        end)
        test.it("reports an already observed exit when stdin closure races a short-lived CLI", function()
            local prepared = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", native_fixture.launch({"sh", "-c", "exit 0"}, "direct_process")))
            local exits = assert(process.listen(protocol.TOPIC_EXIT, {message = true}))
            native_fixture.call(native_fixture.OWNER, "attach", {attempt_id = prepared.attempt_id, recipient = process.pid(), generation = 1})
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "start", {attempt_id = prepared.attempt_id}))
            local observed = false
            while not observed do
                local data = assert(bounds.object(exits:receive():payload():data()))
                observed = data.attempt_id == prepared.attempt_id
            end
            process.unlisten(exits)
            local closed = native_fixture.value(native_fixture.call(native_fixture.OWNER, "close_stdin", {attempt_id = prepared.attempt_id}))
            local decoded = assert(placement_decode.stdin_closure(closed, prepared.attempt_id))
            test.is_false(decoded.closed)
            test.eq(decoded.reason, "the child has exited")
            local attempt = assert(bounds.object(closed.attempt))
            test.eq(attempt.execution_state, "exited")
            test.is_true(type(attempt.exit_source) == "string")
            test.is_false(native_fixture.has(native_fixture.kinds(prepared.attempt_id), "stdin.closed"))
        end)
    end)
end


return {execution = native_fixture.suite(execution_tests)}
