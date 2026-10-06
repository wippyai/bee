-- MIT. The node's application test runs in the node database. The request a
-- run is made with (workspace, actor, application, the tests planned) is
-- written once by the authorized backend; the runner reads it from here and
-- writes the results. Only holders of db.get on the node database reach it,
-- which no application scope does.
local sql = require("sql")
local json = require("json")
local time = require("time")
local tests = require("tests")

local M = {}
M.DB = "bee:db"

type Object = {[string]: unknown}
type Planned = {id: string, suite: string, timeout: string}
-- state is pending until the runner takes the run, running while it executes,
-- then complete, or interrupted when the node stopped under it.
type Row = {run_id: string, workspace_id: string, actor_id: string, overlay: string, application: string,
    plan: {Planned}, state: string, result: Object?}
M.Row = Row

local COLUMNS = "run_id, workspace_id, actor_id, overlay, application, plan_json, state, result_json"

local function row_of(raw: {[string]: unknown}): (Row?, string?)
    local plan = json.decode(tostring(raw.plan_json))
    if type(plan) ~= "table" then return nil, "stored plan is invalid" end
    local result: Object? = nil
    if raw.result_json ~= nil then
        local decoded = json.decode(tostring(raw.result_json))
        if type(decoded) ~= "table" then return nil, "stored result is invalid" end
        result = decoded
    end
    return {run_id = tostring(raw.run_id), workspace_id = tostring(raw.workspace_id), actor_id = tostring(raw.actor_id),
        overlay = tostring(raw.overlay), application = tostring(raw.application), plan = plan :: {Planned},
        state = tostring(raw.state), result = result}, nil
end

-- create keeps a new run within the active and retained bounds, dropping the
-- oldest finished runs to make room, and reports a refusal code when it cannot.
function M.create(run: Row): (boolean, string?, string?)
    local plan, plan_error = json.encode(run.plan)
    if not plan then return false, "INTERNAL", tostring(plan_error) end
    local db, err = sql.get(M.DB)
    if not db then return false, "UNAVAILABLE", "node database: " .. tostring(err) end
    local tx, begin_error = db:begin()
    if not tx then db:release(); return false, "UNAVAILABLE", tostring(begin_error) end
    local counted, count_error = tx:query("SELECT state, COUNT(*) AS count FROM bee_node_test_runs GROUP BY state")
    if not counted then tx:rollback(); db:release(); return false, "UNAVAILABLE", tostring(count_error) end
    local active, retained = 0, 0
    for _, counts in ipairs(counted) do
        local count = math.floor(tonumber(counts.count) or 0)
        retained = retained + count
        if counts.state == "pending" or counts.state == "running" then active = active + count end
    end
    if active >= tests.MAX_ACTIVE then
        tx:rollback(); db:release()
        return false, "BUSY", "too many test runs are in progress; wait for one to complete"
    end
    local excess = retained - tests.MAX_RUNS + 1
    if excess > 0 then
        local _, drop_error = tx:execute("DELETE FROM bee_node_test_runs WHERE run_id IN (SELECT run_id FROM bee_node_test_runs "
            .. "WHERE state NOT IN ('pending', 'running') ORDER BY created_ms, rowid LIMIT ?)", {excess})
        if drop_error then tx:rollback(); db:release(); return false, "UNAVAILABLE", tostring(drop_error) end
    end
    local _, insert_error = tx:execute("INSERT INTO bee_node_test_runs (run_id, workspace_id, actor_id, overlay, application, plan_json, state, created_ms) "
        .. "VALUES (?, ?, ?, ?, ?, ?, 'pending', ?)",
        {run.run_id, run.workspace_id, run.actor_id, run.overlay, run.application, plan, math.floor(time.now():unix_nano() / 1000000)})
    if insert_error then tx:rollback(); db:release(); return false, "UNAVAILABLE", tostring(insert_error) end
    local committed, commit_error = tx:commit()
    db:release()
    if not committed then return false, "UNAVAILABLE", tostring(commit_error) end
    return true, nil, nil
