-- MIT. Hook inbox persistence.
local M = {}

function M.reject_unclaimed_for_binding(db: sql.DB | sql.Transaction, binding_id: string, reason: string, at: string)
    return db:execute("UPDATE bee_gateway_hooks SET status = 'rejected', rejected_reason = ?, updated_at = ? WHERE binding_id = ? AND status = 'queued' AND claimed_epoch = 0", {reason, at, binding_id})
end

function M.reject_revoked_for_binding(db: sql.DB, binding_id: string, at: string)
    return db:execute("UPDATE bee_gateway_hooks SET status = 'rejected', rejected_reason = 'binding revoked', updated_at = ? WHERE binding_id = ? AND status = 'queued' AND claimed_epoch = 0", {at, binding_id})
end

function M.reject_revoked_attempt(db: sql.DB, attempt_id: string, at: string)
    return db:execute("UPDATE bee_gateway_hooks SET status = 'rejected', rejected_reason = 'binding revoked', updated_at = ? WHERE status = 'queued' AND claimed_epoch = 0 AND binding_id IN (SELECT binding_id FROM bee_gateway_bindings WHERE attempt_id = ? AND revoked_at = ?)", {at, attempt_id, at})
end

function M.reject_superseded(tx: sql.Transaction, at: string, attempt_id: string, carrier_epoch: integer)
    return tx:execute("UPDATE bee_gateway_hooks SET status = 'rejected', rejected_reason = 'binding superseded', updated_at = ? WHERE status = 'queued' AND claimed_epoch = 0 AND binding_id IN (SELECT binding_id FROM bee_gateway_bindings WHERE attempt_id = ? AND carrier_epoch < ? AND revoked_at IS NULL)", {at, attempt_id, carrier_epoch})
end

function M.existing_occurrence(tx: sql.Transaction, binding_id: string, event: string, occurrence: string)
    return tx:query("SELECT event_id, digest, status, rejected_reason FROM bee_gateway_hooks WHERE binding_id = ? AND event = ? AND occurrence = ? AND ambiguous = 0", {binding_id, event, occurrence})
end

function M.queued_count(tx: sql.Transaction, binding_id: string)
    return tx:query("SELECT COUNT(*) AS queued FROM bee_gateway_hooks WHERE binding_id = ? AND status = 'queued'", {binding_id})
end

function M.last_sequence(tx: sql.Transaction, binding_id: string)
    return tx:query("SELECT COALESCE(MAX(sequence), 0) AS last FROM bee_gateway_hooks WHERE binding_id = ?", {binding_id})
end

function M.insert(tx: sql.Transaction, event_id: string, binding_id: string, attempt_id: string, action_id: string,
    carrier_epoch: integer, event: string, occurrence: string, ambiguous: integer, digest: string, fields_json: string,
    provenance: string, sequence: integer, at: string)
    return tx:execute("INSERT INTO bee_gateway_hooks (event_id, binding_id, attempt_id, action_id, carrier_epoch, event, occurrence, ambiguous, digest, fields_json, provenance, status, sequence, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'queued', ?, ?, ?)",
        {event_id, binding_id, attempt_id, action_id, carrier_epoch, event, occurrence, ambiguous, digest, fields_json, provenance, sequence, at, at})
end

function M.status(db: sql.DB, event_id: string, binding_id: string)
    return db:query("SELECT event, occurrence, ambiguous, status, sequence, claimed_epoch, rejected_reason FROM bee_gateway_hooks WHERE event_id = ? AND binding_id = ?", {event_id, binding_id})
end

function M.queue(db: sql.DB, binding_id: string)
    return db:query("SELECT event_id, event, occurrence, ambiguous, digest, fields_json, provenance, status, sequence, created_at, claimed_epoch, rejected_reason FROM bee_gateway_hooks WHERE binding_id = ? ORDER BY sequence", {binding_id})
end

function M.queued_ids(tx: sql.Transaction, binding_id: string, carrier_epoch: integer, recovery_only: boolean, limit: integer)
    if recovery_only then
        return tx:query("SELECT event_id FROM bee_gateway_hooks WHERE binding_id = ? AND status = 'queued' AND claimed_epoch > 0 AND claimed_epoch <= ? ORDER BY sequence LIMIT ?", {binding_id, carrier_epoch, limit})
    end
    return tx:query("SELECT event_id FROM bee_gateway_hooks WHERE binding_id = ? AND status = 'queued' AND claimed_epoch <= ? ORDER BY sequence LIMIT ?", {binding_id, carrier_epoch, limit})
end

function M.claim(tx: sql.Transaction, event_id: string, carrier_epoch: integer, at: string)
    return tx:execute("UPDATE bee_gateway_hooks SET claimed_epoch = ?, claimed_at = ?, updated_at = ? WHERE event_id = ? AND status = 'queued' AND claimed_epoch <= ?", {carrier_epoch, at, at, event_id, carrier_epoch})
end

function M.claimed_row(tx: sql.Transaction, event_id: string)
    return tx:query("SELECT event_id, event, occurrence, ambiguous, digest, fields_json, provenance, sequence, created_at FROM bee_gateway_hooks WHERE event_id = ?", {event_id})
end

function M.retained(db: sql.DB, binding_id: string)
    return db:query("SELECT event_id, LENGTH(fields_json) AS bytes FROM bee_gateway_hooks WHERE binding_id = ? AND status IN ('committed', 'rejected') ORDER BY sequence DESC", {binding_id})
end

function M.delete(db: sql.DB, event_id: string)
    return db:execute("DELETE FROM bee_gateway_hooks WHERE event_id = ?", {event_id})
end

function M.acknowledge(tx: sql.Transaction, at: string, event_id: string, binding_id: string, carrier_epoch: integer)
    return tx:execute("UPDATE bee_gateway_hooks SET status = 'committed', updated_at = ? WHERE event_id = ? AND binding_id = ? AND status = 'queued' AND claimed_epoch = ?", {at, event_id, binding_id, carrier_epoch})
end

function M.reject_binding(tx: sql.Transaction, at: string, reason: string, binding_id: string)
    return tx:execute("UPDATE bee_gateway_hooks SET status = 'rejected', rejected_reason = ?, updated_at = ? WHERE binding_id = ? AND status = 'queued' AND claimed_epoch = 0", {reason, at, binding_id})
end

return M
