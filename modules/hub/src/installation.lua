-- MIT. A person-approved Hub installation request: the agent names a package,
-- the host resolves its exact plan, and one approval carries the plan digest
-- with the dependency, policy, migration and auto-start changes the person
-- decides on. The approved digest is the only authority to apply it. Pure:
-- nothing here calls the Hub, the approval owner or the registry.
local bounds = require("bounds")
local canonical = require("canonical")
local hash = require("hash")
local semver = require("semver")
local M = {}
M.REF = "bee.hub:apply"
M.SOURCE = "hub"
type Object = {[string]: unknown}
type Kind = "install" | "uninstall"
type Decoded = {kind: Kind, component: string, version: string?}
type Context = {thread_id: string, action_id: string, attempt_id: string}
type Request = {action: string, component: string, version: string, migration_policy: string}
type Verified = {request: Request, digest: string}
type Status = {status: string, code: string?, message: string?, state: string?}

local function hex(value: unknown): string?
    if type(value) ~= "string" or #value ~= 64 or not value:match("^[0-9a-f]+$") then return nil end
    return value
end

local function component_name(value: unknown): string?
    local name = bounds.line(value, 160)
    if not name or not name:match("^[a-z0-9][a-z0-9._-]*/[a-z0-9][a-z0-9._-]*$") then return nil end
    return name
end

-- decode: the agent's wire shape. Install names a component and optionally
-- an exact version; uninstall names only the component.
function M.decode(kind: Kind, raw: unknown): (Decoded?, string?)
    local value = bounds.object(raw)
    if not value then return nil, "installation request must be an object" end
    local allowed: {string} = {"component"}
    if kind == "install" then allowed = {"component", "version"} end
    local extra = bounds.fields(value, allowed)
    if extra then return nil, extra end
    local component = component_name(value.component)
    if not component then return nil, "component must name a Hub package as owner/name" end
    if value.version == nil then return {kind = kind, component = component, version = nil}, nil end
    local version = bounds.line(value.version, 128)
    if not version or not semver.parse(version) then return nil, "version must be an exact package version" end
    return {kind = kind, component = component, version = version}, nil
end

-- The plan action for an install: update when this installer already holds
-- a Hub dependency root for the component, else install.
function M.action(decoded: Decoded, installed_raw: unknown): (string?, string?)
    if decoded.kind == "uninstall" then return "uninstall", nil end
    local installed = bounds.object(installed_raw)
    if not installed or type(installed.roots) ~= "table" then return nil, "installed inventory is malformed" end
    for _, raw_root in ipairs(installed.roots :: {unknown}) do
        local root = bounds.object(raw_root)
        local id = root and bounds.id(root.id) or nil
        if root and id and id:sub(1, 13) == "bee.hub.deps:" and root.component == decoded.component then
            return "update", nil
        end
    end
    return "install", nil
end

-- The highest version a Hub details page lists that is not yanked.
function M.latest(details_raw: unknown): (string?, string?)
    local details = bounds.object(details_raw)
    if not details or type(details.versions) ~= "table" then return nil, "package details are malformed" end
    local selected: string? = nil
    for _, raw_version in ipairs(details.versions :: {unknown}) do
        local item = bounds.object(raw_version)
        local version = item and bounds.line(item.version, 128) or nil
        if item and version and item.yanked == false and semver.parse(version) then
            if not selected or (semver.compare(version, selected) or 0) > 0 then selected = version end
        end
    end
    if not selected then return nil, "package has no installable version" end
    return selected, nil
end

-- The Hub plan request. Install and update run the package's migrations
-- under the host's migration grants; uninstall blocks on applied migrations.
function M.request(action: string, component: string, version: string?): Object
    if action == "uninstall" then return {action = action, component = component, migration_policy = "block"} end
    return {action = action, component = component, version = version, migration_policy = "up"}
end

local function lines(): {string}
    local result: {string} = table.create(4, 0)
    return result
end

