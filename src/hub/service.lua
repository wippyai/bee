-- MIT. Private dependency-root publication using existing registry APIs.
-- The worker serializes Bee Hub operations; other registry writers still
-- require revalidation and can prevent automatic baseline restoration.
local registry = require("registry")
local security = require("security")
local bounds = require("bounds")
local plan = require("plan")
local catalog = require("catalog")
local inspect = require("inspect")
local transaction = require("transaction")
local inventory = require("inventory")
local canonical = require("canonical")
local hash = require("hash")
local M = {}
type Result = transaction.Result
type ExpectedModule = {component: string, version: string, change: string}
type Receipt = {actor_id: string, digest: string, request_digest: string?, component: string, state: string,
    baseline_revision: integer, message: string, action: string, expected_modules: {ExpectedModule}?}

local function receipt_id(digest: string): string return "bee.hub.operations:" .. digest end
local function digest(raw: unknown): string?
    if type(raw) ~= "string" or #raw ~= 64 or not raw:match("^[0-9a-f]+$") then return nil end
    return raw
end
local function source(): {versions: (string, integer) -> ({string}?, boolean?, string?),
    artifact: (string, string) -> (inspect.Inspection?, string?)}
    return {versions = catalog.available,
        artifact = function(component: string, version: string): (inspect.Inspection?, string?)
            return inspect.read({component = component, version = version})
        end}
end

function M.prepare(raw: unknown): (plan.Prepared?, string?)
    local request, request_error = plan.decode(raw)
    if not request then return nil, request_error end
    local snapshot, snapshot_error = registry.snapshot()
    if not snapshot then return nil, tostring(snapshot_error) end
    local state, state_error = snapshot:state()
    if not state then return nil, tostring(state_error) end
    local revision = bounds.count(snapshot:version():id())
    if revision == nil then return nil, "invalid registry revision" end
    return plan.prepare(state, revision, request, source())
end

