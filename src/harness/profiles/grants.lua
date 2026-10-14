local grants = require("grants")
local bounds = require("bounds")
local clock = require("clock")
local M = {}
function M.live(tx: sql.Transaction | sql.DB, record: grants.Grant): string?
    local seen: {[string]: boolean} = {}
    local current = record
    for _ = 1, 16 do
        if grants.state(current, clock.milliseconds()) ~= "active" then return "profile consent is no longer active" end
        local parameters = bounds.object(current.scope.parameters)
        local parent = parameters and bounds.id(parameters.parent_grant_id)
        if current.provenance.kind ~= "delegated" and not parent then return nil end
        local id = parent or bounds.id(current.provenance.approving_grant_id)
        if not id or seen[id] then return "invalid delegated profile provenance" end
        seen[id] = true
        local parent, err = grants.read(tx, id)
        if not parent then return err or "approving profile grant is missing" end
        current = parent
    end
    return "delegated profile provenance exceeds its bound"
end
function M.folder(tx: sql.Transaction | sql.DB, parent: grants.Grant, workdir: string, binding: string): (grants.Grant?, string?)
    if parent.domain ~= "profile_choices" or M.live(tx, parent) then return nil, nil end
    local records, err = grants.find(tx, {domain = "profile_choices", owner_node = parent.owner_node,
        workspace_id = parent.workspace_id, metadata_key = "folder_profile_grant", metadata_value = parent.grant_id, active = true})
    if not records then return nil, err end
    for _, record in ipairs(records) do
        local parameters = bounds.object(record.scope.parameters)
        local configuration = parameters and bounds.object(parameters.configuration)
        local provider = configuration and bounds.object(configuration.provider)
        local options = provider and bounds.object(provider.options)
        if record.provenance.kind == "consent" and parameters and parameters.parent_grant_id == parent.grant_id
            and parameters.canonical_workdir == workdir and configuration and configuration.driver_binding_ref == binding
            and options and options.folder_trust == "approved-workdir" and not M.live(tx, record) then return record, nil end
    end
    return nil, nil
end
return M
