-- SPDX-License-Identifier: MIT
local io = require("io")
local json = require("json")
local placement = require("placement")
local request = require("request")
local types = require("types")
local preparers = require("preparers")
local sync = require("sync")
local persist = require("persist")
local gateway_migrations = require("gateway_migrations")
local resource_migrations = require("resource_migrations")
local credential_migrations = require("credential_migrations")
local bindings = require("bindings")
local surfaces = require("surfaces")
local bounds = require("bounds")
local M = {}
local ATTEMPT = "layout-attempt"
local SUBJECT = "bee.layout.fixture"
local OPAQUE = "bee.git_worktree:cleanup"
local function gateway(): sql.DB
    return assert(persist.open({resource = "bee.gateway.env:db", ledger = {table = "bee_gateway_schema_migrations", label = "gateway"}, migrations = gateway_migrations.all()}))
end
local function resource_owners()
    local db = assert(persist.open({resource = "bee.resources.env:db", ledger = {table = "bee_resource_schema_migrations", label = "resource"}, migrations = resource_migrations.all()}))
    db:release()
    db = assert(persist.open({resource = "bee.credentials.env:db", ledger = {table = "bee_credential_schema_migrations", label = "credential"}, migrations = credential_migrations.all()}))
    db:release()
end
function M.seed()
    local registry = require("registry")
    for _, id in ipairs({"bee.git.worktree.binding:binding", "bee.git.worktree.binding:plan",
        "bee.git.worktree.binding:setup", "bee.git.worktree.binding:cleanup",
        "bee.driver.codex.binding:binding", "bee.threads.binding:delivery_claim"}) do
        assert(registry.get(id), "seed reference is not callable: " .. id)
    end
    resource_owners()
    local db = assert(placement.open())
    local launch: types.LaunchRequest = {
        idempotency_key = "layout-attempt-key", owner_id = SUBJECT, owner_incarnation = 1,
        action_id = "layout-action", attempt_id = ATTEMPT, binding_ref = "bee.driver.codex.binding:binding",
        policy_ref = "bee.layout.fixture:policy", profile_id = "session",
        binding_digest = string.rep("c", 64), profile_digest = string.rep("c", 64),
        launch = {executable = "fixture", argv = {"fixture"}, environment = {}, readiness = "protocol:system.init"},
        resources = {}, environment = {}, environment_refs = {}, projections = {},
        required_cleanup = "direct_process", required_exit_observation = "eof_gated",
        timeouts = {stop_grace_ms = 500, drain_ms = 1000, retain_ms = 1000},
    }
    local intended = placement.intend(db, launch, assert(request.digest(launch)), assert(json.encode(launch)),
        {capability = "direct_process", exit_observation = "eof_gated"})
    assert(intended.ok, intended.message)
    assert(placement.record_preparer_plan(db, ATTEMPT, "bee.git.worktree.binding:binding", assert(json.encode({
        binding_id = "bee.git.worktree.binding:binding", plan = "bee.git.worktree.binding:plan",
        setup = "bee.git.worktree.binding:setup", cleanup = "bee.git.worktree.binding:cleanup", state = {token = OPAQUE},
    }))) == nil)
    local exited = placement.transition(db, ATTEMPT, {execution = "exited", fields = {exit_source = "runner"},
        evidence = {kind = "workdir_preparer.cleaned", detail = "bee.git.worktree.binding:binding"}})
    assert(exited.ok, exited.message)
    db:release()
    local projection = assert(sync.open({resource = "bee.sync.env:db", owner = SUBJECT}))
    local written = projection:append({feed = "layout", event_id = "layout-event", idempotency_key = "layout-event-key",
        event_type = "layout.references", projection_key = "references", expected_revision = 0,
        projection_value = {driver_binding = "bee.driver.codex.binding:binding", binding = "bee.git.worktree.binding:binding", method = "bee.threads.binding:delivery_claim", opaque = OPAQUE .. ":instance", owner_ref = {node_id = "node", service_id = "bee.hive.telemetry.binding"}},
        payload = {method = "bee.threads.binding:delivery_claim"}})
    assert(written.ok, written.message)
    assert(projection:close())
    db = gateway()
    local tx = assert(db:begin())
    local inserted, insert_error = bindings.insert(tx, "layout-binding", SUBJECT, "layout-action", ATTEMPT, "layout-thread",
        1, 1, "[]", "[]", 1, "2000-01-01T00:00:00.000Z", "layout-binding-key", string.rep("c", 64),
        "2000-01-01T00:00:00.000Z", "bee.layout.fixture:policy", "layout-workspace", "layout", "{}")
    assert(inserted, insert_error)
    local surface, surface_error = surfaces.initialize(tx, "layout-binding",
        assert(json.encode({driver_binding = "bee.driver.codex.binding:binding", target = "bee.git.worktree.binding:binding", method = "bee.threads.binding:delivery_claim"})),
        assert(json.encode({method = "bee.threads.binding:delivery_claim"})), "{}")
    assert(surface, surface_error and surface_error.message)
    assert(tx:commit())
    db:release()
    io.print("LAYOUT_SEEDED_THROUGH_OWNER_STORES")
end
function M.verify()
    resource_owners()
    local db = assert(placement.open())
    local plans = assert(placement.preparer_plans(db, ATTEMPT))
    assert(#plans == 1 and plans[1].binding_id == "bee.git.worktree.binding:binding")
    local record = assert(bounds.object(json.decode(plans[1].record_json)))
    assert(record.plan == "bee.git.worktree.binding:plan" and record.setup == "bee.git.worktree.binding:setup"
        and record.cleanup == "bee.git.worktree.binding:cleanup")
    local state = assert(bounds.object(record.state))
    assert(state.token == OPAQUE)
    local row = assert(placement.row(db, ATTEMPT))
    local retained = assert(bounds.object(json.decode(assert(bounds.text(row.request_json, 65536)))))
    assert(retained.binding_ref == "bee.driver.codex.binding:binding")
    local attempt = assert(placement.attempt(db, ATTEMPT))
    db:release()
    local cleaned, cleanup_error = preparers.cleanup(attempt)
    assert(cleaned, cleanup_error)
    local projection = assert(sync.open({resource = "bee.sync.env:db", owner = SUBJECT}))
    local stored = projection:projection("layout", "references")
    assert(stored.ok, stored.message)
    local value = assert(bounds.object(assert(bounds.object(stored.value)).value))
    assert(value.binding == "bee.git.worktree.binding:binding" and value.method == "bee.threads.binding:delivery_claim")
    assert(value.driver_binding == "bee.driver.codex.binding:binding")
    assert(value.opaque == OPAQUE .. ":instance")
    assert(assert(bounds.object(value.owner_ref)).service_id == "bee.hive.telemetry.binding")
    assert(projection:close())
    db = gateway()
    local tx = assert(db:begin())
    local stored, store_error = surfaces.read(tx, "layout-binding")
    local saved = assert(stored, store_error and store_error.message)
    local surface = assert(bounds.object(json.decode(saved.surface_json)))
    local active = assert(bounds.object(json.decode(saved.active_json)))
    assert(surface.target == "bee.git.worktree.binding:binding" and surface.method == "bee.threads.binding:delivery_claim")
    assert(surface.driver_binding == "bee.driver.codex.binding:binding")
    assert(active.method == surface.method)
    assert(tx:commit())
    db:release()
    io.print("LAYOUT_MIGRATIONS_RECOVERED_OWNER_DATA_AND_CLEANUP")
end
return M
