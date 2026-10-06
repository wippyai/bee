-- MIT. An approved command runs through its host-created executor exactly as
-- approved: the command alone or followed by further arguments, in the
-- approved folder, with no caller environment. Everything else is refused
-- by the runtime before a process exists.
local funcs = require("funcs")
local security = require("security")
local registry = require("registry")
local app_scope = require("app_scope")
local test = require("test")
local bounds = require("bounds")
local grants = require("capability_grants")
local model = require("capability_model")

local WORKSPACE = string.rep("e", 32)
local NAME = "processgrant"
local APP = "app." .. NAME .. ":app"
local OWNER = "bee.gov.apps:" .. WORKSPACE .. "." .. NAME
local PROBE = "bee.tests.gov:process_grant_probe"
local CALL_POLICY = "bee.tests.gov:process_grant_call_policy"
local FOLDER = {root_ref = "bee.env:workspace_root", directory = ".", base = "project", subpath = ""}
type Object = {[string]: unknown}
type Outcome = {result: Object, stage: string}

-- Proposes one process.exec grant and installs its executor and policy the
-- way activation composes them.
local function install(requirement: string, command: string, directory: string): (Object, Object, {string})
    local vocabulary = assert(model.decode(assert(registry.get("bee.capability:catalog"))))
    local proposal = assert(grants.propose(vocabulary, OWNER, APP, {
        {id = "app." .. NAME .. ":" .. requirement, expected_kind = "security.policy", targets = {APP},
            capability_request = {capability = "process.exec", parameters = {command = command, directory = directory},
                template_revision = 1, catalog_revision = model.revisions(vocabulary, "process.exec"),
                reason = "run the approved command", target = APP, path = ".security.policies +="}}}, nil, FOLDER))
    local policy = assert(bounds.object(proposal.policies[1]))
    local executor = assert(bounds.object(proposal.executors[1]))
    local changes = assert(registry.snapshot()):changes()
    local created: {string} = {}
    for _, entry in ipairs({executor, policy}) do
        local id = assert(bounds.id(entry.id))
        if not registry.get(id) then
            changes:create({id = id, kind = assert(bounds.text(entry.kind, 160)),
                meta = assert(bounds.object(entry.meta)), data = entry.data})
            created[#created + 1] = id
        end
    end
    if #created > 0 then assert(changes:apply()) end
    return policy, executor, created
end

local function remove(created: {string})
    if #created == 0 then return end
    local changes = assert(registry.snapshot()):changes()
    for _, id in ipairs(created) do changes:delete(id) end
    assert(changes:apply())
end

local function actor(): security.Actor
    return security.new_actor("bee.application:" .. WORKSPACE .. ":instance-1",
        {workspace_id = WORKSPACE, definition_id = APP, definition_revision = "1", execution_generation = 1})
end

local function run(policy: Object, executor: string, command: string, options: Object?): Object
    local request: Object = {executor = executor, command = command}
    for key, value in pairs(options or {}) do request[key] = value end
    local scope = app_scope.boundary({assert(bounds.id(policy.id)), CALL_POLICY})
    local result, err = funcs.new():with_actor(actor()):with_scope(scope):call(PROBE, request)
    if err then error(tostring(err)) end
    return assert(bounds.object(result))
end

local function define_tests()
    test.describe("approved process grant", function()
        test.it("runs the approved command with further arguments in the approved folder", function()
            local policy, executor, created = install("echo", "/bin/echo approved", "lua")
            local executor_id = assert(bounds.id(executor.id))
            local alone = run(policy, executor_id, "/bin/echo approved")
            local extended = run(policy, executor_id, "/bin/echo approved and more")
            local where_policy, where_executor, where_created = install("pwd", "/bin/pwd", "lua")
            local where = run(where_policy, assert(bounds.id(where_executor.id)), "/bin/pwd")
            remove(where_created)
            remove(created)
            test.is_true(alone.ok == true)
            test.eq(alone.output, "approved\n")
            test.is_true(extended.ok == true)
            test.eq(extended.output, "approved and more\n")
            test.is_true(where.ok == true)
            test.is_true(tostring(where.output):find("/lua\n$") ~= nil)
        end)
        test.it("refuses another command, a joined argument, a chosen folder, caller environment and other executors", function()
            local policy, executor, created = install("refusals", "/bin/echo approved", "lua")
            local executor_id = assert(bounds.id(executor.id))
            local outcomes: {Outcome} = {
                {result = run(policy, executor_id, "/bin/echo other"), stage = "exec"},
                {result = run(policy, executor_id, "/bin/echo approvedX"), stage = "exec"},
                {result = run(policy, executor_id, "/bin/echo 'approved'"), stage = "exec"},
                {result = run(policy, executor_id, "/bin/sh -c id"), stage = "exec"},
                {result = run(policy, executor_id, "/bin/echo approved", {work_dir = "/"}), stage = "exec"},
                {result = run(policy, executor_id, "/bin/echo approved", {env = {LEAK = "1"}}), stage = "exec"},
                {result = run(policy, "bee.git.worktree.env:git_executor", "/bin/echo approved"), stage = "get"},
            }
            remove(created)
            local scope = app_scope.boundary({CALL_POLICY})
            local revoked, revoked_error = funcs.new():with_actor(actor()):with_scope(scope):call(PROBE,
                {executor = executor_id, command = "/bin/echo approved"})
            if revoked_error then error(tostring(revoked_error)) end
            outcomes[#outcomes + 1] = {result = assert(bounds.object(revoked)), stage = "get"}
            for _, outcome in ipairs(outcomes) do
                test.is_false(outcome.result.ok == true)
                test.eq(outcome.result.stage, outcome.stage)
            end
        end)
    end)
end
return test.run_cases(define_tests)
