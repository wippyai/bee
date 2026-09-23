-- Real PTY acceptance for the process-local native window seam.
local test = require("test")
local process = require("process")
local channel = require("channel")
local tty = require("tty")
local time = require("time")
local security = require("security")
local funcs = require("funcs")
local window = require("window")
local store = require("placement_store")
local registry = require("registry")
local OWNER = "bee.window.native.owner"
local FOREIGN = "bee.window.native.foreign"
local POLICY = "bee.window_native:launch_policy"
local GROUP_POLICY = "bee.window_native:launch_policy_group"
local function request(attempt_id: string, required_cleanup: string?): {[string]: unknown}
    local cleanup = required_cleanup or "direct_process"
    local policy = cleanup == "process_group" and GROUP_POLICY or POLICY
    return {idempotency_key = "window-key-" .. attempt_id, owner_id = OWNER, owner_incarnation = 1,
        action_id = "window-action-" .. attempt_id, attempt_id = attempt_id, binding_ref = "bee.window_native:binding",
        policy_ref = policy, profile_id = "window", binding_digest = string.rep("a", 64), profile_digest = string.rep("b", 64),
        launch = {executable = "sh", argv = {"-c", "IFS= read -r line; printf 'WINDOW:%s\\n' \"$line\"; stty size; sleep 30"}, environment = {}, working_directory_ref = nil, readiness = "none"},
        resources = {}, environment = {}, environment_refs = {}, projections = {}, required_cleanup = cleanup,
        required_exit_observation = "eof_gated", timeouts = {start_ms = 10000, stop_grace_ms = 500, drain_ms = 1000, retain_ms = 1000}}
end
local function caller()
    local policy = assert(security.policy("bee.window_native:caller_policy"))
    local store_policy = assert(security.policy("bee:placement_store_policy"))
    local exec_policy = assert(security.policy("bee:placement_exec_policy"))
    local resource_policy = assert(security.policy("bee:resource_resolve_policy"))
    return funcs.new():with_actor(security.new_actor(OWNER)):with_scope(security.new_scope({policy, store_policy, exec_policy, resource_policy}))
end
local function prepare(attempt_id: string, required_cleanup: string?): string
    local reply, err = caller():call("bee.placement.native:prepare", request(attempt_id, required_cleanup))
    if err then error(tostring(err)) end
    local value = reply :: {[string]: unknown}
    if value.ok ~= true then error(tostring((value.error :: {[string]: unknown}).message)) end
    return tostring((value.value :: {[string]: unknown}).attempt_id)
end
local function captured_identity(attempt_id: string): boolean
    local db = store.open()
    if not db then return false end
    local row = db and store.row(db, attempt_id) or nil
    db:release()
    if not row then return false end
    return type(row.pid) == "number" and (row.pid :: number) > 1
        and type(row.pgid) == "number" and (row.pgid :: number) > 1
        and type(row.start_ticks) == "number" and (row.start_ticks :: number) > 0
        and type(row.boot_id) == "string" and #(row.boot_id :: string) > 0
end
local function process_group_recorded(attempt_id: string): boolean
    local db = store.open()
    if not db then return false end
    local row = db and store.row(db, attempt_id) or nil
    db:release()
    if not row then return false end
    return row.capability == "process_group" and row.required_cleanup == "process_group"
        and captured_identity(attempt_id)
