-- MIT. How the protected kernel holds one namespace, built from the current
-- registry state. It answers only the area and the namespaces the host opens
-- to a super-edit profile, so callers learn the kernel boundary without
-- reading the registry themselves.
local registry = require("registry")
local bounds = require("bounds")
local protected_kernel = require("protected_kernel")
local M = {}

function M.handle(raw: unknown): {[string]: unknown}
    local request = bounds.object(raw)
    local namespace = request and bounds.id(request.namespace)
    if not namespace then return {ok = false, error = {code = "INVALID", message = "namespace is required"}} end
    local snapshot, snapshot_error = registry.snapshot()
    if not snapshot then return {ok = false, error = {code = "UNAVAILABLE", message = tostring(snapshot_error or "registry is unavailable")}} end
    local state, state_error = snapshot:state()
    if not state then return {ok = false, error = {code = "UNAVAILABLE", message = tostring(state_error or "registry state is unavailable")}} end
    local manifest, _, build_error = protected_kernel.build(state.entries)
    if not manifest then return {ok = false, error = {code = "UNAVAILABLE", message = build_error or "protected kernel is unavailable"}} end
    return {ok = true, value = {area = protected_kernel.area(manifest, namespace), opened = protected_kernel.opened_areas(manifest)}}
end

return M
