-- MIT. SQL repository for credential metadata and consumed generations.
local sql = require("sql")
local bounds = require("bounds")
local node_database = require("node_database")
local M = {}
type Row = {[string]: unknown}
type Reader = sql.DB | sql.Transaction
type Definition = {workspace_id: string, name: string, definition_id: string, revision: integer,
    provider: string, source_kind: string, source_ref: string, projection_kind: string,
    destination: string, optional: boolean, digest: string, format_json: string, owner_node: string, at: string}
type Projection = {projection_id: string, workspace_id: string, name: string,
    definition_id: unknown, definition_revision: unknown, issuer_owner: string, subject: string,
    audience: string, attempt_id: string, profile_id: string, profile_digest: string,
    binding_digest: string, launch_policy_digest: string, provider: unknown,
    projection_kind: unknown, destination: unknown, format_json: string, materializer: string,
    idempotency_key: string, expires_at: string, lease_ms: integer, authorization_epoch: integer, created_at: string}

function M.open(): (sql.DB?, string?)
    return node_database.open()
end

function M.definition(db: Reader, workspace_id: string, name: string): (Row?, string?)
    local rows, err = db:query("SELECT * FROM bee_credential_definitions WHERE workspace_id = ? AND name = ?", {workspace_id, name})
    if err or not rows then return nil, "read definition" end
    if #rows == 0 then return nil, nil end
    return rows[1], nil
end

function M.projection(db: Reader, projection_id: string): (Row?, string?)
    local rows, err = db:query("SELECT * FROM bee_credential_projections WHERE projection_id = ?", {projection_id})
    if err or not rows then return nil, "read projection" end
    if #rows == 0 then return nil, nil end
    return rows[1], nil
end

function M.epoch(db: Reader, workspace_id: string): (integer?, string?)
    local rows, err = db:query("SELECT epoch FROM bee_credential_epochs WHERE workspace_id = ?", {workspace_id})
    if err or not rows then return nil, "read authorization epoch" end
    if #rows == 0 then return 0, nil end
    local epoch = bounds.integer(rows[1].epoch)
    if not epoch or epoch < 0 then return nil, "authorization epoch is corrupt" end
    return epoch, nil
end

function M.save_definition(tx: sql.Transaction, row: Definition, replace: boolean): string?
    if replace then
        local _, err = tx:execute("UPDATE bee_credential_definitions SET definition_id = ?, revision = ?, provider = ?, source_kind = ?, source_ref = ?, projection_kind = ?, destination = ?, optional = ?, digest = ?, format_json = ?, owner_node = ?, updated_at = ? WHERE workspace_id = ? AND name = ?",
            {row.definition_id, row.revision, row.provider, row.source_kind, row.source_ref, row.projection_kind, row.destination,
                row.optional and 1 or 0, row.digest, row.format_json, row.owner_node, row.at, row.workspace_id, row.name})
        if err then return "replace definition" end
    else
        local _, err = tx:execute("INSERT INTO bee_credential_definitions (workspace_id, name, definition_id, revision, provider, source_kind, source_ref, projection_kind, destination, optional, digest, format_json, owner_node, created_at, updated_at) VALUES (?, ?, ?, 1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(workspace_id, name) DO NOTHING",
            {row.workspace_id, row.name, row.definition_id, row.provider, row.source_kind, row.source_ref, row.projection_kind,
                row.destination, row.optional and 1 or 0, row.digest, row.format_json, row.owner_node, row.at, row.at})
        if err then return "record definition" end
    end
    return nil
end

function M.issue_replay(db: sql.DB, subject: string, key: string): ({Row}?, string?)
    local rows, err = db:query("SELECT * FROM bee_credential_projections WHERE subject = ? AND idempotency_key = ?", {subject, key})
    if err or not rows then return nil, "read projections" end
    return rows, nil
end

function M.insert_projection(db: sql.DB, row: Projection): string?
    local _, err = db:execute([[INSERT INTO bee_credential_projections (projection_id, workspace_id, name, definition_id, definition_revision, issuer_owner, issuer_incarnation,
        subject, audience, attempt_id, profile_id, profile_digest, binding_digest, launch_policy_digest, provider, projection_kind, destination, format_json, materializer, idempotency_key,
        materialization_generation, expires_at, lease_ms, authorization_epoch, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?)]],
        {row.projection_id, row.workspace_id, row.name, row.definition_id, row.definition_revision, row.issuer_owner, 1, row.subject, row.audience, row.attempt_id,
            row.profile_id, row.profile_digest, row.binding_digest, row.launch_policy_digest, row.provider, row.projection_kind, row.destination,
            row.format_json, row.materializer, row.idempotency_key, row.expires_at, row.lease_ms, row.authorization_epoch, row.created_at})
    if err then return "record projection" end
    return nil
