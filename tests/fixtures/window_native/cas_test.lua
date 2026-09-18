-- Two callers may observe intended before either claims it. The expected
-- execution state makes the second stale claim conflict atomically.
local test = require("test")
local store = require("store")

local function run()
    local db, open_error = store.open()
    if not db then error(tostring(open_error)) end
    local attempt_id = "window-cas-attempt"
    local _, insert_error = db:execute([[INSERT INTO bee_placement_attempts
        (attempt_id, owner_id, owner_incarnation, action_id, idempotency_key, request_digest, request_json,
         execution_state, cleanup_state, capability, required_cleanup, exit_observation, evidence_count, created_at, updated_at)
        VALUES (?, 'cas-owner', 1, 'cas-action', 'cas-key', 'digest', '{}', 'intended', 'pending',
         'direct_process', 'direct_process', 'eof_gated', 1, 'before', 'before')]], {attempt_id})
    if insert_error then db:release(); error(tostring(insert_error)) end
    local _, evidence_error = db:execute([[INSERT INTO bee_placement_evidence (attempt_id, sequence, at, kind, detail)
        VALUES (?, 1, 'before', 'cas.intent', 'both contenders observed intended')]], {attempt_id})
    if evidence_error then db:release(); error(tostring(evidence_error)) end

    local first_observation = store.row(db, attempt_id)
    local second_observation = store.row(db, attempt_id)
    test.eq(first_observation and first_observation.execution_state, "intended")
    test.eq(second_observation and second_observation.execution_state, "intended")
    local first = store.transition(db, attempt_id, {expected_execution = "intended", execution = "starting",
        fields = {runner_pid = "first-contender"}, evidence = {kind = "cas.first", detail = "first contender claimed"}})
    test.eq(first.ok, true)
    local second = store.transition(db, attempt_id, {expected_execution = "intended", execution = "starting",
        fields = {runner_pid = "second-contender"}, evidence = {kind = "cas.second", detail = "stale contender claimed"}})
    test.eq(second.ok, false)
    test.eq(second.code, "CONFLICT")
    local current = store.attempt(db, attempt_id)
    test.eq(current and current.execution_state, "starting")
    test.eq(current and current.runner, "first-contender")
    test.eq(current and current.evidence_count, 2)
    local page = store.evidence(db, attempt_id, 0, 64)
    test.eq(page and #page.evidence, 2)
    test.eq(page and page.evidence[2].kind, "cas.first")
    db:release()
end

return {run = run}
