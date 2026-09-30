-- MIT. A person-approved Hub publication request: the agent names a package,
-- the host packs and measures its exact bytes, and one approval carries the
-- module, version, digest and visibility the person decides on. The approved
-- digest is the only authority to upload those bytes. Pure: nothing here
-- calls the Hub, the approval owner, the credential broker or the registry.
local bounds = require("bounds")
local canonical = require("canonical")
local hash = require("hash")
local semver = require("semver")
local M = {}
M.REF = "bee.hub:publish"
M.SOURCE = "hub-publish"
type Object = {[string]: unknown}
type Decoded = {component: string, version: string, visibility: string, source: string}
type Context = {binding_id: string, thread_id: string, action_id: string, attempt_id: string}
type Request = {action: string, component: string, version: string, visibility: string,
    digest: string, organization: string, source: string}
type Measured = {component: string, version: string, digest: string, visibility: string,
    organization: string, source: string}
type Verified = {request: Request, digest: string}
type Status = {status: string, code: string?, message: string?, state: string?, replayed: boolean?}

local function hex(value: unknown): string?
    if type(value) ~= "string" or #value ~= 64 or not value:match("^[0-9a-f]+$") then return nil end
    return value
end

local function component_name(value: unknown): string?
    local name = bounds.line(value, 160)
    if not name or not name:match("^[a-z0-9][a-z0-9._-]*/[a-z0-9][a-z0-9._-]*$") then return nil end
    return name
end

local function source_path(value: unknown): string?
    local path = bounds.text(value, 8192)
    if not path or path:sub(1, 1) ~= "/" or path:find("%z", 1, true) then return nil end
    return path
end

-- decode: the agent's wire shape. A publication names the exact component,
-- version and visibility plus the module source directory the host admits.
function M.decode(raw: unknown): (Decoded?, string?)
    local value = bounds.object(raw)
    if not value then return nil, "publication request must be an object" end
    local extra = bounds.fields(value, {"component", "version", "visibility", "source"})
    if extra then return nil, extra end
    local component = component_name(value.component)
    if not component then return nil, "component must name a Hub package as owner/name" end
    local version = bounds.line(value.version, 128)
    if not version or not semver.parse(version) then return nil, "version must be an exact package version" end
    local visibility = bounds.member(value.visibility, {"public", "private"})
    if not visibility then return nil, "visibility must be public or private" end
    local source = source_path(value.source)
    if not source then return nil, "source must name an absolute module directory" end
    return {component = component, version = version, visibility = visibility, source = source}, nil
end

local function measured_value(value: unknown): (Measured?, string?)
    local object = bounds.object(value)
    if not object then return nil, "measured publication must be an object" end
    local extra = bounds.fields(object, {"component", "version", "digest", "visibility", "organization", "source"})
    if extra then return nil, extra end
    local component = component_name(object.component)
    local version = bounds.line(object.version, 128)
    if not component or not version or not semver.parse(version) then
        return nil, "measured publication names a malformed component or version"
    end
    local digest = hex(object.digest)
    local visibility = bounds.member(object.visibility, {"public", "private"})
    local organization = bounds.line(object.organization, 128)
    local source = source_path(object.source)
    if not digest or not visibility or not organization then
        return nil, "measured publication names a malformed digest, visibility or organization"
    end
    if not source then return nil, "measured publication names a malformed source" end
    local owner = component:match("^([a-z0-9][a-z0-9._-]*)/")
    if owner ~= organization then return nil, "measured publication organization differs from its component" end
    return {component = component, version = version, digest = digest,
        visibility = visibility, organization = organization, source = source}, nil
end

-- plan_digest: the measurement binding module, version, pack digest,
-- visibility, organization and source. The approval carries it; the worker
-- uploads only staged bytes that measure to it.
function M.plan_digest(raw: unknown): string?
    local measured, _ = measured_value(raw)
    if not measured then return nil end
    local encoded = canonical.encode(measured)
    if not encoded then return nil end
    return hash.sha256(encoded)
end

-- proposal: the exact approval body for measured bytes. The person sees the
-- module, version, pack digest, visibility, organization and source.
function M.proposal(raw: unknown, context: Context): (Object?, string?, string?)
    local measured, measured_error = measured_value(raw)
    if not measured then return nil, nil, measured_error end
    local digest = M.plan_digest(measured)
    if not digest then return nil, nil, "publication measurement cannot be encoded" end
    local proposal: Object = {kind = "operation", ref = M.REF, revision = digest, input_digest = digest,
        payload = {action = "publish", component = measured.component, version = measured.version,
            digest = measured.digest, visibility = measured.visibility, organization = measured.organization,
            source = measured.source, plan_digest = digest, binding_id = context.binding_id,
            thread_id = context.thread_id, action_id = context.action_id, attempt_id = context.attempt_id}}
    local prompt = "Publish " .. measured.component .. " " .. measured.version .. " (" .. measured.visibility .. ")?"
    return proposal, prompt, nil
end

-- The idempotency key binds the asking gateway attempt to the exact measured
-- bytes, so a retried request replays one approval instead of asking twice.
function M.idempotency_key(context: Context, digest: string): string?
    local encoded = canonical.encode({binding_id = context.binding_id, attempt_id = context.attempt_id, plan_digest = digest})
    local sum = encoded and hash.sha256(encoded) or nil
    return sum and "hub-publish:" .. sum or nil
end

function M.effect_key(approval_id: string): string
    return "hub-publish:" .. approval_id
end

