-- MIT. Decode the identity and schema of Hub's existing durable operation records.
-- Registry history predates metadata tags; the measured data and exact persisted
-- record ID are verified for every candidate, without rewriting history.
local bounds = require("bounds")
local M = {}
type Object = {[string]: unknown}
function M.record(raw: unknown): Object?
    local entry = bounds.object(raw)
    local data = entry and entry.kind == "registry.entry" and bounds.object(entry.data)
    local digest = data and bounds.line(data.digest, 64)
    if not entry or not data or not digest or #digest ~= 64 or not digest:match("^[0-9a-f]+$")
        or entry.id ~= "bee.hub.operations:" .. digest
        or not bounds.id(data.actor_id) or not bounds.line(data.component, 160)
        or bounds.count(data.baseline_revision) == nil or not bounds.text(data.message, 4096)
        or not bounds.member(data.action, {"install", "update", "uninstall"})
        or not bounds.member(data.state, {"prepared", "published", "complete", "failed", "recovery_required"}) then return nil end
    return data
end
return M
