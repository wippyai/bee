-- MIT. Destination principal mapping: the host's typed table of the
-- trusted issuer and subject pairs it admits and the policies each acts
-- under. The destination actor is derived from the pair itself, so a
-- pair always maps to one actor across every table version and restart,
-- no table can retarget a pair to another actor or alias two pairs to one
-- actor, and no local service actor can be named; identity linking
-- between issuers is not a table edit but an explicit future policy.
-- Nothing in a request selects an actor or a scope; a pair the table does
-- not admit is denied. A table change affects later admissions only:
-- existing commits keep the identity their actor gave them.
local hash = require("hash")
local types = require("types")
local bounds = require("bounds")
local M = {}
M.ENTRY = "bee.hive_host.supervisor:principal_mappings"
M.ENTRY_TYPE = "bee.hive.principal_mappings"
M.ACTOR_PREFIX = "bee.hive.member."
-- The identity encoding: sha256 over the issuer, a newline and the
-- subject (identifiers never carry a newline, so the pair is unambiguous),
-- the first 128 bits in hex after the prefix. Changing this is an identity
-- migration, never a silent edit.
M.ENCODING = "bee.hive.member@1"
M.MAX_MAPPINGS = 256
M.MAX_POLICIES = 16
type Mapping = {issuer: string, subject_id: string, actor_id: string, policies: {string}}
type Mappings = {list: {Mapping}, index: {[string]: Mapping}}
local function pair(issuer: string, subject_id: string): string
    return issuer .. "\n" .. subject_id
end
-- actor_of: the one destination actor a pair maps to, a function of the
-- pair and nothing else.
function M.actor_of(issuer: string, subject_id: string): string
    local digest, err = hash.sha256(pair(issuer, subject_id))
    if err or not digest then error("derive principal actor: " .. tostring(err)) end
    return M.ACTOR_PREFIX .. digest:sub(1, 32)
end
-- decode: an exact table or nothing; every pair once, every subject a
-- principal in the issuer's namespace, no actor named by the host.
function M.decode(value: unknown): (Mappings?, string?)
    local object = bounds.object(value)
    if not object then return nil, "principal mappings must be an object" end
    local unknown_field = bounds.fields(object, {"mappings"})
    if unknown_field then return nil, unknown_field end
    if type(object.mappings) ~= "table" then return nil, "mappings must be a list" end
    local raw = object.mappings :: {unknown}
    if #raw > M.MAX_MAPPINGS then return nil, "mappings exceeds " .. tostring(M.MAX_MAPPINGS) .. " entries" end
    local list: {Mapping} = {}
    local index: {[string]: Mapping} = {}
    for position, item in ipairs(raw) do
        local mapping = bounds.object(item)
        if not mapping then return nil, "mappings[" .. tostring(position) .. "] must be an object" end
        local unknown_mapping = bounds.fields(mapping, {"issuer", "subject_id", "policies"})
        if unknown_mapping then return nil, "mappings[" .. tostring(position) .. "]: " .. unknown_mapping end
        local issuer, subject_id = bounds.id(mapping.issuer), bounds.id(mapping.subject_id)
        if not issuer then return nil, "mappings[" .. tostring(position) .. "] issuer is not an identifier" end
        if not subject_id then return nil, "mappings[" .. tostring(position) .. "] subject_id is not an identifier" end
        local subject_node = types.pid_parts(subject_id)
        if subject_node ~= nil and subject_node ~= issuer then return nil, "mappings[" .. tostring(position) .. "] subject is outside the issuer's namespace" end
        local policies, policies_error = bounds.ids(mapping.policies == nil and {} or mapping.policies)
        if not policies then return nil, "mappings[" .. tostring(position) .. "] policies: " .. tostring(policies_error) end
        if #policies > M.MAX_POLICIES then return nil, "mappings[" .. tostring(position) .. "] policies exceeds " .. tostring(M.MAX_POLICIES) end
        local key = pair(issuer, subject_id)
        if index[key] then return nil, "mappings[" .. tostring(position) .. "] repeats issuer " .. issuer .. " subject " .. subject_id end
        local decoded: Mapping = {issuer = issuer, subject_id = subject_id, actor_id = M.actor_of(issuer, subject_id), policies = policies}
        index[key] = decoded
        list[#list + 1] = decoded
    end
    return {list = list, index = index}, nil
end
-- resolve: the mapping for a verified principal, or nothing. The caller
-- passes the issuer and subject the ingress authenticated, never values
-- read from the request payload.
function M.resolve(mappings: Mappings, principal: types.PrincipalRef): Mapping?
    return mappings.index[pair(principal.issuer, principal.subject_id)]
end
return M
