-- MIT. Require an overlay review to fence the durable base it composes with.
-- A runtime that accepts the reviewed A change after the base moves is missing
-- the composed-base precondition, even when owner generation CAS works.
local registry = require("registry")
local logger = require("logger")
local OWNER = "bee.gov.overlay.composed.probe:owner"
local DEPENDENCY = "bee.gov.overlay.composed.probe:dependency"
local SUBJECT = "bee.gov.overlay.composed.probe:subject"

local function main()
    local base = registry.snapshot()
    assert(base)
    local dependency = base:get(DEPENDENCY)
    assert(dependency and type(dependency.data) == "table" and dependency.data.value == "base-v1",
        "review did not observe the original dependency")
    local reviewed, review_error = registry.overlay(OWNER)
    assert(reviewed, tostring(review_error))
    local reviewed_version = reviewed:version():id()
    assert(reviewed_version == base:version():id(), "review snapshots do not share the durable base")
    local candidate = reviewed:changes()
    assert(candidate)
    assert(candidate:create({
        id = SUBJECT,
        kind = "registry.entry",
        data = {dependency = DEPENDENCY, expected_value = dependency.data.value, value = "reviewed-against-base-v1"},
    }))

    local base_change = base:changes()
    assert(base_change)
    dependency.data = {value = "base-v2"}
    assert(base_change:update(dependency))
    local committed, base_error = base_change:apply()
    assert(committed, tostring(base_error))
    assert(committed:id() ~= reviewed_version, "intervening write did not advance the durable base")

    local applied, stale_error = candidate:apply()
    if applied then
        local effective = registry.snapshot()
        assert(effective)
        local subject = effective:get(SUBJECT)
        local current_dependency = effective:get(DEPENDENCY)
        assert(subject and type(subject.data) == "table" and subject.data.value == "reviewed-against-base-v1",
            "stale composed overlay acceptance changed no effective value")
        assert(current_dependency and type(current_dependency.data) == "table" and current_dependency.data.value == "base-v2",
            "intervening durable dependency update was lost")
        logger:error("GOVERNANCE_COMPOSED_BASE_STALE_ACCEPTED", {
            reviewed_version = reviewed_version,
            intervening_version = committed:id(),
            effective_value = subject.data.value,
            dependency_value = current_dependency.data.value,
        })
        error("governance gate: reviewed overlay accepted after composed durable base changed")
    end

    assert(stale_error, "composed-base refusal must explain why publication failed")
    assert(stale_error:kind() == "Conflict", "composed-base refusal must return Conflict")
    local effective = registry.snapshot()
    assert(effective)
    assert(not effective:get(SUBJECT), "refused stale overlay changed effective state")
    local current_dependency = effective:get(DEPENDENCY)
    assert(current_dependency and type(current_dependency.data) == "table" and current_dependency.data.value == "base-v2",
        "refused stale overlay reverted the intervening dependency update")
    logger:info("GOVERNANCE_COMPOSED_BASE_REFUSED", {
        reviewed_version = reviewed_version,
        intervening_version = committed:id(),
        retained_dependency_value = current_dependency.data.value,
    })
end

return {main = main}
