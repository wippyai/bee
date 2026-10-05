-- MIT. The node workspace catalog: a workspace's row under the root its
-- folder lies in, the roots the node admits, and one page of a folder's
-- folders with the workspace that holds each. Every operation authorizes its
-- caller first, and an app reaches it from inside the application boundary.
local test = require("test")
local funcs = require("funcs")
local security = require("security")
local bounds = require("bounds")
local client = require("client")
local system = require("system")
local app_scope = require("app_scope")

type Object = {[string]: unknown}

local READ_POLICY = "bee.node.security:workspace_folder_read_policy"
local BROWSE_POLICY = "bee.node.security:workspace_folder_browse_policy"

local function home(): client.Workspace
    local value, err = client.call(assert(system.node.id()), "watch", {})
    if not value then error("watch: " .. tostring(err)) end
    local state = assert(client.state(value))
    for _, workspace in ipairs(state.workspaces) do
        if workspace.id == state.home then return workspace end
    end
    error("no home workspace")
end

local function caller(workspace_id: string, policies: {string}): funcs.Executor
    local actor = assert(security.new_actor("bee.application:" .. workspace_id .. ":catalog-test",
        {workspace_id = workspace_id}))
    return funcs.new():with_actor(actor):with_scope(app_scope.boundary(policies))
end

local function call(executor: funcs.Executor, target: string, request: Object): Object
    local raw, err = executor:call(target, request)
    test.is_nil(err, tostring(err))
    return assert(bounds.object(raw))
end

local function value(reply: Object): Object
    if reply.ok ~= true then
        local fault = bounds.object(reply.error) or {}
        error(tostring(fault.code) .. ": " .. tostring(fault.message))
    end
    return assert(bounds.object(reply.value))
end

local function define_tests()
    test.describe("node workspace catalog", function()
        test.it("reads a workspace as its folder under the admitted root, from inside the application boundary", function()
            local workspace = home()
            local reply = value(call(caller(workspace.id, {READ_POLICY}), "bee.node.binding:read", {workspace_id = workspace.id}))
            local row = assert(bounds.object(reply.workspace))
            test.eq(row.workspace_id, workspace.id)
            test.eq(row.label, workspace.label)
            test.eq(row.root_ref, "bee.node:machine")
            test.eq("/" .. tostring(row.subpath), workspace.path)
        end)

        test.it("refuses a caller without the workspace read grant", function()
            local workspace = home()
            local reply = call(caller(workspace.id, {}), "bee.node.binding:read", {workspace_id = workspace.id})
            test.is_false(reply.ok == true)
            test.eq((assert(bounds.object(reply.error))).code, "DENIED")
        end)

        test.it("lists the admitted roots with their access", function()
            local workspace = home()
            local roots = value(call(caller(workspace.id, {READ_POLICY}), "bee.node.binding:roots", {}))
            local listed = assert(bounds.array(roots.roots, 8))
            test.eq(#listed, 1)
            local root = assert(bounds.object(listed[1]))
            test.eq(root.root_ref, "bee.node:machine")
            test.eq(root.access, "write")
        end)

        test.it("pages a folder's folders and names the workspace that holds one", function()
            local workspace = home()
            local parent, name = workspace.path:match("^/(.*)/([^/]+)$")
            assert(parent and name, "home folder has no parent: " .. workspace.path)
            local executor = caller(workspace.id, {BROWSE_POLICY})
            local page = value(call(executor, "bee.node.binding:folders", {root_ref = "bee.node:machine", path = parent, limit = 100}))
            test.eq(page.root_ref, "bee.node:machine")
            test.eq(page.path, parent)
            test.eq(page.access, "write")
            local held: string? = nil
            local after: string? = nil
            local pages = 0
            local current = page
            while true do
                for _, raw in ipairs(assert(bounds.array(current.folders, 100))) do
                    local folder = assert(bounds.object(raw))
                    if folder.name == name then held = folder.workspace_id :: string? end
                end
                after = current.next_after :: string?
                pages = pages + 1
                if not after or held or pages > 50 then break end
                current = value(call(executor, "bee.node.binding:folders",
                    {root_ref = "bee.node:machine", path = parent, after = after, limit = 100}))
            end
            test.eq(held, workspace.id)
            local inside = value(call(executor, "bee.node.binding:folders",
                {root_ref = "bee.node:machine", path = parent .. "/" .. name, limit = 1}))
            test.eq(inside.workspace_id, workspace.id)
        end)

        test.it("refuses to browse without the browse grant or under a root the node does not admit", function()
            local workspace = home()
            local denied = call(caller(workspace.id, {READ_POLICY}), "bee.node.binding:folders",
                {root_ref = "bee.node:machine", path = "", limit = 1})
            test.eq((assert(bounds.object(denied.error))).code, "DENIED")
            local foreign = call(caller(workspace.id, {BROWSE_POLICY}), "bee.node.binding:folders",
                {root_ref = "bee.env:workspace_root", path = "", limit = 1})
            test.is_false(foreign.ok == true)
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options: unknown) return cases(options) end}
