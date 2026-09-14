-- MIT. Bounded host policy regression tests.
-- Verifies host policy expr constraints, core spawn boundary defenses,
-- reconstructed scopes, and isolation of ordinary application scopes.
local test = require("test")
local funcs = require("funcs")
local security = require("security")

local function call_can(policy_names: {string}, action: string, resource: string): boolean
    local policies: {security.Policy} = {}
    for index, name in ipairs(policy_names) do
        local policy, err = security.policy(name)
        if not policy then
            error("security.policy(" .. name .. "): " .. tostring(err))
        end
        policies[index] = policy
    end
    local scope = security.new_scope(policies)
    local result, err = funcs.new():with_scope(scope):call("bee.host_policy_test:can_probe", {
        action = action,
        resource = resource,
    })
    if err ~= nil then
        error("funcs.call to can_probe failed: " .. tostring(err))
    end
    if type(result) ~= "boolean" then
        error("can_probe returned non-boolean: " .. tostring(result))
    end
    return result
end

-- Evaluates the security invariants for any of the 3 ordinary host policies:
-- worker process.host is true, supervisor and arbitrary foreign host false;
-- process.send still true; representative allowed nonhost action remains allowed.
local function evaluate_host_policy(policy_name: string, nonhost_action: string, nonhost_resource: string)
    local scope = {policy_name}
    -- 1. worker process.host is true
    test.is_true(call_can(scope, "process.host", "bee:workers"))
    -- 2. supervisor host is false
    test.is_false(call_can(scope, "process.host", "bee.hive:supervisor_host"))
    -- 3. arbitrary foreign host is false
    test.is_false(call_can(scope, "process.host", "bee.hive:other_host"))
    test.is_false(call_can(scope, "process.host", "foreign:host"))
    -- 4. process.send is still true
    test.is_true(call_can(scope, "process.send", "target:process"))
    -- 5. representative allowed nonhost action remains allowed
    test.is_true(call_can(scope, nonhost_action, nonhost_resource))
end

