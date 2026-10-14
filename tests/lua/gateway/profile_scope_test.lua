-- SPDX-License-Identifier: MIT
local test = require("test")
local access = require("access")
local scope = require("scope")
local context = require("context")
local subject_call = require("subject_call")
local bounds = require("bounds")
local security = require("security")
type Object = {[string]: unknown}
local function define_tests()
    test.describe("Saved gateway authority", function()
        test.it("checks nested session definitions and exact owner methods", function()
            local profile = assert(access.decode({mcp = {{tool = "session_open", scope = {definitions = {"bee:agent"}, methods = {"bee.threads.sessions.binding:open"}}}}}))
            test.is_nil(scope.check(profile, "session_open", "bee.threads.sessions.binding:open", "home", {spec = {definition = "bee:agent"}}))
            test.not_nil(scope.check(profile, "session_open", "bee.threads.sessions.binding:open", "home", {spec = {definition = "bee:other"}}))
            test.not_nil(scope.check(profile, "session_close", "bee.threads.sessions.binding:close", "home", {}))
            test.not_nil(scope.check(profile, "session_open", "bee.threads.sessions.binding:run", "home", {spec = {definition = "bee:agent"}}))
        end)
        test.it("requires destination operations and narrowed resource paths", function()
            local profile = assert(access.decode({workspaces = {{workspace_id = "other", operations = {"files:read"}}},
                files = {{workspace_id = "other", resource = "project", subpath = "src", access = "read"}}}))
            test.is_nil(scope.check(profile, "files", "files:read", "home", {workspace_id = "other", resource = "project", subpath = "src/a", access = "read"}))
            test.not_nil(scope.check(profile, "files", "files:read", "home", {workspace_id = "other", resource = "project", subpath = "src-escape", access = "read"}))
            test.not_nil(scope.check(profile, "files", "files:write", "home", {workspace_id = "other", resource = "project", subpath = "src/a", access = "write"}))
        end)
        test.it("checks the destination carried by session and work references", function()
            local operation = "bee.threads.sessions:contract.send"
            local profile = assert(access.decode({workspaces = {{workspace_id = "other", operations = {operation}}}}))
            test.is_nil(scope.check(profile, "session_send", operation, "home", {session = "bs:node:other:id"}))
            test.not_nil(scope.check(profile, "session_send", operation, "home", {workspace_id = "home", session = "bs:node:foreign:id"}))
            test.not_nil(scope.check(profile, "session_cancel", "bee.threads.sessions:contract.cancel", "home", {work = "bw:node:other:id"}))
            test.not_nil(scope.check(profile, "session_join", operation, "home", {works = {"bw:node:home:one", "bw:node:foreign:two"}}))
            profile.mcp = {{tool = "session_send", scope = {workspace_id = "other"}}}
            test.is_nil(scope.check(profile, "session_send", operation, "home", {session = "bs:node:other:id"}))
            test.not_nil(scope.check(profile, "session_send", operation, "home", {session = "bs:node:home:id"}))
        end)
        test.it("supplies admitted grant references through authenticated tool context", function()
            local grants: {context.ResourceGrant} = {{grant_ref = "g", workspace_id = "home", name = "project", subpath = "src", access = "read", subject = "owner"}}
            local binding = {binding_id = "binding", subject = "owner", action_id = "action", attempt_id = "attempt", thread_id = "thread", workspace_id = "home"}
            local executor, failure = subject_call.executor(binding, {assert(security.policy("bee.gateway:profile_context_policy"))}, {}, nil, grants)
            if not executor then error(tostring(failure and failure.error and failure.error.message)) end
            local raw, err = executor:call("bee.gateway:profile_context_probe", {})
            if err then error(tostring(err)) end
            local attributed = assert(bounds.object(raw))
            test.eq(attributed.subject, "owner")
            test.eq(attributed.attempt_id, "attempt")
            local carried = assert(bounds.object(assert(bounds.array(attributed.resource_grants, 64))[1]))
            test.eq(carried.grant_ref, "g")
            test.eq(carried.subpath, "src")
            carried.subpath = "changed"
            test.eq(grants[1].subpath, "src")
            test.is_nil(context.bind({[context.BINDING_KEY] = {resource_grants = grants}}, binding))
        end)
        test.it("revalidates admitted grant identities on every dispatch", function()
            local revoked = false
            local calls = 0
            local function owner(target: string, raw: unknown): (unknown, unknown)
                test.eq(target, "bee.resources.binding:resolve")
                calls = calls + 1
                if revoked then return {ok = false, error = {code = "REVOKED"}}, nil end
                return {ok = true, value = {grant_id = "g", workspace_id = "home", name = "project", subpath = "src", access = "read"}}, nil
            end
            local grants = {{grant_ref = "g", workspace_id = "home", name = "project", subpath = "src", access = "read", subject = "owner"}}
            test.is_nil(scope.revalidate(grants, "attempt", owner))
            revoked = true
            test.not_nil(scope.revalidate(grants, "attempt", owner))
            test.eq(calls, 2)
        end)
    end)
end
return test.run_cases(define_tests)
