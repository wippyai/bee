-- MIT. Pure classification of driver bindings and their profile
-- declarations. No registry, no time: the catalog hands in what it read and
-- gets back what is compatible, what is not, and why.
local hash = require("hash")
local bounds = require("bounds")
local canonical = require("canonical")
local profile = require("profile")
local driver_types = require("driver_types")
local permission = require("permission")
local M = {}
M.CONTRACT = "bee.driver:driver"
M.METHODS = {"prepare", "dispatch", "normalize"}
type Entry = {[string]: unknown}
type Digest = {entry: string, scope: "entry"}
-- permission reports proof eligibility apart from compatibility: eligible
-- means the profile pins an adapter the snapshot measures; acceptance is a
-- host record checked at admission, never inferred from a fixture name.
type Permission = {mode: string, adapter_ref: string?, adapter_digest: string?, proof_fixture: string?, eligible: boolean}
type Profile = {id: string, mode: string, protocol: string, protocol_revision: string, supported: boolean, permission: Permission}
type Binding = {
    binding_id: string,
    driver_id: string,
    title: string,
    implementation_version: string,
    profiles_ref: string,
    binding_digest: Digest,
    profile_digest: Digest,
    default_profile: string,
    profiles: {Profile},
    methods: {[string]: string},
    state: "compatible" | "incompatible",
    activated: boolean,
    diagnostics: {string},
}
type Input = {binding: Entry, declaration: Entry?, methods: {[string]: Entry?}, adapters: {[string]: Entry?}?, activated: boolean}
local function digest(value: unknown): (string?, string?)
    local encoded, encode_error = canonical.encode(value)
    if not encoded then return nil, encode_error end
    local sum, hash_error = hash.sha256(encoded)
    if hash_error or not sum then return nil, "digest failed" end
    return sum, nil
end
-- Compatibility follows the actual execution paths. Activation and authority
-- remain host-selected; test metadata cannot add a transport capability.
local function supported(mode: string, protocol: string): boolean
    if mode == "window" then return protocol == "pty" end
    return (mode == "batch" or mode == "session") and protocol == "stream-json"
