-- MIT. Listener state persistence.
local M = {}

function M.read(db: sql.DB)
    return db:query("SELECT epoch, address, secret, drained, opened_at, drain_deadline_at, native_key FROM bee_gateway_listener WHERE singleton = 1")
end

function M.initialize_native(db: sql.DB, address: string, secret: string, opened_at: string, native_key: string)
    return db:execute("INSERT INTO bee_gateway_listener (singleton, epoch, address, secret, drained, opened_at, native_key) VALUES (1, 1, ?, ?, 0, ?, ?) " ..
        "ON CONFLICT(singleton) DO UPDATE SET epoch = bee_gateway_listener.epoch + 1, address = excluded.address, secret = excluded.secret, drained = 0, drain_deadline_at = NULL, opened_at = excluded.opened_at, native_key = excluded.native_key " ..
        "WHERE bee_gateway_listener.native_key IS NOT excluded.native_key", {address, secret, opened_at, native_key})
end

function M.open(db: sql.DB, epoch: integer, address: string, secret: string, opened_at: string, native_key: string)
    return db:execute("INSERT INTO bee_gateway_listener (singleton, epoch, address, secret, drained, drain_deadline_at, opened_at, native_key) VALUES (1, ?, ?, ?, 0, NULL, ?, NULLIF(?, '')) " ..
        "ON CONFLICT(singleton) DO UPDATE SET epoch = excluded.epoch, address = excluded.address, secret = excluded.secret, drained = 0, drain_deadline_at = NULL, opened_at = excluded.opened_at, native_key = excluded.native_key",
        {epoch, address, secret, opened_at, native_key})
end

function M.reconcile(db: sql.DB, expected_epoch: integer, expected_address: string, expected_native_key: string?, address: string,
    secret: string, opened_at: string, native_key: string?)
    return db:execute("UPDATE bee_gateway_listener SET epoch = epoch + 1, address = ?, secret = ?, drained = 0, drain_deadline_at = NULL, " ..
        "opened_at = ?, native_key = NULLIF(?, '') WHERE singleton = 1 AND epoch = ? AND address = ? AND COALESCE(native_key, '') = ?",
        {address, secret, opened_at, native_key or "", expected_epoch, expected_address, expected_native_key or ""})
end

function M.start_drain(db: sql.DB, deadline_at: string)
    return db:execute("UPDATE bee_gateway_listener SET drained = 1, drain_deadline_at = ? WHERE singleton = 1", {deadline_at})
end

function M.epoch(tx: sql.Transaction)
    return tx:query("SELECT epoch FROM bee_gateway_listener WHERE singleton = 1")
end

return M