-- verify: the approval the agent names must be its own request for this
-- thread and attempt under the host policy. The publication fields and
-- digest come from the recorded proposal, never from the agent.
function M.verify(view_raw: unknown, subject: string, workspace_id: string, policy: string,
    context: Context): (Verified?, string?)
    local view = bounds.object(view_raw)
    local proposal = view and bounds.object(view.proposal) or nil
    local payload = proposal and bounds.object(proposal.payload) or nil
    if not view or not proposal or not payload or proposal.ref ~= M.REF then
        return nil, "request is not a Hub publication request"
    end
    if view.requester_id ~= subject or view.thread_id ~= context.thread_id or view.workspace_id ~= workspace_id
        or view.policy ~= policy then
        return nil, "request does not belong to this agent, thread and workspace"
    end
    if payload.binding_id ~= context.binding_id or payload.attempt_id ~= context.attempt_id
        or payload.action_id ~= context.action_id then
        return nil, "request does not belong to this attempt"
    end
    local digest = hex(payload.plan_digest)
    if not digest or proposal.input_digest ~= digest then return nil, "recorded proposal is malformed" end
    local measured, measured_error = measured_value({component = payload.component, version = payload.version,
        digest = payload.digest, visibility = payload.visibility, organization = payload.organization, source = payload.source})
    if not measured then return nil, measured_error end
    if M.plan_digest(measured) ~= digest then return nil, "recorded proposal digest does not measure its publication" end
    return {request = {action = "publish", component = measured.component, version = measured.version,
        visibility = measured.visibility, digest = measured.digest, organization = measured.organization,
        source = measured.source}, digest = digest}, nil
end

-- The decision the approval owner records, before any effect.
function M.decision(view_raw: unknown): Status
    local view = bounds.object(view_raw) or {}
    if view.state == "pending" then return {status = "pending"} end
    if view.state == "decided" and view.decision == "approved" then return {status = "approved"} end
    if view.state == "decided" then
        return {status = "refused", code = "DENIED", message = "the person refused the publication"}
    end
    local reason = tostring(view.state)
    return {status = "refused", code = reason:upper(), message = "the request " .. reason .. " before a decision"}
end

-- publish_command: the exact uploader invocation for verified bytes. It
-- carries no credential: the CLI reads the person's publishing credential
-- from its host-confined store and the receipt records digests only.
function M.publish_command(verified: Verified, cli: string, wapp: string): {string}
    return {cli, "publish", "--config", verified.request.source, "--wapp", wapp,
        "--version", verified.request.version, "--create", "--protected",
        "--module-visibility", verified.request.visibility}
end

-- plan_command: the exact dry-run invocation that packs the source without
-- uploading. The worker stages the reported pack file and measures its
-- bytes; the approval digest binds those bytes.
function M.plan_command(decoded: Decoded, cli: string): {string}
    return {cli, "publish", "--config", decoded.source, "--version", decoded.version, "--dry-run"}
end

-- parse_pack_path: the staged pack file the dry run reports.
function M.parse_pack_path(output: unknown): string?
    if type(output) ~= "string" then return nil end
    local path = (output :: string):match("Pack created:%s+([^\n]+)%s+%(%d+ B%)")
    if not path or path:sub(1, 1) ~= "/" or path:find("%z", 1, true) or #path > 8192 then return nil end
    return path
end

-- parse_digest: the Hub digest the uploader reports for the uploaded bytes.
function M.parse_digest(output: unknown): string?
    if type(output) ~= "string" then return nil end
    local digest = (output :: string):match("Digest:%s+(sha256:[0-9a-f]+)")
    if not digest or #digest ~= 7 + 64 then return nil end
    return digest
end

-- status: the publish effect reply as the agent's outcome. An uncertain or
-- unavailable upload stays approved so the owner worker can repeat the same
-- digest-bound effect; agent polling only reads status and recorded receipts.
function M.status(reply_raw: unknown): Status
    local reply = bounds.object(reply_raw) or {}
    local receipt = bounds.object(reply.value)
    local code = bounds.line(reply.code, 160)
    local message = bounds.text(reply.message, 4096)
    local state = receipt and bounds.line(receipt.state, 80) or nil
    if receipt and not message then message = bounds.text(receipt.message, 4096) end
    if reply.ok == true and (state == "published" or state == "complete") then
        return {status = "applied", state = state, message = message, replayed = reply.replayed == true}
    end
    if reply.ok ~= true and (code == "UNCERTAIN" or code == "UNAVAILABLE" or code == "NOT_FOUND") then
        return {status = "approved", code = code, message = message, replayed = reply.replayed == true}
    end
    return {status = "failed", code = code or "FAILED", state = state,
        message = message or "the Hub publication did not complete", replayed = reply.replayed == true}
end

-- effect_result: keep the status receipt the agent needs without copying
-- uploader output, which never enters durable records.
function M.effect_result(reply_raw: unknown): Object
    local reply = bounds.object(reply_raw) or {}
    local receipt = bounds.object(reply.value)
    local state = receipt and bounds.line(receipt.state, 80) or nil
    local message = bounds.text(reply.message, 4096)
    if receipt and not message then message = bounds.text(receipt.message, 4096) end
    local applied = reply.ok == true and (state == "published" or state == "complete")
    local result: Object = {ok = applied, replayed = reply.replayed == true}
    if not applied then result.code = bounds.line(reply.code, 160) or "FAILED" end
    if message then result.message = message end
    if state then result.value = {state = state, message = message} end
    return result
end

return M
