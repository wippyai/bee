-- MIT. Hub receipt selection uses declared metadata; data is decoded separately.
local bounds = require("bounds")
local M = {}
type Object = {[string]: unknown}
function M.record(raw: unknown): (Object?, string?)
    local entry = bounds.object(raw)
    local meta = entry and bounds.object(entry.meta)
    if not entry or not meta or meta.type ~= "bee.hub_operation" then return nil, nil end
    if entry.kind ~= "registry.entry" then return nil, "Hub operation receipt kind is invalid" end
    local data = bounds.object(entry.data)
    if not data then return nil, "Hub operation receipt data is not an object" end
    local digest = bounds.line(data.digest, 64)
    if not digest or #digest ~= 64 or not digest:match("^[0-9a-f]+$") then return nil, "Hub operation receipt digest is invalid" end
    if not bounds.id(data.actor_id) then return nil, "Hub operation receipt actor_id is invalid" end
    if not bounds.line(data.component, 160) then return nil, "Hub operation receipt component is invalid" end
    if bounds.count(data.baseline_revision) == nil then return nil, "Hub operation receipt baseline_revision is invalid" end
    if not bounds.text(data.message, 4096) then return nil, "Hub operation receipt message is invalid" end
    if not bounds.member(data.action, {"install", "update", "uninstall"}) then return nil, "Hub operation receipt action is invalid" end
    if not bounds.member(data.state, {"prepared", "published", "complete", "failed", "recovery_required"}) then return nil, "Hub operation receipt state is invalid" end
    return data, nil
end
return M
