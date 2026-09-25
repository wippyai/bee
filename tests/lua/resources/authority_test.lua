-- MIT. The resource authority: associations under the host ceiling,
-- grants bound to the authenticated subject and their exact selection,
-- and resolve refusing everything that no longer holds.
local test = require("test")
local principals = require("principals")
local funcs = require("funcs")
local security = require("security")
local registry = require("registry")
local time = require("time")
local authority = require("authority")
local migrations = require("migrations")
local persist = require("persist")
local resources = require("resources")
local PROJECT = "bee.resources:project_fixture"
local SHARED = "bee.resources:shared_fixture"
local UNRELATED_ENV_ROOT = "bee.resources:unrelated_env_root"
local MANAGER, USER, OTHER, PLACEMENT = "bee.test.manager", "bee.test.user", "bee.test.other", "bee.test.placement"
local counter = 0
local function fresh(prefix: string): string
    counter = counter + 1
    return prefix .. "-" .. tostring(math.floor(time.now():unix_nano() / 1000)) .. "-" .. tostring(counter)
end
local function scope(names: {string}): security.Scope
    local policies: {security.Policy} = {}
    for index, name in ipairs(names) do
        local policy, err = security.policy(name)
        if err or not policy then error("policy " .. name .. ": " .. tostring(err)) end
        policies[index] = policy
    end
    return security.new_scope(policies)
