local funcs = require("funcs")
local security = require("security")
local sql = require("sql")

local EVIDENCE = "probe:evidence_db"

local function call(policy_names, method)
    local policies = {}
    for index, name in ipairs(policy_names) do
        local policy, policy_error = security.policy(name)
        assert(policy and not policy_error, tostring(policy_error))
        policies[index] = policy
    end
    local scope, scope_error = security.new_scope(policies)
    assert(scope and not scope_error, tostring(scope_error))
    local value, problem = funcs.new():with_scope(scope):call("probe:negative_" .. method, {})
    assert(not problem, tostring(problem))
    assert(type(value) == "table", "negative function returned no object")
    return value
end

local function record(phase, value, problem)
    local db, err = sql.get(EVIDENCE)
    assert(db and not err, tostring(err))
    local _, create_error = db:execute("CREATE TABLE IF NOT EXISTS negative_evidence (phase TEXT PRIMARY KEY, value TEXT, problem TEXT)")
    assert(not create_error, tostring(create_error))
    local _, insert_error = db:execute("INSERT INTO negative_evidence (phase, value, problem) VALUES ($1, $2, $3)", {
        phase, tostring(value), tostring(problem),
    })
    db:release()
    assert(not insert_error, tostring(insert_error))
end

local function main()
    local absent = call({"probe:policy"}, "absent")
    assert(absent.applied == false and absent.problem == nil, "absent ledger read was not a clean false: applied=" .. tostring(absent.applied) .. " problem=" .. tostring(absent.problem))
    record("absent_ledger", absent.applied, absent.problem)

    local database_denied = call({"probe:func_only"}, "allowed")
    assert(database_denied.allowed == false and tostring(database_denied.problem):find("database grant", 1, true), "allowed did not refuse missing db grant")
    record("missing_db_grant", database_denied.allowed, database_denied.problem)
    local database_attempt = call({"probe:func_only"}, "attempt")
    assert(tostring(database_attempt.problem):find("database", 1, true), "db-denied adapter attempt did not fail closed")
    record("missing_db_attempt", database_attempt.result ~= nil, database_attempt.problem)

    local function_denied = call({"probe:db_only", "probe:db_grant"}, "allowed")
    assert(function_denied.allowed == false and tostring(function_denied.problem):find("function grant", 1, true), "allowed did not refuse missing function grant")
    record("missing_func_grant", function_denied.allowed, function_denied.problem)
    local function_attempt = call({"probe:db_only", "probe:db_grant"}, "attempt")
    assert(function_attempt.result ~= nil and tostring(function_attempt.problem):find("function grant", 1, true), "func-denied adapter did not stop before migration")
    record("missing_func_attempt", function_attempt.result ~= nil, function_attempt.problem)
end

return {main = main}
