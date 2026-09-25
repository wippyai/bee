-- MIT. The directory: the live form asks the supervisor for presence and
-- stats under the telemetry owner, keeps this node when membership is
-- absent, pages a node's workspaces and opens a confirmed attach as a view.
local test = require("test")
local directory = require("directory")
local types = require("types")
type Object = {[string]: unknown}
local function no_view(_request: directory.Attach): directory.Outcome error("this directory opens no remote view") end
local function define_tests()
    test.describe("Hive Manager directory", function()
        test.it("reads client role only from native membership metadata", function()
            local live = directory.live({open_view = no_view, local_node = "local", lookup = function(): (string?, string?) return nil, nil end,
                membership = function(): (unknown, unknown) return {
                    {id = "display", meta = {["bee.role"] = "client"}},
                    {id = "bee-client-name-only", meta = {}},
                    {id = "malformed-role", meta = {["bee.role"] = true}},
                }, nil end,
                call = function(_owner: types.OwnerRef, _target: types.Target, _input: {[string]: unknown}, _options: {timeout: string?}): types.Reply
                    error("Membership decoding must not issue a remote operation")
                end})
            local members = live:members()
            test.is_false(members[1].client_only == true)
            test.is_true(members[2].client_only == true)
            test.is_false(members[3].client_only == true)
            test.is_false(members[4].client_only == true)
        end)
        test.it("asks the supervisor for presence and stats under the telemetry owner and keeps this node without membership", function()
            local calls: {{owner: types.OwnerRef, target: types.Target, timeout: string?}} = {}
            local live = directory.live({open_view = no_view, 
                local_node = "local",
                lookup = function(): (string?, string?) return nil, "supervisor is not running" end,
                membership = function(): (unknown, unknown) return nil, "membership unavailable" end,
                call = function(owner: types.OwnerRef, target: types.Target, _input: {[string]: unknown}, options: {timeout: string?}): types.Reply
                    calls[#calls + 1] = {owner = owner, target = target, timeout = options.timeout}
                    return types.reply_ok("r", {role = "non-member", cluster_size = 1})
                end,
                timeout = "2s",
            })
            local supervisor = live:supervisor()
            test.is_false(supervisor.running)
            test.eq(supervisor.detail, "supervisor is not running")
            local members, problem = live:members()
            test.eq(#members, 1)
            test.eq(members[1].node_id, "local")
            test.is_true(members[1].is_local)
            test.eq(problem, "membership unavailable")
            local presence = live:presence("peer-1")
            test.is_true(presence.ok)
            test.eq(calls[1].owner.node_id, "peer-1")
            test.eq(calls[1].owner.service_id, "bee.hive.telemetry")
            test.eq(calls[1].target.operation_ref, "bee.hive.telemetry:presence")
            test.eq(calls[1].timeout, "2s")
            live:stats("peer-1")
            test.eq(calls[2].target.operation_ref, "bee.hive.telemetry:stats")
        end)
        test.it("decodes runtime membership, bounds it and always includes this node", function()
            local raw: {unknown} = {}
            for index = 1, 70 do raw[#raw + 1] = {id = "n" .. tostring(index), addr = "10.0.0." .. tostring(index) .. ":7946", is_local = false} end
            local live = directory.live({open_view = no_view, 
                local_node = "me",
                lookup = function(): (string?, string?) return "{me@bee.hive_host:supervisor_host|1}", nil end,
                membership = function(): (unknown, unknown) return raw, nil end,
                call = function(_owner: types.OwnerRef, _target: types.Target, _input: {[string]: unknown}, _options: {timeout: string?}): types.Reply
                    return types.reply_ok("r", {})
                end,
            })
            local members, problem = live:members()
            test.eq(#members, directory.MAX_NODES)
            test.eq(members[1].node_id, "me")
            test.is_true(members[1].is_local)
            test.is_true(tostring(problem):find("more than 64", 1, true) ~= nil)
            test.is_true(live:supervisor().running)
            local hostile: {unknown} = {{id = "ok", addr = "bad\27addr"}, {id = ""}, {id = "ok"}, "junk", {id = "me", is_local = true}}
            local decoded = live:members()
            decoded = ({directory.live({open_view = no_view, local_node = "me", lookup = function(): (string?, string?) return nil, "x" end,
                membership = function(): (unknown, unknown) return hostile, nil end,
                call = function(_owner: types.OwnerRef, _target: types.Target, _input: {[string]: unknown}, _options: {timeout: string?}): types.Reply
                    return types.reply_ok("r", {})
                end}):members()})[1]
            test.eq(#decoded, 2)
            test.eq(decoded[1].node_id, "ok")
            test.eq(decoded[1].addr, "")
            test.eq(decoded[2].node_id, "me")
        end)
        test.it("preserves catalog denial and opens a confirmed attach as a remote view", function()
            local opened: {directory.Attach} = {}
            local live = directory.live({
                local_node = "local",
                lookup = function(): (string?, string?) return "{local@bee.hive_host:supervisor_host|1}", nil end,
                membership = function(): (unknown, unknown) return {}, nil end,
                call = function(_owner: types.OwnerRef, _target: types.Target, _input: {[string]: unknown}, _options: {timeout: string?}): types.Reply
                    test.eq(_owner.service_id, "bee.hive_host")
                    test.eq(_target.operation_ref, directory.WORKSPACES)
                    return types.reply_error("read", types.fault("DENIED", "not admitted"))
                end,
                open_view = function(request: directory.Attach): directory.Outcome
                    opened[#opened + 1] = request
                    if request.mode == "observe" then return {ok = false, code = "DENIED", message = "the node does not admit this node's displays"} end
                    return {ok = true, code = "", message = "", session_id = "session-1", mode = "control", viewer = "{local@bee.hive_host.desktop:display_host|9}"}
                end,
            })
            local catalog = live:workspaces("local", {})
            test.is_false(catalog.available)
            test.eq(catalog.reason, "DENIED: not admitted")
            test.eq(#catalog.workspaces, 0)
            local intent: directory.Attach = {node_id = "forge", workspace_id = string.rep("b", 32), owner_generation = "forge",
                mode = "control", idempotency_key = "k"}
            local outcome = live:attach(intent)
            test.is_true(outcome.ok)
            test.eq(outcome.session_id, "session-1")
            test.eq(outcome.viewer, "{local@bee.hive_host.desktop:display_host|9}")
            test.eq(opened[1].node_id, "forge")
            test.eq(opened[1].workspace_id, string.rep("b", 32))
            intent.mode = "observe"
            local refused = live:attach(intent)
            test.is_false(refused.ok)
            test.eq(refused.code, "DENIED")
        end)
        test.it("pages and searches the selected node's workspaces through the supervisor", function()
            local asked: {Object} = {}
            local workspace = string.rep("b", 32)
            local live = directory.live({open_view = no_view, local_node = "local",
                lookup = function(): (string?, string?) return nil, nil end,
                membership = function(): (unknown, unknown) return {}, nil end,
                call = function(owner: types.OwnerRef, target: types.Target, input: Object, _options: {timeout: string?}): types.Reply
                    asked[#asked + 1] = input
                    test.eq(owner.node_id, "selected")
                    test.eq(owner.service_id, "bee.hive_host")
                    test.eq(target.operation_ref, directory.WORKSPACES)
                    return types.reply_ok("read", {node_id = "selected", workspaces = {{workspace_id = workspace, label = "Main", served = true}},
                        next_after = "cursor-2"})
                end})
            local catalog = live:workspaces("selected", {label = "ma", after = "cursor-1"})
            test.eq(#asked, 1)
            local first = asked[1]
            if not first then error("the directory asked nothing") end
            test.eq(first.label, "ma")
            test.eq(first.after, "cursor-1")
            test.eq(first.limit, directory.PAGE)
            test.is_true(catalog.available)
            test.eq(catalog.next_after, "cursor-2")
            test.eq(catalog.workspaces[1].workspace_id, workspace)
            test.eq(catalog.workspaces[1].label, "Main")
            test.eq(catalog.workspaces[1].served, true)
        end)
        test.it("decodes one page of workspaces and rejects authority-bearing, duplicate or sparse replies", function()
            local workspace = string.rep("b", 32)
            local function response(rows: unknown): Object
                return {node_id = "forge", workspaces = rows}
            end
            local catalog = directory.decode_workspaces(response({{workspace_id = workspace, label = "Main", served = false}}))
            test.is_true(catalog.available)
            test.eq(catalog.owner_generation, "forge")
            test.is_nil(catalog.next_after)
            test.eq(catalog.workspaces[1].served, false)
            test.is_true(directory.decode_workspaces(response({})).available)
            -- The folder workspace's catalog row is unnamed; the view names it by identity.
            local unnamed = directory.decode_workspaces(response({{workspace_id = workspace, label = "", served = true}}))
            test.is_true(unnamed.available)
            test.eq(unnamed.workspaces[1].label, "")
            test.is_false(directory.decode_workspaces(response({{workspace_id = workspace, label = "two\nlines", served = false}})).available)
            test.is_false(directory.decode_workspaces(response({[2] = {workspace_id = workspace, label = "Main", served = false}})).available)
            test.is_false(directory.decode_workspaces(response({{workspace_id = workspace, label = "Main", served = false, mount_ref = "secret"}})).available)
            test.is_false(directory.decode_workspaces(response({{workspace_id = workspace, label = "Main", served = false},
                {workspace_id = workspace, label = "Again", served = true}})).available)
            test.is_false(directory.decode_workspaces(response({{workspace_id = "short", label = "Main", served = false}})).available)
            test.is_false(directory.decode_workspaces({node_id = "forge", workspaces = {}, next_after = ""}).available)
            test.is_false(directory.decode_workspaces({node_id = "forge", workspaces = {}, session_id = "secret"}).available)
        end)
    end)
end
return require("test").run_cases(define_tests)
