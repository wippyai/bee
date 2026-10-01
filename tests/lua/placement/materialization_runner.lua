-- MIT. Test support: a hosted runner process claims an intended attempt and
-- materializes its configuration, so placement supervision observes a present
-- runner exactly as it does for a production runner. The test process keeps
-- the store assertions; the runner only owns the claim and prepare.
local process = require("process")
local channel = require("channel")
local security = require("security")
local time = require("time")
local store = require("store")
local materialization = require("materialization")
local observe = require("observe")
local types = require("types")
local M = {}
local CLAIMED = "bee.test.runner.claimed"
local PREPARED = "bee.test.runner.prepared"
local GO = "bee.test.runner.go"
local TIMEOUT = "30s"

type Job = {attempt_id: string, generation: integer, request: types.LaunchRequest, reply_to: string,
    claim_as: string?, inject_binding_failure: string?}
type Runner = {pid: string, attempt_id: string}
-- The prepared configuration crosses the process boundary from the trusted
-- test runner as a value with the materialization's shape.
type Prepared = {environment: {[string]: string}, working_directory: string, arguments: {string}, home_path: string}
type Outcome = {prepared: Prepared?, error: string?, observed: {[string]: unknown}}

local function stay(events: Channel<process.Event>)
    while true do
        local event = events:receive()
        if not event or event.kind == process.event.CANCEL then return end
    end
end

-- Process entry: claim, wait for the test's go, prepare, then stay present
-- until the test releases the runner.
function M.main(job: Job)
    local events = assert(process.events())
    local go = assert(process.listen(GO, {message = true}))
    local db = assert(store.open())
    local claimed = store.transition(db, job.attempt_id, {expected_execution = "intended", execution = "starting",
        fields = {runner_pid = job.claim_as or process.pid()}, evidence = {kind = "test.claimed", detail = "hosted materialization runner"}})
    process.send(job.reply_to, CLAIMED, {attempt_id = job.attempt_id, ok = claimed.ok, message = claimed.message})
    if not claimed.ok then db:release(); stay(events); return end
    local selected = channel.select({go:case_receive(), events:case_receive()})
    process.unlisten(go)
    if selected.channel ~= go then db:release(); return end
    local failure = job.inject_binding_failure
    if failure then
        store.bind_session_file = function(_db: unknown, _owner: string, _session: string, _path: string, _digest: string): string?
            return failure
        end
    end
    local prepared, prepare_error = materialization.prepare(db, job.request, job.attempt_id, job.generation)
    db:release()
    process.send(job.reply_to, PREPARED, {attempt_id = job.attempt_id, prepared = prepared, error = prepare_error, observed = observe.snapshot()})
    stay(events)
end

local function await(replies: Channel<process.Message>, topic: string, attempt_id: string): {[string]: unknown}
    local deadline = time.after(TIMEOUT)
    local found: {[string]: unknown}? = nil
    while not found do
        local selected = channel.select({replies:case_receive(), deadline:case_receive()})
        if selected.channel == deadline then process.unlisten(replies); error("materialization runner did not answer " .. topic) end
        local data = selected.value:payload():data()
        if type(data) == "table" and data.attempt_id == attempt_id then found = data :: {[string]: unknown} end
    end
    process.unlisten(replies)
    return assert(found)
end

-- Spawns the runner entry under the caller's scope and returns once the
-- attempt is claimed. claim_as records another runner identity instead.
function M.claim(entry: string, request: types.LaunchRequest, generation: integer, claim_as: string?, inject_binding_failure: string?): Runner
    local replies = assert(process.listen(CLAIMED, {message = true}))
    local pid, spawn_error = process.with_options({}):with_scope(assert(security.scope())):spawn(entry, "bee:workers",
        {attempt_id = request.attempt_id, generation = generation, request = request, reply_to = tostring(process.pid()),
            claim_as = claim_as, inject_binding_failure = inject_binding_failure})
    if not pid then process.unlisten(replies); error("spawn materialization runner: " .. tostring(spawn_error)) end
    local claimed = await(replies, CLAIMED, request.attempt_id)
    if claimed.ok ~= true then error("runner claim refused: " .. tostring(claimed.message)) end
    return {pid = tostring(pid), attempt_id = request.attempt_id}
end

-- Runs the claimed runner's prepare and returns its outcome.
function M.prepare(runner: Runner): Outcome
    local replies = assert(process.listen(PREPARED, {message = true}))
    assert(process.send(runner.pid, GO, {attempt_id = runner.attempt_id}))
    local reply = await(replies, PREPARED, runner.attempt_id)
    local prepared = reply.prepared
    local failure = reply.error
    local observed = reply.observed
    return {prepared = type(prepared) == "table" and prepared :: Prepared or nil,
        error = type(failure) == "string" and failure or nil,
        observed = type(observed) == "table" and observed :: {[string]: unknown} or {}}
end

function M.release(runner: Runner)
    process.terminate(runner.pid)
end

return M
