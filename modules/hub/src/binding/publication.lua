-- MIT. Private dependency-root publication using existing registry APIs.
-- The worker serializes Bee Hub operations; other registry writers still
-- require revalidation and can prevent automatic baseline restoration.
local registry = require("registry")
local security = require("security")
local bounds = require("bounds")
local plan = require("plan")
local catalog = require("catalog")
local inspect = require("inspect")
local inspection = require("inspection")
local transaction = require("transaction")
local inventory = require("inventory")
local inventory_reader = require("inventory_reader")
local canonical = require("canonical")
local hash = require("hash")
local migration_runner = require("migration_runner")
local migrations = require("migrations")
local migration_work = require("migration_work")
local M = {}
type Result = transaction.Result
type ExpectedModule = {component: string, version: string, change: string}
type Removal = {root_digest: string, before_modules: {ExpectedModule}, published: boolean}
type Receipt = {actor_id: string, digest: string, request_digest: string?, component: string, state: string,
    baseline_revision: integer, message: string, action: string, expected_modules: {ExpectedModule}?,
    migration_work: migration_work.Work?, request: {[string]: unknown}?, removal: Removal?}

local function receipt_id(digest: string): string return "bee.hub.operations:" .. digest end
local function digest(raw: unknown): string?
    if type(raw) ~= "string" or #raw ~= 64 or not raw:match("^[0-9a-f]+$") then return nil end
    return raw
