-- MIT. The directory: the live form asks the supervisor for presence and
-- stats under the telemetry owner, keeps this node when membership is
-- absent, and refuses desktop listing and attachment without a call; the
-- fixture form decodes strictly, names itself, and never lets control
-- displace a controller.
local test = require("test")
local directory = require("directory")
local types = require("types")
type Object = {[string]: unknown}
local function fixture_data(): Object
    return {label = "review fixture", nodes = {
        {node_id = "forge", is_local = true, addr = "10.0.0.1:7946", reachable = true, role = "leader", cluster_size = 2},
        {node_id = "laptop", is_local = false, reachable = true},
        {node_id = "attic", is_local = false, reachable = false, detail = "peer connection ended"},
    }, catalogs = {
        forge = {available = true, owner_generation = "forge-1", desktops = {{workspace_id = "ws1", desktop_id = "d1", label = "main"}}},
        laptop = {available = true, owner_generation = "laptop-1", desktops = {{workspace_id = "ws2", desktop_id = "d2", controller = "bee.client.laptop", observers = 1}}},
        attic = {available = false, reason = "owner unreachable"},
    }}
end
local function define_tests()
    test.describe("Hive Manager directory", function()
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
            test.eq(live.source, "live")
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
        test.it("refuses desktop listing and attachment without calling anyone", function()
            local live = directory.live({
                local_node = "local",
                lookup = function(): (string?, string?) return "{local@bee.hive:supervisor_host|1}", nil end,
                membership = function(): (unknown, unknown) return {}, nil end,
                call = function(_owner: types.OwnerRef, _target: types.Target, _input: {[string]: unknown}, _options: {timeout: string?}): types.Reply
                    error("no call may be made for desktops")
                end,
            })
            local catalog = live:desktops("local")
            test.is_false(catalog.available)
            test.eq(catalog.reason, directory.DESKTOPS_UNAVAILABLE)
            test.eq(#catalog.desktops, 0)
            local outcome = live:attach({node_id = "local", workspace_id = "ws", desktop_id = "d", owner_generation = "", mode = "control", idempotency_key = "k"})
            test.is_false(outcome.ok)
            test.eq(outcome.code, "UNSUPPORTED_CAPABILITY")
            test.eq(outcome.message, directory.ATTACH_UNAVAILABLE)
        end)
        test.it("decodes a fixture strictly", function()
            local fixture, err = directory.decode_fixture(fixture_data())
            if not fixture then error(tostring(err)) end
            test.eq(fixture.label, "review fixture")
            test.eq(#fixture.nodes, 3)
            test.eq(fixture.catalogs["laptop"].desktops[1].controller, "bee.client.laptop")
            local cases: {{data: Object, expected: string}} = {}
            local function case(mutate: (Object) -> (), expected: string)
                local data = fixture_data()
                mutate(data)
                cases[#cases + 1] = {data = data, expected = expected}
            end
            case(function(data: Object) data.extra = true end, "unknown field extra")
            case(function(data: Object) data.label = "a\nb" end, "fixture label must be one bounded line")
            local function node(data: Object, index: integer): Object
                local nodes = data.nodes :: {Object}
                return nodes[index]
            end
            local function catalogs(data: Object): Object
                return data.catalogs :: Object
            end
            case(function(data: Object) node(data, 2).is_local = true end, "fixture names exactly one local node")
            case(function(data: Object) node(data, 2).node_id = "forge" end, "fixture repeats node forge")
            case(function(data: Object) node(data, 2).reachable = "yes" end, "node reachable must be a boolean")
            case(function(data: Object) catalogs(data).cellar = {available = true} end, "fixture catalog for unknown node cellar")
            case(function(data: Object) catalogs(data).attic = {available = false} end, "an unavailable catalog names its reason")
            local function forge(data: Object): Object
                local catalogs = data.catalogs :: Object
                return catalogs.forge :: Object
            end
            case(function(data: Object) forge(data).desktops = {{workspace_id = "ws1", desktop_id = "d1"}, {workspace_id = "ws1", desktop_id = "d1"}} end, "catalog repeats a desktop")
            case(function(data: Object) forge(data).desktops = {{workspace_id = "ws1", desktop_id = "d1", observers = 17}} end, "desktop observers must be 0 to 16")
            case(function(data: Object) forge(data).owner_generation = nil end, "an available catalog names its owner generation")
            for _, item in ipairs(cases) do
                local decoded, decode_error = directory.decode_fixture(item.data)
                test.is_nil(decoded)
                test.is_true(tostring(decode_error):find(item.expected, 1, true) ~= nil, item.expected .. " vs " .. tostring(decode_error))
            end
            local absent = directory.decode_fixture(nil)
            test.is_nil(absent)
        end)
        test.it("replays the fixture and never lets control displace a controller", function()
            local fixture = directory.decode_fixture(fixture_data())
            if not fixture then error("fixture") end
            local replay = directory.fixture(fixture)
            test.eq(replay.source, "fixture")
            test.is_true(replay:supervisor().running)
            local members = replay:members()
            test.eq(#members, 3)
            test.is_true(replay:presence("forge").ok)
            local down = replay:presence("attic")
            test.is_false(down.ok)
            test.eq(down.error and down.error.message, "peer connection ended")
            test.eq(replay:presence("unknown").error and replay:presence("unknown").error.code, "UNAVAILABLE")
            test.is_false(replay:desktops("attic").available)
            test.is_false(replay:desktops("nowhere").available)
            local conflict = replay:attach({node_id = "laptop", workspace_id = "ws2", desktop_id = "d2", owner_generation = "laptop-1", mode = "control", idempotency_key = "k-1"})
            test.is_false(conflict.ok)
            test.eq(conflict.code, "CONFLICT")
            local observed = replay:attach({node_id = "laptop", workspace_id = "ws2", desktop_id = "d2", owner_generation = "laptop-1", mode = "observe", idempotency_key = "k-2"})
            test.is_true(observed.ok)
            test.eq(observed.mode, "observe")
            test.eq(replay:desktops("laptop").desktops[1].observers, 2)
            local controlled = replay:attach({node_id = "forge", workspace_id = "ws1", desktop_id = "d1", owner_generation = "forge-1", mode = "control", idempotency_key = "k-3"})
            test.is_true(controlled.ok)
            test.eq(replay:desktops("forge").desktops[1].controller, "bee.hive_manager")
            local missing = replay:attach({node_id = "forge", workspace_id = "ws1", desktop_id = "nope", owner_generation = "forge-1", mode = "observe", idempotency_key = "k-4"})
            test.eq(missing.code, "NOT_FOUND")
            test.eq(replay:attach({node_id = "attic", workspace_id = "ws", desktop_id = "d", owner_generation = "x", mode = "observe", idempotency_key = "k-5"}).code, "UNAVAILABLE")
        end)
        test.it("refuses a stale catalog generation and replays an identical request without a second session", function()
            local fixture = directory.decode_fixture(fixture_data())
            if not fixture then error("fixture") end
            local replay = directory.fixture(fixture)
            local stale = replay:attach({node_id = "forge", workspace_id = "ws1", desktop_id = "d1", owner_generation = "forge-0", mode = "observe", idempotency_key = "k-1"})
            test.eq(stale.code, "CONFLICT")
            test.is_true(stale.message:find("owner generation changed", 1, true) ~= nil)
            local first = replay:attach({node_id = "forge", workspace_id = "ws1", desktop_id = "d1", owner_generation = "forge-1", mode = "observe", idempotency_key = "k-2"})
            test.is_true(first.ok)
            local again = replay:attach({node_id = "forge", workspace_id = "ws1", desktop_id = "d1", owner_generation = "forge-1", mode = "observe", idempotency_key = "k-2"})
            test.eq(again.session_id, first.session_id)
            test.eq(replay:desktops("forge").desktops[1].observers, 1)
            local reused = replay:attach({node_id = "forge", workspace_id = "ws1", desktop_id = "d1", owner_generation = "forge-1", mode = "control", idempotency_key = "k-2"})
            test.eq(reused.code, "CONFLICT")
            test.is_true(reused.message:find("already used", 1, true) ~= nil)
        end)
    end)
end
return require("test").run_cases(define_tests)
