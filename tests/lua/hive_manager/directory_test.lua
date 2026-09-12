-- MIT. The directory: the live form asks the supervisor for presence and
-- stats under the telemetry owner, keeps this node when membership is
-- absent, and refuses desktop listing and attachment without a call.
local test = require("test")
local directory = require("directory")
local types = require("types")
type Object = {[string]: unknown}
local function define_tests()
    test.describe("Hive Manager directory", function()
        test.it("reads client role only from native membership metadata", function()
            local live = directory.live({local_node = "local", lookup = function(): (string?, string?) return nil, nil end,
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
            local live = directory.live({
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
            local live = directory.live({
                local_node = "me",
                lookup = function(): (string?, string?) return "{me@bee.hive:supervisor_host|1}", nil end,
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
            decoded = ({directory.live({local_node = "me", lookup = function(): (string?, string?) return nil, "x" end,
                membership = function(): (unknown, unknown) return hostile, nil end,
                call = function(_owner: types.OwnerRef, _target: types.Target, _input: {[string]: unknown}, _options: {timeout: string?}): types.Reply
                    return types.reply_ok("r", {})
                end}):members()})[1]
            test.eq(#decoded, 2)
            test.eq(decoded[1].node_id, "ok")
            test.eq(decoded[1].addr, "")
            test.eq(decoded[2].node_id, "me")
        end)
        test.it("preserves catalog denial and keeps attachment unavailable", function()
            local live = directory.live({
                local_node = "local",
                lookup = function(): (string?, string?) return "{local@bee.hive:supervisor_host|1}", nil end,
                membership = function(): (unknown, unknown) return {}, nil end,
                call = function(_owner: types.OwnerRef, _target: types.Target, _input: {[string]: unknown}, _options: {timeout: string?}): types.Reply
                    test.eq(_owner.service_id, "bee.desktop")
                    test.eq(_target.operation_ref, "bee.desktop:catalog")
                    return types.reply_error("read", types.fault("DENIED", "not admitted"))
                end,
            })
            local catalog = live:desktops("local")
            test.is_false(catalog.available)
            test.eq(catalog.reason, "DENIED: not admitted")
            test.eq(#catalog.desktops, 0)
            local outcome = live:attach({node_id = "local", workspace_id = "ws", desktop_id = "d", owner_generation = "", mode = "control", idempotency_key = "k"})
            test.is_false(outcome.ok)
            test.eq(outcome.code, "UNSUPPORTED_CAPABILITY")
            test.eq(outcome.message, directory.ATTACH_UNAVAILABLE)
        end)
        test.it("reads the selected owner's durable catalog through the supervisor", function()
            local calls = 0
            local workspace, display = string.rep("b", 32), string.rep("c", 32)
            local live = directory.live({local_node = "local",
                lookup = function(): (string?, string?) return nil, nil end,
                membership = function(): (unknown, unknown) return {}, nil end,
                call = function(owner: types.OwnerRef, target: types.Target, input: Object, _options: {timeout: string?}): types.Reply
                    calls = calls + 1
                    test.eq(owner.node_id, "selected")
                    test.eq(owner.service_id, "bee.desktop")
                    test.eq(target.operation_ref, "bee.desktop:catalog")
                    test.is_nil(next(input))
                    return types.reply_ok("read", {owner_execution = string.rep("a", 32), workspaces = {
                        {workspace_id = workspace, desktops = {{desktop_id = display, is_default = true}}}}})
                end})
            local catalog = live:desktops("selected")
            test.eq(calls, 1)
            test.is_true(catalog.available)
            test.eq(catalog.desktops[1].desktop_id, display)
        end)
        test.it("decodes retained identities without inventing occupancy and rejects authority-bearing or sparse replies", function()
            local execution = string.rep("a", 32)
            local workspace = string.rep("b", 32)
            local display = string.rep("c", 32)
            local function response(items: unknown): Object
                return {owner_execution = execution, workspaces = {{workspace_id = workspace, desktops = items}}}
            end
            local catalog = directory.decode_desktops(response({{desktop_id = display, is_default = true}}))
            test.is_true(catalog.available)
            test.eq(catalog.owner_generation, execution)
            test.eq(catalog.desktops[1].workspace_id, workspace)
            test.eq(catalog.desktops[1].desktop_id, display)
            test.is_nil(catalog.desktops[1].controller)
            test.is_nil(catalog.desktops[1].observers)
            test.is_false(directory.decode_desktops(response({[2] = {desktop_id = display, is_default = true}})).available)
            test.is_false(directory.decode_desktops(response({{desktop_id = display, is_default = true, mount_ref = "secret"}})).available)
            test.is_false(directory.decode_desktops(response({{desktop_id = display, is_default = false}})).available)
            test.is_false(directory.decode_desktops(response({{desktop_id = display, is_default = true}, {desktop_id = display, is_default = false}})).available)
            test.is_false(directory.decode_desktops(response({})).available)
            test.is_false(directory.decode_desktops({owner_execution = execution, workspaces = {}, session_id = "secret"}).available)
        end)
    end)
end
return require("test").run_cases(define_tests)
