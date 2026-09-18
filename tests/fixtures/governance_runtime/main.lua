-- MIT. Disposable registry only: demonstrate whether a reviewed snapshot is
-- an enforced publication precondition, with an intervening writer.
local registry = require("registry")
local logger = require("logger")

local function main()
    local reviewed, read_error = registry.snapshot()
    assert(reviewed, tostring(read_error))
    local first, first_error = reviewed:changes()
    assert(first, tostring(first_error))
    local staged, stage_error = first:update({
        id = "bee.governance_probe:subject", kind = "registry.entry",
        data = {value = "reviewed"},
    })
    assert(staged, tostring(stage_error))

    local intervening, intervening_error = reviewed:changes()
    assert(intervening, tostring(intervening_error))
    local prepared, prepare_error = intervening:update({
        id = "bee.governance_probe:subject", kind = "registry.entry",
        data = {value = "intervening"},
    })
    assert(prepared, tostring(prepare_error))
    local committed, commit_error = intervening:apply()
    assert(committed, tostring(commit_error))

    local stale_commit, stale_error = first:apply()
    if stale_commit then
        logger:error("GOVERNANCE_STALE_APPLY_ACCEPTED", {
            reviewed_version = reviewed:version():id(),
            intervening_version = committed:id(),
            stale_version = stale_commit:id(),
        })
        error("governance gate: durable apply accepted a stale reviewed snapshot")
    end
    assert(stale_error, "rejection must explain why publication failed")
    assert(stale_error:kind() == "Conflict", "stale apply must return a conflict")
    local current, current_error = registry.snapshot()
    assert(current, tostring(current_error))
    assert(current:version():id() == committed:id(), "rejected apply changed registry version")
    local subject, subject_error = current:get("bee.governance_probe:subject")
    assert(subject, tostring(subject_error))
    assert(type(subject.data) == "table" and subject.data.value == "intervening", "rejected apply changed the entry")
    logger:info("GOVERNANCE_STALE_APPLY_REFUSED")
end

return {main = main}
