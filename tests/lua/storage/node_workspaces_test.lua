-- MIT. One node database holds many logical workspaces as keyed rows.
local test = require("test")
local sql = require("sql")
local store = require("store")
local catalog = require("catalog")
local binding = require("binding")
local assignments = require("assignments")
local thread_bindings = require("thread_bindings")
local legacy_schema = require("legacy_schema")

local NODE = "bee.workspace.db:node_test"

local function open(resource: string, selection: unknown): store.Store
    local handle, err = store.open(resource, selection)
    if not handle then error("open workspace: " .. tostring(err)) end
    return handle
end

-- Insert one catalog row in its own transaction; a fault returns its code.
local function insert(label: string, root_ref: string, subpath: string): (string?, string?)
    local db, open_error = store.database(NODE)
    if not db then error("open node database: " .. tostring(open_error)) end
    local tx, begin_error = db:begin()
    if not tx then db:release(); error("begin: " .. tostring(begin_error)) end
    local row, failure = catalog.insert(tx, {label = label, root_ref = root_ref, subpath = subpath})
    if not row then
        tx:rollback(); db:release()
        return nil, failure and failure.code or "STORAGE"
    end
    local _, commit_error = tx:commit()
    db:release()
    if commit_error then error("commit: " .. tostring(commit_error)) end
    return row.workspace_id, nil
end

local function created(label: string, root_ref: string, subpath: string): string
    local id, code = insert(label, root_ref, subpath)
    if not id then error("create workspace: " .. tostring(code)) end
    return id
end

local function binding_request(instance_id: string, key: string): {[string]: unknown}
    return {instance_id = instance_id, thread_id = "thread-" .. instance_id, definition_id = "bee.settings:app",
        actor_id = "actor-" .. instance_id, role = "participant", idempotency_key = key,
        definition_revision = "rev-1", initiating_owner_id = "owner", gateway_binding_id = "binding",
        gateway_approval_id = "approval", gateway_proposal_digest = string.rep("a", 64), access = "observe_post",
        join_expected_revision = 1}
end

local function query(resource: string, statement: string, params: {unknown}?): {{[string]: unknown}}
    local db = assert(sql.get(resource))
    local rows, err = db:query(statement, params or {})
    db:release()
    if not rows then error(tostring(err)) end
    return rows
end

local function execute(resource: string, statement: string, params: {unknown}?)
    local db = assert(sql.get(resource))
    local _, err = db:execute(statement, params or {})
    db:release()
    if err then error(tostring(err)) end
end