local function joined(raw: unknown): string
    if type(raw) ~= "table" then return "" end
    local parts: {string} = {}
    for _, item in ipairs(raw :: {unknown}) do
        if type(item) == "string" then parts[#parts + 1] = item end
    end
    return table.concat(parts, ", ")
end

local VERBS: {[string]: string} = {add = "added", update = "replaced", remove = "removed"}

local function dependency_line(item: Object): string?
    local component = bounds.line(item.component, 160)
    local change = bounds.member(item.change, {"install", "update", "remove", "keep"})
    if not component or not change then return nil end
    if change == "install" then return "install " .. component .. " " .. tostring(item.version) end
    if change == "update" then
        return "update " .. component .. " " .. tostring(item.previous_version) .. " -> " .. tostring(item.version)
    end
    if change == "remove" then return "remove " .. component .. " " .. tostring(item.previous_version) end
    return ""
end

local function policy_line(item: Object): string?
    local id = bounds.line(item.id, 160)
    local verb = VERBS[tostring(item.change)]
    if not id or not verb then return nil end
    local shown = verb .. ": " .. id .. " allows " .. joined(item.actions) .. " on " .. joined(item.resources)
    if item.expression == true then shown = shown .. " where its expression holds" end
    return shown
end

local function measured(value: unknown): string?
    local encoded = canonical.encode(value)
    if not encoded then return nil end
    return hash.sha256(encoded)
end

-- The idempotency key binds the asking attempt to the exact plan, so a
-- retried request replays one approval instead of asking twice.
function M.idempotency_key(context: Context, digest: string): string?
    local sum = measured({attempt_id = context.attempt_id, plan_digest = digest})
    return sum and "hub-install:" .. sum or nil
end

function M.effect_key(approval_id: string): string
    return "hub-install:" .. approval_id
end

-- proposal: the exact approval body for a ready plan. The person sees the
-- package, version, source, dependency changes, the security policies the
-- change adds, replaces or removes, migrations it runs and entries that
-- start themselves. The plan digest binds every one of them.
function M.proposal(plan_raw: unknown, context: Context): (Object?, string?, string?)
    local plan = bounds.object(plan_raw)
    local digest = plan and hex(plan.digest) or nil
    local request = plan and bounds.object(plan.request) or nil
    if not plan or not digest or not request then return nil, nil, "Hub plan is malformed" end
    if plan.ready ~= true then return nil, nil, "package needs requirement values the person selects in Modules" end
    local action = bounds.member(request.action, {"install", "update", "uninstall"})
    local component = component_name(request.component)
    local migration_policy = bounds.member(request.migration_policy, {"up", "block"})
    local revision = bounds.count(plan.base_revision)
    if not action or not component or not migration_policy or not revision then
        return nil, nil, "Hub plan request is malformed"
    end
    local version = action == "uninstall" and "" or bounds.line(request.version, 128)
    if not version then return nil, nil, "Hub plan version is malformed" end
    local dependencies, policies, migrations, starts = lines(), lines(), lines(), lines()
    for _, raw in ipairs((plan.modules or {}) :: {unknown}) do
        local item = bounds.object(raw)
        local shown = item and dependency_line(item) or nil
        if not shown then return nil, nil, "Hub plan module is malformed" end
        if shown ~= "" then dependencies[#dependencies + 1] = shown end
    end
    for _, raw in ipairs((plan.policy_changes or {}) :: {unknown}) do
        local item = bounds.object(raw)
        local shown = item and policy_line(item) or nil
        if not shown then return nil, nil, "Hub plan policy change is malformed" end
        policies[#policies + 1] = shown
    end
    for _, raw in ipairs((plan.migrations or {}) :: {unknown}) do
        local item = bounds.object(raw)
        local id = item and bounds.line(item.id, 160) or nil
        local target = item and bounds.line(item.target_db, 160) or nil
        if not id or not target then return nil, nil, "Hub plan migration is malformed" end
        migrations[#migrations + 1] = (action == "uninstall" and "blocks removal: " or "runs: ") .. id .. " on " .. target
    end
    for _, raw in ipairs((plan.starts or {}) :: {unknown}) do
        local id = bounds.line(raw, 160)
        if not id then return nil, nil, "Hub plan auto start is malformed" end
        starts[#starts + 1] = id
    end
    local proposal: Object = {kind = "operation", ref = M.REF, revision = digest, input_digest = digest,
        payload = {action = action, component = component, version = version, source = M.SOURCE,
            plan_digest = digest, base_revision = revision, migration_policy = migration_policy,
            dependency_changes = dependencies, permission_changes = policies, migrations = migrations,
            auto_start = starts, thread_id = context.thread_id, action_id = context.action_id,
            attempt_id = context.attempt_id}}
    local verb = action == "uninstall" and "Remove " or (action == "update" and "Update " or "Install ")
    local prompt = verb .. component .. (version ~= "" and (" " .. version) or "") .. " from the Hub?"
    return proposal, prompt, nil
end

-- verify: the approval the agent names must be its own request for this
-- thread and attempt under the host policy. The Hub request and digest come
-- from the recorded proposal, never from the agent.
function M.verify(view_raw: unknown, subject: string, workspace_id: string, policy: string,
    context: Context): (Verified?, string?)
    local view = bounds.object(view_raw)
    local proposal = view and bounds.object(view.proposal) or nil
    local payload = proposal and bounds.object(proposal.payload) or nil
    if not view or not proposal or not payload or proposal.ref ~= M.REF then
        return nil, "request is not a Hub installation request"
    end
    if view.requester_id ~= subject or view.thread_id ~= context.thread_id or view.workspace_id ~= workspace_id
        or view.policy ~= policy then
        return nil, "request does not belong to this agent, thread and workspace"
    end
    if payload.attempt_id ~= context.attempt_id or payload.action_id ~= context.action_id then
        return nil, "request does not belong to this attempt"
    end
    local digest = hex(payload.plan_digest)
    local action = bounds.member(payload.action, {"install", "update", "uninstall"})
    local component = component_name(payload.component)
    local migration_policy = bounds.member(payload.migration_policy, {"up", "block"})
    if not digest or proposal.input_digest ~= digest or not action or not component or not migration_policy then
        return nil, "recorded proposal is malformed"
    end
    local version = ""
    if action ~= "uninstall" then
        local recorded = bounds.line(payload.version, 128)
        if not recorded then return nil, "recorded proposal version is malformed" end
        version = recorded
    end
    return {request = {action = action, component = component, version = version,
        migration_policy = migration_policy}, digest = digest}, nil
end

-- The Hub apply request the approved proposal names.
function M.apply_request(verified: Verified): Object
    local request = verified.request
    if request.action == "uninstall" then
        return {action = "uninstall", component = request.component, migration_policy = request.migration_policy}
    end
    return {action = request.action, component = request.component, version = request.version,
        migration_policy = request.migration_policy}
end

-- The decision the approval owner records, before any effect.
function M.decision(view_raw: unknown): Status
    local view = bounds.object(view_raw) or {}
    if view.state == "pending" then return {status = "pending"} end
    if view.state == "decided" and view.decision == "approved" then return {status = "approved"} end
    local reason = view.state == "decided" and "denied" or tostring(view.state)
    return {status = "refused", code = reason:upper(), message = "the person " .. (reason == "denied"
        and "refused the installation" or ("left the request " .. reason))}
end

-- status: the Hub apply reply as the agent's outcome. An uncertain or
-- unavailable apply stays approved: the next poll repeats the same
-- digest-bound apply, which replays its recorded receipt.
function M.status(reply_raw: unknown): Status
    local reply = bounds.object(reply_raw) or {}
    local receipt = bounds.object(reply.value)
    local code = bounds.line(reply.code, 160)
    local message = bounds.text(reply.message, 4096)
    local state = receipt and bounds.line(receipt.state, 80) or nil
    if receipt and not message then message = bounds.text(receipt.message, 4096) end
    if reply.ok == true and state == "complete" then return {status = "applied", state = state, message = message} end
    if reply.ok ~= true and (code == "UNCERTAIN" or code == "UNAVAILABLE") then
        return {status = "approved", code = code, message = message}
    end
    return {status = "failed", code = code or "FAILED", state = state,
        message = message or "the Hub operation did not complete"}
end

return M
