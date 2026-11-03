-- MIT. Generic workdir-preparer extension point discovery, host authorization,
-- setup execution and cleanup execution.
local registry = require("registry")
local funcs = require("funcs")
local sql = require("sql")
local json = require("json")
local bounds = require("bounds")
local paths = require("paths")
local types = require("types")
local resources = require("resources")
local store = require("store")
local process = require("process")
local cdc = require("cdc")
local channel = require("channel")

local M = {}
type Preparer = {binding_id: string, plan: string, setup: string, cleanup: string}

local function resolve_preparer(binding_ref: string): (Preparer?, string?)
    local entry, err = registry.get(binding_ref)
    if err or not entry then return nil, "preparer binding " .. binding_ref .. " is not in the registry" end
    local obj = bounds.object(entry)
    if not obj or obj.kind ~= "contract.binding" then return nil, "preparer binding " .. binding_ref .. " is not a contract binding" end
    local meta = bounds.object(obj.meta) or {}
    if meta.type ~= types.WORKDIR_PREPARER_BINDING_TYPE then
        return nil, "preparer binding " .. binding_ref .. " meta.type is not " .. types.WORKDIR_PREPARER_BINDING_TYPE
    end
    local data = bounds.object(obj.data)
    if not data then return nil, "preparer binding " .. binding_ref .. " has no data" end
    local contracts = data.contracts
    if type(contracts) ~= "table" then return nil, "preparer binding " .. binding_ref .. " has no contracts" end
    local plan_target: string? = nil
    local setup_target: string? = nil
    local cleanup_target: string? = nil
    for _, raw in ipairs(contracts) do
        local c = bounds.object(raw)
        if c and c.contract == types.WORKDIR_PREPARER_CONTRACT then
            local methods = bounds.object(c.methods)
            if methods then
                plan_target = bounds.id(methods.plan)
                setup_target = bounds.id(methods.setup)
                cleanup_target = bounds.id(methods.cleanup)
            end
        end
    end
    if not plan_target or not setup_target or not cleanup_target then
        return nil, "preparer binding " .. binding_ref .. " does not implement " .. types.WORKDIR_PREPARER_CONTRACT
    end
    return {binding_id = binding_ref, plan = plan_target, setup = setup_target, cleanup = cleanup_target}, nil
end

