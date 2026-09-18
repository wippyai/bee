-- MIT. Resolve one host-selected implementation of the placement contract
-- from a caller-owned registry snapshot. This module only measures registry
-- metadata and method targets; it does not grant execution authority.
local hash = require("hash")
local registry = require("registry")
local bounds = require("bounds")
local canonical = require("canonical")
local types = require("types")
local M = {}
M.CONTRACT = "bee.placement:placement"
M.TYPE = "placement"
M.DEFAULT = "bee.placement.native:binding"
-- The lifecycle methods are the public placement contract. The last three
-- are used by the carrier's measured capability and session-end paths and
-- therefore must be selected by the same binding rather than falling back to
-- native targets.
M.METHODS = {"prepare", "start", "status", "stop", "reconcile", "cleanup", "evidence", "attach", "capabilities", "measure_executable", "close_stdin"}
type Entry = {[string]: unknown}
local function digest(value: unknown): (string?, string?)
    local encoded, encode_error = canonical.encode(value)
    if not encoded then return nil, encode_error end
    local result, hash_error = hash.sha256(encoded)
    if hash_error or not result then return nil, "placement binding digest failed" end
    return result, nil
end
local function entry(pinned: registry.Snapshot, ref: string): Entry?
    local value, err = pinned:get(ref)
    if err then return nil end
    return bounds.object(value)
end
function M.resolve(pinned: registry.Snapshot, requested: string?): (types.PlacementBinding?, string?)
    local ref = requested or M.DEFAULT
    if not bounds.id(ref) then return nil, "placement binding is not an identifier" end
    local value = entry(pinned, ref)
    if not value then return nil, "placement binding " .. ref .. " is not in the registry" end
    if value.kind ~= "contract.binding" then return nil, "placement binding " .. ref .. " is not a contract binding" end
    local meta = bounds.object(value.meta) or {}
    if meta.type ~= M.TYPE then return nil, "placement binding " .. ref .. " is not a placement binding" end
    local data = bounds.object(value.data)
    if not data then return nil, "placement binding " .. ref .. " has malformed data" end
    local contracts = data.contracts
    if type(contracts) ~= "table" then return nil, "placement binding " .. ref .. " has no contracts" end
    local mapped: {[string]: string} = {}
    local found = false
    for _, raw in ipairs(contracts :: {unknown}) do
        local contract = bounds.object(raw)
        if contract and contract.contract == M.CONTRACT then
            if found then return nil, "placement binding " .. ref .. " declares the placement contract twice" end
            found = true
            local methods = bounds.object(contract.methods)
            if not methods then return nil, "placement binding " .. ref .. " methods must be an object" end
            for _, name in ipairs(M.METHODS) do
                local target = bounds.id(methods[name])
                if not target then return nil, "placement binding " .. ref .. " binds no " .. name end
                local target_entry = entry(pinned, target)
                if not target_entry or target_entry.kind ~= "function.lua" then
                    return nil, "placement binding " .. ref .. " method " .. name .. " is not a function"
                end
                mapped[name] = target
            end
        end
    end
    if not found then return nil, "placement binding " .. ref .. " does not implement " .. M.CONTRACT end
    local binding_digest, digest_error = digest({kind = value.kind, meta = meta, data = data})
    if not binding_digest then return nil, digest_error end
    return {binding_id = ref, binding_digest = binding_digest, placement_kind = tostring(meta.placement_kind or ""), methods = mapped}, nil
end
return M
