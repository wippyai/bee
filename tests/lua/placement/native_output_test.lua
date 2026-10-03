-- MIT. Native placement output regressions.
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

local function output_tests()
    test.describe("Native placement output", function()
        local measured = native_fixture.value(service.capabilities())
        local capability = tostring(measured.capability)
        local observation = tostring(measured.exit_observation)
        test.it("drains for a bounded time after an independently observed exit while descendants hold the pipes", function()
            local outputs = assert(process.listen(protocol.TOPIC_OUTPUT, {message = true}))
            local exits = assert(process.listen(protocol.TOPIC_EXIT, {message = true}))
            local release = native_fixture.shell("pwd"):gsub("\n$", "") .. "/.wippy/" .. native_fixture.fresh("descendant-drain")
            native_fixture.shell("mkfifo " .. quote.posix(release))
            local script = "read release < " .. quote.posix(release) .. " & echo hi"
            local request = native_fixture.launch({"sh", "-c", script}, "direct_process")
            request.timeouts = {stop_grace_ms = 500, drain_ms = 300, retain_ms = 300}
            local prepared = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", request))
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "attach", {attempt_id = prepared.attempt_id, recipient = process.pid(), generation = 1}))
            local started = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "start", {attempt_id = prepared.attempt_id}))
            if started.exit_observation ~= "independent" then native_fixture.shell("exec 3<> " .. quote.posix(release) .. "; printf 'release\n' >&3") end
            while true do
                local message = assert((exits:receive()))
                if message:payload():data().attempt_id == prepared.attempt_id then break end
            end
            local eof, marked = 0, false
            while eof < 2 do
                local message = assert((outputs:receive()))
                local data = assert(bounds.object(message:payload():data()))
                if data.attempt_id == prepared.attempt_id then
                    if data.eof == true then eof = eof + 1 end
                    if data.truncated == true then marked = true end
                    assert(process.send(tostring(message:from()), protocol.TOPIC_ACK, {generation = 1, consumed_through = data.sequence}))
                end
            end
            if started.exit_observation == "independent" then native_fixture.shell("exec 3<> " .. quote.posix(release) .. "; printf 'release\n' >&3") end
            native_fixture.shell("rm " .. quote.posix(release))
            test.eq(marked, started.exit_observation == "independent", table.concat(native_fixture.kinds(prepared.attempt_id), ","))
            process.unlisten(outputs)
            process.unlisten(exits)
        end)
        test.it("retains pipe data across post-exit consumer backpressure without false truncation", function()
            local outputs = assert(process.listen(protocol.TOPIC_OUTPUT, {message = true}))
            local exits = assert(process.listen(protocol.TOPIC_EXIT, {message = true}))
            local request = native_fixture.launch({"sh", "-c", "head -c 300000 /dev/zero | tr '\\000' x"}, "direct_process")
            request.timeouts = {stop_grace_ms = 500, drain_ms = 100, retain_ms = 1500}
            local prepared = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", request))
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "attach", {attempt_id = prepared.attempt_id, recipient = process.pid(), generation = 1}))
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "start", {attempt_id = prepared.attempt_id}))
            local end_deadline = time.after("10s")
            while true do
                local exited = channel.select({exits:case_receive(), end_deadline:case_receive()})
                assert(exited.ok and exited.channel == exits, "producer did not exit with buffered output")
                if exited.value:payload():data().attempt_id == prepared.attempt_id then break end
            end
            local hold = time.after("300ms")
            channel.select({hold:case_receive()})
            local received, eof, marked = 0, 0, false
            local deadline = time.after("10s")
            while eof < 2 do
                local selected = channel.select({outputs:case_receive(), deadline:case_receive()})
                assert(selected.ok and selected.channel == outputs, "buffered streams did not finish")
                local data = assert(bounds.object(selected.value:payload():data()))
                if data.attempt_id == prepared.attempt_id then
                received = received + #(type(data.data) == "string" and data.data or "")
                if data.eof == true then eof = eof + 1 end
                if data.truncated == true then marked = true end
                assert(process.send(tostring(selected.value:from()), protocol.TOPIC_ACK, {generation = 1, consumed_through = data.sequence}))
                end
            end
            test.eq(received, 300000)
            test.is_false(marked)
            test.is_false(native_fixture.has(native_fixture.kinds(prepared.attempt_id), "output.drain_elapsed"))
            process.unlisten(outputs)
            process.unlisten(exits)
        end)
        test.it("consumes queued pipe data before an expired drain is selected", function()
            local outputs = assert(process.listen(protocol.TOPIC_OUTPUT, {message = true}))
            local exits = assert(process.listen(protocol.TOPIC_EXIT, {message = true}))
            local request = native_fixture.launch({"sh", "-c", "head -c 300000 /dev/zero | tr '\\000' x"}, "direct_process")
            request.environment = {PROBE_VALUE = "expire-pipe"}
            request.timeouts = {stop_grace_ms = 500, drain_ms = 100, retain_ms = 1500}
            local prepared = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", request))
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "attach", {attempt_id = prepared.attempt_id, recipient = process.pid(), generation = 1}))
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "start", {attempt_id = prepared.attempt_id}))
            while true do
                local message = assert((exits:receive()))
                if message:payload():data().attempt_id == prepared.attempt_id then break end
            end
            local received, eof, marked = 0, 0, false
            while eof < 2 do
                local message = assert((outputs:receive()))
                local data = assert(bounds.object(message:payload():data()))
                if data.attempt_id == prepared.attempt_id then
                    if type(data.data) == "string" then received = received + #data.data end
                    if data.eof == true then eof = eof + 1 end
                    if data.truncated == true then marked = true end
                    assert(process.send(tostring(message:from()), protocol.TOPIC_ACK, {generation = 1, consumed_through = data.sequence}))
                end
            end
            local order = table.concat(native_fixture.kinds(prepared.attempt_id), ",")
            test.eq(received, 300000, order)
            test.is_false(marked, order)
            test.is_false(native_fixture.has(native_fixture.kinds(prepared.attempt_id), "output.drain_elapsed"), order)
            process.unlisten(outputs)
            process.unlisten(exits)
        end)
        test.it("replays an acknowledged stream end to a takeover while the other pipe remains open", function()
            local outputs = assert(process.listen(protocol.TOPIC_OUTPUT, {message = true}))
            local exits = assert(process.listen(protocol.TOPIC_EXIT, {message = true}))
            local release = native_fixture.shell("pwd"):gsub("\n$", "") .. "/.wippy/" .. native_fixture.fresh("eof-replay")
            native_fixture.shell("mkfifo " .. quote.posix(release))
            local request = native_fixture.launch({"sh", "-c", "exec 2>&-; echo before; read release < " .. quote.posix(release) .. "; echo after"}, "direct_process")
            local prepared = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", request))
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "attach", {attempt_id = prepared.attempt_id, recipient = process.pid(), generation = 1}))
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "start", {attempt_id = prepared.attempt_id}))
            local ended = false
            while not ended do
                local message = assert((outputs:receive()))
                local data = assert(protocol.decode_output(message:payload():data()))
                if data.attempt_id == prepared.attempt_id then
                    assert(process.send(tostring(message:from()), protocol.TOPIC_ACK, {generation = 1, consumed_through = data.sequence}))
                    ended = data.stream == "stderr" and data.eof
                end
            end
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "attach", {attempt_id = prepared.attempt_id, recipient = process.pid(), generation = 2}))
            local replayed = false
            while not replayed do
                local message = assert((outputs:receive()))
                local data = assert(protocol.decode_output(message:payload():data()))
                if data.attempt_id == prepared.attempt_id and data.generation == 2 then
                    assert(process.send(tostring(message:from()), protocol.TOPIC_ACK, {generation = 2, consumed_through = data.sequence}))
                    replayed = data.stream == "stderr" and data.eof
                end
            end
            native_fixture.shell("exec 3<> " .. quote.posix(release) .. "; printf 'release\n' >&3")
            while true do
                local message = assert((exits:receive()))
                local data = assert(protocol.decode_exit(message:payload():data()))
                if data.attempt_id == prepared.attempt_id and data.generation == 2 then break end
            end
            while true do
                local message = assert((outputs:receive()))
                local data = assert(protocol.decode_output(message:payload():data()))
                if data.attempt_id == prepared.attempt_id and data.generation == 2 then
                    assert(process.send(tostring(message:from()), protocol.TOPIC_ACK, {generation = 2, consumed_through = data.sequence}))
                    if data.stream == "stdout" and data.eof then break end
                end
            end
            native_fixture.shell("rm " .. quote.posix(release))
            process.unlisten(outputs)
            process.unlisten(exits)
        end)
        test.it("records unacknowledged output as lost once the retention deadline passes after exit", function()
            local request = native_fixture.launch({"sh", "-c", "echo one; echo two"}, "direct_process")
            request.timeouts = {stop_grace_ms = 500, retain_ms = 300}
            request.environment = {PROBE_VALUE = "hold-retention"}
            local prepared = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", request))
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "attach", {attempt_id = prepared.attempt_id, recipient = process.pid(), generation = 1}))
            native_fixture.await_retained_runner(prepared)
            local recorded = native_fixture.kinds(prepared.attempt_id)
            test.is_true(native_fixture.has(recorded, "child.exited"))
            test.is_true(native_fixture.has(recorded, "output.lost"))
            test.is_true(native_fixture.has(recorded, "runner.finished"))
            local after_finish = assert(store.open())
            local final_row = store.row(after_finish, prepared.attempt_id)
            after_finish:release()
            test.is_nil(final_row and final_row.runner_pid, "runner.finished clears its process identity")
            local page = native_fixture.value(native_fixture.call(native_fixture.OWNER, "evidence", {attempt_id = prepared.attempt_id, limit = 64}))
            for _, item in ipairs(principals.objects(page.evidence)) do
                if item.kind == "output.lost" then test.is_true(tostring(item.detail):find("unacknowledged chunks", 1, true) ~= nil) end
            end
        end)
        test.it("bounds post-exit retention when an unacknowledged burst fills the spool", function()
            local request = native_fixture.launch({"sh", "-c", "head -c 300000 /dev/zero | tr '\\000' x"}, "direct_process")
            request.timeouts = {stop_grace_ms = 500, drain_ms = 100, retain_ms = 300}
            request.environment = {PROBE_VALUE = "hold-retention"}
            local prepared = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", request))
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "attach", {attempt_id = prepared.attempt_id, recipient = process.pid(), generation = 1}))
            native_fixture.await_retained_runner(prepared)
            local recorded = native_fixture.kinds(prepared.attempt_id)
            test.is_true(native_fixture.has(recorded, "child.exited"))
            test.is_true(native_fixture.has(recorded, "output.lost"))
            test.is_true(native_fixture.has(recorded, "runner.finished"))
            test.is_false(native_fixture.has(recorded, "output.drain_elapsed"))
        end)
        test.it("keeps supervising a live attempt without an execution identity while its runner answers", function()
            local request = native_fixture.launch({"sh", "-c", "sleep 8"}, "direct_process")
            local prepared = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", request))
            local started = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "start", {attempt_id = prepared.attempt_id}))
            test.eq(started.execution_state, "running")
            local db = store.open()
            if not db then error("store") end
            local _, clear_error = db:execute("UPDATE bee_placement_attempts SET pid = NULL, pgid = NULL, start_ticks = NULL, boot_id = NULL WHERE attempt_id = ?", {prepared.attempt_id})
            db:release()
            if clear_error then error("clear identity: " .. tostring(clear_error)) end
            local reconciled = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "reconcile", {attempt_id = prepared.attempt_id}))
            test.eq(reconciled.execution_state, "running")
            test.is_true(native_fixture.has(native_fixture.kinds(prepared.attempt_id), "reconcile.supervised"))
            local page = native_fixture.value(native_fixture.call(native_fixture.OWNER, "evidence", {attempt_id = prepared.attempt_id, limit = 64}))
            local reported = false
            for _, item in ipairs(principals.objects(page.evidence)) do
                if item.kind == "reconcile.supervised" and tostring(item.detail):find("runner reports running", 1, true) then reported = true end
            end
            test.is_true(reported)
            test.eq(native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "reconcile", {attempt_id = prepared.attempt_id})).execution_state, "running")
            native_fixture.call(native_fixture.OWNER, "stop", {attempt_id = prepared.attempt_id, mode = "forced"})
        end)
        test.it("keeps uncertainty when the runner is lost without an execution identity", function()
            local request = native_fixture.launch({"sh", "-c", "sleep 8"}, "direct_process")
            local prepared = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", request))
            local db = store.open()
            if not db then error("store") end
            -- Inject the persisted state left by an unobserved execution.
            -- Starting and killing a real child first allowed the background
            -- sweep to prove its exit before the fixture removed its identity.
            local _, clear_error = db:execute("UPDATE bee_placement_attempts SET execution_state = 'running', runner_pid = NULL, pid = NULL, pgid = NULL, start_ticks = NULL, boot_id = NULL WHERE attempt_id = ?", {prepared.attempt_id})
            db:release()
            if clear_error then error("clear identity: " .. tostring(clear_error)) end
            local reconciled = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "reconcile", {attempt_id = prepared.attempt_id}))
            test.eq(reconciled.execution_state, "uncertain")
            local stopped = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "stop", {attempt_id = prepared.attempt_id, mode = "forced"}))
            test.eq(stopped.execution_state, "uncertain")
            local blocked = native_fixture.call(native_fixture.OWNER, "cleanup", {attempt_id = prepared.attempt_id})
            test.eq(blocked.error and blocked.error.code, "CONFLICT")
        end)
        test.it("keeps a starting attempt whose runner is present while it prepares the child", function()
            local request = native_fixture.launch({"sh", "-c", "sleep 8"}, "direct_process")
            local prepared = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", request))
            local db = store.open()
            if not db then error("store") end
            -- A runner materializing configuration is a live host process
            -- that does not answer status probes until its child exists.
            local runner = tostring(assert(process.spawn("bee.host:idle_process", "bee:workers")))
            local _, claim_error = db:execute("UPDATE bee_placement_attempts SET execution_state = 'starting', runner_pid = ?, pid = NULL, pgid = NULL, start_ticks = NULL, boot_id = NULL WHERE attempt_id = ?", {runner, prepared.attempt_id})
            db:release()
            if claim_error then error("claim attempt: " .. tostring(claim_error)) end
            local reconciled = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "reconcile", {attempt_id = prepared.attempt_id}))
            test.eq(reconciled.execution_state, "starting")
            test.is_true(native_fixture.has(native_fixture.kinds(prepared.attempt_id), "reconcile.supervised"))
            assert(process.cancel(runner, "runner stand-in released"))
            local released = store.open()
            if not released then error("store") end
            local _, release_error = released:execute("UPDATE bee_placement_attempts SET runner_pid = NULL WHERE attempt_id = ?", {prepared.attempt_id})
            released:release()
            if release_error then error("release attempt: " .. tostring(release_error)) end
            test.eq(native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "reconcile", {attempt_id = prepared.attempt_id})).execution_state, "uncertain")
        end)
        test.it("resolves grants through the resource authority when the host selects granted mode", function()
            local workspace = native_fixture.fresh("ws")
            native_fixture.resource_call("associate", {workspace_id = workspace, name = "project", root_ref = native_fixture.ROOT, subpath = "", allowed_access = "write"})
            native_fixture.resource_mode("granted")
            local attempt_id = native_fixture.fresh("attempt")
            local granted = native_fixture.resource_call("grant", {workspace_id = workspace, name = "project", access = "write", purpose = "project", audience = native_fixture.OWNER, attempt_id = attempt_id})
            local request = native_fixture.launch({"sh", "-c", "pwd"}, "direct_process")
            request.attempt_id = attempt_id
            local grant = (principals.objects(request.resources))[1]
            grant.grant_ref = granted.grant_id
            grant.root_ref = "bee.placement.native.env:root"
            local prepared = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", request))
            test.eq(prepared.execution_state, "intended")
            local reported = native_fixture.value(service.capabilities())
            test.eq(reported.resource_authority, "granted")
            test.is_true(reported.delegated_resource_grants == true)
            local downgraded = native_fixture.launch({"sh", "-c", "true"}, "direct_process")
            local plain = (principals.objects(downgraded.resources))[1]
            plain.grant_ref = "host"
            local refused = native_fixture.call(native_fixture.OWNER, "prepare", downgraded)
            test.eq(refused.error and refused.error.code, "NOT_FOUND")
            local foreign = native_fixture.launch({"sh", "-c", "true"}, "direct_process")
            local borrowed = (principals.objects(foreign.resources))[1]
            borrowed.grant_ref = granted.grant_id
            local scoped = native_fixture.call(native_fixture.OWNER, "prepare", foreign)
            test.eq(scoped.error and scoped.error.code, "DENIED")
            local short_attempt = native_fixture.fresh("attempt")
            local short = native_fixture.resource_call("grant", {workspace_id = workspace, name = "project", access = "read", purpose = "project", audience = native_fixture.OWNER, attempt_id = short_attempt, ttl_ms = 300})
            local expiring = native_fixture.launch({"sh", "-c", "true"}, "direct_process")
            expiring.attempt_id = short_attempt
            local expiring_grant = (principals.objects(expiring.resources))[1]
            expiring_grant.grant_ref = short.grant_id
            expiring_grant.access = "read"
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", expiring))
            time.sleep("400ms")
            local late = native_fixture.call(native_fixture.OWNER, "start", {attempt_id = short_attempt})
            test.eq(late.error and late.error.code, "EXPIRED")
            test.is_true(native_fixture.has(native_fixture.kinds(short_attempt), "grant.refused"))
            local started = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "start", {attempt_id = attempt_id}))
            test.is_true(started.execution_state == "running" or started.execution_state == "exited")
            native_fixture.resource_mode("host_configured")
        end)
        test.it("stops a running attempt whose grant is revoked, with enforcement pending until the exit is proven", function()
            local workspace = native_fixture.fresh("ws")
            native_fixture.resource_call("associate", {workspace_id = workspace, name = "project", root_ref = native_fixture.ROOT, subpath = "", allowed_access = "write"})
            native_fixture.resource_mode("granted")
            local attempt_id = native_fixture.fresh("attempt")
            local granted = native_fixture.resource_call("grant", {workspace_id = workspace, name = "project", access = "write", purpose = "project", audience = native_fixture.OWNER, attempt_id = attempt_id})
            local request = native_fixture.launch({"sh", "-c", "sleep 8"}, "direct_process")
            request.attempt_id = attempt_id
            local grant = (principals.objects(request.resources))[1]
            grant.grant_ref = granted.grant_id
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", request))
            test.eq(native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "start", {attempt_id = attempt_id})).execution_state, "running")
            local before = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "reconcile", {attempt_id = attempt_id}))
            test.is_true(before.execution_state == "running" or before.execution_state == "uncertain")
            local db = store.open()
            if not db then error("store") end
            local _, identify_error = db:execute("UPDATE bee_placement_attempts SET pid = COALESCE(pid, 0) WHERE attempt_id = ?", {attempt_id})
            db:release()
            if identify_error then error("identify: " .. tostring(identify_error)) end
            local revoked = native_fixture.resource_call("revoke", {grant_id = granted.grant_id})
            local fenced = (principals.strings((revoked.revocation).fenced_attempts))
            local stop_results = principals.objects(revoked.stop_results)
            test.eq(#fenced, 1)
            test.eq(fenced[1], attempt_id)
            test.eq(#stop_results, 1)
            test.eq(stop_results[1].attempt_id, attempt_id)
            test.is_true(stop_results[1].stopped == true, tostring(stop_results[1].error))
            local enforced = native_fixture.call(native_fixture.OWNER, "reconcile", {attempt_id = attempt_id})
            local recorded = native_fixture.kinds(attempt_id)
            if capability == "process_group" then
                test.is_true(enforced.ok)
                test.is_true(native_fixture.has(recorded, "grant.revoked"))
                test.is_true(native_fixture.has(recorded, "stop.requested"))
                if not native_fixture.wait_for(function()
                    return (native_fixture.value(native_fixture.call(native_fixture.OWNER, "status", {attempt_id = attempt_id})).attempt).execution_state == "exited"
                end, 8000) then error("revocation did not end the child: " .. table.concat(native_fixture.kinds(attempt_id), ",")) end
            else
                native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "stop", {attempt_id = attempt_id, mode = "forced"}))
            end
            native_fixture.resource_mode("host_configured")
        end)
        test.it("stops a running attempt reported by revoke_all", function()
            local workspace = native_fixture.fresh("epoch-stop")
            native_fixture.resource_call("associate", {workspace_id = workspace, name = "project", root_ref = native_fixture.ROOT,
                subpath = "", allowed_access = "write"})
            native_fixture.resource_mode("granted")
            local attempt_id = native_fixture.fresh("attempt")
            local granted = native_fixture.resource_call("grant", {workspace_id = workspace, name = "project", access = "write",
                purpose = "project", audience = native_fixture.OWNER, attempt_id = attempt_id})
            local request = native_fixture.launch({"sh", "-c", "trap '' TERM; sleep 8"}, "direct_process")
            request.attempt_id = attempt_id
            local grant = (principals.objects(request.resources))[1]
            grant.grant_ref = granted.grant_id
            grant.root_ref = "bee.placement.native.env:root"
            native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", request))
            test.eq(native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "start", {attempt_id = attempt_id})).execution_state, "running")
            local revoked = native_fixture.resource_call("revoke_all", {workspace_id = workspace})
            local fenced = principals.items(revoked.fenced_attempts)
            local results = principals.objects(revoked.stop_results)
            test.eq(#fenced, 1)
            test.eq(fenced[1], attempt_id)
            test.eq(#results, 1)
            test.eq(results[1].attempt_id, attempt_id)
            test.is_true(results[1].stopped == true, tostring(results[1].error))
            if not native_fixture.wait_for(function()
                return (native_fixture.value(native_fixture.call(native_fixture.OWNER, "status", {attempt_id = attempt_id})).attempt).execution_state == "exited"
            end, 8000) then error("revoke_all did not stop the child: " .. table.concat(native_fixture.kinds(attempt_id), ",")) end
            native_fixture.resource_mode("host_configured")
        end)
    end)
end


return {output = native_fixture.suite(output_tests)}