end
local function child_scope(extra: string?): security.Scope
    local names = {"bee:placement_store_policy", "bee:placement_exec_policy", "bee:placement_runner_policy", "bee:resource_resolve_policy", "bee.window_native:child_policy"}
    if extra then names[#names + 1] = extra end
    local policies: {security.Policy} = {}
    for index, name in ipairs(names) do policies[index] = assert(security.policy(name)) end
    return security.new_scope(policies)
end
local function wait_for(view: tty.Viewport, text: string, timeout_ms: integer): boolean
    local function contains(snapshot: tty.ViewportSnapshot?): boolean
        if not snapshot then return false end
        return table.concat(snapshot.rows, "\n"):find(text, 1, true) ~= nil
    end
    local deadline = time.now():unix_nano() + timeout_ms * 1000000
    while time.now():unix_nano() < deadline do
        local snapshot = view:snapshot()
        if contains(snapshot) then return true end
        time.sleep("50ms")
    end
    local snapshot = view:snapshot()
    return contains(snapshot)
end
local function run()
    local activation = assert(registry.get("bee:harness_activation"))
    local data = activation.data :: {[string]: unknown}
    local bindings = data.bindings :: {string}
    bindings[#bindings + 1] = "bee.window_native:binding"
    local changes = registry.snapshot():changes()
    changes:update(activation)
    local applied, apply_error = changes:apply()
    if not applied then error(tostring(apply_error)) end
    assert(window.open)
    local view = assert(tty.viewport({width = 40, height = 12}))
    local parent = process.pid()
    local attempt_id = "window-attempt-" .. tostring(time.now():unix_nano())
    local prepared = prepare(attempt_id)
    local grant = assert(view:grant())
    local results = assert(process.listen("bee.window.native.result", {message = true}))
    local owner_child = assert(process.with_options({terminal = grant}):with_actor(security.new_actor(OWNER)):with_scope(child_scope())
        :spawn_monitored("bee.window_native:child", "bee:workers", parent, prepared, "owner"))
    local foreign_child = ""
    local saw_open, saw_identity, saw_io, saw_finish, saw_foreign = false, false, false, false, false
    local deadline = time.after("20s")
    while not (saw_finish and saw_foreign) do
        local selected = channel.select({results:case_receive(), deadline:case_receive()})
        if not selected.ok then break end
        if selected.channel == deadline then break end
        local message = selected.value
        local data = message:payload():data()
        if type(data) == "table" and tostring(message:from()) == owner_child then
            if data.phase == "open" then
                saw_open = data.ok == true and data.duplicate_ok == false
                saw_identity = captured_identity(prepared)
                -- A raw process message cannot authorize stopping the child.
                process.send(owner_child, "bee.placement.control", {command = "stop", mode = "forced", grace_ms = 0})
                time.sleep("100ms")
                local reconciled, reconcile_error = caller():call("bee.placement.native:reconcile", {attempt_id = prepared})
                local reply = type(reconciled) == "table" and reconciled :: {[string]: unknown} or nil
                local attempt = reply and type(reply.value) == "table" and reply.value :: {[string]: unknown} or nil
                test.is_nil(reconcile_error)
                test.eq(reply and reply.ok, true)
                test.eq(attempt and attempt.execution_state, "running", "live terminal retains supervised running state")
                if foreign_child == "" then
                    foreign_child = assert(process.with_options({}):with_actor(security.new_actor(FOREIGN)):with_scope(child_scope())
                        :spawn_monitored("bee.window_native:child", "bee:workers", parent, prepared, "foreign"))
                end
            elseif data.phase == "io" then
                saw_io = data.sent == true and data.resized == true
                if saw_io and wait_for(view, "WINDOW:hello from window", 3000) and wait_for(view, "10 30", 3000) then
                    local stopped, stop_error = caller():call("bee.placement.native:stop", {attempt_id = prepared})
                    local stop_reply = type(stopped) == "table" and stopped :: {[string]: unknown} or nil
                    test.is_nil(stop_error)
                    test.eq(stop_reply and stop_reply.ok, true)
                    process.send(tostring(owner_child), "bee.window.native.close." .. parent, {})
                end
            elseif data.phase == "close" then
                saw_io = saw_io and data.closed == true and data.timed_out ~= true and data.stop_seen == true
            elseif data.phase == "finish" then
                saw_finish = data.finished == true
            end
        elseif type(data) == "table" and tostring(message:from()) == foreign_child and data.phase == "foreign" then
            saw_foreign = data.ok == false and tostring(data.error):find("another actor", 1, true) ~= nil
        end
    end
    test.ok(saw_open, "same owner opens once and duplicate open is refused")
    test.ok(saw_identity, "native PTY identity fields are captured before readiness")
    test.ok(saw_io, "window accepts input, resize and close")
    test.ok(saw_finish, "terminal completion is finalized by finish")
    test.ok(saw_foreign, "foreign actor cannot open the attempt")
    local status_reply, status_call_error = caller():call("bee.placement.native:status", {attempt_id = prepared})
    local status_object = type(status_reply) == "table" and status_reply :: {[string]: unknown} or nil
    local status_result = status_object and type(status_object.value) == "table" and status_object.value :: {[string]: unknown} or nil
    local status_value = status_result and type(status_result.attempt) == "table" and status_result.attempt :: {[string]: unknown} or nil
    test.is_nil(status_call_error)
    test.eq(status_object and status_object.ok, true)
    test.eq(status_value and status_value.execution_state, "exited")
    test.eq(status_value and status_value.cleanup_state, "pending")
    test.not_nil(status_value and status_value.home_ref)
    local cleanup_reply, cleanup_call_error = caller():call("bee.placement.native:cleanup", {attempt_id = prepared})
    local cleanup_object = type(cleanup_reply) == "table" and cleanup_reply :: {[string]: unknown} or nil
    local cleanup_error = cleanup_object and type(cleanup_object.error) == "table" and cleanup_object.error :: {[string]: unknown} or nil
    test.is_nil(cleanup_call_error)
    test.eq(cleanup_object and cleanup_object.ok, false)
    test.is_true(tostring(cleanup_error and cleanup_error.message):find("not proven gone", 1, true) ~= nil)

    -- A process-group attempt retains its home while live and can be cleaned
    -- only after terminal completion plus an independent group-absence probe.
    local group_attempt = prepare("window-group-" .. tostring(time.now():unix_nano()), "process_group")
    local group_view = assert(tty.viewport({width = 32, height = 10}))
    local group_child = assert(process.with_options({terminal = assert(group_view:grant())}):with_actor(security.new_actor(OWNER)):with_scope(child_scope())
        :spawn_monitored("bee.window_native:child", "bee:workers", parent, group_attempt, "group"))
    local group_open, group_finish, group_live_refused = false, false, false
    local group_deadline = time.after("15s")
    while not group_finish do
        local selected = channel.select({results:case_receive(), group_deadline:case_receive()})
        if not selected.ok or selected.channel == group_deadline then break end
        local message = selected.value
        local data = message:payload():data()
        if type(data) == "table" and tostring(message:from()) == group_child then
            if data.phase == "open" then
                group_open = data.ok == true and process_group_recorded(group_attempt)
            elseif data.phase == "io" and group_open then
                local live_cleanup = caller():call("bee.placement.native:cleanup", {attempt_id = group_attempt})
                local live_object = type(live_cleanup) == "table" and live_cleanup :: {[string]: unknown} or nil
                if live_object and live_object.ok == false then group_live_refused = true end
                local stopped = caller():call("bee.placement.native:stop", {attempt_id = group_attempt})
                local stop_object = type(stopped) == "table" and stopped :: {[string]: unknown} or nil
                test.eq(stop_object and stop_object.ok, true)
                time.sleep("100ms")
                process.send(tostring(group_child), "bee.window.native.close." .. parent, {})
            elseif data.phase == "finish" then
                group_finish = data.finished == true
            end
        end
    end
    test.ok(group_open, "process-group PTY records durable group identity")
    test.ok(group_live_refused, "live process-group cleanup is refused")
    test.ok(group_finish, "process-group terminal completion is observed")
    group_view:close()
    local group_cleanup_ok = false
    for _ = 1, 20 do
        local group_cleanup = caller():call("bee.placement.native:cleanup", {attempt_id = group_attempt})
        local group_object = type(group_cleanup) == "table" and group_cleanup :: {[string]: unknown} or nil
        if group_object and group_object.ok == true then
            group_cleanup_ok = true
            break
        end
        time.sleep("100ms")
    end
    test.ok(group_cleanup_ok, "process-group cleanup follows proven group absence")

    -- Kill the owning actor without its finish() path. Reconciliation must
    -- establish leader absence; actor death alone cannot authorize cleanup.
    local lost_attempt = prepare("window-lost-" .. tostring(time.now():unix_nano()), "process_group")
    local lost_view = assert(tty.viewport({width = 32, height = 10}))
    local lost_child = assert(process.with_options({terminal = assert(lost_view:grant())}):with_actor(security.new_actor(OWNER)):with_scope(child_scope())
        :spawn_monitored("bee.window_native:child", "bee:workers", parent, lost_attempt, "lost"))
    local lost_open = false
    local lost_deadline = time.after("10s")
    while not lost_open do
        local selected = channel.select({results:case_receive(), lost_deadline:case_receive()})
        if not selected.ok or selected.channel == lost_deadline then break end
        local message = selected.value
        local data = message:payload():data()
        if tostring(message:from()) == lost_child and type(data) == "table" and data.phase == "open" then
            lost_open = data.ok == true and process_group_recorded(lost_attempt)
        end
    end
    test.ok(lost_open, "crash fixture captured a real process-group identity")
    assert(process.terminate(lost_child))
    local lost_cleaned = false
    for _ = 1, 50 do
        local raw = caller():call("bee.placement.native:reconcile", {attempt_id = lost_attempt})
        local result = type(raw) == "table" and raw :: {[string]: unknown} or nil
        local attempt = result and type(result.value) == "table" and result.value :: {[string]: unknown} or nil
        if attempt and attempt.execution_state == "exited" then
            local cleaned = caller():call("bee.placement.native:cleanup", {attempt_id = lost_attempt})
            local cleanup = type(cleaned) == "table" and cleaned :: {[string]: unknown} or nil
            if cleanup and cleanup.ok == true then lost_cleaned = true; break end
        end
        time.sleep("100ms")
    end
    test.ok(lost_cleaned, "owner death reconciles actual child exit and group absence")
    lost_view:close()

    local race_attempt = prepare("window-race-" .. tostring(time.now():unix_nano()))
    local race_view_a = assert(tty.viewport({width = 24, height = 8}))
    local race_view_b = assert(tty.viewport({width = 24, height = 8}))
    local race_a = assert(process.with_options({terminal = assert(race_view_a:grant())}):with_actor(security.new_actor(OWNER)):with_scope(child_scope())
        :spawn_monitored("bee.window_native:child", "bee:workers", parent, race_attempt, "race"))
    local race_b = assert(process.with_options({terminal = assert(race_view_b:grant())}):with_actor(security.new_actor(OWNER)):with_scope(child_scope())
        :spawn_monitored("bee.window_native:child", "bee:workers", parent, race_attempt, "race"))
    local race_results, race_successes = 0, 0
    local race_deadline = time.after("10s")
    while race_results < 2 do
        local selected = channel.select({results:case_receive(), race_deadline:case_receive()})
        if not selected.ok or selected.channel == race_deadline then break end
        local message = selected.value
        local data = message:payload():data()
        local sender = tostring(message:from())
        if type(data) == "table" and data.phase == "race" and (sender == tostring(race_a) or sender == tostring(race_b)) then
            race_results = race_results + 1
            if data.ok == true then race_successes = race_successes + 1 end
        end
    end

    -- A stop committed while executor:terminal() starts the child wins: the
    -- window either refuses to open or ends without its owner closing it, and
    -- reconciliation proves the child gone.
    local startup_attempt = prepare("window-startup-stop-" .. tostring(time.now():unix_nano()))
    local startup_view = assert(tty.viewport({width = 24, height = 8}))
    local startup_child = assert(process.with_options({terminal = assert(startup_view:grant())}):with_actor(security.new_actor(OWNER))
        :with_scope(child_scope("bee.window_native:caller_policy"))
        :spawn_monitored("bee.window_native:child", "bee:workers", parent, startup_attempt, "startup_stop"))
    local startup: {[string]: unknown}? = nil
    local startup_deadline = time.after("15s")
    while not startup do
        local selected = channel.select({results:case_receive(), startup_deadline:case_receive()})
        if not selected.ok or selected.channel == startup_deadline then break end
        local message = selected.value
        local data = message:payload():data()
        if tostring(message:from()) == startup_child and type(data) == "table" and data.phase == "startup_stop" then
            startup = data :: {[string]: unknown}
        end
    end
    test.not_nil(startup, "startup-stop child reported")
    test.eq(startup and startup.stop_ok, true, "stop is committed while the window starts: " .. tostring(startup and startup.stop_error))
    if startup and startup.ok == true then
        test.eq(startup.stop_seen, true, "an opened window ends from the committed stop")
        test.eq(startup.finished, true)
    else
        test.eq(startup and startup.error, "window stopped during startup")
    end
    local startup_settled = false
    for _ = 1, 50 do
        local raw = caller():call("bee.placement.native:reconcile", {attempt_id = startup_attempt})
        local result = type(raw) == "table" and raw :: {[string]: unknown} or nil
        local attempt = result and type(result.value) == "table" and result.value :: {[string]: unknown} or nil
        if attempt and attempt.execution_state == "exited" then startup_settled = true; break end
        time.sleep("100ms")
    end
    test.ok(startup_settled, "a stop during startup settles to exited")
    startup_view:close()

    process.unlisten(results)
    test.eq(race_results, 2)
    test.eq(race_successes, 1)
    race_view_a:close()
    race_view_b:close()
    test.ok(wait_for(view, "WINDOW:hello from window", 3000), "PTY receives input and renders output")
    test.ok(wait_for(view, "10 30", 3000), "PTY observes the requested resize")
    view:close()
end
return {run = run}
