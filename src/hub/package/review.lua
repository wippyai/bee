-- MIT. Read-only effects of a prepared package plan. The summary does not
-- participate in the confirmation digest or registry publication.
local bounds = require("bounds")
local canonical = require("canonical")
local plan = require("plan")
local M = {}
type Summary = {migration_runs: {plan.Migration}, policy_changes: {plan.PolicyChange}, other_entries: integer}
type Ledger = (string, string) -> (boolean?, string?)
local function same(a: unknown, b: unknown): boolean
    local left, right = bounds.object(a), bounds.object(b)
    if not left or not right then return false end
    local a_data, b_data = canonical.encode(left.data, 1048576), canonical.encode(right.data, 1048576)
    return left.kind == right.kind and a_data ~= nil and b_data ~= nil and a_data == b_data
end
function M.summarize(prepared: plan.Prepared, state: unknown, ledger: Ledger): (Summary?, string?)
    local snapshot = bounds.object(state)
    if not snapshot or type(snapshot.entries) ~= "table" then return nil, "invalid review baseline" end
    local resident: {[string]: unknown}, proposed: {[string]: unknown} = {}, {}
    for _, raw in ipairs(snapshot.entries) do
        local entry = bounds.object(raw)
        if entry and type(entry.id) == "string" then resident[entry.id] = entry end
    end
    local changed: {[string]: boolean} = {}
    for _, module in ipairs(prepared.plan.modules) do changed[module.component] = module.change ~= "keep" end
    local other_entries = 0
    for _, package in ipairs(prepared.resolved.packages) do
        for _, entry in ipairs(package.entries) do
            proposed[entry.id] = entry
            if changed[package.component] and entry.meta.type ~= "migration"
                and entry.kind ~= "security.policy" and entry.kind ~= "security.policy.expr"
                and (not same(resident[entry.id], entry) or canonical.encode((bounds.object(resident[entry.id]) or {}).meta or {}) ~= canonical.encode(entry.meta)) then other_entries = other_entries + 1 end
        end
    end
    local policies: {plan.PolicyChange} = {}
    for _, policy in ipairs(prepared.plan.policy_changes) do
        if policy.change ~= "update" or not same(resident[policy.id], proposed[policy.id]) then policies[#policies + 1] = policy end
    end
    local runs: {plan.Migration} = {}
    local policy = prepared.plan.request.migration_policy
    if policy == "up" or policy == "down" then
        for _, migration in ipairs(prepared.plan.migrations) do
            local applied = false
            if resident[migration.target_db] then
                local checked, problem = ledger(migration.target_db, migration.id)
                if checked == nil then return nil, problem or "migration ledger unavailable" end
                applied = checked
            elseif not proposed[migration.target_db] then return nil, "migration database unavailable: " .. migration.target_db end
            if (policy == "up" and not applied) or (policy == "down" and applied) then runs[#runs + 1] = migration end
        end
    end
    return {migration_runs = runs, policy_changes = policies, other_entries = other_entries}, nil
end
return M
