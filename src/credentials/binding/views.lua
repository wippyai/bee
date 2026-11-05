-- MIT. Credential projection views shared by the broker entries.
local configuration = require("configuration")
local integer = configuration.integer
local stored_format = configuration.stored_format
type Row = configuration.Row
local M = {}
local function definition_view(row: Row): ({[string]: unknown}?, string?)
    local revision, optional = integer(row.revision), integer(row.optional)
    if not revision or revision < 1 or (optional ~= 0 and optional ~= 1) then return nil, "credential definition numeric fields are corrupt" end
    local format, format_error = stored_format(row)
    if not format then return nil, format_error or "credential definition format is corrupt" end
    return {workspace_id = row.workspace_id, name = row.name, definition_id = row.definition_id, revision = revision, provider = row.provider,
        source_kind = row.source_kind, source_ref = row.source_ref, projection_kind = row.projection_kind, destination = row.destination, optional = optional == 1, digest = row.digest,
        format = format, owner_node = row.owner_node, created_at = row.created_at, updated_at = row.updated_at}, nil
end
local function projection_view(row: Row): ({[string]: unknown}?, string?)
    local definition_revision, issuer_incarnation = integer(row.definition_revision), integer(row.issuer_incarnation)
    local generation, authorization_epoch = integer(row.materialization_generation), integer(row.authorization_epoch)
    if not definition_revision or definition_revision < 1 or not issuer_incarnation or issuer_incarnation < 1
        or not generation or generation < 0 or not authorization_epoch or authorization_epoch < 0 then
        return nil, "credential projection numeric fields are corrupt"
    end
    local format, format_error = stored_format(row)
    if not format then return nil, format_error or "credential projection format is corrupt" end
    return {projection_id = row.projection_id, workspace_id = row.workspace_id, name = row.name, definition_id = row.definition_id, definition_revision = definition_revision,
        issuer_owner = row.issuer_owner, issuer_incarnation = issuer_incarnation, subject = row.subject, audience = row.audience, attempt_id = row.attempt_id,
        profile_id = row.profile_id, profile_digest = row.profile_digest, binding_digest = row.binding_digest, launch_policy_digest = row.launch_policy_digest,
        provider = row.provider, projection_kind = row.projection_kind, destination = row.destination, materializer = row.materializer,
        materialization_generation = generation, expires_at = row.expires_at, authorization_epoch = authorization_epoch,
        format = format, revoked_at = row.revoked_at, created_at = row.created_at}, nil
end
M.definition_view = definition_view
M.projection_view = projection_view
return M
