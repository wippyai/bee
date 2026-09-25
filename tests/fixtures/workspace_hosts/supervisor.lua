-- MIT. Bounded acceptance supervisor proving two workspace hosts in one runtime.
local process = require("process")
local channel = require("channel")
local security = require("security")
local time = require("time")
local logger = require("logger")
local contract = require("contract")
local decode = require("decode")
local recovery = require("recovery")

local M = {}

local function snapshot_app_count(saved: unknown): integer?
    if type(saved) ~= "table" or type(saved.applications) ~= "table" then return nil end
    local count = 0
    for _ in ipairs(saved.applications) do count = count + 1 end
    return count
end

local function snapshot_first_record(saved: unknown): recovery.Record?
    if type(saved) ~= "table" or type(saved.applications) ~= "table" then return nil end
    local first: unknown = saved.applications[1]
    return recovery.record(first)
end

function M.main()
    local self = tostring(process.pid())
    local ready = assert(process.listen("bee.host.ready", {message = true}))
    local replies = assert(process.listen("bee.app.reply", {message = true}))
    local checkpoints = assert(process.listen("bee.host.checkpoint", {message = true}))
    local restores = assert(process.listen("bee.host.restore_result", {message = true}))
    local events = assert(process.events())

    local host_policy, host_err = security.policy("bee.security.desktop:host_policy")
    if not host_policy then error(tostring(host_err)) end
    local host_spawn_policy, spawn_err = security.policy("bee.security.desktop:host_spawn_policy")
    if not host_spawn_policy then error(tostring(spawn_err)) end
    local first_storage_policy, first_err = security.policy("bee.workspace_hosts:first_storage_policy")
    if not first_storage_policy then error(tostring(first_err)) end
    local second_storage_policy, second_err = security.policy("bee.workspace_hosts:second_storage_policy")
    if not second_storage_policy then error(tostring(second_err)) end

    local observed_exits: {[string]: unknown} = {}

    local function spawn_host_with_policies(resource: string, policies: {security.Policy}): string
        local scope = security.new_scope(policies)
        local host = tostring(assert(process.with_options({}):with_context({["bee.host_owner"] = self})
            :with_scope(scope):spawn_monitored("bee.host:main", "bee:workers", self, {root_ref = "bee.environment:workspace_root", subpath = ""}, resource)))
        return host
    end

    local function spawn_host(resource: string, storage_policy: security.Policy): string
        return spawn_host_with_policies(resource, {host_policy, host_spawn_policy, storage_policy})
    end

    local function wait_reply(expected_host: string, req_id: string, op: string): decode.Reply
        local deadline = time.after("10s")
        while true do
            if observed_exits[expected_host] ~= nil then
                error("Host " .. expected_host .. " exited while waiting for reply: " .. (decode.exit_error(observed_exits[expected_host]) or "unknown"))
            end
            local selected = channel.select({replies:case_receive(), deadline:case_receive(), events:case_receive()})
            if not selected.ok then error("Reply channel closed") end
            if selected.channel == deadline then
                error("Timeout waiting for reply: " .. req_id .. " op=" .. op .. " from host " .. expected_host)
            elseif selected.channel == events then
                local event = selected.value
                if event.kind == process.event.EXIT then
                    local from = tostring(event.from)
                    observed_exits[from] = event.result
                    if from == expected_host then
                        error("Host " .. expected_host .. " exited while waiting for reply: " .. (decode.exit_error(event.result) or "unknown"))
                    end
                end
            else
                local message = selected.value
                if tostring(message:from()) == expected_host then
                    local result = decode.reply(message:payload():data())
                    if result and result.request_id == req_id and result.op == op then
                        return result
                    end
                end
            end
        end
        error("Unreachable in wait_reply")
    end

    local function collect_two_replies(
        h1: string, r1_id: string, r1_op: string,
        h2: string, r2_id: string, r2_op: string
    ): (decode.Reply, decode.Reply)
        local rep1: decode.Reply? = nil
        local rep2: decode.Reply? = nil
        local deadline = time.after("10s")
        while not (rep1 and rep2) do
            if rep1 == nil and observed_exits[h1] ~= nil then
                error("Host " .. h1 .. " exited while waiting for reply: " .. (decode.exit_error(observed_exits[h1]) or "unknown"))
            end
            if rep2 == nil and observed_exits[h2] ~= nil then
                error("Host " .. h2 .. " exited while waiting for reply: " .. (decode.exit_error(observed_exits[h2]) or "unknown"))
            end
            local selected = channel.select({replies:case_receive(), events:case_receive(), deadline:case_receive()})
            if not selected.ok then error("Reply channel closed") end
            if selected.channel == deadline then
                error("Timeout waiting for concurrent replies from " .. h1 .. " and " .. h2)
            elseif selected.channel == events then
                local event = selected.value
                if event.kind == process.event.EXIT then
                    local from = tostring(event.from)
                    observed_exits[from] = event.result
                    if (from == h1 and rep1 == nil) or (from == h2 and rep2 == nil) then
                        error("Host " .. from .. " exited while waiting for reply: " .. (decode.exit_error(event.result) or "unknown"))
                    end
                end
            else
                local message = selected.value
                local from = tostring(message:from())
                local result = decode.reply(message:payload():data())
                if result then
                    if from == h1 and result.request_id == r1_id and result.op == r1_op then
                        rep1 = result
                    elseif from == h2 and result.request_id == r2_id and result.op == r2_op then
                        rep2 = result
                    end
                end
            end
        end
        return rep1, rep2
    end

    local function wait_checkpoint(expected_host: string, expected_ws: string): recovery.Record
        local deadline = time.after("10s")
        while true do
            if observed_exits[expected_host] ~= nil then
                error("Host " .. expected_host .. " exited while waiting for checkpoint")
            end
            local selected = channel.select({checkpoints:case_receive(), deadline:case_receive(), events:case_receive()})
            if not selected.ok then error("Checkpoint channel closed") end
            if selected.channel == deadline then
                error("Timeout waiting for checkpoint on host: " .. expected_host)
            elseif selected.channel == events then
                local event = selected.value
                if event.kind == process.event.EXIT then
                    local from = tostring(event.from)
                    observed_exits[from] = event.result
                    if from == expected_host then
                        error("Host " .. expected_host .. " exited while waiting for checkpoint")
                    end
                end
            else
                local message = selected.value
                if tostring(message:from()) == expected_host then
                    local data: unknown = message:payload():data()
                    if type(data) == "table" and data.version == 1 and data.workspace_id == expected_ws then
                        local record = recovery.record(data.record)
                        if record then return record end
                    end
                end
            end
        end
        error("Unreachable in wait_checkpoint")
    end

    local function stop_host(host: string, wsid: string, req_id: string)
        local sent = process.send(host, "bee.app.request", {
            version = 1,
            request_id = req_id,
            op = "shutdown",
            workspace_id = wsid,
        })
        assert(sent, "Failed to send shutdown to " .. host)

        local deadline = time.after("10s")
        local shutdown_reply: decode.Reply? = nil

        while not (shutdown_reply and observed_exits[host] ~= nil) do
            local selected = channel.select({replies:case_receive(), events:case_receive(), deadline:case_receive()})
            if not selected.ok then error("Channel closed during stop_host") end
            if selected.channel == deadline then
                error("Timeout waiting for host shutdown: " .. host .. " reply=" .. tostring(shutdown_reply ~= nil) .. " exit=" .. tostring(observed_exits[host] ~= nil))
            elseif selected.channel == events then
                local event = selected.value
                if event.kind == process.event.EXIT then
                    observed_exits[tostring(event.from)] = event.result
                end
            else
                local message = selected.value
                if tostring(message:from()) == host then
                    local rep = decode.reply(message:payload():data())
                    if rep and rep.request_id == req_id and rep.op == "shutdown" then
                        shutdown_reply = rep
                    end
                end
            end
        end

        assert(shutdown_reply ~= nil, "Shutdown reply missing for " .. host)
        assert(shutdown_reply.error_code == "", "Shutdown reply error: " .. shutdown_reply.error)
        local exit_err = decode.exit_error(observed_exits[host])
        assert(exit_err == nil, "Host exited with error during shutdown: " .. tostring(exit_err))
    end

    -- Step 1: Negative authorization probe selecting second DB while only first storage policy granted
    local denied_host = spawn_host_with_policies("bee.workspace.db:second", {host_policy, host_spawn_policy, first_storage_policy})
    local denied_deadline = time.after("5s")
    while observed_exits[denied_host] == nil do
        local selected = channel.select({ready:case_receive(), events:case_receive(), denied_deadline:case_receive()})
        if not selected.ok then error("Channel closed during negative authorization probe") end
        if selected.channel == denied_deadline then
            error("Negative authorization probe timed out: unauthorized host did not exit")
        elseif selected.channel == ready then
            local message = selected.value
            if tostring(message:from()) == denied_host then
                error("Negative probe failed: unauthorized host signaled readiness")
            end
        elseif selected.channel == events then
            local event = selected.value
            if event.kind == process.event.EXIT then
                observed_exits[tostring(event.from)] = event.result
            end
        end
    end
    local denied_error = decode.exit_error(observed_exits[denied_host])
    assert(denied_error ~= nil, "Negative authorization probe: host must exit with error")
    assert(denied_error and denied_error:find("not allowed to access database: bee.workspace.db:second", 1, true),
        "Negative probe failed for an unexpected reason")
    logger:info("Negative authorization probe verified: unauthorized DB selection rejected", {host = denied_host, error = denied_error})

    -- Step 2: Boot two hosts in ONE runtime with distinct DB resources and exact storage policies
    local host_1 = spawn_host("bee.workspace.db:first", first_storage_policy)
    local host_2 = spawn_host("bee.workspace.db:second", second_storage_policy)

    local host_ready: {[string]: {workspace_id: string, saved: unknown}} = {}
    local deadline = time.after("10s")
    while (not host_ready[host_1] or not host_ready[host_2]) do
        if observed_exits[host_1] ~= nil then
            error("Host 1 exited during boot: " .. (decode.exit_error(observed_exits[host_1]) or "unknown"))
        end
        if observed_exits[host_2] ~= nil then
            error("Host 2 exited during boot: " .. (decode.exit_error(observed_exits[host_2]) or "unknown"))
        end
        local selected = channel.select({ready:case_receive(), deadline:case_receive(), events:case_receive()})
        if not selected.ok then error("Readiness channel closed") end
        if selected.channel == deadline then
            error("Timeout waiting for dual host readiness")
        elseif selected.channel == events then
            local event = selected.value
            if event.kind == process.event.EXIT then
                local from = tostring(event.from)
                observed_exits[from] = event.result
                if from == host_1 or from == host_2 then
                    error("Host " .. from .. " exited during boot: " .. (decode.exit_error(event.result) or "unknown"))
                end
            end
        else
            local message = selected.value
            local from = tostring(message:from())
            if from == host_1 or from == host_2 then
                local data: unknown = message:payload():data()
                if type(data) ~= "table" or data.version ~= 1 then error("Invalid readiness version") end
                local saved: unknown = data.saved
                if type(saved) ~= "table" or type(saved.applications) ~= "table" then error("Missing saved applications") end
                local wsid = contract.workspace_id(data.workspace_id)
                if not wsid then error("Invalid workspace identity in readiness") end
                assert(#saved.applications == 0, "Initial host boot must have 0 saved applications")
                host_ready[from] = {workspace_id = wsid, saved = saved}
            end
        end
    end

    local ws1_opt = host_ready[host_1].workspace_id
    local ws2_opt = host_ready[host_2].workspace_id
    if not ws1_opt or not ws2_opt then error("Missing workspace identity") end
    local ws1: string = ws1_opt
    local ws2: string = ws2_opt

    assert(host_1 ~= host_2, "Dual hosts must have distinct PIDs")
    assert(ws1 ~= ws2, "Dual hosts must have distinct workspace IDs")
    logger:info("Dual hosts booted in one runtime", {host_1 = host_1, ws1 = ws1, host_2 = host_2, ws2 = ws2})

    -- Step 3: Open real Settings on Host 1 and verify checkpoint
    local open_req_id = "req-open-settings"
    local associated_thread = "host-recovery-thread"
    local open_sent = process.send(host_1, "bee.app.request", {
        version = 1,
        request_id = open_req_id,
        op = "open",
        workspace_id = ws1,
        definition_id = "bee.settings:app",
        thread_id = associated_thread,
    })
    assert(open_sent, "Failed to send open request to host 1")

    local open_reply = wait_reply(host_1, open_req_id, "open")
    assert(open_reply.error_code == "", "Open Settings on host 1 failed: " .. open_reply.error)
    local opened_instance_id = open_reply.instance_id
    assert(opened_instance_id ~= "", "Missing instance_id in open reply")
    assert(open_reply.workspace_id == ws1, "Open reply workspace_id must match ws1")
    assert(open_reply.thread_id == associated_thread, "Open lost its authorized thread association")

    local checkpoint_record = wait_checkpoint(host_1, ws1)
    assert(checkpoint_record.instance_id == opened_instance_id, "Checkpoint instance_id must match opened app")
    assert(checkpoint_record.definition_id == "bee.settings:app", "Checkpoint definition_id must match Settings")
    assert(checkpoint_record.thread_id == associated_thread, "Checkpoint lost its host-owned thread association")
    assert(process.send(host_1, "bee.app.request", {version = 1, request_id = open_req_id,
        op = "open", workspace_id = ws1, definition_id = "bee.settings:app", thread_id = "different-thread"}))
    assert(wait_reply(host_1, open_req_id, "open").error_code == "request_conflict", "Retry changed thread association")
    assert(process.send(host_1, "bee.app.request", {version = 1, request_id = "singleton-thread-conflict",
        op = "open", workspace_id = ws1, definition_id = "bee.settings:app", thread_id = "different-thread"}))
    assert(wait_reply(host_1, "singleton-thread-conflict", "open").error_code == "thread_conflict", "Singleton was rebound")
    logger:info("Settings opened and checkpointed on host 1", {instance_id = opened_instance_id})

    -- Step 4: Concurrent requests with same public ID to both hosts
    -- Round A: Same ID sent concurrently; Host 1 processes valid close, Host 2 rejects ws1 mismatch
    local id_a = "concurrent-same-id-01"
    local sent_a1 = process.send(host_1, "bee.app.request", {
        version = 1,
        request_id = id_a,
        op = "close",
        workspace_id = ws1,
        id = "non-existent-view",
    })
    assert(sent_a1, "Failed to send req A to host 1")
    local sent_a2 = process.send(host_2, "bee.app.request", {
        version = 1,
        request_id = id_a,
        op = "open",
        workspace_id = ws1,
        definition_id = "bee.settings:app",
    })
    assert(sent_a2, "Failed to send req A to host 2")

    local rep_a1, rep_a2 = collect_two_replies(host_1, id_a, "close", host_2, id_a, "open")
    assert(rep_a1.workspace_id == ws1, "Host 1 reply must match ws1")
    assert(rep_a1.request_id == id_a, "Host 1 reply must match request id")
    assert(rep_a1.error_code == "not_found", "Host 1 must process its own close request")
    assert(rep_a2.workspace_id == ws2, "Host 2 reply must identify its own ws2")
    assert(rep_a2.request_id == id_a, "Host 2 reply must match request id")
    assert(rep_a2.error_code == "workspace_mismatch", "Host 2 must reject ws1 with workspace_mismatch")

    -- Round B: Same ID sent concurrently; Host 1 rejects ws2 mismatch, Host 2 processes valid close
    local id_b = "concurrent-same-id-02"
    local sent_b1 = process.send(host_1, "bee.app.request", {
        version = 1,
        request_id = id_b,
        op = "open",
        workspace_id = ws2,
        definition_id = "bee.settings:app",
    })
    assert(sent_b1, "Failed to send req B to host 1")
    local sent_b2 = process.send(host_2, "bee.app.request", {
        version = 1,
        request_id = id_b,
        op = "close",
        workspace_id = ws2,
        id = "non-existent-view",
    })
    assert(sent_b2, "Failed to send req B to host 2")

    local rep_b1, rep_b2 = collect_two_replies(host_1, id_b, "open", host_2, id_b, "close")
    assert(rep_b1.workspace_id == ws1, "Host 1 reply must identify its own ws1")
    assert(rep_b1.request_id == id_b, "Host 1 reply must match request id")
    assert(rep_b1.error_code == "workspace_mismatch", "Host 1 must reject ws2 with workspace_mismatch")
    assert(rep_b2.workspace_id == ws2, "Host 2 reply must match ws2")
    assert(rep_b2.request_id == id_b, "Host 2 reply must match request id")
    assert(rep_b2.error_code == "not_found", "Host 2 must process its own close request")
    logger:info("Concurrent requests with same IDs and cross-workspace rejections verified")

    -- Step 5: Stop both initial hosts, observe shutdown reply and EXIT in bounded loop
    stop_host(host_1, ws1, "shutdown-h1")
    stop_host(host_2, ws2, "shutdown-h2")
    logger:info("Both initial hosts shut down with verified EXIT")

    -- Step 6: Restart both hosts, verify preserved workspace IDs and independent application states
    local host_1_restarted = spawn_host("bee.workspace.db:first", first_storage_policy)
    assert(host_1_restarted ~= host_1, "Restarted host 1 must have a new PID")

    local host_1_ready = false
    local host_1_restored = false
    local host_1_saved_wsid = ""
    local host_1_saved_snapshot: unknown = nil
    local host_1_restored_reply: decode.Reply? = nil
    deadline = time.after("10s")
    while (not host_1_ready or not host_1_restored) do
        if observed_exits[host_1_restarted] ~= nil then
            error("Host 1 exited during restart: " .. (decode.exit_error(observed_exits[host_1_restarted]) or "unknown"))
        end
        local selected = channel.select({ready:case_receive(), restores:case_receive(), deadline:case_receive(), events:case_receive()})
        if not selected.ok then error("Channel closed during host 1 restart") end
        if selected.channel == deadline then
            error("Timeout waiting for host 1 restart")
        elseif selected.channel == events then
            local event = selected.value
            if event.kind == process.event.EXIT then
                local from = tostring(event.from)
                observed_exits[from] = event.result
                if from == host_1_restarted then
                    error("Host 1 exited during restart: " .. (decode.exit_error(event.result) or "unknown"))
                end
            end
        elseif selected.channel == ready then
            local msg = selected.value
            if tostring(msg:from()) == host_1_restarted then
                local data: unknown = msg:payload():data()
                if type(data) == "table" and data.version == 1 then
                    host_1_saved_wsid = contract.workspace_id(data.workspace_id) or ""
                    host_1_saved_snapshot = data.saved
                    host_1_ready = true
                end
            end
        elseif selected.channel == restores then
            local msg = selected.value
            if tostring(msg:from()) == host_1_restarted then
                local rep = decode.reply(msg:payload():data())
                if rep and rep.op == "open" and rep.instance_id == opened_instance_id then
                    host_1_restored_reply = rep
                    host_1_restored = true
                end
            end
        end
    end

    assert(host_1_saved_wsid == ws1, "Workspace ID 1 must be preserved across restart")
    local count_1 = snapshot_app_count(host_1_saved_snapshot)
    if not count_1 or count_1 ~= 1 then error("Host 1 must preserve exactly 1 saved application") end
    local first_rec = snapshot_first_record(host_1_saved_snapshot)
    if not first_rec or first_rec.instance_id ~= opened_instance_id then
        error("Preserved application instance mismatch")
    end
    assert(host_1_restored_reply ~= nil and host_1_restored_reply.error_code == "", "Restored app must succeed without error")
    assert(first_rec.thread_id == associated_thread, "Stored thread association changed across owner restart")
    assert(host_1_restored_reply and host_1_restored_reply.thread_id == associated_thread, "Restored app lost its thread association")

    local host_2_restarted = spawn_host("bee.workspace.db:second", second_storage_policy)
    assert(host_2_restarted ~= host_2, "Restarted host 2 must have a new PID")

    local host_2_ready = false
    local host_2_saved_wsid = ""
    local host_2_saved_snapshot: unknown = nil
    deadline = time.after("10s")
    while not host_2_ready do
        if observed_exits[host_2_restarted] ~= nil then
            error("Host 2 exited during restart: " .. (decode.exit_error(observed_exits[host_2_restarted]) or "unknown"))
        end
        local selected = channel.select({ready:case_receive(), deadline:case_receive(), events:case_receive()})
        if not selected.ok then error("Channel closed during host 2 restart") end
        if selected.channel == deadline then
            error("Timeout waiting for host 2 restart readiness")
        elseif selected.channel == events then
            local event = selected.value
            if event.kind == process.event.EXIT then
                local from = tostring(event.from)
                observed_exits[from] = event.result
                if from == host_2_restarted then
                    error("Host 2 exited during restart: " .. (decode.exit_error(event.result) or "unknown"))
                end
            end
        else
            local msg = selected.value
            if tostring(msg:from()) == host_2_restarted then
                local data: unknown = msg:payload():data()
                if type(data) == "table" and data.version == 1 then
                    host_2_saved_wsid = contract.workspace_id(data.workspace_id) or ""
                    host_2_saved_snapshot = data.saved
                    host_2_ready = true
                end
            end
        end
    end

    assert(host_2_saved_wsid == ws2, "Workspace ID 2 must be preserved across restart")
    local count_2 = snapshot_app_count(host_2_saved_snapshot)
    if not count_2 or count_2 ~= 0 then error("Host 2 must have 0 saved applications on restart") end
    logger:info("Restart verified: Host 1 restored 1 application, Host 2 restored 0 applications")

    -- Step 7: Shutdown restarted hosts & unlisten
    stop_host(host_1_restarted, ws1, "shutdown-h1-restarted")
    stop_host(host_2_restarted, ws2, "shutdown-h2-restarted")

    for _, subscription in ipairs({ready, replies, checkpoints, restores}) do
        process.unlisten(subscription)
    end
    logger:info("ACCEPTANCE VERIFIED: dual workspace hosts inside ONE runtime proven successfully")
end

return {main = M.main}
