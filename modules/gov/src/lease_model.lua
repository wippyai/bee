-- MIT. Pure approval-lease envelope logic: a bounded ceiling over capability
-- grants a person has already decided on, reused by activation_owner to
-- auto-apply a future non-empty capability diff without asking again. This
-- module performs no I/O, storage or approval call; it only measures whether
-- one proposed capability set is fully contained in a granted envelope.
local bounds = require("bounds")
local canonical = require("canonical")
local hash = require("hash")
local capability_model = require("capability_model")
local super_edit = require("super_edit")

local M = {}
M.MAX_ENVELOPE = 128
M.MAX_TTL_SECONDS = 86400 * 30
type Object = {[string]: unknown}
type Grant = capability_model.Grant
type Vocabulary = capability_model.Vocabulary

local function digest(value: unknown): string?
    local encoded = canonical.encode(value)
    return encoded and hash.sha256(encoded) or nil
end

-- Every extra must be a well-formed, currently templated grant: the same
-- reproducibility check the host already runs for an installed grant record
-- (capability_grants.decode calls the equivalent through M.propose). Reusing
-- M.render here is deliberate: it recomputes the exact expected operation
-- from the grant's own capability/parameters and refuses anything that does
-- not match its host template, so a lease can never bless a fabricated grant.
local function validated(vocabulary: Vocabulary, grants: {Grant}): (boolean, string?)
    if #grants > M.MAX_ENVELOPE then return false, "lease envelope exceeds its bound" end
    local _, render_error = capability_model.render(vocabulary, grants)
    if render_error then return false, render_error end
    return true, nil
end

-- The envelope a lease grants: the currently installed capability set plus
-- any explicit, individually validated extras, deduplicated by meaning.
-- installed and extras are both already-resolved Grant lists; this performs
-- no host-template resolution of its own beyond the validation above.
function M.envelope(vocabulary: Vocabulary, installed: {Grant}, extras: {Grant}): ({Grant}?, string?)
    local ok, validate_error = validated(vocabulary, extras)
    if not ok then return nil, validate_error end
    local combined: {Grant} = {}
    local seen: {[string]: boolean} = {}
    for _, list in ipairs({installed, extras}) do
        for _, grant in ipairs(list) do
            local key = digest(grant)
            if not key then return nil, "lease envelope grant cannot be measured" end
            if not seen[key] then
                seen[key] = true
                combined[#combined + 1] = grant
            end
        end
    end
    if #combined == 0 then return nil, "lease envelope must not be empty" end
    if #combined > M.MAX_ENVELOPE then return nil, "lease envelope exceeds its bound" end
    table.sort(combined, function(a: Grant, b: Grant): boolean
        local left, right = digest(a) or "", digest(b) or ""
        return left < right
    end)
    return combined, nil
end

function M.envelope_digest(envelope: {Grant}): string?
    return digest(envelope)
end

-- Ceiling containment: every grant in the full proposed set must be
-- contained in some envelope grant of identical meaning (capability,
-- template revision, operation, resource) and equal-or-narrower scope.
-- Checking the complete proposal, not only its delta against the last
-- installed revision, refuses a lease that would silently also cover an
-- unrelated capability riding along in the same proposal.
function M.covers(envelope: {Grant}, proposed: {Grant}): boolean
    for _, grant in ipairs(proposed) do
        local found = false
        for _, allowed in ipairs(envelope) do
            if capability_model.contains(allowed, grant) then found = true; break end
        end
        if not found then return false end
    end
    return true
end

-- A lease must expire on its own: by a deadline, a use count, or both.
-- Reuses super_edit's own bounded-duration grammar and 24h ceiling rather
-- than inventing a second one.
function M.duration(raw: unknown): (string?, string?)
    return super_edit.duration(raw)
end

function M.bounded(ttl_seconds: unknown, max_applies: unknown): (integer?, integer?, string?)
    local ttl = ttl_seconds == nil and nil or bounds.integer(ttl_seconds)
    local max = max_applies == nil and nil or bounds.integer(max_applies)
    if ttl_seconds ~= nil and (not ttl or ttl < 1 or ttl > M.MAX_TTL_SECONDS) then return nil, nil, "lease ttl is invalid" end
    if max_applies ~= nil and (not max or max < 1) then return nil, nil, "lease max_applies must be a positive integer" end
    if not ttl and not max then return nil, nil, "a lease requires an expiry, a use limit, or both" end
    return ttl, max, nil
end

return M
