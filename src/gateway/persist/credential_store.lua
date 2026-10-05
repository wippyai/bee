-- MIT. Credential hash persistence.
local M = {}

function M.insert(db: sql.DB, credential_id: string, binding_id: string, generation: integer, kind: string,
    token_hash: string, runner: string, materialized_at: string)
    return db:execute("INSERT INTO bee_gateway_credentials (credential_id, binding_id, generation, kind, token_hash, runner, materialized_at, revoked_at) VALUES (?, ?, ?, ?, ?, ?, ?, NULL)",
        {credential_id, binding_id, generation, kind, token_hash, runner, materialized_at})
end

function M.revoke_through_generation(db: sql.DB, binding_id: string, generation: integer, revoked_at: string)
    return db:execute("UPDATE bee_gateway_credentials SET revoked_at = COALESCE(revoked_at, ?) WHERE binding_id = ? AND generation <= ?", {revoked_at, binding_id, generation})
end

function M.by_hash(db: sql.DB, token_hash: string)
    return db:query("SELECT credential_id, binding_id, generation, kind, revoked_at FROM bee_gateway_credentials WHERE token_hash = ?", {token_hash})
end

function M.presented(db: sql.DB, credential_id: string, at: string)
    return db:execute("UPDATE bee_gateway_credentials SET presented_count = presented_count + 1, last_presented_at = ? WHERE credential_id = ?", {at, credential_id})
end

return M