local function expected_modules(raw: unknown): {ExpectedModule}?
    if type(raw) ~= "table" then return nil end
    local count = 0
    for key in pairs(raw) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then return nil end
        count = count + 1
    end
    if count ~= #raw or count > 512 then return nil end
    local result: {ExpectedModule} = {}
    local seen: {[string]: boolean} = {}
    for _, item in ipairs(raw :: {unknown}) do
        local value = bounds.object(item)
        if not value then return nil end
        local component = bounds.line(value.component, 160)
        local version = bounds.text(value.version, 128)
        local change = bounds.member(value.change, {"keep", "install", "update", "remove"})
        if not component or not version or not change or seen[component] then return nil end
        if (change == "install" or change == "update") and version == "" then return nil end
        seen[component] = true
        result[#result + 1] = {component = component, version = version, change = change}
    end
    return result
end

local function decode_receipt(raw: unknown): Receipt?
    local value = bounds.object(raw)
    if not value then return nil end
    local actor, measured, component = bounds.id(value.actor_id), digest(value.digest), bounds.line(value.component, 160)
    local state = bounds.member(value.state, {"published", "complete", "failed", "recovery_required"})
    local baseline = bounds.count(value.baseline_revision)
    local message, action = bounds.text(value.message, 4096), bounds.member(value.action, {"install", "update", "uninstall"})
    if not actor or not measured or not component or not state or not baseline or not message or not action then return nil end
    local request_digest = digest(value.request_digest)
    if value.request_digest ~= nil and not request_digest then return nil end
    local expected = expected_modules(value.expected_modules)
    if value.expected_modules ~= nil and not expected then return nil end
    return {actor_id = actor, digest = measured, request_digest = request_digest, component = component, state = state,
        baseline_revision = baseline, message = message, action = action, expected_modules = expected}
end

function M.status(raw: unknown): Result
    local measured = digest(raw)
    if not measured then return transaction.failure("INVALID", "invalid plan digest") end
    local actor = security.actor()
    if not actor then return transaction.failure("DENIED", "authenticated installer required") end
    local snapshot, problem = registry.snapshot()
    if not snapshot then return transaction.failure("UNAVAILABLE", tostring(problem)) end
    local entry = snapshot:get(receipt_id(measured))
    if not entry then return transaction.failure("NOT_FOUND", "no published operation for this plan") end
    local receipt = decode_receipt(entry.data)
    if not receipt then return transaction.failure("INTERNAL", "invalid Hub operation receipt") end
    if receipt.actor_id ~= actor:id() then return transaction.failure("DENIED", "operation belongs to another actor") end
    return transaction.success(receipt, false)
end

local function save(receipt: Receipt): Result
    local snapshot, problem = registry.snapshot()
    if not snapshot then return transaction.failure("UNCERTAIN", tostring(problem)) end
    local changes, change_error = snapshot:changes()
    if not changes then return transaction.failure("UNCERTAIN", tostring(change_error)) end
    local entry = {id = receipt_id(receipt.digest), kind = "registry.entry", data = receipt}
    local stored = snapshot:get(entry.id)
    local staged, stage_error
    if stored then staged, stage_error = changes:update(entry)
    else staged, stage_error = changes:create(entry) end
    if not staged then return transaction.failure("UNCERTAIN", tostring(stage_error)) end
    local version, apply_error = changes:apply()
    if not version then return transaction.failure("UNCERTAIN", tostring(apply_error)) end
    return transaction.success(receipt, false)
end

local function verify(expected: {ExpectedModule}, actual: inventory.Result): string?
    local selected: {[string]: string} = {}
    for _, item in ipairs(actual.modules) do selected[item.component] = item.version end
    for _, item in ipairs(expected) do
        if item.change == "remove" then
            if selected[item.component] then return "removed module remains installed: " .. item.component end
        elseif selected[item.component] == nil then
            return "runtime removed retained module: " .. item.component
        elseif item.version ~= "" and selected[item.component] ~= item.version then
            return "runtime selected another version for " .. item.component
        end
        selected[item.component] = nil
    end
    if next(selected) then return "runtime installed modules outside the displayed plan" end
    return nil
end

local function reconcile(receipt: Receipt, request: plan.Request): Result
    local expected = receipt.expected_modules
    if not expected then return transaction.failure("UNCERTAIN", "published operation has no captured recovery evidence") end
    local snapshot, problem = registry.snapshot()
    if not snapshot then return transaction.failure("UNAVAILABLE", tostring(problem)) end
    local root_id, root_error = plan.root_id(request.component)
    if not root_id then return transaction.failure("INTERNAL", tostring(root_error)) end
    local state, state_error = snapshot:state()
    if not state then return transaction.failure("UNAVAILABLE", tostring(state_error)) end
    -- The complete snapshot carries derived dependency ownership; get() only
    -- returns the authored entry fields.
    local root = nil
    for _, entry in ipairs(state.entries) do
        if entry.id == root_id then root = entry; break end
    end
    local mismatch: string? = nil
    if request.action == "uninstall" then
        if root then mismatch = "removed dependency root is present" end
    elseif not root or root.kind ~= "ns.dependency" or not root.registry or root.registry.root ~= true then
        mismatch = "published dependency root is absent or no longer a root"
    else
        local data = bounds.object(root.data)
        local observed = data and plan.decode({action = request.action, component = data.component, version = data.version,
            parameters = data.parameters, migration_policy = request.migration_policy}) or nil
        local encoded = observed and canonical.encode(observed) or nil
        local measured = encoded and hash.sha256(encoded) or nil
        if measured ~= receipt.request_digest then mismatch = "published dependency root differs from the confirmed request" end
    end
    local actual, inventory_error = inventory.decode(state, snapshot:version():id())
    if not actual then return transaction.failure("UNAVAILABLE", tostring(inventory_error)) end
    mismatch = mismatch or verify(expected, actual)
    receipt.state = mismatch and "recovery_required" or "complete"
    receipt.message = mismatch or "Published dependency change verified after interruption"
    local result = save(receipt)
    result.replayed = true
    return result
end

-- Called only inside the named publication worker after facade authorization.
function M.apply(raw: unknown, expected: unknown): Result
    if not security.can("bee.hub.execute", "bee.hub:worker") then return transaction.failure("DENIED", "Hub worker authority required") end
    local measured = digest(expected)
    if not measured then return transaction.failure("INVALID", "confirmation requires the displayed plan digest") end
    local actor = security.actor()
    if not actor then return transaction.failure("DENIED", "authenticated installer required") end
    local decoded, decode_error = plan.decode(raw)
    if not decoded then return transaction.failure("INVALID", decode_error or "invalid operation request") end
    local encoded, encode_error = canonical.encode(decoded)
    if not encoded then return transaction.failure("INVALID", encode_error or "cannot measure operation request") end
    local request_digest, hash_error = hash.sha256(encoded)
    if not request_digest then return transaction.failure("INTERNAL", tostring(hash_error)) end
    local previous = M.status(measured)
    if previous.ok then
        local receipt = decode_receipt(previous.value)
        if not receipt or receipt.request_digest ~= request_digest then
            return transaction.failure("STALE", "request differs from the recorded operation; refresh its plan")
        end
        if receipt.state == "published" then return reconcile(receipt, decoded) end
        previous.replayed = true
        return previous
    end
    if previous.code ~= "NOT_FOUND" then return previous end
    local prepared, prepare_error = M.prepare(raw)
    if not prepared then return transaction.failure("INVALID", prepare_error or "cannot prepare installation") end
    local displayed = prepared.plan
    if displayed.digest ~= measured then return transaction.failure("STALE", "the install plan changed; refresh and confirm it again") end
    if not displayed.ready then return transaction.failure("INCOMPLETE", "fill the missing package requirements") end
    -- The public migration runner is an optional composition dependency. Never
    -- publish an 'up' plan and then discover that its runner is unavailable.
    if displayed.request.migration_policy == "up" and #displayed.migrations > 0 then
        return transaction.failure("UNAVAILABLE", "package migrations need the host migration runner binding")
    end
    local baseline, baseline_error = registry.snapshot()
    if not baseline then return transaction.failure("UNAVAILABLE", tostring(baseline_error)) end
    if baseline:version():id() ~= displayed.base_revision then return transaction.failure("STALE", "registry changed while preparing the operation") end
    local request = displayed.request
    if request.action == "uninstall" then
        local state, state_error = baseline:state()
        if not state then return transaction.failure("UNAVAILABLE", tostring(state_error)) end
        for _, entry in ipairs(state.entries) do
            if entry.registry and entry.registry.owner == request.component and entry.meta and entry.meta.type == "migration" then
                if request.migration_policy ~= "leave" then
                    return transaction.failure("UNAVAILABLE", "checking or reverting package migrations needs the host migration runner binding")
                end
            end
        end
    end
    local changes, changes_error = baseline:changes()
    if not changes then return transaction.failure("UNAVAILABLE", tostring(changes_error)) end
    local data: {[string]: unknown} = {component = request.component, version = request.version}
    -- Empty Lua tables encode as objects; omit the optional native slice when
    -- no bindings are supplied.
    if #request.parameters > 0 then data.parameters = request.parameters end
    local entry = {id = displayed.root_id, kind = "ns.dependency", dependency_root = true, data = data}
    local staged, stage_error
    if request.action == "install" then staged, stage_error = changes:create(entry)
    elseif request.action == "update" then staged, stage_error = changes:update(entry)
    else staged, stage_error = changes:delete(displayed.root_id) end
    if not staged then return transaction.failure("FAILED", tostring(stage_error)) end
    local expected: {ExpectedModule} = {}
    for _, item in ipairs(displayed.modules) do
        expected[#expected + 1] = {component = item.component, version = item.version, change = item.change}
    end
    local receipt: Receipt = {actor_id = actor:id(), digest = measured, request_digest = request_digest, component = request.component, action = request.action,
        baseline_revision = displayed.base_revision, state = "published", message = "", expected_modules = expected}
    local recorded, record_error = changes:create({id = receipt_id(measured), kind = "registry.entry", data = receipt})
    if not recorded then return transaction.failure("FAILED", tostring(record_error)) end
    local applied, apply_error = changes:apply()
    if not applied then return transaction.failure("FAILED", tostring(apply_error)) end
    local actual, inventory_error = inventory.read()
    local mismatch: string? = inventory_error
    if actual then mismatch = verify(expected, actual)
    else mismatch = inventory_error or "cannot verify installed module inventory" end
    if mismatch then
        receipt.state, receipt.message = "recovery_required", mismatch
        local current = registry.snapshot()
        if current and current:version():id() == applied:id() then
            local restored, restore_error = registry.apply_version(baseline:version())
            if restored then receipt.state = "failed"; receipt.message = mismatch .. "; registry restored to baseline"
            else receipt.message = mismatch .. "; registry restore failed: " .. tostring(restore_error) end
        else receipt.message = mismatch .. "; registry changed after publication; review recovery" end
        return save(receipt)
    end
    receipt.state, receipt.message = "complete", "Dependency root " .. request.action .. " completed"
    return save(receipt)
end
return M