end

function M.generation_used(tx: sql.Transaction, projection_id: string, key: string): (boolean?, string?)
    local rows, err = tx:query("SELECT generation_key FROM bee_credential_generations WHERE projection_id = ? AND generation_key = ?", {projection_id, key})
    if err or not rows then return nil, "read materialization generation key" end
    return #rows > 0, nil
end

function M.reserve_generation(tx: sql.Transaction, projection_id: string, key: string, generation: integer, materializer: string, at: string): string?
    local _, key_error = tx:execute("INSERT INTO bee_credential_generations (projection_id, generation_key, generation, materializer_actor, created_at) VALUES (?, ?, ?, ?, ?)",
        {projection_id, key, generation, materializer, at})
    if key_error then return "reserve materialization generation" end
    local _, update_error = tx:execute("UPDATE bee_credential_projections SET materialization_generation = ? WHERE projection_id = ?", {generation, projection_id})
    if update_error then return "advance materialization generation" end
    return nil
end

function M.serialize_write_back(tx: sql.Transaction, projection_id: unknown): string?
    local _, err = tx:execute("UPDATE bee_credential_projections SET materialization_generation = materialization_generation WHERE projection_id = ?", {projection_id})
    if err then return tostring(err) end
    return nil
end

function M.revoke(db: sql.DB, projection_id: string, at: string): string?
    local _, err = db:execute("UPDATE bee_credential_projections SET revoked_at = ? WHERE projection_id = ?", {at, projection_id})
    if err then return "revoke projection" end
    return nil
end

-- attempt_leases lists an attempt's unrevoked, unexpired projections for its
-- subject and audience.
function M.attempt_leases(db: sql.DB, attempt_id: string, subject: string, audience: string, at: string): ({Row}?, string?)
    local rows, err = db:query("SELECT projection_id, workspace_id, expires_at, lease_ms, authorization_epoch FROM bee_credential_projections " ..
        "WHERE attempt_id = ? AND subject = ? AND audience = ? AND revoked_at IS NULL AND expires_at > ?", {attempt_id, subject, audience, at})
    if err or not rows then return nil, "read attempt projections" end
    return rows, nil
end

function M.extend(db: sql.DB, projection_id: string, expires_at: string): string?
    local _, err = db:execute("UPDATE bee_credential_projections SET expires_at = ? WHERE projection_id = ? AND revoked_at IS NULL", {expires_at, projection_id})
    if err then return "renew projection" end
    return nil
end

function M.set_epoch(db: sql.DB, workspace_id: string, epoch: integer): string?
    local _, err = db:execute("INSERT INTO bee_credential_epochs (workspace_id, epoch) VALUES (?, ?) ON CONFLICT(workspace_id) DO UPDATE SET epoch = excluded.epoch", {workspace_id, epoch})
    if err then return "advance authorization epoch" end
    return nil
end

function M.definitions(db: sql.DB, workspace_id: string, limit: integer): ({Row}?, string?)
    local rows, err = db:query("SELECT * FROM bee_credential_definitions WHERE workspace_id = ? ORDER BY name LIMIT ?", {workspace_id, limit})
    if err or not rows then return nil, "read workspace credentials" end
    return rows, nil
end

function M.active_projections(db: sql.DB, workspace_id: string, at: string, limit: integer): ({Row}?, string?)
    local rows, err = db:query("SELECT * FROM bee_credential_projections WHERE workspace_id = ? AND revoked_at IS NULL AND expires_at > ? ORDER BY created_at LIMIT ?", {workspace_id, at, limit})
    if err or not rows then return nil, "read workspace credentials" end
    return rows, nil
end
function M.configuration_admitted(db: sql.DB, workspace: string, source: string, path: string, digest: string): (boolean?, string?)
    local rows, err = db:query("SELECT digest FROM bee_configuration_admissions WHERE workspace_id = ? AND source_ref = ? AND source_path = ?", {workspace, source, path})
    if err or not rows then return nil, "Configuration setup could not read its saved approval." end
    return #rows == 1 and rows[1].digest == digest, nil
end
function M.admit_configuration(db: sql.DB, workspace: string, source: string, path: string, digest: string, approval: string): string?
    local _, err = db:execute([[INSERT INTO bee_configuration_admissions (workspace_id, source_ref, source_path, digest, approval_id)
        VALUES (?, ?, ?, ?, ?) ON CONFLICT (workspace_id, source_ref, source_path) DO UPDATE SET digest = excluded.digest, approval_id = excluded.approval_id]],
        {workspace, source, path, digest, approval})
    if err then return "Configuration setup could not save the approval. Open Agents and choose Setup again." end
    return nil
end
return M
