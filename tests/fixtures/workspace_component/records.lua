-- MIT. Nonempty main-created owner records, reopened through extracted stores.
local store = require("store")
local catalog = require("catalog")
local assignments = require("assignments")
local thread_bindings = require("thread_bindings")
local logger = require("logger"):named("componentproof")

local function main(mode: string)
    local db = assert(store.database(nil))
    local tx = assert(db:begin())
    local workspace_id: string
    if mode == "seed" then
        local created, failure = catalog.insert(tx, {label = "Restore records", root_ref = "bee.env:workspace_root", subpath = "records"})
        if not created then error(failure and failure.message or "create restore workspace") end
        workspace_id = created.workspace_id
    else
        local page, failure = catalog.page(tx, {state = "active", order = "label", prefix = "Restore records", limit = 10})
        if not page then error(failure and failure.message or "open restore catalog") end
        assert(#page.items == 1)
        workspace_id = page.items[1].workspace_id
        local reopened, get_failure = catalog.get(tx, workspace_id)
        if not reopened then error(get_failure and get_failure.message or "open restore workspace") end
    end
    assert(tx:commit())
    assert(db:release())
    local workspace = assert(store.open(nil, {workspace_id = workspace_id}))
    local displays = assert(assignments.open(workspace))
    local bindings = assert(thread_bindings.open(workspace))
    if mode == "seed" then
        assert(displays:claim({view_id = "restore-view", instance_id = "restore-instance", display_id = "source-display"}))
        assert(displays:prepare({request_id = "restore-transfer", view_id = "restore-view", instance_id = "restore-instance",
            source_display_id = "source-display", target_display_id = "target-display", expected_revision = 1}))
        assert(displays:commit({request_id = "restore-transfer", view_id = "restore-view", instance_id = "restore-instance"}))
        assert(bindings:prepare({instance_id = "restore-instance", thread_id = "restore-thread", definition_id = "bee.settings.app:app",
            actor_id = "restore-actor", role = "participant", idempotency_key = "restore-open", definition_revision = "rev-1",
            initiating_owner_id = "restore-owner", gateway_binding_id = "restore-binding", gateway_approval_id = "restore-approval",
            gateway_proposal_digest = string.rep("a", 64), access = "observe_post", join_expected_revision = 1}))
        assert(bindings:activate({instance_id = "restore-instance", expected_revision = 1, expected_state = "pending", membership_revision = 3}))
    end
    local placement = assert(displays:get({view_id = "restore-view", instance_id = "restore-instance"}))
    assert(placement.assignment.display_id == "target-display" and placement.assignment.revision == 2)
    assert(#assert(displays:reconcile()) == 1)
    local receipt = assert(displays:receipt("restore-transfer"))
    assert(receipt.phase == "committed" and receipt.source_display_id == "source-display" and receipt.target_display_id == "target-display")
    local binding = assert(bindings:get("restore-instance"))
    assert(binding.state == "active" and binding.thread_id == "restore-thread" and binding.membership_revision == 3)
    assert(#assert(bindings:list()) == 1)
    assert(workspace:close())
    logger:info("RESTORE OWNER RECORDS OPENABLE")
end

return {main = main}
