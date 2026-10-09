-- SPDX-License-Identifier: MIT
local sql = require("sql")
local M = {}
local NATIVE = "COALESCE(placement_kind, 'native') = 'native' AND (execution_state IN ('starting', 'running', 'stopping') OR (execution_state = 'exited' AND cleanup_state != 'complete' AND EXISTS (SELECT 1 FROM bee_placement_evidence e WHERE e.attempt_id = bee_placement_attempts.attempt_id AND e.kind = 'workdir_preparer.state') AND NOT EXISTS (SELECT 1 FROM bee_placement_evidence e WHERE e.attempt_id = bee_placement_attempts.attempt_id AND e.kind = 'workdir_preparers.settled')))"
local DOCKER = "placement_kind = 'docker' AND (execution_state IN ('starting', 'running', 'stopping', 'uncertain') OR (execution_state = 'exited' AND cleanup_state != 'complete') OR (execution_state = 'start_failed' AND cleanup_state != 'complete' AND EXISTS (SELECT 1 FROM bee_placement_evidence e WHERE e.attempt_id = bee_placement_attempts.attempt_id AND e.kind = 'docker.cleanup_requested')))"
function M.rows(db: sql.DB, kind: string, limit: integer): ({{[string]: unknown}}?, string?)
    assert(kind == "native" or kind == "docker")
    return db:query("SELECT attempt_id FROM bee_placement_attempts WHERE " .. (kind == "native" and NATIVE or DOCKER) .. " ORDER BY updated_at LIMIT ?", {limit})
end
function M.pending(db: sql.DB, kind: string): boolean
    local rows, problem = M.rows(db, kind, 1)
    if problem or not rows then error("read supervision backlog: " .. tostring(problem)) end
    return #rows > 0
end
return M
