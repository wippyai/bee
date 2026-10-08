-- SPDX-License-Identifier: MIT
local M = {}
function M.insert(db: sql.DB, id: string, name: string, workspace: string, caller: string, binding: string)
    return db:execute("INSERT INTO bee_gateway_external_clients(client_id, name, workspace_id, caller, binding_id, created_at) VALUES (?, ?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))", {id, name, workspace, caller, binding})
end
function M.bind_approval(db: sql.DB, id: string, approval: string)
    return db:execute("UPDATE bee_gateway_external_clients SET approval_id = ? WHERE client_id = ? AND approval_id IS NULL", {approval, id})
end
function M.read(db: sql.DB, id: string)
    return db:query([[SELECT c.*, b.subject, b.action_id, b.attempt_id, b.thread_id, b.owner_incarnation, b.carrier_epoch,
        b.revoked_at, b.expires_at FROM bee_gateway_external_clients c JOIN bee_gateway_bindings b USING(binding_id) WHERE c.client_id = ?]], {id})
end
function M.by_binding(db: sql.DB, binding: string)
    return db:query("SELECT client_id FROM bee_gateway_external_clients WHERE binding_id = ?", {binding})
end
function M.claim(db: sql.DB, id: string)
    return db:execute([[UPDATE bee_gateway_external_clients SET issued = 1 WHERE client_id = ? AND issued = 0
        AND EXISTS (SELECT 1 FROM bee_gateway_bindings b WHERE b.binding_id = bee_gateway_external_clients.binding_id AND b.revoked_at IS NULL)]], {id})
end
function M.list(db: sql.DB, workspace: string)
    return db:query([[SELECT c.client_id, c.name, c.approval_id, c.issued, c.created_at, b.thread_id, b.binding_id, b.revoked_at, b.expires_at
        FROM bee_gateway_external_clients c JOIN bee_gateway_bindings b USING(binding_id)
        WHERE c.workspace_id = ? ORDER BY c.created_at DESC, c.client_id LIMIT 128]], {workspace})
end
return M