end

-- get returns the run run_id names, only when it belongs to actor_id in
-- workspace_id when those are given.
function M.get(run_id: string, workspace_id: string?, actor_id: string?): (Row?, string?)
    local db, err = sql.get(M.DB)
    if not db then return nil, "node database: " .. tostring(err) end
    local rows, query_error = db:query("SELECT " .. COLUMNS .. " FROM bee_node_test_runs WHERE run_id = ?", {run_id})
    db:release()
    if not rows then return nil, tostring(query_error) end
    if not rows[1] then return nil, nil end
    local row, row_error = row_of(rows[1])
    if not row then return nil, row_error end
    if (workspace_id and row.workspace_id ~= workspace_id) or (actor_id and row.actor_id ~= actor_id) then return nil, nil end
    return row, nil
end

-- take claims a pending run for the runner and returns it, or nothing when no
-- such run is waiting.
function M.take(run_id: string): (Row?, string?)
    local db, err = sql.get(M.DB)
    if not db then return nil, "node database: " .. tostring(err) end
    local tx, begin_error = db:begin()
    if not tx then db:release(); return nil, tostring(begin_error) end
    local rows, query_error = tx:query("SELECT " .. COLUMNS .. " FROM bee_node_test_runs WHERE run_id = ? AND state = 'pending'", {run_id})
    if not rows then tx:rollback(); db:release(); return nil, tostring(query_error) end
    if not rows[1] then tx:rollback(); db:release(); return nil, nil end
    local _, update_error = tx:execute("UPDATE bee_node_test_runs SET state = 'running' WHERE run_id = ?", {run_id})
    if update_error then tx:rollback(); db:release(); return nil, tostring(update_error) end
    local committed, commit_error = tx:commit()
    db:release()
    if not committed then return nil, tostring(commit_error) end
    return row_of(rows[1])
end

-- waiting lists the runs the runner has not taken yet, oldest first.
function M.waiting(): ({string}?, string?)
    local db, err = sql.get(M.DB)
    if not db then return nil, "node database: " .. tostring(err) end
    local rows, query_error = db:query("SELECT run_id FROM bee_node_test_runs WHERE state = 'pending' ORDER BY created_ms, rowid")
    db:release()
    if not rows then return nil, tostring(query_error) end
    local ids: {string} = {}
    for _, row in ipairs(rows) do ids[#ids + 1] = tostring(row.run_id) end
    return ids, nil
end

-- save records a run's progress or final results.
function M.save(run_id: string, state: string, result: Object): (boolean, string?)
    local encoded, encode_error = json.encode(result)
    if not encoded then return false, tostring(encode_error) end
    local db, err = sql.get(M.DB)
    if not db then return false, "node database: " .. tostring(err) end
    local _, update_error = db:execute("UPDATE bee_node_test_runs SET state = ?, result_json = ? WHERE run_id = ?", {state, encoded, run_id})
    db:release()
    if update_error then return false, tostring(update_error) end
    return true, nil
end

-- interrupt ends the runs a previous runner was executing when the node stopped.
function M.interrupt(): (boolean, string?)
    local db, err = sql.get(M.DB)
    if not db then return false, "node database: " .. tostring(err) end
    local rows, query_error = db:query("SELECT " .. COLUMNS .. " FROM bee_node_test_runs WHERE state = 'running'")
    if not rows then db:release(); return false, tostring(query_error) end
    for _, raw in ipairs(rows) do
        local row = row_of(raw)
        if row then
            local result: Object = row.result or {run_id = row.run_id, application = row.application,
                progress = {done = 0, total = #row.plan}}
            result.state = "interrupted"
            result.error = "the node stopped before the run completed"
            local encoded = json.encode(result)
            if encoded then
                db:execute("UPDATE bee_node_test_runs SET state = 'interrupted', result_json = ? WHERE run_id = ?", {encoded, row.run_id})
            end
        end
    end
    db:release()
    return true, nil
end

return M