local function define_tests()
    test.describe("Node workspace catalog", function()
        test.it("serves the classic folder workspace by its root and by its identity", function()
            local classic = open(NODE, binding.classic())
            local id = assert(classic:identity())
            test.eq(#id, 32)
            local by_id = open(NODE, {workspace_id = id})
            test.eq(assert(by_id:identity()), id)
            local again = open(NODE, binding.classic())
            test.eq(assert(again:identity()), id)
            for _, handle in ipairs({classic, by_id, again}) do assert(handle:close()) end
            local rows = query(NODE, "SELECT label, root_ref, subpath, state FROM workspaces WHERE workspace_id = ?", {id})
            test.eq(#rows, 1)
            test.eq(rows[1].root_ref, "bee:workspace_root")
            test.eq(rows[1].subpath, "")
            test.eq(rows[1].state, "active")
        end)

        test.it("refuses selections that name no active catalog row", function()
            local _, invalid = store.open(NODE, {workspace_id = "not-an-id"})
            test.contains(tostring(invalid), "Invalid workspace selection")
            local _, ambiguous = store.open(NODE, {workspace_id = string.rep("a", 32), root_ref = "bee:workspace_root", subpath = ""})
            test.contains(tostring(ambiguous), "Invalid workspace selection")
            local _, missing = store.open(NODE, nil)
            test.contains(tostring(missing), "Invalid workspace selection")
            local _, unknown = store.open(NODE, {workspace_id = string.rep("0", 32)})
            test.contains(tostring(unknown), "not in the node catalog")
            local _, escaped = store.open(NODE, {root_ref = "bee:workspace_root", subpath = "../other"})
            test.contains(tostring(escaped), "Invalid workspace selection")
            local archived = created("archived", "bee.storage.test:archived_root", "")
            execute(NODE, "UPDATE workspaces SET state = 'archived' WHERE workspace_id = ?", {archived})
            local _, inactive = store.open(NODE, {workspace_id = archived})
            test.contains(tostring(inactive), "not active")
        end)

        test.it("gives one root exactly one workspace", function()
            local first = created("project", "bee.storage.test:projects", "legacy/one")
            local _, duplicate = insert("again", "bee.storage.test:projects", "legacy/one")
            test.eq(duplicate, "CONFLICT")
            local handle = open(NODE, {root_ref = "bee.storage.test:projects", subpath = "legacy/one"})
            test.eq(assert(handle:identity()), first)
            assert(handle:close())
        end)

        test.it("keeps each workspace's state apart in one node database", function()
            local left_id = created("left", "bee.storage.test:state", "left")
            local right_id = created("right", "bee.storage.test:state", "right")
            test.neq(left_id, right_id)
            local left = open(NODE, {workspace_id = left_id})
            local right = open(NODE, {workspace_id = right_id})
            test.is_nil(left:read())
            test.is_nil(right:read())
            assert(left:write('{"version":1,"owner":"left"}'))
            test.is_nil(right:read())
            assert(right:write('{"version":1,"owner":"right"}'))
            assert(left:write('{"version":1,"owner":"left-2"}'))
            test.eq(left:read(), '{"version":1,"owner":"left-2"}')
            test.eq(right:read(), '{"version":1,"owner":"right"}')
            -- A second handle on the right workspace is fenced only by the right
            -- workspace's generation; writes to the left never make it stale.
            local right_again = open(NODE, {workspace_id = right_id})
            assert(left:write('{"version":1,"owner":"left-3"}'))
            assert(right_again:write('{"version":1,"owner":"right-2"}'))
            local stale, stale_error = right:write('{"version":1,"owner":"stale"}')
            test.is_false(stale)
            test.contains(tostring(stale_error), "changed")
            test.eq(left:read(), '{"version":1,"owner":"left-3"}')
            local rows = query(NODE, "SELECT workspace_id, generation FROM workspace_state WHERE workspace_id IN (?, ?) ORDER BY generation",
                {left_id, right_id})
            test.eq(#rows, 2)
            for _, handle in ipairs({left, right, right_again}) do assert(handle:close()) end
        end)

        test.it("keys display assignments and transfer receipts by workspace", function()
            local left = open(NODE, {workspace_id = created("left", "bee.storage.test:displays", "left")})
            local right = open(NODE, {workspace_id = created("right", "bee.storage.test:displays", "right")})
            local left_displays = assert(assignments.open(left))
            local right_displays = assert(assignments.open(right))
            assert(left_displays:claim({view_id = "view", instance_id = "instance", display_id = "display-a"}))
            test.is_nil(right_displays:get({view_id = "view", instance_id = "instance"}))
            assert(right_displays:claim({view_id = "view", instance_id = "instance", display_id = "display-z"}))
            local move = {request_id = "move-1", view_id = "view", instance_id = "instance",
                source_display_id = "display-a", target_display_id = "display-b", expected_revision = 1}
            assert(left_displays:prepare(move))
            test.is_nil(right_displays:receipt("move-1"))
            local right_move = {request_id = "move-1", view_id = "view", instance_id = "instance",
                source_display_id = "display-z", target_display_id = "display-y", expected_revision = 1}
            test.eq((assert(right_displays:prepare(right_move))).target_display_id, "display-y")
            local committed = assert(left_displays:commit({request_id = "move-1", view_id = "view", instance_id = "instance"}))
            test.eq(committed.assignment.display_id, "display-b")
            local right_current = assert(right_displays:get({view_id = "view", instance_id = "instance"}))
            test.eq(right_current.assignment.display_id, "display-z")
            test.eq(right_current.intent and right_current.intent.phase, "prepared")
            test.eq(#(assert(left_displays:reconcile())), 1)
            test.eq(#(assert(right_displays:reconcile())), 1)
            assert(left:close()); assert(right:close())
        end)

        test.it("keys application thread bindings and their idempotency keys by workspace", function()
            local left = open(NODE, {workspace_id = created("left", "bee.storage.test:bindings", "left")})
            local right = open(NODE, {workspace_id = created("right", "bee.storage.test:bindings", "right")})
            local left_bindings = assert(thread_bindings.open(left))
            local right_bindings = assert(thread_bindings.open(right))
            assert(left_bindings:prepare(binding_request("instance", "open:instance")))
            test.is_nil(right_bindings:get("instance"))
            test.eq(#(assert(right_bindings:list())), 0)
            local mirrored = assert(right_bindings:prepare(binding_request("instance", "open:instance")))
            test.eq(mirrored.binding_revision, 1)
            assert(left_bindings:activate({instance_id = "instance", expected_revision = 1, expected_state = "pending", membership_revision = 3}))
            test.eq((assert(right_bindings:get("instance"))).state, "pending")
            test.eq((assert(left_bindings:get("instance"))).state, "active")
            assert(left:close()); assert(right:close())
        end)
    end)

    test.describe("Folder workspace composition", function()
        test.it("holds no workspace in a fresh node database until the folder is opened", function()
            local resource = "bee.workspace.db:fresh_test"
            local db, open_error = store.database(resource)
            if not db then error("open node database: " .. tostring(open_error)) end
            db:release()
            test.eq(#query(resource, "SELECT workspace_id FROM workspaces"), 0)
            test.eq(#query(resource, "SELECT id FROM workspace_schema_migrations"), 8)
            local classic = open(resource, binding.classic())
            local id = assert(classic:identity())
            assert(classic:close())
            local rows = query(resource, "SELECT workspace_id, label, root_ref, subpath, state FROM workspaces")
            test.eq(#rows, 1)
            test.eq(rows[1].workspace_id, id)
            test.eq(rows[1].label, "")
            test.eq(rows[1].root_ref, "bee:workspace_root")
            test.eq(rows[1].subpath, "")
            test.eq(rows[1].state, "active")
            local again = open(resource, binding.classic())
            test.eq(assert(again:identity()), id)
            assert(again:close())
            test.eq(#query(resource, "SELECT workspace_id FROM workspaces"), 1)
            -- A created folder row that goes missing is never minted again.
            execute(resource, "DELETE FROM workspaces WHERE workspace_id = ?", {id})
            local _, missing = store.open(resource, binding.classic())
            test.contains(tostring(missing), "not in the node catalog")
            test.eq(#query(resource, "SELECT workspace_id FROM workspaces"), 0)
        end)

        test.it("keeps the folder workspace of an upgraded node catalog", function()
            local resource = "bee.workspace.db:catalog_upgrade_test"
            local db = assert(sql.get(resource))
            assert(legacy_schema.build_catalog(db))
            db:release()
            local seeded = query(resource, "SELECT workspace_id FROM workspaces WHERE root_ref = 'bee:workspace_root' AND subpath = ''")
            test.eq(#seeded, 1)
            local migrated, open_error = store.database(resource)
            if not migrated then error("open node database: " .. tostring(open_error)) end
            migrated:release()
            test.eq(#query(resource, "SELECT id FROM workspace_schema_migrations"), 8)
            local kept = query(resource, "SELECT workspace_id FROM workspaces")
            test.eq(#kept, 1)
            test.eq(kept[1].workspace_id, seeded[1].workspace_id)
            local classic = open(resource, binding.classic())
            test.eq(assert(classic:identity()), seeded[1].workspace_id)
            assert(classic:close())
        end)
    end)

    test.describe("Single-workspace install upgrade", function()
        test.it("turns the existing identity into the classic catalog row with its state and rows", function()
            local resource = "bee.workspace.db:legacy_test"
            local db = assert(sql.get(resource))
            assert(legacy_schema.build(db))
            local identity = assert(db:query("SELECT workspace_id FROM workspace_identity WHERE singleton = 1"))[1].workspace_id
            assert(db:execute("INSERT INTO workspace_state VALUES (1, 1, 7, ?, 'before')", {'{"version":1,"probe":"legacy"}'}))
            assert(db:execute("INSERT INTO workspace_display_assignments VALUES ('view', 'instance', 'display-a', 4)"))
            assert(db:execute("INSERT INTO workspace_display_transfer_receipts VALUES ('move', 'view', 'instance', 'display-a', 'display-b', 4, 'prepared', NULL, 'before')"))
            assert(db:execute("INSERT INTO workspace_application_thread_bindings VALUES ('instance', 'thread', 'bee.settings:app', 'actor', 'participant', 2, 'active', 'key', 'rev', 'owner', 'binding', 'approval', ?, 'observe_post', 1, 5, 0, NULL)",
                {string.rep("b", 64)}))
            db:release()

            local classic = open(resource, binding.classic())
            test.eq(assert(classic:identity()), identity)
            test.eq(classic:read(), '{"version":1,"probe":"legacy"}')
            test.eq(classic.generation, 7)
            local displays = assert(assignments.open(classic))
            local current = assert(displays:get({view_id = "view", instance_id = "instance"}))
            test.eq(current.assignment.revision, 4)
            test.eq(current.intent and current.intent.request_id, "move")
            local bindings = assert(thread_bindings.open(classic))
            local bound = assert(bindings:get("instance"))
            test.eq(bound.state, "active")
            test.eq(bound.membership_revision, 5)
            assert(classic:write('{"version":1,"probe":"upgraded"}'))
            assert(classic:close())
            local ledger = query(resource, "SELECT id FROM workspace_schema_migrations ORDER BY id")
            test.eq(#ledger, 8)
            test.eq(#query(resource, "SELECT name FROM sqlite_master WHERE name = 'workspace_identity'"), 0)
            local reopened = open(resource, {workspace_id = identity})
            test.eq(reopened:read(), '{"version":1,"probe":"upgraded"}')
            assert(reopened:close())
        end)

        test.it("fails the upgrade instead of dropping state when the identity row is missing", function()
            local resource = "bee.workspace.db:corrupt_legacy_test"
            local db = assert(sql.get(resource))
            assert(legacy_schema.build(db))
            assert(db:execute("INSERT INTO workspace_state VALUES (1, 1, 3, ?, 'before')", {'{"version":1,"probe":"kept"}'}))
            assert(db:execute("DELETE FROM workspace_identity"))
            db:release()
            local handle, err = store.open(resource, binding.classic())
            test.is_nil(handle)
            test.contains(tostring(err), "apply workspace migration node_workspaces_v1")
            test.eq(#query(resource, "SELECT id FROM workspace_schema_migrations"), 5)
            local kept = query(resource, "SELECT generation, value FROM workspace_state")
            test.eq(#kept, 1)
            test.eq(kept[1].value, '{"version":1,"probe":"kept"}')
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
