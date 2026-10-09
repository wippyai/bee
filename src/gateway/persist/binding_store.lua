-- MIT. Binding row persistence.
local M = {}

function M.by_id(db: sql.DB, binding_id: string)
    return db:query("SELECT * FROM bee_gateway_bindings WHERE binding_id = ?", {binding_id})
end

function M.by_idempotency_key(db: sql.DB, subject: string, key: string)
    return db:query("SELECT * FROM bee_gateway_bindings WHERE subject = ? AND idempotency_key = ?", {subject, key})
end

function M.highest_carrier_epoch(tx: sql.Transaction, attempt_id: string)
    return tx:query("SELECT MAX(carrier_epoch) AS highest FROM bee_gateway_bindings WHERE attempt_id = ?", {attempt_id})
end

function M.live_at_carrier_epoch(tx: sql.Transaction, attempt_id: string, carrier_epoch: integer)
    return tx:query("SELECT * FROM bee_gateway_bindings WHERE attempt_id = ? AND carrier_epoch = ? AND revoked_at IS NULL", {attempt_id, carrier_epoch})
end

function M.workspace_name_conflict(tx: sql.Transaction, workspace_id: string, workspace_name: string,
    action_id: string, listener_epoch: integer)
    return tx:query("SELECT action_id FROM bee_gateway_bindings WHERE workspace_id = ? AND workspace_name = ? AND action_id <> ? AND revoked_at IS NULL AND sealed_at IS NULL AND epoch = ? LIMIT 1",
        {workspace_id, workspace_name, action_id, listener_epoch})
end

function M.insert(tx: sql.Transaction, binding_id: string, subject: string, action_id: string, attempt_id: string,
    thread_id: string, owner_incarnation: integer, carrier_epoch: integer, tools_json: string, hooks_json: string,
    listener_epoch: integer, expires_at: string, lease_ms: integer, idempotency_key: string?, request_digest: string, created_at: string,
    policy_ref: string, workspace_id: string, workspace_name: string, origin_view_json: string)
    return tx:execute([[INSERT INTO bee_gateway_bindings (binding_id, subject, action_id, attempt_id, thread_id, owner_incarnation, carrier_epoch, tools_json, hooks_json,
        epoch, credential_generation, expires_at, lease_ms, revoked_at, idempotency_key, request_digest, created_at, policy_ref, workspace_id, workspace_name, origin_view_json) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, NULL, ?, ?, ?, ?, ?, ?, ?)]],
        {binding_id, subject, action_id, attempt_id, thread_id, owner_incarnation, carrier_epoch, tools_json, hooks_json, listener_epoch,
            expires_at, lease_ms, idempotency_key, request_digest, created_at, policy_ref, workspace_id, workspace_name, origin_view_json})
end

function M.by_carrier(db: sql.DB, attempt_id: string, carrier_epoch: integer, live: boolean)
    if live then
        return db:query("SELECT * FROM bee_gateway_bindings WHERE attempt_id = ? AND carrier_epoch <= ? AND revoked_at IS NULL ORDER BY carrier_epoch DESC, created_at DESC, binding_id DESC LIMIT 1", {attempt_id, carrier_epoch})
    end
    return db:query("SELECT * FROM bee_gateway_bindings WHERE attempt_id = ? AND carrier_epoch <= ? ORDER BY carrier_epoch DESC, created_at DESC, binding_id DESC LIMIT 1", {attempt_id, carrier_epoch})
end

function M.supersede_older(tx: sql.Transaction, at: string, attempt_id: string, carrier_epoch: integer)
    return tx:execute("UPDATE bee_gateway_bindings SET revoked_at = ? WHERE attempt_id = ? AND carrier_epoch < ? AND revoked_at IS NULL", {at, attempt_id, carrier_epoch})
end

function M.materialization_key(db: sql.DB, binding_id: string)
    return db:query("SELECT materialization_key_hash, materialization_expires_at FROM bee_gateway_bindings WHERE binding_id = ?", {binding_id})
end

function M.open_credential_generation(db: sql.DB, binding_id: string)
    return db:execute("UPDATE bee_gateway_bindings SET credential_generation = 1 WHERE binding_id = ? AND credential_generation = 0", {binding_id})
end

function M.consume_materialization_key(db: sql.DB, binding_id: string)
    return db:execute("UPDATE bee_gateway_bindings SET materialization_key_hash = NULL, materialization_expires_at = NULL WHERE binding_id = ?", {binding_id})
