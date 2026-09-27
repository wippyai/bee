-- MIT. Resource authority replies used to select a placement root.
local bounds = require("bounds")
local types = require("types")
local M = {}

type Access = "read" | "write"
type Resolution = {grant_id: string, root_ref: string, root_digest: string, subpath: string, access: Access,
    association_revision: integer, expires_at: string}

function M.decode(value: unknown): (Resolution?, string?)
    local object = bounds.object(value)
    if not object then return nil, "resource resolution must be an object" end
    local unknown_field = bounds.fields(object, {"grant_id", "workspace_id", "name", "root_ref", "root_digest", "directory", "subpath", "access", "purpose", "association_id", "association_revision", "expires_at", "authorization_epoch"})
    if unknown_field then return nil, "resource resolution: " .. unknown_field end
    local grant_id, workspace_id, name = bounds.id(object.grant_id), bounds.id(object.workspace_id), bounds.id(object.name)
    local root_ref, association_id = bounds.id(object.root_ref), bounds.id(object.association_id)
    local root_digest = bounds.text(object.root_digest, 64)
    local directory = bounds.text(object.directory, bounds.MAX_TEXT_BYTES)
    local subpath = bounds.subpath(object.subpath)
    local access = bounds.member(object.access, {"read", "write"})
    local purpose = bounds.member(object.purpose, types.PURPOSES)
    local revision, epoch = bounds.integer(object.association_revision), bounds.integer(object.authorization_epoch)
    local expires_at = bounds.timestamp(object.expires_at)
    if grant_id == nil or workspace_id == nil or name == nil or root_ref == nil or association_id == nil
        or root_digest == nil or directory == nil or subpath == nil or access == nil or purpose == nil
        or revision == nil or epoch == nil or expires_at == nil then return nil, "resource resolution has invalid or missing fields" end
    if #root_digest ~= 64 or not root_digest:match("^[0-9a-f]+$") then return nil, "resource resolution root_digest is invalid" end
    if directory == "" or not directory:match("^/") then return nil, "resource resolution directory is invalid" end
    if revision < 1 or epoch < 0 then return nil, "resource resolution revisions are invalid" end
    local decoded_access: Access
    if access == "read" then decoded_access = "read" else decoded_access = "write" end
    return {grant_id = grant_id, root_ref = root_ref, root_digest = root_digest, subpath = subpath,
        access = decoded_access, association_revision = revision, expires_at = expires_at}, nil
end

return M