function M.authorized_preparers(): ({Preparer}?, string?)
    local authorized_ids, authorized_error = resources.workdir_preparers()
    if not authorized_ids then return nil, authorized_error end
    local preparers: {Preparer} = {}
    for _, binding_ref in ipairs(authorized_ids) do
        local preparer, err = resolve_preparer(binding_ref)
        if not preparer then
            return nil, err
        end
        preparers[#preparers + 1] = preparer
    end
    return preparers, nil
end

local function record(db: sql.DB, id: string, kind: string, detail: string): string?
    local result = store.transition(db, id, {evidence = {kind = kind, detail = detail}})
    return not result.ok and (result.message or "record preparer evidence") or nil
end

local function invoke(target: string, input: unknown): ({[string]: unknown}?, string?)
    local raw, err = funcs.call(target, input)
    if err then return nil, tostring(err) end
    local reply = bounds.object(raw)
    if not reply or reply.ok ~= true then
        local fault = reply and bounds.object(reply.error)
        return nil, fault and tostring(fault.message) or "invalid preparer reply"
    end
    local value = bounds.object(reply.value)
    if not value then return nil, "preparer value must be an object" end
    return value, nil
end

function M.setup(db: sql.DB, request: types.LaunchRequest, attempt_id: string, initial_work_dir: string, write_roots: {string}): (string?, {string}?, string?)
    local function failed(message: string): (string?, {string}?, string?)
        local err = record(db, attempt_id, "workdir_preparer.failed", message)
        return nil, nil, err or message
    end
    local preparers, preparers_error = M.authorized_preparers()
    if not preparers then return failed(preparers_error or "resolve preparers") end
    local executor, executor_error = resources.executor()
    if not executor then return failed(executor_error or "resolve executor") end
    local current_work_dir = initial_work_dir
    local extra_roots: {string} = {}
    local seen: {[string]: boolean} = {}
    local handled: {[string]: boolean} = {}
    for _, preparer in ipairs(preparers) do
        local input: types.WorkdirPreparerSetupInput = {attempt_id = attempt_id, owner_id = request.owner_id,
            working_directory = current_work_dir, write_roots = write_roots, options = request.options, argv = request.launch.argv}
        local plans, plans_error = store.preparer_plans(db, attempt_id)
        if not plans then return failed(plans_error or "read preparer intent") end
        local saved: {[string]: unknown}? = nil
        for _, plan in ipairs(plans) do
            local value = bounds.object(json.decode(plan.record_json))
            if not value then return failed("corrupt preparer intent") end
            if value.binding_id == preparer.binding_id then saved = value end
        end
        if saved then
            if saved.setup ~= preparer.setup or saved.cleanup ~= preparer.cleanup or saved.plan ~= preparer.plan then
                return failed("preparer binding changed since planning")
            end
            input.state = saved.state
        else
            local planned, plan_error = invoke(preparer.plan, input)
            if not planned then return failed("preparer " .. preparer.binding_id .. ": " .. tostring(plan_error)) end
            input.state = planned.state
            local encoded, encode_error = json.encode({binding_id = preparer.binding_id, plan = preparer.plan,
                setup = preparer.setup, cleanup = preparer.cleanup, state = planned.state})
            if not encoded then return failed(tostring(encode_error)) end
            local intent_error = store.record_preparer_plan(db, attempt_id, preparer.binding_id, encoded)
            if intent_error then return failed(intent_error) end
        end
        local current = store.row(db, attempt_id)
        if not current or current.execution_state ~= "starting" then return failed("attempt stopped before workdir setup") end
        local value, setup_error = invoke(preparer.setup, input)
        if not value then return failed("preparer " .. preparer.binding_id .. ": " .. tostring(setup_error)) end
        if value.handled_options ~= nil then
            local names = bounds.array(value.handled_options, 32)
            if not names then return failed("invalid handled options") end
            for _, raw_name in ipairs(names) do
                local name = bounds.id(raw_name)
                if not name then return failed("invalid handled option name") end
                handled[name] = true
            end
        end
        if value.working_directory ~= nil then
            local proposed = bounds.text(value.working_directory, 8192)
            if not proposed then return failed("invalid preparer working_directory") end
            local admitted, path_error = paths.admit(proposed, write_roots, executor)
            if not admitted then return failed(path_error or "workdir outside write grants") end
            current_work_dir = admitted
        end
        if value.extra_writable_roots ~= nil then
            local roots = bounds.array(value.extra_writable_roots, 64)
            if not roots then return failed("invalid preparer writable roots") end
            for _, raw_root in ipairs(roots) do
                local path = bounds.text(raw_root, 8192)
                if not path then return failed("invalid preparer writable root") end
                local admitted, path_error = paths.admit(path, write_roots, executor)
                if not admitted then return failed(path_error or "root outside write grants") end
                if not seen[admitted] then seen[admitted] = true; extra_roots[#extra_roots + 1] = admitted end
            end
        end
        local evidence_error = record(db, attempt_id, "workdir_preparer.setup", preparer.binding_id)
        if evidence_error then return nil, nil, evidence_error end
        current = store.row(db, attempt_id)
        if not current or current.execution_state ~= "starting" then return failed("attempt stopped during workdir setup") end
    end
    for name in pairs(request.options or {}) do
        if not handled[name] then return failed("no authorized preparer handled option " .. name) end
    end
    table.sort(extra_roots)
    return current_work_dir, extra_roots, nil
end

-- An attempt's preparer cleanup runs under its lock: a process name the
-- runtime releases when its holder ends, so one cleanup runs at a time and a
-- crashed holder frees the attempt for the next caller.
M.LOCK = "bee.placement.preparers/"
-- locked runs the cleanup when the caller takes the attempt's lock and
-- reports busy while another live caller holds it.
local function locked(attempt: types.Attempt, lock: string, after: integer?): (boolean?, string?, boolean)
    local taken, take_error = process.registry.register(lock)
    if not taken then
        if take_error and take_error:kind() == errors.ALREADY_EXISTS then return nil, nil, true end
        return false, "take the attempt's cleanup lock: " .. tostring(take_error), false
    end
    local called, cleaned, cleanup_error = pcall(M.execute_cleanup, attempt, after)
    process.registry.unregister(lock, process.registry.LOCAL)
    if not called then return false, tostring(cleaned), false end
    return cleaned, cleanup_error, false
end
-- cleanup runs the attempt's preparer cleanups in the caller. While another
-- caller holds the attempt's lock this one follows it: each outcome the
-- holder records, or the holder's exit, is a reason to try the lock again,
-- and a failure recorded meanwhile is this call's outcome too.
function M.cleanup(attempt: types.Attempt): (boolean, string?)
    local lock = M.LOCK .. attempt.attempt_id
    local db, open_error = store.open()
    if not db then return false, open_error end
    local row = store.row(db, attempt.attempt_id)
    db:release()
    if not row then return false, "cleanup attempt is not recorded" end
    local after = bounds.count(row.evidence_count)
    local cleaned, cleanup_error, busy = locked(attempt, lock, nil)
    if not busy then return cleaned == true, cleanup_error end
    local changes, stream_error = cdc.stream("bee:changes", {tables = {"bee_placement_evidence"}, ops = {"insert"}})
    if not changes then return false, "follow the attempt's cleanup: " .. tostring(stream_error) end
    local events = assert(process.events())
    local watched: string? = nil
    local function finish(ok: boolean, problem: string?): (boolean, string?)
        changes:close()
        if watched then process.unmonitor(watched) end
        return ok, problem
    end
    while true do
        cleaned, cleanup_error, busy = locked(attempt, lock, after)
        if not busy then return finish(cleaned == true, cleanup_error) end
        local holder = process.registry.lookup(lock, process.registry.LOCAL)
        if holder then
            local cases = {changes:channel():case_receive()}
            if tostring(holder) ~= tostring(process.pid()) and tostring(holder) ~= watched then
                if watched then process.unmonitor(watched) end
                watched = process.monitor(tostring(holder)) and tostring(holder) or nil
            end
            if watched then cases[#cases + 1] = events:case_receive() end
            local selected = channel.select(cases)
            if not selected.ok then return finish(false, "the attempt's cleanup could not be followed") end
        end
    end
end

function M.execute_cleanup(attempt: types.Attempt, after: integer?): (boolean, string?)
    if tostring(process.registry.lookup(M.LOCK .. attempt.attempt_id, process.registry.LOCAL)) ~= tostring(process.pid()) then
        return false, "preparer cleanup runs under the attempt's cleanup lock"
    end
    local db, open_error = store.open()
    if not db then return false, open_error end
    local plans, plans_error = store.preparer_plans(db, attempt.attempt_id)
    if not plans then db:release(); return false, plans_error end
    local rows, query_error = db:query("SELECT sequence, kind, detail FROM bee_placement_evidence WHERE attempt_id = ? AND kind IN ('workdir_preparer.cleaned', 'workdir_preparer.retained', 'workdir_preparer.failed') ORDER BY sequence", {attempt.attempt_id})
    if query_error or not rows then db:release(); return false, "read preparer cleanup evidence" end
    local completed: {[string]: boolean} = {}
    local failed: {[string]: string} = {}
    local pending: {{[string]: unknown}} = {}
    for _, plan in ipairs(plans) do
        local value = bounds.object(json.decode(plan.record_json))
        if not value then db:release(); return false, "corrupt preparer intent" end
        pending[#pending + 1] = value
    end
    for _, row in ipairs(rows) do
        local detail = bounds.text(row.detail, 65536)
        if not detail then db:release(); return false, "corrupt preparer evidence" end
        local binding = detail:match("^(.-): ") or detail
        if row.kind ~= "workdir_preparer.failed" then completed[binding] = true
        elseif after and (bounds.count(row.sequence) or 0) > after then failed[binding] = detail end
    end
    -- A preparer's cleanup runs outside the store: the connection is held
    -- only to record each outcome.
    db:release()
    local function note(kind: string, detail: string): string?
        local recorder, recorder_error = store.open()
        if not recorder then return recorder_error or "open placement store" end
        local noted = record(recorder, attempt.attempt_id, kind, detail)
        recorder:release()
        return noted
    end
    local failures: {string} = {}
    for index = #pending, 1, -1 do
        local saved = pending[index]
        local binding = bounds.id(saved.binding_id)
        local target = bounds.id(saved.cleanup)
        if not binding or not target then return false, "invalid cleanup binding" end
        if failed[binding] then failures[#failures + 1] = failed[binding]
        elseif not completed[binding] then
            local input: types.WorkdirPreparerCleanupInput = {attempt_id = attempt.attempt_id, owner_id = attempt.owner_id,
                state = saved.state, exit = attempt.exit, execution_state = attempt.execution_state}
            local value, cleanup_error = invoke(target, input)
            local err: string? = cleanup_error
            if value then
                if type(value.retained) ~= "boolean" then err = "invalid cleanup result"
                elseif value.retained then
                    local reason = bounds.text(value.reason, 8192)
                    if not reason then err = "missing retention reason"
                    else err = note("workdir_preparer.retained", binding .. ": " .. reason) end
                else err = note("workdir_preparer.cleaned", binding) end
            end
            if err then
                local failure = binding .. ": " .. err
                local evidence_error = note("workdir_preparer.failed", failure)
                failures[#failures + 1] = evidence_error or failure
            end
        end
    end
    if #failures > 0 then return false, table.concat(failures, "; ") end
    return true, nil
end
return M