end

function M.authorize_materialization(db: sql.DB, binding_id: string, key_hash: string, expires_at: string)
    return db:execute("UPDATE bee_gateway_bindings SET materialization_key_hash = ?, materialization_expires_at = ? WHERE binding_id = ?", {key_hash, expires_at, binding_id})
end

function M.advance_credential_generation(db: sql.DB, binding_id: string, expected: integer)
    return db:execute("UPDATE bee_gateway_bindings SET credential_generation = ? WHERE binding_id = ? AND credential_generation = ?", {expected + 1, binding_id, expected})
end

function M.revoke(db: sql.DB, binding_id: string, at: string)
    return db:execute("UPDATE bee_gateway_bindings SET revoked_at = COALESCE(revoked_at, ?), sealed_at = COALESCE(sealed_at, ?) WHERE binding_id = ?", {at, at, binding_id})
end

function M.seal(db: sql.DB, binding_id: string, at: string)
    return db:execute("UPDATE bee_gateway_bindings SET sealed_at = COALESCE(sealed_at, ?) WHERE binding_id = ?", {at, binding_id})
end

function M.origins(db: sql.DB, attempt_id: string, carrier_epoch: integer)
    return db:query("SELECT binding_id FROM bee_gateway_bindings WHERE attempt_id = ? AND carrier_epoch <= ?", {attempt_id, carrier_epoch})
end

function M.revoke_attempt(db: sql.DB, attempt_id: string, carrier_epoch: integer, at: string)
    return db:execute("UPDATE bee_gateway_bindings SET revoked_at = ? WHERE attempt_id = ? AND carrier_epoch <= ? AND revoked_at IS NULL", {at, attempt_id, carrier_epoch})
end

-- attempt_leases lists the bindings an attempt holds at or below a carrier
-- epoch that still admit requests: unrevoked, unsealed, unexpired and issued
-- under the current listener epoch.
function M.attempt_leases(db: sql.DB, attempt_id: string, carrier_epoch: integer, listener_epoch: integer, at: string)
    return db:query("SELECT binding_id, expires_at, lease_ms FROM bee_gateway_bindings WHERE attempt_id = ? AND carrier_epoch <= ? AND epoch = ? " ..
        "AND revoked_at IS NULL AND sealed_at IS NULL AND expires_at > ?", {attempt_id, carrier_epoch, listener_epoch, at})
end

function M.extend(db: sql.DB, binding_id: string, expires_at: string)
    return db:execute("UPDATE bee_gateway_bindings SET expires_at = ? WHERE binding_id = ? AND revoked_at IS NULL AND sealed_at IS NULL", {expires_at, binding_id})
end

function M.credential_presentation(db: sql.DB, binding_id: string, generation: integer)
    return db:query("SELECT presented_count, last_presented_at FROM bee_gateway_credentials WHERE binding_id = ? AND generation = ? AND kind = 'tool'", {binding_id, generation})
end

function M.surface_authority(tx: sql.Transaction, binding_id: string)
    return tx:query("SELECT credential_generation, revoked_at, sealed_at, expires_at FROM bee_gateway_bindings WHERE binding_id = ?", {binding_id})
end

function M.access_authority(tx: sql.Transaction, binding_id: string)
    return tx:query("SELECT credential_generation, revoked_at FROM bee_gateway_bindings WHERE binding_id = ?", {binding_id})
end

function M.workspace_bindings(db: sql.DB, workspace_id: string, listener_epoch: integer)
    return db:query("SELECT * FROM bee_gateway_bindings WHERE workspace_id = ? AND revoked_at IS NULL AND sealed_at IS NULL AND epoch = ? ORDER BY action_id ASC",
        {workspace_id, listener_epoch})
end

function M.intake_state(tx: sql.Transaction, binding_id: string)
    return tx:query("SELECT sealed_at, revoked_at FROM bee_gateway_bindings WHERE binding_id = ?", {binding_id})
end

function M.intake_carrier_epoch(tx: sql.Transaction, attempt_id: string)
    return tx:query("SELECT MAX(carrier_epoch) AS highest FROM bee_gateway_bindings WHERE attempt_id = ?", {attempt_id})
end

function M.intake_binding(db: sql.DB | sql.Transaction, binding_id: string)
    return db:query("SELECT * FROM bee_gateway_bindings WHERE binding_id = ?", {binding_id})
end

return M