local function define_tests()
    test.describe("Host policy isolation and boundary enforcement", function()
        test.it("allows the native Hive supervisor to release the eventual name it publishes", function()
            local scope = {"bee:hive_names_policy"}
            test.is_true(call_can(scope, "process.registry.register.eventual", "bee.hive.supervisor/Antares"))
            test.is_true(call_can(scope, "process.registry.unregister.eventual", "bee.hive.supervisor/Antares"))
            test.is_false(call_can({"bee:base_app_policy"}, "process.registry.unregister.eventual", "bee.hive.supervisor/Antares"))
        end)
        test.it("limits waiter startup to its own name and reply delivery", function()
            local scope = {"bee:thread_waiter_policy"}
            test.is_true(call_can(scope, "process.registry.register", "bee.threads.waiter"))
            test.is_true(call_can(scope, "process.send", "waiting:actor"))
            test.is_false(call_can(scope, "process.registry.register", "bee.hive.supervisor"))
            test.is_false(call_can(scope, "process.registry.register", "unrelated.name"))
            test.is_false(call_can(scope, "process.registry.foreign", "bee.threads.waiter"))
            test.is_false(call_can(scope, "process.host", "bee:workers"))
            test.is_false(call_can(scope, "process.spawn", "bee.hive.supervisor:main"))
            test.is_false(call_can(scope, "db.get", "bee.threads:db"))
            test.is_false(call_can(scope, "security.scope.create", "scope"))
        end)
        test.it("limits Hive desktop bootstrap to its selected policies", function()
            local scope = {"bee.hive.desktop:host_policy"}
            for _, name in ipairs({"bee:host_policy", "bee:desktop_policy",
                "bee:retained_supervisor_spawn_policy", "bee:desktop_catalog_policy",
                "bee:desktop_catalog_resource_policy"}) do
                test.is_true(call_can(scope, "security.policy.get", name))
            end
            test.is_false(call_can(scope, "security.policy.get", "bee:workspace_storage_policy"))
            test.is_false(call_can(scope, "security.policy.get", "foreign:policy"))
            test.is_false(call_can(scope, "db.get", "bee:client_db"))
            test.is_false(call_can(scope, "funcs.call", "bee.client:allocate_desktop"))
        end)

        test.it("constrains broker_policy to worker host while retaining nonhost actions", function()
            evaluate_host_policy("bee:broker_policy", "process.spawn", "bee.apps:welcome")
        end)

        test.it("constrains desktop_policy to worker host while retaining nonhost actions", function()
            evaluate_host_policy("bee:desktop_policy", "tty.mount", "screen")
            test.is_true(call_can({"bee:desktop_policy"}, "registry.find", "bee.launch_definition"))
        end)

        test.it("constrains host_policy to worker host while retaining nonhost actions", function()
            evaluate_host_policy("bee:host_policy", "process.monitor", "target:process")
        end)

        test.it("evaluates reconstructed host scope (host_policy + host_spawn_policy + workspace_storage_policy)", function()
            local scope = {
                "bee:host_policy",
                "bee:host_spawn_policy",
                "bee:workspace_storage_policy",
            }
            -- Worker host passes, protected and foreign host fail
            test.is_true(call_can(scope, "process.host", "bee:workers"))
            test.is_false(call_can(scope, "process.host", "bee.hive:supervisor_host"))
            test.is_false(call_can(scope, "process.host", "foreign:host"))
            -- Process send remains allowed
            test.is_true(call_can(scope, "process.send", "target:process"))
            -- Host spawn policy only authorizes broker spawn
            test.is_true(call_can(scope, "process.spawn", "bee.applications:broker"))
            test.is_false(call_can(scope, "process.spawn", "bee.apps:welcome"))
            -- Workspace storage policy allows workspace_db only
            test.is_true(call_can(scope, "db.get", "bee:workspace_db"))
            test.is_false(call_can(scope, "db.get", "bee:client_db"))
        end)

        test.it("evaluates reconstructed broker scope (broker_policy + core_spawn_boundary)", function()
            local scope = {
                "bee:broker_policy",
                "bee:core_spawn_boundary",
            }
            -- Worker host passes, protected and foreign host fail
            test.is_true(call_can(scope, "process.host", "bee:workers"))
            test.is_false(call_can(scope, "process.host", "bee.hive:supervisor_host"))
            test.is_false(call_can(scope, "process.host", "foreign:host"))
            -- Allowed ordinary application spawn succeeds
            test.is_true(call_can(scope, "process.spawn", "bee.apps:welcome"))
            -- Core spawn boundary explicitly denies core and supervisor processes
            test.is_false(call_can(scope, "process.spawn", "bee.applications:broker"))
            test.is_false(call_can(scope, "process.spawn", "bee.hive.supervisor:main"))
            test.is_false(call_can(scope, "process.spawn", "bee.hive:supervisor"))
            -- Process send remains allowed
            test.is_true(call_can(scope, "process.send", "target:process"))
        end)

        test.it("defeats broad fixture host allow via core_spawn_boundary explicit deny", function()
            local scope = {
                "bee.host_policy_test:fixture_broad_host_policy",
                "bee:core_spawn_boundary",
            }
            -- Worker passes
            test.is_true(call_can(scope, "process.host", "bee:workers"))
            -- Core spawn boundary explicitly denies supervisor host despite broad allow('*')
            test.is_false(call_can(scope, "process.host", "bee.hive:supervisor_host"))
            -- Broad allow applies to unboundary foreign resources
            test.is_true(call_can(scope, "process.host", "foreign:host"))
        end)

        test.it("defeats broad fixture spawn allow via core_spawn_boundary explicit deny", function()
            local scope = {
                "bee.host_policy_test:fixture_broad_spawn_policy",
                "bee:core_spawn_boundary",
            }
            -- Spawning supervisor entries is strictly denied
            for _, action in ipairs({"process.spawn", "process.spawn.monitored", "process.spawn.linked", "process.exec"}) do
                test.is_false(call_can(scope, action, "bee.hive.supervisor:main"))
                test.is_false(call_can(scope, action, "bee.hive:supervisor"))
                test.is_false(call_can(scope, action, "bee.hive:supervisor_host"))
                test.is_true(call_can(scope, action, "bee.apps:welcome"))
            end
            -- Non-boundary application spawn passes
            test.is_true(call_can(scope, "process.spawn", "bee.apps:welcome"))
        end)

        test.it("confirms ordinary app scope gains no host authority", function()
            local scope = {
                "bee:base_app_policy",
                "bee:app_boundary_policy",
                "bee:core_spawn_boundary",
            }
            -- App scope cannot host workers, supervisor, or foreign hosts
            test.is_false(call_can(scope, "process.host", "bee:workers"))
            test.is_false(call_can(scope, "process.host", "bee.hive:supervisor_host"))
            test.is_false(call_can(scope, "process.host", "foreign:host"))
            -- App scope cannot spawn supervisor entries or arbitrary apps
            test.is_false(call_can(scope, "process.spawn", "bee.hive.supervisor:main"))
            test.is_false(call_can(scope, "process.spawn", "bee.apps:welcome"))
            -- App scope retains process.send
            test.is_true(call_can(scope, "process.send", "target:process"))
            -- App scope is denied process.security
            test.is_false(call_can(scope, "process.security", "security"))
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
