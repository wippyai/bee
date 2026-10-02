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
local bindings = require("bindings")
local surfaces = require("surfaces")
local bounds = require("bounds")
local M = {}
local ATTEMPT = "layout-attempt"
local SUBJECT = "bee.layout.fixture"
local OPAQUE = "bee.git_worktree:cleanup"
local function gateway(): sql.DB
    return assert(persist.open({resource = "bee.gateway:db", ledger = {table = "bee_gateway_schema_migrations", label = "gateway"}, migrations = gateway_migrations.all()}))
end
function M.seed()
    local db = assert(placement.open())
    local launch: types.LaunchRequest = {
        idempotency_key = "layout-attempt-key", owner_id = SUBJECT, owner_incarnation = 1,
        action_id = "layout-action", attempt_id = ATTEMPT, binding_ref = "bee.driver.codex:binding",
        policy_ref = "bee.layout.fixture:policy", profile_id = "session",
        binding_digest = string.rep("c", 64), profile_digest = string.rep("c", 64),
        launch = {executable = "fixture", argv = {"fixture"}, environment = {}, readiness = "protocol:system.init"},
        resources = {}, environment = {}, environment_refs = {}, projections = {},
        required_cleanup = "direct_process", required_exit_observation = "eof_gated",
        timeouts = {start_ms = 10000, stop_grace_ms = 500, drain_ms = 1000, retain_ms = 1000},
    }
    local intended = placement.intend(db, launch, assert(request.digest(launch)), assert(json.encode(launch)),
        {capability = "direct_process", exit_observation = "eof_gated"})
    assert(intended.ok, intended.message)
    assert(placement.record_preparer_plan(db, ATTEMPT, "bee.git_worktree:binding", assert(json.encode({
        binding_id = "bee.git_worktree:binding", plan = "bee.git_worktree:plan",
        setup = "bee.git_worktree:setup", cleanup = "bee.git_worktree:cleanup", state = {token = OPAQUE},
    }))) == nil)
    local exited = placement.transition(db, ATTEMPT, {execution = "exited", fields = {exit_source = "runner"},
        evidence = {kind = "workdir_preparer.cleaned", detail = "bee.git_worktree:binding"}})
    assert(exited.ok, exited.message)
    db:release()
    local projection = assert(sync.open({resource = "bee.sync:db", owner = SUBJECT}))
    local written = projection:append({feed = "layout", event_id = "layout-event", idempotency_key = "layout-event-key",
        event_type = "layout.references", projection_key = "references", expected_revision = 0,
        projection_value = {binding = "bee.git_worktree:binding", method = "bee.threads.delivery:claim", opaque = OPAQUE .. ":instance"},
        payload = {method = "bee.threads.delivery:claim"}})
    assert(written.ok, written.message)
    assert(projection:close())
    db = gateway()
    local tx = assert(db:begin())
    local inserted, insert_error = bindings.insert(tx, "layout-binding", SUBJECT, "layout-action", ATTEMPT, "layout-thread",
        1, 1, "[]", "[]", 1, "2000-01-01T00:00:00.000Z", "layout-binding-key", string.rep("c", 64),
        "2000-01-01T00:00:00.000Z", "bee.layout.fixture:policy", "layout-workspace", "layout", "{}")
    assert(inserted, insert_error)
    local surface, surface_error = surfaces.initialize(tx, "layout-binding",
        assert(json.encode({target = "bee.git_worktree:binding", method = "bee.threads.delivery:claim"})),
        assert(json.encode({method = "bee.threads.delivery:claim"})), "{}")
    assert(surface, surface_error and surface_error.message)
    assert(tx:commit())
    db:release()
    io.print("LAYOUT_SEEDED_THROUGH_OWNER_STORES")
end
function M.verify()
    local db = assert(placement.open())
    local plans = assert(placement.preparer_plans(db, ATTEMPT))
    assert(#plans == 1 and plans[1].binding_id == "bee.git.worktree:binding")
    local record = assert(bounds.object(json.decode(plans[1].record_json)))
    assert(record.plan == "bee.git.worktree.binding:plan" and record.setup == "bee.git.worktree.binding:setup"
        and record.cleanup == "bee.git.worktree.binding:cleanup")
    local state = assert(bounds.object(record.state))
    assert(state.token == OPAQUE)
    local attempt = assert(placement.attempt(db, ATTEMPT))
    db:release()
    local cleaned, cleanup_error = preparers.cleanup(attempt)
    assert(cleaned, cleanup_error)
    local projection = assert(sync.open({resource = "bee.sync:db", owner = SUBJECT}))
    local stored = projection:projection("layout", "references")
    assert(stored.ok, stored.message)
    local value = assert(bounds.object(assert(bounds.object(stored.value)).value))
    assert(value.binding == "bee.git.worktree:binding" and value.method == "bee.threads.binding:delivery_claim")
    assert(value.opaque == OPAQUE .. ":instance")
    assert(projection:close())
    db = gateway()
    local tx = assert(db:begin())
    local stored, store_error = surfaces.read(tx, "layout-binding")
    local saved = assert(stored, store_error and store_error.message)
    local surface = assert(bounds.object(json.decode(saved.surface_json)))
    local active = assert(bounds.object(json.decode(saved.active_json)))
    assert(surface.target == "bee.git.worktree:binding" and surface.method == "bee.threads.binding:delivery_claim")
    assert(active.method == surface.method)
    assert(tx:commit())
    db:release()
    io.print("LAYOUT_MIGRATIONS_RECOVERED_OWNER_DATA_AND_CLEANUP")
end
return M