end
local function source(): {versions: (string, integer) -> ({string}?, boolean?, string?),
    artifact: (string, string) -> (inspection.Inspection?, string?)}
    return {versions = catalog.available,
        artifact = function(component: string, version: string): (inspection.Inspection?, string?)
            -- Dependency planning reads every entry payload, so it walks all
            -- summary pages with data explicitly; agent-facing reads stop at
            -- the first summary page.
            local collected: {inspection.Entry} = {}
            local offset: integer? = 0
            local head: inspection.Inspection? = nil
            while offset ~= nil do
                local page, problem = inspect.read({component = component, version = version,
                    include_data = true, entry_offset = offset, entry_limit = inspection.MAX_ENTRIES_PER_PAGE})
                if not page then return nil, problem end
                head = head or page
                for _, entry in ipairs(page.entries) do collected[#collected + 1] = entry end
                if #collected > 4096 then return nil, "artifact entry count exceeds planning bound" end
                offset = page.next_offset
            end
            if not head then return nil, "artifact inspection returned no pages" end
            return {component = head.component, version = head.version, digest = head.digest,
                requirements = head.requirements, entries = collected, next_offset = nil, eof = true}, nil
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

local function request_value(request: plan.Request): {[string]: unknown}
    local result: {[string]: unknown} = {action = request.action, component = request.component,
        migration_policy = request.migration_policy}
    if request.action ~= "uninstall" then result.version, result.parameters = request.version, request.parameters end
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
    local work = value.migration_work ~= nil and migration_work.decode(value.migration_work) or nil
    if value.migration_work ~= nil and not work then return nil end
    local request: {[string]: unknown}? = nil
    if value.request ~= nil then
        local decoded = plan.decode(value.request)
        if not decoded or decoded.action ~= action or decoded.component ~= component then return nil end
        local encoded = canonical.encode(decoded)
        if not encoded or hash.sha256(encoded) ~= request_digest then return nil end
        request = request_value(decoded)
    end
    local removal: Removal? = nil
    if value.removal ~= nil then
        local supplied = bounds.object(value.removal)
        if not supplied or bounds.fields(supplied, {"root_digest", "before_modules", "published"}) then return nil end
        local root_digest = digest(supplied.root_digest)
        local before = expected_modules(supplied.before_modules)
        if not root_digest or not before or type(supplied.published) ~= "boolean" or not work
            or not request or request.action ~= "uninstall" or request.migration_policy ~= "down" then return nil end
        for _, item in ipairs(before) do if item.change ~= "keep" or item.version == "" then return nil end end
        removal = {root_digest = root_digest, before_modules = before, published = supplied.published}
    end
    return {actor_id = actor, digest = measured, request_digest = request_digest, component = component, state = state,
        baseline_revision = baseline, message = message, action = action, expected_modules = expected, migration_work = work, request = request, removal = removal}
end

function M.status(raw: unknown, options: unknown?): Result
    local measured = digest(raw)
    if raw ~= nil and not measured then return transaction.failure("INVALID", "invalid plan digest") end
    local actor = security.actor()
    if not actor then return transaction.failure("DENIED", "authenticated installer required") end
    local snapshot, problem = registry.snapshot()
    if not snapshot then return transaction.failure("UNAVAILABLE", tostring(problem)) end
    if not measured then
        local request = bounds.object(options == nil and {} or options)
        if not request or bounds.fields(request, {"page"}) then return transaction.failure("INVALID", "invalid operation history request") end
        local page: integer = 1
        if request.page ~= nil then
            local decoded_page = bounds.count(request.page)
            if not decoded_page or decoded_page < 1 or decoded_page > 10000 then
                return transaction.failure("INVALID", "invalid operation history page")
            end
            page = decoded_page
        end
        local state, state_error = snapshot:state()
        if not state then return transaction.failure("UNAVAILABLE", tostring(state_error)) end
        local owned: {Receipt} = {}
        for _, item in ipairs(state.entries) do
            if item.id:sub(1, 19) == "bee.hub.operations:" then
                local data = bounds.object(item.data)
                if data and data.actor_id == actor:id() then
                    local receipt = decode_receipt(data)
                    if not receipt or item.id ~= receipt_id(receipt.digest) then return transaction.failure("INTERNAL", "invalid owned Hub operation receipt") end
                    owned[#owned + 1] = receipt
                end
            end
        end
        table.sort(owned, function(a: Receipt, b: Receipt): boolean
            if a.baseline_revision ~= b.baseline_revision then return a.baseline_revision > b.baseline_revision end
            return a.digest < b.digest
        end)
        local selected: {Receipt} = {}
        local first = (page - 1) * 25 + 1
        for index = first, math.min(#owned, first + 24) do selected[#selected + 1] = owned[index] end
        return transaction.success({operations = selected, page = page, total = #owned, page_size = 25}, false)
    end
    local entry = snapshot:get(receipt_id(measured))
    if not entry then return transaction.failure("NOT_FOUND", "no published operation for this plan") end
    local receipt = decode_receipt(entry.data)
    if not receipt or receipt.digest ~= measured then return transaction.failure("INTERNAL", "invalid Hub operation receipt") end
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

local function root_digest(raw: unknown): string?
    local entry = bounds.object(raw)
    if not entry or entry.kind ~= "ns.dependency" then return nil end
    local encoded = canonical.encode({id = entry.id, kind = entry.kind, data = entry.data})
    return encoded and hash.sha256(encoded) or nil
end

local function incomplete_removal(receipt: Receipt, message: string): Result
    receipt.state, receipt.message = "recovery_required", message
    return save(receipt)
end

-- The receipt exists before any down function executes. Root removal and its
-- published flag commit together, so restart never reruns functions whose
-- definitions or database resource have already been removed.
local function remove_with_migrations(receipt: Receipt): Result
    local removal, work, expected = receipt.removal, receipt.migration_work, receipt.expected_modules
    if not removal or not work or not expected then return transaction.failure("INTERNAL", "missing removal recovery evidence") end
    local root_id, root_error = plan.root_id(receipt.component)
    if not root_id then return incomplete_removal(receipt, tostring(root_error)) end
    local snapshot, snapshot_error = registry.snapshot()
    if not snapshot then return transaction.failure("UNAVAILABLE", tostring(snapshot_error)) end
    local state, state_error = snapshot:state()
    if not state then return incomplete_removal(receipt, tostring(state_error)) end
    local actual, inventory_error = inventory.decode(state, snapshot:version():id())
    if not actual then return incomplete_removal(receipt, tostring(inventory_error)) end
    if removal.published then
        local mismatch = snapshot:get(root_id) and "removed dependency root is present" or verify(expected, actual)
        if mismatch then return incomplete_removal(receipt, mismatch) end
        receipt.state, receipt.message = "complete", "Migration rollback and dependency removal completed"
        return save(receipt)
    end
    if root_digest(snapshot:get(root_id)) ~= removal.root_digest then return incomplete_removal(receipt, "dependency root changed before removal") end
    local mismatch = verify(removal.before_modules, actual)
    if mismatch then return incomplete_removal(receipt, "installed inventory changed before removal: " .. mismatch) end
    local unchanged, definition_error = migration_work.verify(work, state)
    if not unchanged then return incomplete_removal(receipt, tostring(definition_error)) end
    local entries = migration_work.entries(work)
    local allowed, grant_error = migration_runner.allowed(entries)
    if not allowed then return incomplete_removal(receipt, grant_error or "migration permissions changed") end
    local ids: {string}, components: {string} = {}, {}
    local seen: {[string]: boolean} = {}
    for _, entry in ipairs(work.entries) do
        ids[#ids + 1] = entry.id
        if not seen[entry.component] then components[#components + 1] = entry.component; seen[entry.component] = true end
    end
    local source = migration_runner.source(entries)
    local result, migration_error = migrations.execute(source, {operation = "down", entry_ids = ids, components = components})
    if result then receipt.migration_work = {entries = work.entries, rows = result.rows, databases = work.databases, ledger_checked = work.ledger_checked} end
    if migration_error then return incomplete_removal(receipt, migration_error) end
    -- Recheck after package functions have run, before deleting definitions.
    local current, current_error = registry.snapshot()
    if not current then return incomplete_removal(receipt, tostring(current_error)) end
    local observed, observed_error = current:state()
    if not observed then return incomplete_removal(receipt, tostring(observed_error)) end
    local inventory_now, read_error = inventory.decode(observed, current:version():id())
    if not inventory_now then return incomplete_removal(receipt, tostring(read_error)) end
    if root_digest(current:get(root_id)) ~= removal.root_digest then return incomplete_removal(receipt, "dependency root changed during rollback") end
    mismatch = verify(removal.before_modules, inventory_now)
    if mismatch then return incomplete_removal(receipt, "installed inventory changed during rollback: " .. mismatch) end
    unchanged, definition_error = migration_work.verify(work, observed)
    if not unchanged then return incomplete_removal(receipt, tostring(definition_error)) end
    for _, entry in ipairs(work.entries) do
        local applied, ledger_error = source.is_applied(entry.target_db, entry.id)
        if applied == nil then return incomplete_removal(receipt, ledger_error or "cannot verify rollback ledger") end
        if applied then return incomplete_removal(receipt, "migration remains applied: " .. entry.id) end
    end
    local changes, change_error = current:changes()
    if not changes then return incomplete_removal(receipt, tostring(change_error)) end
    local removed, remove_error = changes:delete(root_id)
    if not removed then return incomplete_removal(receipt, tostring(remove_error)) end
    removal.published, receipt.state, receipt.message = true, "published", "Migration rollback completed; dependency removal published"
    local recorded, record_error = changes:update({id = receipt_id(receipt.digest), kind = "registry.entry", data = receipt})
    if not recorded then removal.published = false; return incomplete_removal(receipt, tostring(record_error)) end
    local published, publish_error = changes:apply()
    if not published then return transaction.failure("UNCERTAIN", tostring(publish_error)) end
    -- Schema has changed: never restore an earlier registry version here.
    return remove_with_migrations(receipt)
end

-- Work is captured in the publication receipt before any package function
-- runs. After interruption, exact definitions and ledger state are checked
-- again under current host permissions.
local function migrate(receipt: Receipt): Result
    local work = receipt.migration_work
    if not work then return save(receipt) end
    local snapshot, snapshot_error = registry.snapshot()
    local state, state_error
    if snapshot then state, state_error = snapshot:state() end
    local verified, verify_error = migration_work.verify(work, state)
    if not verified then
        receipt.state = "recovery_required"
        receipt.message = tostring(snapshot_error or state_error or verify_error)
        return save(receipt)
    end
    local entries = migration_work.entries(work)
    local allowed, grant_error = migration_runner.allowed(entries)
    if not allowed then
        receipt.state, receipt.message = "recovery_required", grant_error or "migration permissions changed"
        return save(receipt)
    end
    if work.databases and not work.ledger_checked then
        local targets: {[string]: boolean} = {}
        for _, database in ipairs(work.databases) do if database.new then targets[database.id] = true end end
        local readable = migration_runner.source(entries)
        for _, entry in ipairs(work.entries) do
            if targets[entry.target_db] then
                local applied, ledger_error = readable.is_applied(entry.target_db, entry.id)
                if applied == nil or applied then
                    receipt.state = "recovery_required"
                    receipt.message = ledger_error or "new database already records migration " .. entry.id .. "; review existing schema"
                    return save(receipt)
                end
            end
        end
        -- Commit the empty-ledger evidence before any package function runs.
        -- A restart before this checkpoint repeats only the read, never an up.
        receipt.migration_work = {entries = work.entries, rows = work.rows, databases = work.databases, ledger_checked = true}
        receipt.state, receipt.message = "published", "New database ledger checked; migrations have not started"
        local recorded = save(receipt)
        if not recorded.ok then return recorded end
        return migrate(receipt)
    end
    local ids: {string}, components: {string} = {}, {}
    local seen: {[string]: boolean} = {}
    for _, entry in ipairs(work.entries) do
        ids[#ids + 1] = entry.id
        if not seen[entry.component] then
            seen[entry.component] = true
            components[#components + 1] = entry.component
        end
    end
    local result, problem = migrations.execute(migration_runner.source(entries),
        {operation = "up", entry_ids = ids, components = components})
    if result then work.rows = result.rows end
    receipt.state = problem and "recovery_required" or "complete"
    receipt.message = problem or "Dependency change and selected migrations completed"
    -- Never restore registry definitions after migration execution: schema
    -- transactions and registry publication are separate commits.
    return save(receipt)
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
    local result = mismatch and save(receipt) or migrate(receipt)
    result.replayed = true
    return result
end

-- Called only inside the named publication worker after facade authorization.
function M.apply(raw: unknown, expected: unknown): Result
    if not security.can("bee.hub.execute", "bee.hub.service:worker") then return transaction.failure("DENIED", "Hub worker authority required") end
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
        if receipt.removal and (receipt.state == "published" or receipt.state == "recovery_required") then
            local resumed = remove_with_migrations(receipt)
            resumed.replayed = true
            return resumed
        end
        if receipt.state == "published" or (receipt.state == "recovery_required" and receipt.migration_work ~= nil) then
            return reconcile(receipt, decoded)
        end
        previous.replayed = true
        return previous
    end
    if previous.code ~= "NOT_FOUND" then return previous end
    local prepared, prepare_error = M.prepare(raw)
    if not prepared then return transaction.failure("INVALID", prepare_error or "cannot prepare installation") end
    local displayed = prepared.plan
    if displayed.digest ~= measured then return transaction.failure("STALE", "the install plan changed; refresh and confirm it again") end
    if not displayed.ready then return transaction.failure("INCOMPLETE", "fill the missing package requirements") end
    local baseline, baseline_error = registry.snapshot()
    if not baseline then return transaction.failure("UNAVAILABLE", tostring(baseline_error)) end
    if baseline:version():id() ~= displayed.base_revision then return transaction.failure("STALE", "registry changed while preparing the operation") end
    local request = displayed.request
    local work: migration_work.Work? = nil
    if request.migration_policy == "up" and #displayed.migrations > 0 then
        local captured, capture_error = migration_work.capture(prepared)
        if not captured then return transaction.failure("INVALID", capture_error or "cannot capture migration work") end
        local entries = migration_work.entries(captured)
        local allowed, grant_error = migration_runner.allowed(entries)
        if not allowed then return transaction.failure("DENIED", grant_error or "host migration grants required") end
        local state, state_error = baseline:state()
        if not state then return transaction.failure("UNAVAILABLE", tostring(state_error)) end
        local deferred, database_error = migration_work.capture_databases(captured, prepared, state)
        if not deferred then return transaction.failure("UNAVAILABLE", database_error or "cannot capture new migration databases") end
        captured = deferred
        local new_targets: {[string]: boolean} = {}
        for _, database in ipairs(captured.databases or {}) do if database.new then new_targets[database.id] = true end end
        local readable = migration_runner.source(entries)
        for _, entry in ipairs(captured.entries) do
            if not new_targets[entry.target_db] then
                local applied, ledger_error = readable.is_applied(entry.target_db, entry.id)
                if applied == nil then return transaction.failure("UNAVAILABLE", ledger_error or "cannot read migration ledger") end
                if applied then
                    local unchanged, change_error = migration_work.verify({entries = {entry}, rows = {}}, state)
                    if not unchanged then
                        return transaction.failure("BLOCKED", "already-applied migration definition differs: " .. entry.id .. "; " .. tostring(change_error))
                    end
                end
            end
        end
        work = captured
    end
    -- Removing a root can also remove its orphaned dependencies. Check every
    -- removed owner, not only the root selected in the UI.
    local removed: {[string]: boolean} = {}
    for _, item in ipairs(displayed.modules) do
        if item.change == "remove" then removed[item.component] = true end
    end
    if next(removed) and request.migration_policy ~= "leave" then
        local state, state_error = baseline:state()
        if not state then return transaction.failure("UNAVAILABLE", tostring(state_error)) end
        local selected: {migrations.Entry} = {}
        for _, entry in ipairs(state.entries) do
            local owner = entry.registry and entry.registry.owner
            if type(owner) == "string" and removed[owner] and entry.meta and entry.meta.type == "migration" then
                selected[#selected + 1] = {id = entry.id, meta = entry.meta, registry = entry.registry}
            end
        end
        if #selected > 0 and request.migration_policy == "down" then
            local captured, capture_error = migration_work.capture_removed(state, removed)
            if not captured then return transaction.failure("INVALID", capture_error or "missing removal migrations") end
            local allowed, grant_error = migration_runner.allowed(migration_work.entries(captured))
            if not allowed then return transaction.failure("DENIED", grant_error or "host migration grants required") end
            local measured_root = root_digest(baseline:get(displayed.root_id))
            if not measured_root then return transaction.failure("STALE", "dependency root is unavailable") end
            local before, inventory_error = inventory.decode(state, baseline:version():id())
            if not before then return transaction.failure("UNAVAILABLE", tostring(inventory_error)) end
            local before_modules: {ExpectedModule}, expected: {ExpectedModule} = {}, {}
            for _, item in ipairs(before.modules) do before_modules[#before_modules + 1] = {component = item.component, version = item.version, change = "keep"} end
            for _, item in ipairs(displayed.modules) do expected[#expected + 1] = {component = item.component, version = item.version, change = item.change} end
            local receipt: Receipt = {actor_id = actor:id(), digest = measured, request_digest = request_digest,
                component = request.component, action = request.action, baseline_revision = displayed.base_revision,
                state = "recovery_required", message = "Rollback prepared; dependency root remains installed",
                expected_modules = expected, migration_work = captured, request = request_value(request),
                removal = {root_digest = measured_root, before_modules = before_modules, published = false}}
            local recorded = save(receipt)
            if not recorded.ok then return recorded end
            return remove_with_migrations(receipt)
        end
        local readable = migration_runner.source(selected)
        for _, entry in ipairs(selected) do
            local target = bounds.id(entry.meta.target_db)
            if not target then return transaction.failure("INVALID", "migration has no resolved database: " .. entry.id) end
            local applied, ledger_error = readable.is_applied(target, entry.id)
            if applied == nil then return transaction.failure("UNAVAILABLE", ledger_error or "cannot check migration ledger") end
            if applied then
                return transaction.failure("BLOCKED", "applied migration prevents removal: " .. entry.id .. "; select leave or revert explicitly")
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
        baseline_revision = displayed.base_revision, state = "published", message = "", expected_modules = expected, migration_work = work, request = request_value(request)}
    local recorded, record_error = changes:create({id = receipt_id(measured), kind = "registry.entry", data = receipt})
    if not recorded then return transaction.failure("FAILED", tostring(record_error)) end
    local applied, apply_error = changes:apply()
    if not applied then return transaction.failure("FAILED", tostring(apply_error)) end
    local actual, inventory_error = inventory_reader.read()
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
    return migrate(receipt)
end
return M