end
type Principal = {id: string, names: {string}}
local function caller(id: string, grants: {string}): Principal
    local names: {string} = {"bee.resources:client_test_policy"}
    for _, grant in ipairs(grants) do names[#names + 1] = grant end
    return {id = id, names = names}
end
-- A principal acts bound to one workspace; by default the one its request names.
local function bound(client: Principal, workspace_id: unknown): funcs.Executor
    return funcs.new():with_actor(principals.actor(client.id, workspace_id)):with_scope(scope(client.names))
end
local function executor(client: Principal, value: unknown): funcs.Executor
    return bound(client, principals.workspace(value))
end
local manager = caller(MANAGER, {"bee.security.resources:resource_manage_policy"})
local user = caller(USER, {"bee.security.resources:resource_grant_policy"})
local other = caller(OTHER, {"bee.security.resources:resource_grant_policy"})
local consumer = caller("bee.test.consumer", {"bee.security.resources:resource_grant_thread_policy"})
local THREAD_ACTOR = "bee.test.thread-actor"
local placement = caller(PLACEMENT, {"bee.security.resources:resource_resolve_policy"})
local outsider = caller("bee.test.outsider", {})
local function call(client: Principal, method: string, value: unknown): authority.Reply
    local reply, err = executor(client, value):call("bee.resources.binding:" .. method, value)
    if err then error(method .. ": " .. tostring(err)) end
    return reply :: authority.Reply
end
local function value(reply: authority.Reply): {[string]: unknown}
    if not reply.ok then error(tostring(reply.error and reply.error.code) .. ": " .. tostring(reply.error and reply.error.message)) end
    return reply.value :: {[string]: unknown}
end
local function code(reply: authority.Reply): string
    if reply.ok then error("expected a failure, got success") end
    return reply.error and reply.error.code or ""
end
local function await(future: any): authority.Reply
    local response = future:response()
    local payload, open = response:receive()
    local value, err = future:result()
    if err then error("async associate: " .. tostring(err)) end
    if not open or not payload then error("async associate closed without a reply") end
    local data: unknown = value:data()
    if type(data) ~= "table" then error("async associate returned " .. type(data)) end
    return data :: authority.Reply
end
local function admit_roots()
    local entry = registry.get("bee:resource_roots")
    if not entry then error("admitted roots entry") end
    local data = entry.data :: {[string]: unknown}
    local roots = data.roots :: {{[string]: unknown}}
    local present: {[string]: boolean} = {}
    for _, root in ipairs(roots) do present[tostring(root.root_ref)] = true end
    if present[PROJECT] and present[SHARED] and present[UNRELATED_ENV_ROOT] then return end
    if not present[PROJECT] then roots[#roots + 1] = {root_ref = PROJECT, access = "write"} end
    if not present[SHARED] then roots[#roots + 1] = {root_ref = SHARED, access = "read"} end
    if not present[UNRELATED_ENV_ROOT] then roots[#roots + 1] = {root_ref = UNRELATED_ENV_ROOT, access = "write"} end
    local changes = registry.snapshot():changes()
    changes:update(entry)
    local applied, err = changes:apply()
    if not applied then error("admit roots: " .. tostring(err)) end
end
local function define_tests()
    test.describe("Resource authority", function()
        admit_roots()
        test.it("associates under the host ceiling for managers only and replaces at the next revision", function()
            local workspace = fresh("ws")
            test.eq(code(call(outsider, "associate", {workspace_id = workspace, name = "project", root_ref = PROJECT, subpath = "", allowed_access = "write"})), "DENIED")
            test.eq(code(call(manager, "associate", {workspace_id = workspace, name = "project", root_ref = "bee.resources:unadmitted_fixture", allowed_access = "read"})), "FORBIDDEN")
            test.eq(code(call(manager, "associate", {workspace_id = workspace, name = "shared", root_ref = SHARED, allowed_access = "write"})), "FORBIDDEN")
            test.eq(code(call(manager, "associate", {workspace_id = workspace, name = "project", root_ref = PROJECT, subpath = "../up"})), "INVALID")
            local first = value(call(manager, "associate", {workspace_id = workspace, name = "project", root_ref = PROJECT, subpath = "src", allowed_access = "write"}))
            test.eq(first.revision, 1)
            test.eq(#(first.root_digest :: string), 64)
            local shared = value(call(manager, "associate", {workspace_id = workspace, name = "shared", root_ref = SHARED, allowed_access = "read"}))
            test.eq(shared.allowed_access, "read")
            local replaced = value(call(manager, "associate", {workspace_id = workspace, name = "project", root_ref = PROJECT, subpath = "app", allowed_access = "write"}))
            test.eq(replaced.revision, 2)
            test.neq(replaced.association_id, first.association_id)
            local replayed = value(call(manager, "associate", {workspace_id = workspace, name = "project", root_ref = PROJECT, subpath = "app", allowed_access = "write", expected_revision = 2}))
            test.eq(replayed.revision, replaced.revision)
            test.eq(replayed.association_id, replaced.association_id)
            local listed = value(call(manager, "list", {workspace_id = workspace}))
            test.eq(#(listed.associations :: {unknown}), 2)
            test.eq(code(call(user, "list", {workspace_id = workspace})), "DENIED")
        end)
        test.it("creates an association once under concurrent zero CAS and preserves it on stale CAS", function()
            local workspace = fresh("cas")
            local first, first_error = bound(manager, workspace):async("bee.resources.binding:associate", {workspace_id = workspace, name = "project", root_ref = PROJECT,
                subpath = "first", allowed_access = "write", expected_revision = 0})
            local second, second_error = bound(manager, workspace):async("bee.resources.binding:associate", {workspace_id = workspace, name = "project", root_ref = PROJECT,
                subpath = "second", allowed_access = "write", expected_revision = 0})
            if first_error or not first or second_error or not second then error("start association race: " .. tostring(first_error or second_error)) end
            local replies = {await(first), await(second)}
            local created: authority.Reply? = nil
            local conflicts = 0
            for _, reply in ipairs(replies) do
                if reply.ok then created = reply else
                    test.eq(reply.error and reply.error.code, "CONFLICT")
                    conflicts = conflicts + 1
                end
            end
            test.eq(conflicts, 1)
            if not created then error("association race created nothing") end
            local association = created.value :: {[string]: unknown}
            test.eq(association.revision, 1)
            local listed = value(call(manager, "list", {workspace_id = workspace}))
            test.eq(#(listed.associations :: {unknown}), 1)
            local current = (listed.associations :: {{[string]: unknown}})[1]
            test.eq(current.revision, 1)
            test.eq(current.subpath, association.subpath)

            local granted = value(call(user, "grant", {workspace_id = workspace, name = "project", access = "write", purpose = "project",
                audience = USER, attempt_id = "cas-attempt"}))
            local stale = call(manager, "associate", {workspace_id = workspace, name = "project", root_ref = PROJECT, subpath = "stale",
                allowed_access = "write", expected_revision = 0})
            test.eq(code(stale), "CONFLICT")
            local after_stale = value(call(manager, "list", {workspace_id = workspace}))
            local unchanged = (after_stale.associations :: {{[string]: unknown}})[1]
            test.eq(unchanged.revision, 1)
            test.eq(unchanged.association_id, association.association_id)
            value(call(placement, "resolve", {grant_id = granted.grant_id, subject = USER, audience = USER, attempt_id = "cas-attempt"}))

            local updated = value(call(manager, "associate", {workspace_id = workspace, name = "project", root_ref = PROJECT, subpath = "updated",
                allowed_access = "write", expected_revision = 1}))
            test.eq(updated.revision, 2)
            test.neq(updated.association_id, association.association_id)
            test.eq(code(call(placement, "resolve", {grant_id = granted.grant_id, subject = USER, audience = USER, attempt_id = "cas-attempt"})), "CONFLICT")
        end)
        test.it("does not let resource authority read an unrelated environment variable", function()
            local workspace = fresh("env-denied")
            test.eq(code(call(manager, "associate", {workspace_id = workspace, name = "secret", root_ref = UNRELATED_ENV_ROOT,
                subpath = "", allowed_access = "write", expected_revision = 0})), "INVALID")
            local listed = value(call(manager, "list", {workspace_id = workspace}))
            test.eq(#(listed.associations :: {unknown}), 0)
        end)
        test.it("lets a principal take grants only in the workspace it is bound to", function()
            local home, foreign = fresh("home"), fresh("foreign")
            for _, workspace in ipairs({home, foreign}) do
                value(call(manager, "associate", {workspace_id = workspace, name = "project", root_ref = PROJECT, subpath = "src", allowed_access = "write"}))
            end
            local request = {workspace_id = foreign, name = "project", access = "read", purpose = "project", audience = USER}
            local denied, denied_error = bound(user, home):call("bee.resources.binding:grant", request)
            if denied_error then error(tostring(denied_error)) end
            test.eq(code(denied :: authority.Reply), "DENIED")
            local unbound, unbound_error = bound(user, nil):call("bee.resources.binding:grant", request)
            if unbound_error then error(tostring(unbound_error)) end
            test.eq(code(unbound :: authority.Reply), "DENIED")
            local own, own_error = bound(user, home):call("bee.resources.binding:grant",
                {workspace_id = home, name = "project", access = "read", purpose = "project", audience = USER})
            if own_error then error(tostring(own_error)) end
            test.eq((value(own :: authority.Reply)).subject, USER)
        end)
        test.it("grants bind the authenticated subject and resolve only for the admitted placement, subject and audience", function()
            local workspace = fresh("ws")
            value(call(manager, "associate", {workspace_id = workspace, name = "project", root_ref = PROJECT, subpath = "src", allowed_access = "write"}))
            test.eq(code(call(user, "grant", {workspace_id = workspace, name = "missing", access = "read", purpose = "project", audience = USER})), "NOT_FOUND")
            test.eq(code(call(outsider, "grant", {workspace_id = workspace, name = "project", access = "read", purpose = "project", audience = USER})), "DENIED")
            local granted = value(call(user, "grant", {workspace_id = workspace, name = "project", access = "write", purpose = "project", audience = USER, attempt_id = "attempt-1"}))
            test.eq(granted.subject, USER)
            test.eq(granted.audience, USER)
            test.eq(granted.association_revision, 1)
            test.eq(granted.authorization_epoch, 0)
            local grant_id = granted.grant_id :: string
            test.eq(code(call(user, "resolve", {grant_id = grant_id, subject = USER, audience = USER, attempt_id = "attempt-1"})), "DENIED")
            local resolved = value(call(placement, "resolve", {grant_id = grant_id, subject = USER, audience = USER, attempt_id = "attempt-1"}))
            test.eq(resolved.root_ref, PROJECT)
            test.eq(resolved.subpath, "src")
            test.eq(resolved.access, "write")
            test.is_true(tostring(resolved.directory):find("resources%-project") ~= nil)
            test.eq(code(call(placement, "resolve", {grant_id = grant_id, subject = OTHER, audience = USER, attempt_id = "attempt-1"})), "DENIED")
            test.eq(code(call(placement, "resolve", {grant_id = grant_id, subject = USER, audience = OTHER, attempt_id = "attempt-1"})), "DENIED")
            test.eq(code(call(placement, "resolve", {grant_id = grant_id, subject = USER, audience = USER, attempt_id = "attempt-2"})), "DENIED")
            test.eq(code(call(placement, "resolve", {grant_id = "nope", subject = USER, audience = USER})), "NOT_FOUND")
            local keyed = value(call(user, "grant", {workspace_id = workspace, name = "project", access = "read", purpose = "cache", audience = USER, idempotency_key = "same-request"}))
            local replayed = value(call(user, "grant", {workspace_id = workspace, name = "project", access = "read", purpose = "cache", audience = USER, idempotency_key = "same-request"}))
            test.eq(replayed.grant_id, keyed.grant_id)
            test.eq(code(call(user, "grant", {workspace_id = workspace, name = "project", access = "write", purpose = "cache", audience = USER, idempotency_key = "same-request"})), "CONFLICT")
            local reader = value(call(manager, "associate", {workspace_id = workspace, name = "shared", root_ref = SHARED, allowed_access = "read"}))
            test.eq(reader.allowed_access, "read")
            test.eq(code(call(user, "grant", {workspace_id = workspace, name = "shared", access = "write", purpose = "cache", audience = USER})), "FORBIDDEN")
        end)
        test.it("writes thread-bound grants only for the admitted consumer", function()
            local workspace = fresh("thread-grant")
            value(call(manager, "associate", {workspace_id = workspace, name = "project", root_ref = PROJECT, subpath = "src", allowed_access = "write"}))
            local elevated = {workspace_id = workspace, name = "project", access = "read", purpose = "session",
                audience = THREAD_ACTOR, attempt_id = "attempt-1", subject = THREAD_ACTOR, thread_id = "thread-1",
                ttl_ms = 60000, idempotency_key = "elevation-1"}
            test.eq(code(call(user, "grant", elevated)), "DENIED")
            local granted = value(call(consumer, "grant", elevated))
            test.eq(granted.subject, THREAD_ACTOR)
            test.eq(granted.thread_id, "thread-1")
            test.eq(granted.audience, THREAD_ACTOR)
            test.eq(granted.attempt_id, "attempt-1")
            local grant_id = granted.grant_id :: string
            value(call(placement, "resolve", {grant_id = grant_id, subject = THREAD_ACTOR, audience = THREAD_ACTOR, attempt_id = "attempt-1"}))
            test.eq(code(call(placement, "resolve", {grant_id = grant_id, subject = THREAD_ACTOR, audience = THREAD_ACTOR, attempt_id = "attempt-2"})), "DENIED")
            test.eq(code(call(placement, "resolve", {grant_id = grant_id, subject = USER, audience = THREAD_ACTOR, attempt_id = "attempt-1"})), "DENIED")
            local replayed = value(call(consumer, "grant", elevated))
            test.eq(replayed.grant_id, grant_id)
            local changed = {workspace_id = workspace, name = "project", access = "write", purpose = "session",
                audience = THREAD_ACTOR, attempt_id = "attempt-1", subject = THREAD_ACTOR, thread_id = "thread-1",
                ttl_ms = 60000, idempotency_key = "elevation-1"}
            test.eq(code(call(consumer, "grant", changed)), "CONFLICT")
            local foreign = {workspace_id = fresh("elsewhere"), name = "project", access = "read", purpose = "session",
                audience = THREAD_ACTOR, attempt_id = "attempt-1", subject = THREAD_ACTOR, thread_id = "thread-1"}
            local denied, denied_error = bound(consumer, workspace):call("bee.resources.binding:grant", foreign)
            if denied_error then error(tostring(denied_error)) end
            test.eq(code(denied :: authority.Reply), "DENIED")
        end)
        test.it("stops resolving on expiry, revocation, epoch advance, replaced associations, changed roots and foreign nodes", function()
            local workspace = fresh("ws")
            value(call(manager, "associate", {workspace_id = workspace, name = "project", root_ref = PROJECT, subpath = "", allowed_access = "write"}))
            local short = value(call(user, "grant", {workspace_id = workspace, name = "project", access = "read", purpose = "project", audience = USER, ttl_ms = 1}))
            time.sleep("20ms")
            test.eq(code(call(placement, "resolve", {grant_id = short.grant_id, subject = USER, audience = USER})), "EXPIRED")
            local revocable = value(call(user, "grant", {workspace_id = workspace, name = "project", access = "read", purpose = "project", audience = USER}))
            test.eq(code(call(other, "revoke", {grant_id = revocable.grant_id})), "DENIED")
            value(call(user, "revoke", {grant_id = revocable.grant_id}))
            test.eq(code(call(placement, "resolve", {grant_id = revocable.grant_id, subject = USER, audience = USER})), "REVOKED")
            local epochal = value(call(user, "grant", {workspace_id = workspace, name = "project", access = "read", purpose = "project", audience = USER}))
            value(call(placement, "resolve", {grant_id = epochal.grant_id, subject = USER, audience = USER}))
            test.eq(code(call(user, "revoke_all", {workspace_id = workspace})), "DENIED")
            local advanced = value(call(manager, "revoke_all", {workspace_id = workspace}))
            test.eq(advanced.authorization_epoch, 1)
            test.eq(code(call(placement, "resolve", {grant_id = epochal.grant_id, subject = USER, audience = USER})), "REVOKED")
            local renewed = value(call(user, "grant", {workspace_id = workspace, name = "project", access = "read", purpose = "project", audience = USER}))
            test.eq(renewed.authorization_epoch, 1)
            value(call(placement, "resolve", {grant_id = renewed.grant_id, subject = USER, audience = USER}))
            value(call(manager, "associate", {workspace_id = workspace, name = "project", root_ref = PROJECT, subpath = "other", allowed_access = "write"}))
            test.eq(code(call(placement, "resolve", {grant_id = renewed.grant_id, subject = USER, audience = USER})), "CONFLICT")
            local fresh_grant = value(call(user, "grant", {workspace_id = workspace, name = "project", access = "read", purpose = "project", audience = USER}))
            value(call(placement, "resolve", {grant_id = fresh_grant.grant_id, subject = USER, audience = USER}))
            local root_entry = registry.get(PROJECT)
            if not root_entry then error("root entry") end
            local root_meta = root_entry.meta :: {[string]: unknown}
            root_meta.comment = "re-defined " .. fresh("at")
            local changes = registry.snapshot():changes()
            changes:update(root_entry)
            local applied, apply_error = changes:apply()
            if not applied then error("change root: " .. tostring(apply_error)) end
            test.eq(code(call(placement, "resolve", {grant_id = fresh_grant.grant_id, subject = USER, audience = USER})), "CONFLICT")
            value(call(manager, "associate", {workspace_id = workspace, name = "project", root_ref = PROJECT, subpath = "", allowed_access = "write"}))
            local relocated = value(call(user, "grant", {workspace_id = workspace, name = "project", access = "read", purpose = "project", audience = USER}))
            value(call(placement, "resolve", {grant_id = relocated.grant_id, subject = USER, audience = USER}))
            local resource = resources.database()
            local db = persist.open({resource = resource :: string, ledger = authority.LEDGER, migrations = migrations.all()})
            if not db then error("store") end
            local _, move_error = db:execute("UPDATE bee_resource_associations SET owner_node = 'node-elsewhere' WHERE workspace_id = ? AND name = 'project'", {workspace})
            db:release()
            if move_error then error("move association: " .. tostring(move_error)) end
            test.eq(code(call(placement, "resolve", {grant_id = relocated.grant_id, subject = USER, audience = USER})), "RESOURCE_NOT_LOCAL")
            local reported = value(call(outsider, "capabilities", {}))
            test.eq(reported.resource_authority, "granted")
            test.eq(reported.transfer, false)
        end)
    end)
end
return test.run_cases(define_tests)