end
-- Classifies one binding with everything the catalog resolved for it.
function M.binding(input: Input): Binding
    local entry = input.binding
    local diagnostics: {string} = {}
    local function fail(message: string)
        diagnostics[#diagnostics + 1] = message
    end
    local binding_id = bounds.id(entry.id) or "?"
    local meta = bounds.object(entry.meta) or {}
    local driver_id = bounds.id(meta.driver_id) or ""
    if driver_id == "" then fail("meta.driver_id is not an identifier") end
    local profiles_ref = bounds.id(meta.profiles_ref) or ""
    if profiles_ref == "" then fail("meta.profiles_ref is not an identifier") end
    if entry.kind ~= "contract.binding" then fail("binding must be a contract.binding") end
    local data = bounds.object(entry.data) or {}
    local contracts: unknown = data.contracts
    local implements = false
    local mapped: {[string]: string} = {}
    if type(contracts) == "table" then
        for _, item in ipairs(contracts :: {unknown}) do
            local declared = bounds.object(item)
            if declared and declared.contract == M.CONTRACT then
                implements = true
                local methods = bounds.object(declared.methods) or {}
                for _, name in ipairs(M.METHODS) do
                    local target = bounds.id(methods[name])
                    if not target then fail("method " .. name .. " is not bound") else mapped[name] = target end
                end
            end
        end
    end
    if not implements then fail("binding does not implement " .. M.CONTRACT) end
    for _, name in ipairs(M.METHODS) do
        local target = mapped[name]
        if target then
            local method = input.methods[target]
            if not method then fail("method " .. name .. " points at a missing entry " .. target)
            elseif method.kind ~= "function.lua" then fail("method " .. name .. " points at " .. tostring(method.kind) .. ", not a function") end
        end
    end
    local binding_digest, binding_digest_error = digest({kind = entry.kind, meta = meta, data = data})
    if not binding_digest then fail("binding is not measurable: " .. tostring(binding_digest_error)) end
    local declaration = input.declaration
    local decoded: driver_types.Binding? = nil
    local profile_digest = ""
    if not declaration then
        fail("profiles_ref " .. profiles_ref .. " does not exist")
    else
        local declaration_meta = bounds.object(declaration.meta) or {}
        if declaration_meta.type ~= "harness.profile" then fail("profiles entry is not a harness.profile") end
        if declaration_meta.driver_ref ~= binding_id then fail("profiles entry names another binding: " .. tostring(declaration_meta.driver_ref)) end
        local declaration_data = bounds.object(declaration.data) or {}
        local parsed, parse_error = profile.decode(declaration_data.driver)
        if not parsed then fail("profiles: " .. tostring(parse_error)) else decoded = parsed end
        local sum, sum_error = digest(declaration_data)
        if not sum then fail("profiles are not measurable: " .. tostring(sum_error)) else profile_digest = sum end
    end
    local profiles: {Profile} = {}
    local title = ""
    local version = ""
    local default_profile = ""
    if decoded then
        title = decoded.title
        version = decoded.implementation_version
        default_profile = decoded.default_profile
        local any_supported = false
        for index, item in ipairs(decoded.profiles) do
            local ok = supported(item.mode, item.protocol)
            if ok then any_supported = true end
            profiles[index] = {id = item.id, mode = item.mode, protocol = item.protocol, protocol_revision = item.protocol_revision, supported = ok,
                permission = {mode = item.permission_exchange.mode, adapter_ref = item.permission_exchange.adapter_ref, adapter_digest = item.permission_exchange.adapter_digest, proof_fixture = nil, eligible = false}}
        end
        if not any_supported then fail("no profile uses a supported protocol") end
        local default = profile.find(decoded, decoded.default_profile)
        if default and not supported(default.mode, default.protocol) then fail("the default profile uses an unsupported protocol") end
        local adapters = input.adapters or {}
        for position, item in ipairs(decoded.profiles) do
            local exchange = item.permission_exchange
            local report = profiles[position].permission
            if exchange.mode == "adapter" then
                local adapter_ref = exchange.adapter_ref or ""
                local adapter_entry = adapters[adapter_ref]
                if not adapter_entry then
                    fail("profile " .. item.id .. " pins permission adapter " .. adapter_ref .. " which does not exist")
                else
                    local adapter_meta = bounds.object(adapter_entry.meta) or {}
                    if adapter_meta.type ~= "harness.permission_adapter" then fail("profile " .. item.id .. ": " .. adapter_ref .. " is not a harness.permission_adapter") end
                    local adapter_data = bounds.object(adapter_entry.data) or {}
                    local adapter, adapter_error = permission.decode(adapter_ref, adapter_data.adapter)
                    if not adapter then
                        fail("profile " .. item.id .. ": permission adapter " .. adapter_ref .. ": " .. tostring(adapter_error))
                    else
                        local pin_error = permission.pinned(adapter, exchange)
                        if pin_error then
                            fail("profile " .. item.id .. ": " .. pin_error)
                        else
                            report.eligible = true
                            report.proof_fixture = adapter.proof_fixture
                        end
                    end
                end
            end
        end
    end
    local state: "compatible" | "incompatible" = "compatible"
    if #diagnostics > 0 then state = "incompatible" end
    return {binding_id = binding_id, driver_id = driver_id, title = title, implementation_version = version, profiles_ref = profiles_ref,
        binding_digest = {entry = binding_digest or "", scope = "entry"}, profile_digest = {entry = profile_digest, scope = "entry"},
        default_profile = default_profile, profiles = profiles, methods = mapped, state = state, activated = input.activated, diagnostics = diagnostics}
end
-- Two compatible bindings with one driver_id are ambiguous: neither is usable.
function M.disambiguate(bindings: {Binding}): {Binding}
    local seen: {[string]: {Binding}} = {}
    for _, item in ipairs(bindings) do
        if item.state == "compatible" then
            local group = seen[item.driver_id] or {}
            group[#group + 1] = item
            seen[item.driver_id] = group
        end
    end
    for driver_id, group in pairs(seen) do
        if #group > 1 then
            for _, item in ipairs(group) do
                item.state = "incompatible"
                item.diagnostics[#item.diagnostics + 1] = "driver_id " .. driver_id .. " is declared by " .. tostring(#group) .. " compatible bindings"
            end
        end
    end
    return bindings
end
return M
