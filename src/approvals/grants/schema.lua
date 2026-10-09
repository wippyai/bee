local M = {}
M.STATEMENTS = {
    [[CREATE TABLE IF NOT EXISTS bee_approval_grants (grant_id TEXT PRIMARY KEY, approval_id TEXT, decision_id TEXT, subject_json TEXT NOT NULL, scope_json TEXT NOT NULL, terms_json TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('active','revoked','expired','exhausted')), revision INTEGER NOT NULL, used INTEGER NOT NULL DEFAULT 0, reserved INTEGER NOT NULL DEFAULT 0, until_ms INTEGER, max_uses INTEGER, created_at TEXT NOT NULL, domain TEXT NOT NULL DEFAULT 'decision', owner_node TEXT NOT NULL DEFAULT '', workspace_id TEXT NOT NULL DEFAULT '', requester_id TEXT NOT NULL DEFAULT '', granted_by TEXT NOT NULL DEFAULT '', granted_definition TEXT, provenance_json TEXT NOT NULL DEFAULT '{"kind":"legacy"}', metadata_json TEXT NOT NULL DEFAULT '{}', revoked_at TEXT, revoked_by TEXT)]],
    [[CREATE INDEX IF NOT EXISTS bee_approval_grants_scope ON bee_approval_grants(owner_node,workspace_id,domain,grant_id)]],
    [[CREATE TABLE IF NOT EXISTS bee_approval_grant_history (grant_id TEXT NOT NULL REFERENCES bee_approval_grants(grant_id) ON DELETE CASCADE, revision INTEGER NOT NULL, kind TEXT NOT NULL, actor_id TEXT NOT NULL, body_json TEXT NOT NULL, at TEXT NOT NULL, PRIMARY KEY(grant_id,revision))]],
    [[CREATE TABLE IF NOT EXISTS bee_approval_grant_uses (grant_id TEXT NOT NULL REFERENCES bee_approval_grants(grant_id) ON DELETE CASCADE, effect_key TEXT NOT NULL, request_digest TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('reserved','admitted','released','fenced')), created_at TEXT NOT NULL, admitted_at TEXT, PRIMARY KEY(grant_id,effect_key))]],
}
function M.ensure(db: sql.DB): string?
    for _, statement in ipairs(M.STATEMENTS) do
        local _, err = db:execute(statement)
        if err then return tostring(err) end
    end
    return nil
end
return M
