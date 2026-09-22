-- MIT. The host acceptance record for a permission exchange: a
-- host-approved binding of the driver binding and profile measurements,
-- the adapter digest, the proof fixture digest and the proof revision. A
-- profile's adapter pin makes it eligible; only a matching acceptance
-- record lets admission enable the exchange, and any changed measurement
-- needs renewed acceptance. Fixtures named by entries are never executed
-- during discovery or ordinary admission.
local hash = require("hash")
local bounds = require("bounds")
local canonical = require("canonical")
local M = {}
M.REVISION = "bee.permission-acceptance@2"
M.PROOF_REVISION = "bee.permission-proof@1"
M.ENTRY_TYPE = "harness.permission_acceptance"
type Object = {[string]: unknown}
type Acceptance = {
    acceptance_id: string,
    schema_revision: string,
    binding_id: string,
    profile_id: string,
    binding_digest: string,
    profile_digest: string,
    adapter_ref: string,
    adapter_digest: string,
    fixture_digest: string,
    -- The executable the exchange was proven with, as placement measures
    -- it: the measurement revision, what the digest covers (elf covers the
    -- native image; script covers the script file, never its interpreter;
    -- other covers bytes of no known form) and the content digest. A path
    -- is not an identity.
    executable_revision: string,
    executable_kind: string,
    executable_digest: string,
    proof_revision: string,
    accepted_by: string,
    accepted_at: string,
    digest: string,
}
type Measurements = {binding_id: string, profile_id: string, binding_digest: string, profile_digest: string, adapter_ref: string, adapter_digest: string, fixture_digest: string,
    executable_revision: string?, executable_kind: string?, executable_digest: string?}
M.EXECUTABLE_KINDS = {"elf", "script", "other"}
local function digest(object: Object, name: string): (string?, string?)
    local value = bounds.id(object[name])
    if not value or #value ~= 64 or not value:match("^%x+$") then return nil, "acceptance " .. name .. " must be a sha256 hex digest" end
    return value, nil
end
function M.decode(acceptance_id: string, value: unknown): (Acceptance?, string?)
    local object = bounds.object(value)
    if not object then return nil, "acceptance must be an object" end
    local unknown_field = bounds.fields(object, {"schema_revision", "binding_id", "profile_id", "binding_digest", "profile_digest", "adapter_ref", "adapter_digest", "fixture_digest", "executable_revision", "executable_kind", "executable_digest", "proof_revision", "accepted_by", "accepted_at"})
    if unknown_field then return nil, "acceptance: " .. unknown_field end
    if object.schema_revision ~= M.REVISION then return nil, "acceptance schema_revision must be " .. M.REVISION end
    if object.proof_revision ~= M.PROOF_REVISION then return nil, "acceptance proof_revision must be " .. M.PROOF_REVISION end
    local binding_id, profile_id, adapter_ref = bounds.id(object.binding_id), bounds.id(object.profile_id), bounds.id(object.adapter_ref)
    if not binding_id then return nil, "acceptance binding_id is not an identifier" end
    if not profile_id then return nil, "acceptance profile_id is not an identifier" end
    if not adapter_ref then return nil, "acceptance adapter_ref is not an identifier" end
    local binding_digest, binding_error = digest(object, "binding_digest")
    if not binding_digest then return nil, binding_error end
    local profile_digest, profile_error = digest(object, "profile_digest")
    if not profile_digest then return nil, profile_error end
    local adapter_digest, adapter_error = digest(object, "adapter_digest")
    if not adapter_digest then return nil, adapter_error end
    local fixture_digest, fixture_error = digest(object, "fixture_digest")
    if not fixture_digest then return nil, fixture_error end
    local executable_revision = bounds.id(object.executable_revision)
    if not executable_revision then return nil, "acceptance executable_revision is not an identifier" end
    local executable_kind = bounds.member(object.executable_kind, M.EXECUTABLE_KINDS)
    if not executable_kind then return nil, "acceptance executable_kind must be elf, script or other" end
    local executable_digest, executable_error = digest(object, "executable_digest")
    if not executable_digest then return nil, executable_error end
    local accepted_by = bounds.id(object.accepted_by)
    if not accepted_by then return nil, "acceptance accepted_by is not an identifier" end
    local accepted_at = bounds.timestamp(object.accepted_at)
    if not accepted_at then return nil, "acceptance accepted_at is not a canonical UTC timestamp" end
    local encoded, encode_error = canonical.encode(object)
    if not encoded then return nil, "acceptance is not measurable: " .. tostring(encode_error) end
    local sum, hash_error = hash.sha256(encoded)
    if hash_error or not sum then return nil, "acceptance digest failed" end
    return {acceptance_id = acceptance_id, schema_revision = M.REVISION, binding_id = binding_id, profile_id = profile_id, binding_digest = binding_digest, profile_digest = profile_digest,
        adapter_ref = adapter_ref, adapter_digest = adapter_digest, fixture_digest = fixture_digest, executable_revision = executable_revision, executable_kind = executable_kind, executable_digest = executable_digest, proof_revision = M.PROOF_REVISION, accepted_by = accepted_by, accepted_at = accepted_at, digest = sum}, nil
end
-- matches: names the first measurement the record no longer covers.
function M.matches(acceptance: Acceptance, measured: Measurements): string?
    if acceptance.binding_id ~= measured.binding_id then return "acceptance covers binding " .. acceptance.binding_id .. ", not " .. measured.binding_id end
    if acceptance.profile_id ~= measured.profile_id then return "acceptance covers profile " .. acceptance.profile_id .. ", not " .. measured.profile_id end
    if acceptance.binding_digest ~= measured.binding_digest then return "binding measurement changed since acceptance" end
    if acceptance.profile_digest ~= measured.profile_digest then return "profile measurement changed since acceptance" end
    if acceptance.adapter_ref ~= measured.adapter_ref then return "acceptance covers adapter " .. acceptance.adapter_ref .. ", not " .. measured.adapter_ref end
    if acceptance.adapter_digest ~= measured.adapter_digest then return "adapter measurement changed since acceptance" end
    if acceptance.fixture_digest ~= measured.fixture_digest then return "proof fixture changed since acceptance" end
    if measured.executable_revision ~= nil and acceptance.executable_revision ~= measured.executable_revision then return "executable measurement revision changed since acceptance" end
    if measured.executable_kind ~= nil and acceptance.executable_kind ~= measured.executable_kind then return "executable kind changed since acceptance" end
    if measured.executable_digest ~= nil and acceptance.executable_digest ~= measured.executable_digest then return "executable measurement changed since acceptance" end
    return nil
end
return M
